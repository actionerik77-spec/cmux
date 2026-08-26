import CryptoKit
import Foundation

extension CMUXCLI {
    enum ClaudeBlockingAttentionBeginResult: Equatable {
        case active
        case unavailable
        case uncertain
        case rejected
    }

    private static let legacyClaudeBlockingAttentionRequestId = "legacy-session-blocker"
    /// Synchronous Claude hooks have five-second deadlines for their targeted
    /// blocking transitions; leave room for parsing and the final ack.
    private static let claudeBlockingAttentionResponseTimeout: TimeInterval = 1
    /// Session/turn cleanup also runs from Claude's one-second SessionEnd hook.
    private static let claudeBlockingAttentionTurnBoundaryTimeout: TimeInterval = 0.5

    func claudeBlockingAttentionRequestId(
        toolUseId: String?
    ) -> String {
        nonEmptyClaudeHookIdentifier(toolUseId)
            ?? Self.legacyClaudeBlockingAttentionRequestId
    }

    /// Hashes a session into the stable key for its native permission row.
    func claudePermissionNotificationCorrelationKey(
        sessionId: String
    ) -> String? {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let token = Data(SHA256.hash(data: Data(normalized.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "claude-permission:\(token)"
    }

    @discardableResult
    func beginClaudeBlockingAttention(
        client: SocketClient,
        sessionId: String,
        toolUseId: String?,
        workspaceId: String,
        surfaceId: String,
        owner: ClaudeHookSessionRecord?,
        title: String,
        subtitle: String,
        body: String
    ) -> ClaudeBlockingAttentionBeginResult {
        var params: [String: Any] = [
            "source": "claude",
            "session_id": sessionId,
            "request_id": claudeBlockingAttentionRequestId(toolUseId: toolUseId),
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "title": title,
            "subtitle": subtitle,
            "body": body,
        ]
        if !client.isRelayBacked {
            guard let owner,
                  let ownerPID = owner.pid,
                  ownerPID > 0,
                  ownerPID <= Int(Int32.max),
                  let ownerPIDStartSeconds = owner.pidStartSeconds,
                  let ownerPIDStartMicroseconds = owner.pidStartMicroseconds,
                  ownerPIDStartSeconds >= 0,
                  (0..<1_000_000).contains(ownerPIDStartMicroseconds) else {
                return .unavailable
            }
            params["ppid"] = ownerPID
            params["ppid_start_seconds"] = ownerPIDStartSeconds
            params["ppid_start_microseconds"] = ownerPIDStartMicroseconds
        }
        do {
            let response = try client.sendV2(
                method: "feed.attention.begin",
                params: params,
                responseTimeout: Self.claudeBlockingAttentionResponseTimeout
            )
            return response["active"] as? Bool == false ? .rejected : .active
        } catch let error as CLIError where error.v2Code == "method_not_found"
                || error.v2Code == "unrecognized_method" {
            return .unavailable
        } catch {
            // A timeout may race an app-side commit. Do not switch to a V1
            // fallback until the request's ownership is known.
            return .uncertain
        }
    }

    /// Keeps older cmux builds visible when the transient-attention endpoint is
    /// unavailable. The durable Claude lifecycle already says Needs input, so
    /// this legacy path only restores the status and targeted notification.
    func fallbackClaudeBlockingAttention(
        client: SocketClient,
        sessionStore: ClaudeHookSessionStore,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        title: String,
        subtitle: String,
        body: String,
        pid: Int?
    ) {
        let boundedBody = boundedClaudeBlockingAttentionText(body)
        try? sessionStore.setLegacyBlockingAttentionFallback(
            sessionId: sessionId,
            active: true
        )
        setAgentLifecycle(
            client: client,
            key: Self.claudeCodeStatusKey,
            lifecycle: .needsInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        try? setClaudeStatus(
            client: client,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            value: String(
                localized: "feed.status.needsInput",
                defaultValue: "Needs input"
            ),
            icon: "bell.fill",
            color: "#4C8DFF",
            pid: pid
        )
        let payload = notificationPayload(
            title: title,
            subtitle: subtitle,
            body: boundedBody,
            meta: AgentHookNotifyCategory.needsPermission.metaSegment(pending: false)
        )
        _ = try? sendV1Command(
            "notify_target_async \(workspaceId) \(surfaceId) \(payload)",
            client: client
        )
    }

    /// Bounds model-controlled fallback text by UTF-8 bytes, matching the V2
    /// attention body limit while preserving a valid scalar boundary.
    func boundedClaudeBlockingAttentionText(_ value: String) -> String {
        let maximumBytes = 4_096
        guard value.utf8.count > maximumBytes else { return value }
        var bounded = value
        while bounded.utf8.count > maximumBytes - 3 {
            bounded.removeLast()
        }
        return bounded + "…"
    }

    /// Clears only Claude's permission row, with an old-app pane fallback.
    func clearClaudePermissionNotification(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String,
        sessionId: String,
        deadline: Date
    ) -> Bool {
        guard let correlationKey = claudePermissionNotificationCorrelationKey(
            sessionId: sessionId
        ) else { return false }
        func remainingTimeout() -> TimeInterval {
            max(0.05, deadline.timeIntervalSinceNow)
        }
        let targetedCommandRejected: Bool
        do {
            _ = try sendV1Command(
                "clear_notification_correlation \(correlationKey)",
                client: client,
                responseTimeout: remainingTimeout(),
                deadline: deadline
            )
            targetedCommandRejected = false
        } catch let error as CLIError where error.message.hasPrefix("ERROR:") {
            targetedCommandRejected = true
        } catch {
            // A transport timeout may race an app-side clear. Do not widen it
            // into a pane-wide fallback whose result is now ambiguous.
            return false
        }
        guard targetedCommandRejected else { return true }
        // Compatibility with an app that predates correlation-scoped clears.
        do {
            _ = try sendV1Command(
                "clear_notifications --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                client: client,
                responseTimeout: remainingTimeout(),
                deadline: deadline
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func endClaudeBlockingAttention(
        client: SocketClient,
        sessionId: String,
        toolUseId: String?,
        owner: ClaudeHookSessionRecord? = nil,
        responseTimeout: TimeInterval = Self.claudeBlockingAttentionResponseTimeout
    ) -> Bool {
        var params: [String: Any] = [
            "source": "claude",
            "session_id": sessionId,
            "request_id": claudeBlockingAttentionRequestId(toolUseId: toolUseId),
        ]
        guard appendLocalAttentionOwnerParams(
            to: &params,
            owner: owner,
            client: client
        ) else {
            return false
        }
        do {
            let response = try client.sendV2(
                method: "feed.attention.end",
                params: params,
                responseTimeout: responseTimeout
            )
            if params["legacy_release"] as? Bool == true {
                return true
            }
            return transientAttentionEndResponseSucceeded(response)
        } catch let error as CLIError where error.v2Code == "method_not_found"
                || error.v2Code == "unrecognized_method" {
            // Older app builds never acquired transient attention, so an
            // unsupported release is already reconciled.
            return true
        } catch {
            return false
        }
    }

    /// A turn boundary supersedes any tool callback that never arrived (for
    /// example after native permission denial or interruption). Feed-owned
    /// requests are harmless no-ops here; bypass-mode requests release every
    /// transient request in this session without clearing pane-wide attention.
    @discardableResult
    func endClaudeBlockingAttentionForTurnBoundary(
        client: SocketClient,
        sessionId: String,
        owner: ClaudeHookSessionRecord? = nil
    ) -> Bool {
        // Send a session-scoped release even after an earlier boundary cleared
        // durable blocker IDs. If its first transport attempt failed, the next
        // current turn boundary can still reconcile app-owned attention.
        var params: [String: Any] = [
            "source": "claude",
            "session_id": sessionId,
            "all_requests": true,
        ]
        guard appendLocalAttentionOwnerParams(
            to: &params,
            owner: owner,
            client: client
        ) else {
            return false
        }
        do {
            let response = try client.sendV2(
                method: "feed.attention.end",
                params: params,
                responseTimeout: Self.claudeBlockingAttentionTurnBoundaryTimeout
            )
            if params["legacy_release"] as? Bool == true {
                return true
            }
            return transientAttentionEndResponseSucceeded(response)
        } catch let error as CLIError where error.v2Code == "method_not_found"
                || error.v2Code == "unrecognized_method" {
            return true
        } catch {
            return false
        }
    }

    /// SessionEnd cleanup releases the snapshot's correlated requests
    /// individually. An all-requests release is unsafe across a race where a
    /// newer blocker registers after the stale hook read its session record.
    @discardableResult
    func endClaudeBlockingAttentionForSessionEnd(
        client: SocketClient,
        sessionId: String,
        owner: ClaudeHookSessionRecord?
    ) -> Bool {
        guard let pending = owner?.pendingBlockingToolUseIds else {
            return endClaudeBlockingAttentionForTurnBoundary(
                client: client,
                sessionId: sessionId,
                owner: owner
            )
        }
        guard !pending.isEmpty else {
            return true
        }
        let deadline = Date().addingTimeInterval(
            Self.claudeBlockingAttentionTurnBoundaryTimeout
        )
        var didReleaseAll = true
        for requestId in pending {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                didReleaseAll = false
                break
            }
            let released = endClaudeBlockingAttention(
                client: client,
                sessionId: sessionId,
                toolUseId: requestId,
                owner: owner,
                responseTimeout: min(remaining, 0.2)
            )
            if !released {
                didReleaseAll = false
            }
        }
        return didReleaseAll
    }

    /// Releases old-session attention claimed by the durable superseded-cleanup
    /// queue. A failed transport leaves the candidate queued so a later Claude
    /// hook can claim and retry it without relying on the old session's hooks.
    @discardableResult
    func releaseSupersededClaudeBlockingAttention(
        client: SocketClient,
        sessionStore: ClaudeHookSessionStore,
        candidates: [ClaudeHookSessionRecord]
    ) -> [ClaudeHookSessionRecord] {
        guard !candidates.isEmpty else { return [] }
        var released: [ClaudeHookSessionRecord] = []
        for candidate in candidates {
            guard endClaudeBlockingAttentionForTurnBoundary(
                client: client,
                sessionId: candidate.sessionId,
                owner: candidate
            ) else {
                continue
            }
            released.append(candidate)
        }
        try? sessionStore.acknowledgeSupersededSessionCleanup(released)
        return released
    }

    private func transientAttentionEndResponseSucceeded(
        _ response: [String: Any]
    ) -> Bool {
        switch response["outcome"] as? String {
        case "absent", "ended":
            return true
        case "unauthorized":
            return false
        default:
            // Older app builds returned an empty success payload. Preserve
            // their compatibility while treating an explicit false as a
            // rejected/owner-mismatched release.
            return response["ended"] as? Bool != false
        }
    }

    private func appendLocalAttentionOwnerParams(
        to params: inout [String: Any],
        owner: ClaudeHookSessionRecord?,
        client: SocketClient
    ) -> Bool {
        guard !client.isRelayBacked else { return true }
        if owner?.legacyBlockingAttentionFallbackActive == true {
            params["legacy_release"] = true
            return true
        }
        guard let owner,
              let pid = owner.pid,
              let startSeconds = owner.pidStartSeconds,
              let startMicroseconds = owner.pidStartMicroseconds,
              pid > 0,
              pid <= Int(Int32.max),
              startSeconds >= 0,
              (0..<1_000_000).contains(startMicroseconds) else {
            // Older session records may predate PID birth metadata. They could
            // not have acquired a current authenticated transient entry, but
            // durable Claude state still needs to complete; the app treats
            // this marker as a no-op transient release.
            params["legacy_release"] = true
            return true
        }
        params["ppid"] = pid
        params["ppid_start_seconds"] = startSeconds
        params["ppid_start_microseconds"] = startMicroseconds
        return true
    }

    /// Clears the app-owned lifecycle/status raised by a Claude permission
    /// notification once its native prompt or targeted blocker completes.
    /// Targeted wrappers no longer observe ordinary tools, so hook completion
    /// is the authoritative resume transition for that notification path.
    func resumeClaudeNeedsInputLifecycle(
        client: SocketClient,
        parsedInput: ClaudeHookParsedInput,
        sessionStore: ClaudeHookSessionStore,
        routing: ClaudeHookRoutingContext,
        telemetry: CLISocketSentryTelemetry,
        expectedSession: ClaudeHookSessionRecord? = nil,
        allowResolvedState: Bool = false
    ) {
        guard let sessionId = parsedInput.sessionId else { return }
        let mappedSession = expectedSession ?? (try? sessionStore.lookup(sessionId: sessionId))
        guard let mappedSession,
              mappedSession.agentLifecycle == .needsInput,
              mappedSession.pendingPermissionRequestIds?.isEmpty != false else {
            return
        }

        var cleanupRouting = routing
        cleanupRouting.allowsPidProbe = false
        guard let resolvedTarget = try? resolveClaudeHookDeliveryTarget(
            mappedSession: mappedSession,
            routing: cleanupRouting,
            client: client
        ) else {
            telemetry.breadcrumb("claude-hook.permission-request.resume-unresolved")
            return
        }
        let workspaceId = resolvedTarget.workspaceId
        let resolvedSurfaceId = resolvedTarget.surfaceId
        let surfaceId = resolvedTarget.isAuthoritative
            ? resolvedSurfaceId
            : (nonEmptyClaudeHookIdentifier(mappedSession.surfaceId) ?? resolvedSurfaceId)
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            sessionId: sessionId,
            turnId: parsedInput.turnId,
            workspaceId: workspaceId,
            surfaceId: resolvedTarget.isAuthoritative ? resolvedSurfaceId : nil,
            telemetry: telemetry
        ), !shouldSuppressNestedAgentVisibleMutations(
            currentAgentPID: mappedSession.pid ?? claudeAgentPID(from: ProcessInfo.processInfo.environment),
            env: ProcessInfo.processInfo.environment
        ) else {
            telemetry.breadcrumb("claude-hook.permission-request.resume-stale")
            return
        }

        let cleanupDeadline = Date.now.addingTimeInterval(
            Self.claudeBlockingAttentionResponseTimeout
        )
        guard clearClaudePermissionNotification(
            client: client,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            sessionId: sessionId,
            deadline: cleanupDeadline
        ) else {
            telemetry.breadcrumb("claude-hook.permission-request.resume-clear-pending")
            return
        }
        guard (try? sessionStore.clearBlockingAttentionLifecycleIfEligible(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: parsedInput.cwd,
            transcriptPath: parsedInput.transcriptPath,
            expectedUpdatedAt: mappedSession.updatedAt,
            allowRunningState: allowResolvedState
        )) == true else {
            telemetry.breadcrumb("claude-hook.permission-request.resume-state-changed")
            return
        }
        let remainingTimeout = max(0.05, cleanupDeadline.timeIntervalSinceNow)
        setAgentLifecycle(
            client: client,
            key: Self.claudeCodeStatusKey,
            lifecycle: .running,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            responseTimeout: remainingTimeout,
            deadline: cleanupDeadline
        )
        try? setClaudeStatus(
            client: client,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            value: String(localized: "agent.generic.status.running", defaultValue: "Running"),
            icon: "bolt.fill",
            color: "#4C8DFF",
            pid: mappedSession.pid ?? claudeAgentPID(from: ProcessInfo.processInfo.environment),
            responseTimeout: max(0.05, cleanupDeadline.timeIntervalSinceNow),
            deadline: cleanupDeadline
        )
    }
}
