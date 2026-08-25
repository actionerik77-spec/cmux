import AppKit
import CmuxControlSocket
import CmuxCore
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for https://github.com/manaflow-ai/cmux/issues/7939 /
/// https://github.com/manaflow-ai/cmux/issues/5781: a notification addressed
/// with a stale workspace id but a live surface id must be retargeted to the
/// surface's CURRENT workspace at delivery time — not dropped (async path) and
/// not recorded against the stale workspace (sync path). The unread ring and
/// the stored notification must land on the pane that owns the surface.
extension AgentNotificationRegressionTests {
    private struct LiveRetargetFixture {
        let store: TerminalNotificationStore
        let appDelegate: AppDelegate
        let manager: TabManager
        let claimedWorkspace: Workspace
        let owningWorkspace: Workspace
        let panelId: UUID
        let restore: () -> Void
    }

    private func makeLiveRetargetFixture() throws -> LiveRetargetFixture {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let claimedWorkspace = manager.addWorkspace(select: false)
        let owningWorkspace = manager.addWorkspace(select: true)
        let panelId = try #require(owningWorkspace.focusedPanelId)

        let restore = {
            for workspace in [claimedWorkspace, owningWorkspace] where manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }
        return LiveRetargetFixture(
            store: store,
            appDelegate: appDelegate,
            manager: manager,
            claimedWorkspace: claimedWorkspace,
            owningWorkspace: owningWorkspace,
            panelId: panelId,
            restore: restore
        )
    }

    @Test
    func testQueuedNotificationRetargetsToSurfaceCurrentWorkspace() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // Claimed workspace is stale (e.g. captured at spawn, pane since moved):
        // the surface lives in `owningWorkspace`.
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "All done"
        )
        TerminalMutationBus.shared.drainForTesting()

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        #expect(
            recorded.map(\.tabId) == [fixture.owningWorkspace.id],
            "Queued notification must be retargeted to the surface's current workspace, not dropped or misfiled"
        )
        #expect(recorded.first?.surfaceId == fixture.panelId)
        #expect(
            fixture.store.hasUnreadNotification(forTabId: fixture.owningWorkspace.id, surfaceId: fixture.panelId),
            "Unread ring must appear on the pane that owns the surface"
        )
        #expect(
            !fixture.store.hasUnreadNotification(forTabId: fixture.claimedWorkspace.id, surfaceId: fixture.panelId),
            "Unread ring must not appear under the stale workspace"
        )
    }

    @Test
    func testSyncDeliveredNotificationRetargetsToSurfaceCurrentWorkspace() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        TerminalController.shared.deliverNotificationSynchronously(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "All done"
        )

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        #expect(
            recorded.map(\.tabId) == [fixture.owningWorkspace.id],
            "Synchronously delivered notification must be recorded under the surface's current workspace"
        )
        #expect(recorded.first?.surfaceId == fixture.panelId)
        #expect(
            fixture.store.hasUnreadNotification(forTabId: fixture.owningWorkspace.id, surfaceId: fixture.panelId)
        )
    }

    @Test
    func testTransientAttentionAndNotificationUseSurfaceCurrentWorkspace() throws {
        let fixture = try makeLiveRetargetFixture()
        let sessionId = "moved-transient-session"
        let requestId = "moved-transient-request"
        defer {
            _ = FeedCoordinator.shared.endTransientBlockingAttention(
                source: "claude",
                sessionId: sessionId,
                requestId: requestId
            )
            TerminalMutationBus.shared.drainForTesting()
            fixture.restore()
        }
        let processIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))

        let began = FeedCoordinator.shared.beginTransientBlockingAttention(
            source: "claude",
            sessionId: sessionId,
            requestId: requestId,
            workspaceId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            owner: .localProcess(processIdentity),
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Waiting for input"
        )
        TerminalMutationBus.shared.drainForTesting()

        let attentionKey = FeedCoordinator.attentionStatusKey(forSource: "claude")
        #expect(began)
        #expect(
            fixture.owningWorkspace.agentLifecycleStatesByPanelId[fixture.panelId]?[attentionKey]
                == .needsInput
        )
        #expect(
            fixture.owningWorkspace.agentHibernationLifecycleState(
                panelId: fixture.panelId,
                fallback: nil
            ) == .needsInput
        )
        #expect(
            fixture.owningWorkspace.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"]
                == nil,
            "transient attention must not overwrite the agent-owned lifecycle slot"
        )
        #expect(
            fixture.claimedWorkspace.agentLifecycleStatesByPanelId.values
                .allSatisfy { $0[attentionKey] == nil && $0["claude_code"] == nil },
            "transient attention must not mutate the stale claimed workspace"
        )
        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        #expect(recorded.map(\.tabId) == [fixture.owningWorkspace.id])
        #expect(recorded.first?.surfaceId == fixture.panelId)

        #expect(FeedCoordinator.shared.endTransientBlockingAttention(
            source: "claude",
            sessionId: sessionId,
            requestId: requestId
        ))
        TerminalMutationBus.shared.drainForTesting()
        #expect(
            fixture.owningWorkspace.agentLifecycleStatesByPanelId[fixture.panelId]?[attentionKey]
                == nil
        )
        #expect(fixture.store.notifications.allSatisfy { $0.title != "Claude Code" })
    }

    @Test
    func testTransientAttentionFailsClosedWhenSurfaceDisappeared() throws {
        let fixture = try makeLiveRetargetFixture()
        let sessionId = "missing-transient-session"
        let requestId = "missing-transient-request"
        defer {
            _ = FeedCoordinator.shared.endTransientBlockingAttention(
                source: "claude",
                sessionId: sessionId,
                requestId: requestId
            )
            TerminalMutationBus.shared.drainForTesting()
            fixture.restore()
        }
        let processIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))

        let began = FeedCoordinator.shared.beginTransientBlockingAttention(
            source: "claude",
            sessionId: sessionId,
            requestId: requestId,
            workspaceId: fixture.claimedWorkspace.id,
            surfaceId: UUID(),
            owner: .localProcess(processIdentity),
            title: "Missing transient",
            subtitle: "Waiting",
            body: "Waiting for input"
        )
        TerminalMutationBus.shared.drainForTesting()

        #expect(!began)
        #expect(fixture.store.notifications.allSatisfy { $0.title != "Missing transient" })
    }

    @Test
    func testRelayTransientAttentionFollowsMovedSurfaceAndScopesReleaseToOwner() throws {
        let fixture = try makeLiveRetargetFixture()
        let remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        fixture.claimedWorkspace.remoteConfiguration = remoteConfiguration
        fixture.owningWorkspace.remoteConfiguration = remoteConfiguration

        let sessionId = "relay-transient-session"
        let requestId = "relay-transient-request"
        defer {
            _ = FeedCoordinator.shared.endTransientBlockingAttention(
                source: "claude",
                sessionId: sessionId,
                authenticatedRemoteWorkspaceId: fixture.claimedWorkspace.id
            )
            TerminalMutationBus.shared.drainForTesting()
            fixture.restore()
        }
        let beginResult = TerminalController.shared.v2FeedTransientAttentionBegin(params: [
            "source": "claude",
            "session_id": sessionId,
            "request_id": requestId,
            "workspace_id": fixture.owningWorkspace.id.uuidString,
            "surface_id": fixture.panelId.uuidString,
            "title": "Remote Claude Code",
            "subtitle": "Waiting",
            "body": "Waiting for input",
            "_cmux_remote_workspace_id": fixture.claimedWorkspace.id.uuidString,
        ])
        guard case .ok(let beginPayload) = beginResult,
              let begin = beginPayload as? [String: Any] else {
            Issue.record("Expected relay attention begin, got \(beginResult)")
            return
        }
        #expect(begin["active"] as? Bool == true)
        TerminalMutationBus.shared.drainForTesting()

        let notification = try #require(
            fixture.store.notifications.first { $0.title == "Remote Claude Code" }
        )
        #expect(notification.tabId == fixture.owningWorkspace.id)
        #expect(!notification.persistsInSessionSnapshot)
        let snapshot = fixture.owningWorkspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(
            snapshot.panels.first { $0.id == fixture.panelId }
        )
        #expect(panelSnapshot.notifications?.isEmpty ?? true)
        #expect(panelSnapshot.hasUnreadIndicator != true)
        #expect(snapshot.hasUnreadIndicator != true)

        var preservedConfiguration = remoteConfiguration
        preservedConfiguration.preserveAfterTerminalExit = true
        fixture.owningWorkspace.remoteConfiguration = preservedConfiguration
        #expect(
            fixture.owningWorkspace.markRemoteTerminalSessionEnded(
                surfaceId: fixture.panelId,
                relayPort: nil,
                allowUntracked: true
            )
        )
        TerminalMutationBus.shared.drainForTesting()
        #expect(
            fixture.store.notifications.contains { $0.id == notification.id },
            "A recoverable remote PTY disconnect must not clear live transient attention"
        )

        let wrongOwnerResult = TerminalController.shared.v2FeedTransientAttentionEnd(params: [
            "source": "claude",
            "session_id": sessionId,
            "request_id": requestId,
            "_cmux_remote_workspace_id": fixture.owningWorkspace.id.uuidString,
        ])
        guard case .ok(let wrongOwnerPayload) = wrongOwnerResult,
              let wrongOwner = wrongOwnerPayload as? [String: Any] else {
            Issue.record("Expected owner-scoped no-op, got \(wrongOwnerResult)")
            return
        }
        #expect(wrongOwner["ended"] as? Bool == false)
        #expect(fixture.store.notifications.contains { $0.id == notification.id })

        let endResult = TerminalController.shared.v2FeedTransientAttentionEnd(params: [
            "source": "claude",
            "session_id": sessionId,
            "all_requests": true,
            "_cmux_remote_workspace_id": fixture.claimedWorkspace.id.uuidString,
        ])
        guard case .ok(let endPayload) = endResult,
              let end = endPayload as? [String: Any] else {
            Issue.record("Expected session-wide relay attention release, got \(endResult)")
            return
        }
        #expect(end["ended"] as? Bool == true)
        TerminalMutationBus.shared.drainForTesting()
        #expect(!fixture.store.notifications.contains { $0.id == notification.id })
    }

    @Test(arguments: ["feed.attention.begin", "feed.attention.end"])
    func testRelayStampsTransientAttentionOwner(method: String) throws {
        let authenticatedWorkspaceId = UUID()
        let request: [String: Any] = [
            "id": "relay-attention",
            "method": method,
            "params": [
                "source": "claude",
                "session_id": "relay-session",
                "request_id": "relay-request",
                "_cmux_remote_workspace_id": UUID().uuidString,
            ],
        ]
        let rewritten = WorkspaceRemoteRelayCommandRewriter(
            remoteWorkspaceID: authenticatedWorkspaceId,
            remoteRelayTokenHex: String(repeating: "a", count: 64)
        ).rewriteRemoteRelayCommandLine(
            try JSONSerialization.data(withJSONObject: request),
            workspaceAliases: [:],
            surfaceAliases: [:]
        )
        let rewrittenRequest = try #require(
            JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        let params = try #require(rewrittenRequest["params"] as? [String: Any])

        #expect(
            params["_cmux_remote_workspace_id"] as? String
                == authenticatedWorkspaceId.uuidString
        )
    }

    @Test
    func testSyncDeliverySupersedesPendingNotificationUnderStaleClaimedKey() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // An older async notification still queued under the stale claimed
        // workspace key...
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Working",
            body: "Old queued"
        )
        // ...must be superseded by a newer synchronous notification for the
        // same surface, even though sync delivery retargets to the owning
        // workspace — a different queue key than the stale claim.
        TerminalController.shared.deliverNotificationSynchronously(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "New sync"
        )
        TerminalMutationBus.shared.drainForTesting()

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        #expect(
            recorded.map(\.body) == ["New sync"],
            "A stale-keyed pending notification must not survive (or replace) the newer synchronous one for the same surface"
        )
        #expect(recorded.map(\.tabId) == [fixture.owningWorkspace.id])
    }

    @Test
    func testResolveDeliveryTargetRejectsOutOfRangePid() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // A 64-bit pid beyond pid_t range (any socket caller controls this
        // value) must neither trap nor fall through to a different routing
        // claim supplied in the same untrusted request.
        let result = TerminalController.shared.v2AgentResolveDeliveryTarget(params: [
            "pid": Int(Int32.max) + 1,
            "surface_id": fixture.panelId.uuidString,
        ])
        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid_params for an out-of-range pid, got \(result)")
            return
        }
        #expect(code == "invalid_params")
    }

    @Test
    func testRelayTTYResolutionStaysInsideAuthenticatedWorkspace() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        let remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        fixture.claimedWorkspace.remoteConfiguration = remoteConfiguration
        fixture.owningWorkspace.remoteConfiguration = remoteConfiguration
        let siblingPanelID = try #require(fixture.claimedWorkspace.focusedPanelId)
        fixture.claimedWorkspace.trackRemoteTerminalSurface(siblingPanelID)
        fixture.owningWorkspace.trackRemoteTerminalSurface(fixture.panelId)
        fixture.claimedWorkspace.registerReportedSurfaceTTYName("0", panelId: siblingPanelID)
        fixture.owningWorkspace.registerReportedSurfaceTTYName("0", panelId: fixture.panelId)

        let result = TerminalController.shared.v2AgentResolveDeliveryTarget(params: [
            "tty_name": "0",
            "tty_resolution": "reported_tty",
            "workspace_id": fixture.claimedWorkspace.id.uuidString,
            "_cmux_remote_workspace_id": fixture.owningWorkspace.id.uuidString,
        ])
        guard case .ok(let payload) = result,
              let target = payload as? [String: Any] else {
            Issue.record("Expected authenticated relay TTY resolution, got \(result)")
            return
        }
        #expect(target["source"] as? String == "tty")
        #expect(target["tty_resolution"] as? String == "reported_tty")
        #expect(target["workspace_id"] as? String == fixture.owningWorkspace.id.uuidString)
        #expect(target["surface_id"] as? String == fixture.panelId.uuidString)
    }

    @Test
    func testSurfaceScopedClearDiscardsStaleKeyedPendingNotification() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // Queued under the stale claimed workspace key...
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale queued"
        )
        // ...then the pane (live workspace) is cleared BEFORE the queue
        // drains: the stale-keyed pending entry must not outlive the clear
        // and resurrect the notification the user just dismissed.
        fixture.store.clearNotifications(
            forTabId: fixture.owningWorkspace.id,
            surfaceId: fixture.panelId
        )
        TerminalMutationBus.shared.drainForTesting()

        #expect(
            fixture.store.notifications.filter { $0.title == "Claude Code" }.isEmpty,
            "A cleared pane must stay cleared; the stale-keyed pending entry must not deliver after the clear"
        )
        #expect(
            !fixture.store.hasUnreadNotification(forTabId: fixture.owningWorkspace.id, surfaceId: fixture.panelId)
        )
    }

    @Test
    func testWorkspaceWideClearDiscardsStaleKeyedPendingNotification() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // Queued under a stale claimed workspace, but its surface's CURRENT
        // owner is the workspace being cleared: a tab-wide clear must drop it
        // (drain-time delivery would retarget it right back into the cleared
        // workspace).
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale queued"
        )
        fixture.store.clearNotifications(forTabId: fixture.owningWorkspace.id)
        TerminalMutationBus.shared.drainForTesting()

        #expect(
            fixture.store.notifications.filter { $0.title == "Claude Code" }.isEmpty,
            "A tab-wide clear of the live workspace must discard stale-keyed pending entries destined for it"
        )
        #expect(
            !fixture.store.hasUnreadNotification(forTabId: fixture.owningWorkspace.id, surfaceId: fixture.panelId)
        )
    }

    @Test
    func testWorkspaceWideClearPreservesNotificationRetargetedAwayFromClearedWorkspace() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // The enqueue-time workspace is stale and is the one being cleared,
        // but delivery follows the surface to `owningWorkspace`. Clearing the
        // old workspace must not discard a notification whose live owner is a
        // different workspace.
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Moved away"
        )
        fixture.store.clearNotifications(forTabId: fixture.claimedWorkspace.id)
        TerminalMutationBus.shared.drainForTesting()

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        #expect(recorded.map(\.tabId) == [fixture.owningWorkspace.id])
        #expect(recorded.first?.surfaceId == fixture.panelId)
    }

    @Test
    func testAsyncTabWideClearEndsWithNoResurrectedNotification() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // v1 `clear_notifications --tab` path: the bus is FIFO, so the
        // stale-keyed entry drains (retargeted into the live workspace)
        // BEFORE the clear barrier wipes the store — end state must be clean.
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale queued"
        )
        TerminalMutationBus.shared.enqueueClearNotifications(forTabId: fixture.owningWorkspace.id)
        TerminalMutationBus.shared.drainForTesting()

        #expect(
            fixture.store.notifications.filter { $0.title == "Claude Code" }.isEmpty,
            "An async tab-wide clear must not leave a resurrected notification behind"
        )
    }

    @Test
    func testAsyncSurfaceScopedClearDiscardsStaleKeyedPendingNotification() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // Same resurrection race as the store-clear test, via the async
        // `clear_notifications --tab --panel` socket path.
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale queued"
        )
        TerminalMutationBus.shared.enqueueClearNotifications(
            forTabId: fixture.owningWorkspace.id,
            surfaceId: fixture.panelId
        )
        TerminalMutationBus.shared.drainForTesting()

        #expect(
            fixture.store.notifications.filter { $0.title == "Claude Code" }.isEmpty,
            "An async surface-scoped clear must discard the stale-keyed pending entry, not let it re-deliver"
        )
    }

    @Test
    func testCreateForCallerFollowsMovedPreferredSurface() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // `cmux notify` from a moved pane: spawn-time CMUX_WORKSPACE_ID is
        // stale but CMUX_SURFACE_ID is the pane's stable identity — the
        // notification must follow the surface, not fall back to the stale
        // workspace's focused pane.
        let result = TerminalController.shared.v2NotificationCreateForCaller(params: [
            "preferred_workspace_id": fixture.claimedWorkspace.id.uuidString,
            "preferred_surface_id": fixture.panelId.uuidString,
            "title": "Caller notify",
            "body": "Body",
        ])
        guard case .ok(let payload) = result, let dict = payload as? [String: Any] else {
            Issue.record("Expected delivery, got \(result)")
            return
        }
        #expect((dict["workspace_id"] as? String) == fixture.owningWorkspace.id.uuidString)
        #expect((dict["surface_id"] as? String) == fixture.panelId.uuidString)
        let recorded = fixture.store.notifications.filter { $0.title == "Caller notify" }
        #expect(recorded.map(\.tabId) == [fixture.owningWorkspace.id])
        #expect(recorded.first?.surfaceId == fixture.panelId)
    }

    @Test
    func testCreateForTargetRejectsSurfaceOutsideClaimedWorkspace() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // SECURITY boundary: `notification.create_for_target` is reachable
        // through the cloud relay, whose authorization only pins workspace_id
        // to the relay's owner workspace. The membership guard here is what
        // confines a relay caller to that workspace — it must NOT re-home a
        // surface owned by another workspace (a leaked pane UUID would allow
        // cross-workspace injection).
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: fixture.claimedWorkspace.id,
            surfaceID: nil,
            paneID: nil
        )
        let resolution = TerminalController.shared.controlNotificationCreateForTarget(
            routing: routing,
            workspaceID: fixture.claimedWorkspace.id,
            surfaceID: fixture.panelId,
            title: "Target notify",
            subtitle: "",
            body: "Body"
        )
        #expect(
            resolution == .surfaceNotFound(fixture.panelId),
            "create_for_target must stay confined to the claimed workspace (relay authorization boundary)"
        )
        #expect(fixture.store.notifications.filter { $0.title == "Target notify" }.isEmpty)
    }

    @Test
    func testCreateForSurfaceFollowsMovedSurface() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // `notification.create_for_surface` is local-only (not relay-
        // reachable), so a moved surface follows its live owner — including
        // when the claimed routing workspace no longer lists it.
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: fixture.claimedWorkspace.id,
            surfaceID: nil,
            paneID: nil
        )
        #expect(TerminalController.shared.controlNotificationCreate(
            routing: routing,
            explicitSurfaceID: fixture.panelId,
            title: "Primary notify",
            subtitle: "",
            body: "Body"
        ) == .delivered(workspaceID: fixture.owningWorkspace.id, surfaceID: fixture.panelId))
        let resolution = TerminalController.shared.controlNotificationCreateForSurface(
            routing: routing,
            surfaceID: fixture.panelId,
            title: "Surface notify",
            subtitle: "",
            body: "Body"
        )
        guard case .delivered(let workspaceID, let surfaceID, _) = resolution else {
            Issue.record("A moved surface must be re-homed, not rejected; got \(resolution)")
            return
        }
        #expect(workspaceID == fixture.owningWorkspace.id)
        #expect(surfaceID == fixture.panelId)
        let recorded = fixture.store.notifications.filter { $0.title == "Surface notify" }
        #expect(recorded.map(\.tabId) == [fixture.owningWorkspace.id])
    }

    @Test
    func testRebindKeepsNewerDestinationKeyedPendingNotification() throws {
        let fixture = try makeLiveRetargetFixture()
        defer { fixture.restore() }

        // Mid-move race: the destination already owns the surface and a hook
        // enqueues a valid notification under the destination key BEFORE
        // rebind runs. Rebind processing must not drop it.
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.owningWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Destination queued"
        )
        fixture.store.rebindSurfaceNotifications(
            fromTabId: fixture.claimedWorkspace.id,
            toTabId: fixture.owningWorkspace.id,
            surfaceId: fixture.panelId
        )
        TerminalMutationBus.shared.drainForTesting()

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        #expect(
            recorded.map(\.body) == ["Destination queued"],
            "Rebind must preserve a newer destination-keyed pending entry"
        )
        #expect(recorded.map(\.tabId) == [fixture.owningWorkspace.id])
    }

    @Test
    func pidSignalCombiningUsesExactProcessEnvironmentFallback() {
        let tty = AgentDeliveryTargetCandidate(workspaceId: UUID(), surfaceId: UUID())
        let otherEnv = AgentDeliveryTargetCandidate(workspaceId: UUID(), surfaceId: UUID())
        #expect(agentDeliveryTargetCombining(ttyTarget: tty, envTarget: nil) == tty)
        #expect(
            agentDeliveryTargetCombining(
                ttyTarget: tty,
                envTarget: AgentDeliveryTargetCandidate(workspaceId: otherEnv.workspaceId, surfaceId: tty.surfaceId)
            ) == tty,
            "A corroborating env surface keeps the tty answer"
        )
        #expect(
            agentDeliveryTargetCombining(ttyTarget: tty, envTarget: otherEnv) == nil,
            "Disagreement between two individually stale-able signals must fail closed"
        )
        #expect(
            agentDeliveryTargetCombining(ttyTarget: nil, envTarget: otherEnv) == otherEnv,
            "A start-time-keyed live process environment must resolve nested-PTY sessions whose controlling TTY differs"
        )
        #expect(agentDeliveryTargetCombining(ttyTarget: nil, envTarget: nil) == nil)
    }

    @Test
    func testTTYDeviceMatchRequiresUniqueSurface() throws {
        let workspace = Workspace(), panel = try #require(workspace.focusedPanelId)
        workspace.registerReportedSurfaceTTYName("/dev/null", panelId: panel)
        #expect(workspace.surfaceTTYDevices[panel] == CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: "/dev/null"))
        let w1 = UUID(), s1 = UUID(), w2 = UUID(), s2 = UUID()
        let bindings: [(workspaceId: UUID, surfaceId: UUID, ttyDevice: Int64)] = [
            (workspaceId: w1, surfaceId: s1, ttyDevice: 7),
            (workspaceId: w2, surfaceId: s2, ttyDevice: 9),
        ]
        #expect(
            agentDeliveryTargetMatchingTTYDevice(7, surfaceTTYDevices: bindings)
                == AgentDeliveryTargetCandidate(workspaceId: w1, surfaceId: s1)
        )
        #expect(agentDeliveryTargetMatchingTTYDevice(5, surfaceTTYDevices: bindings) == nil)
        #expect(
            agentDeliveryTargetMatchingTTYDevice(
                7,
                surfaceTTYDevices: bindings + [(workspaceId: w2, surfaceId: s2, ttyDevice: 7)]
            ) == nil,
            "A tty device claimed by two different surfaces must refuse to guess"
        )
        #expect(
            agentDeliveryTargetMatchingTTYDevice(
                7,
                surfaceTTYDevices: bindings + [(workspaceId: w1, surfaceId: s1, ttyDevice: 7)]
            )?.surfaceId == s1,
            "Consistent duplicate rows for the same surface still resolve"
        )
    }

}
