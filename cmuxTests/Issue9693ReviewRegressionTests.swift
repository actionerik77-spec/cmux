import Foundation
import os
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension ClaudeHookWriteAmplificationTests {
    @Test func concurrentPermissionNotificationsCoalesceUntilLastResolution() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "permission-notification-correlation"
        )
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "permission-notification-correlation-session"
        let state: [String: Any] = [
            "version": 1,
            "sessions": [sessionId: [
                "sessionId": sessionId,
                "workspaceId": workspaceId,
                "surfaceId": surfaceId,
                "cwd": context.root.path,
                "agentLifecycle": "needsInput",
                "startedAt": 4_102_444_800,
                "updatedAt": 4_102_444_800,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)

        let feedReceived = DispatchSemaphore(value: 0)
        let feedGate = DispatchSemaphore(value: 0)
        defer {
            feedGate.signal()
            feedGate.signal()
        }
        _ = ClaudeHookLiveDeliveryHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedPushReceived: feedReceived,
            feedPushGate: feedGate,
            feedTerminalDefaultStatus: "resolved"
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let hookEnvironment = environment
        let completion = DispatchSemaphore(value: 0)
        let results = OSAllocatedUnfairLock<[
            ClaudeHookLiveDeliveryHarness.ProcessRunResult
        ]>(initialState: [])

        for command in ["echo first", "echo second"] {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = ClaudeHookLiveDeliveryHarness.runHookProcess(
                    context: context,
                    arguments: ["hooks", "claude", "permission-request"],
                    environment: hookEnvironment,
                    standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"\#(command)"},"permission_mode":"default","cwd":"\#(context.root.path)"}"#
                )
                results.withLock { $0.append(result) }
                completion.signal()
            }
            #expect(feedReceived.wait(timeout: .now() + 5) == .success)
        }

        for title in ["First permission", "Second permission"] {
            let notification = ClaudeHookLiveDeliveryHarness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", "notification"],
                environment: hookEnvironment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Notification","notification_type":"permission_prompt","title":"\#(title)","message":"Claude needs your permission","cwd":"\#(context.root.path)"}"#
            )
            #expect(!notification.timedOut, Comment(rawValue: notification.stderr))
            #expect(notification.status == 0, Comment(rawValue: notification.stderr))
        }

        func permissionNotificationKeys(in commands: [String]) -> [String] {
            commands.compactMap { command in
                guard command.hasPrefix("notify_target_async "),
                      let meta = command.split(separator: "|").last,
                      let key = meta.split(separator: ";").first(where: {
                          $0.hasPrefix("k=claude-permission:")
                      }) else {
                    return nil
                }
                return String(key.dropFirst(2))
            }
        }

        func clearedPermissionKeys(in commands: [String]) -> [String] {
            let prefix = "clear_notification_correlation "
            return commands.compactMap { command in
                guard command.hasPrefix(prefix) else { return nil }
                return String(command.dropFirst(prefix.count))
            }
        }

        let notificationKeys = permissionNotificationKeys(in: context.state.snapshot())
        #expect(notificationKeys.count == 2)
        #expect(Set(notificationKeys).count == 1)

        let beforeFirstResolution = context.state.snapshot().count
        feedGate.signal()
        #expect(completion.wait(timeout: .now() + 10) == .success)
        let firstResolutionCommands = Array(
            context.state.snapshot().dropFirst(beforeFirstResolution)
        )
        let firstClearedKeys = clearedPermissionKeys(in: firstResolutionCommands)
        #expect(firstClearedKeys.isEmpty)

        let beforeSecondResolution = context.state.snapshot().count
        feedGate.signal()
        #expect(completion.wait(timeout: .now() + 10) == .success)
        let secondResolutionCommands = Array(
            context.state.snapshot().dropFirst(beforeSecondResolution)
        )
        let secondClearedKeys = clearedPermissionKeys(in: secondResolutionCommands)
        #expect(secondClearedKeys.count == 1)
        #expect(secondClearedKeys.first == notificationKeys.first)
        let completed = results.withLock { $0 }
        #expect(completed.count == 2)
        #expect(completed.allSatisfy { !$0.timedOut && $0.status == 0 })
    }

    @Test func latePermissionNotificationDoesNotReopenResolvedLifecycle() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "legacy-permission-lifecycle"
        )
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "legacy-permission-lifecycle-session"
        let state: [String: Any] = [
            "version": 1,
            "sessions": [sessionId: [
                "sessionId": sessionId,
                "workspaceId": workspaceId,
                "surfaceId": surfaceId,
                "cwd": context.root.path,
                "agentLifecycle": "needsInput",
                "startedAt": 4_102_444_800,
                "updatedAt": 4_102_444_800,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)
        _ = ClaudeHookLiveDeliveryHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedTerminalDefaultStatus: "resolved"
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let permission = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "permission-request"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo allowed"},"permission_mode":"default","cwd":"\#(context.root.path)"}"#
        )
        #expect(!permission.timedOut, Comment(rawValue: permission.stderr))
        #expect(permission.status == 0, Comment(rawValue: permission.stderr))

        let beforeLateNotification = context.state.snapshot().count
        let notification = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission","cwd":"\#(context.root.path)"}"#
        )
        #expect(!notification.timedOut, Comment(rawValue: notification.stderr))
        #expect(notification.status == 0, Comment(rawValue: notification.stderr))
        let lateNotificationCommands = Array(
            context.state.snapshot().dropFirst(beforeLateNotification)
        )
        #expect(!lateNotificationCommands.contains {
            $0.hasPrefix("notify_target_async ")
        })
        #expect(!lateNotificationCommands.contains {
            $0.hasPrefix("set_agent_lifecycle claude_code needs_input ")
        })

        let record = try ClaudeHookLiveDeliveryHarness.sessionRecord(
            in: context.storeURL,
            sessionId: sessionId
        )
        #expect(record?["agentLifecycle"] as? String == "running")
        #expect(record?["pendingBlockingToolUseIds"] == nil)
    }
}

extension AgentNotificationRegressionTests {
    @Test func removingTransientRowPreservesPersistentFocusedReadIndicator() {
        let store = TerminalNotificationStore.shared
        let tabId = UUID()
        let surfaceId = UUID()
        let persistent = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Persistent",
            subtitle: "Waiting",
            body: "Still unread",
            createdAt: .now,
            isRead: false
        )
        let transient = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            correlationKey: TerminalNotification.transientAgentAttentionCorrelationPrefix
                + UUID().uuidString,
            title: "Transient",
            subtitle: "Waiting",
            body: "Permission prompt",
            createdAt: .now,
            isRead: true
        )
        defer {
            store.replaceNotificationsForTesting([])
            store.clearFocusedReadIndicator(forTabId: tabId)
        }

        store.replaceNotificationsForTesting([transient, persistent])
        store.setFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        store.remove(id: transient.id)

        #expect(store.notifications.map(\.id) == [persistent.id])
        #expect(store.focusedReadIndicatorSurfaceId(forTabId: tabId) == surfaceId)
    }
}
