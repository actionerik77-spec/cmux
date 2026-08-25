import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension ClaudeHookWriteAmplificationTests {
    private typealias AttentionHarness = ClaudeHookLiveDeliveryHarness

    @Test func resolvedPermissionRequestResumesNotificationLifecycle() throws {
        let context = try AttentionHarness.makeContext(name: "permission-resumes-notification")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "permission-resumes-notification-session"
        let now: TimeInterval = 4_102_444_800
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "needsInput",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)

        let serverHandled = AttentionHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedTerminalStatusesByRequestId: ["permission-tool": "resolved"]
        )
        var environment = AttentionHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = AttentionHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "permission-request"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_use_id":"permission-tool","permission_mode":"default","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let commands = context.state.snapshot()
        #expect(commands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(commands.contains { $0.hasPrefix("set_agent_lifecycle claude_code running ") })
        #expect(commands.contains { $0.hasPrefix("set_status claude_code Running ") })
        let record = try AttentionHarness.sessionRecord(
            in: context.storeURL,
            sessionId: sessionId
        )
        #expect(record?["agentLifecycle"] as? String == "running")
    }

    @Test func deniedPlanDoesNotPoisonTheNextBlockingTool() throws {
        let context = try AttentionHarness.makeContext(name: "denied-plan-blocker")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "denied-plan-blocker-session"
        try AttentionHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let serverHandled = AttentionHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedExitPlanModesByPlan: [
                "Rejected plan": "deny",
                "Accepted plan": "manual",
            ]
        )
        var environment = AttentionHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        func runHook(
            subcommand: String,
            eventName: String,
            toolUseId: String,
            plan: String
        ) -> AttentionHarness.ProcessRunResult {
            let toolUseIdField = eventName == "PermissionRequest"
                ? ""
                : ",\"tool_use_id\":\"\(toolUseId)\""
            let result = AttentionHarness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(eventName)","tool_name":"ExitPlanMode"\#(toolUseIdField),"tool_input":{"plan":"\#(plan)"},"permission_mode":"plan","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            return result
        }

        _ = runHook(
            subcommand: "pre-tool-use",
            eventName: "PreToolUse",
            toolUseId: "rejected-plan",
            plan: "Rejected plan"
        )
        let rejection = runHook(
            subcommand: "permission-request",
            eventName: "PermissionRequest",
            toolUseId: "rejected-plan",
            plan: "Rejected plan"
        )
        #expect(rejection.stdout.contains(#""behavior":"deny""#))

        var record = try AttentionHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [])

        _ = runHook(
            subcommand: "pre-tool-use",
            eventName: "PreToolUse",
            toolUseId: "accepted-plan",
            plan: "Accepted plan"
        )
        let approval = runHook(
            subcommand: "permission-request",
            eventName: "PermissionRequest",
            toolUseId: "accepted-plan",
            plan: "Accepted plan"
        )
        #expect(approval.stdout.contains(#""behavior":"allow""#))

        record = try AttentionHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "running")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [])

        let beforeLateCompletion = context.state.snapshot().count
        _ = runHook(
            subcommand: "input-resolved",
            eventName: "PostToolUse",
            toolUseId: "accepted-plan",
            plan: "Accepted plan"
        )
        let lateCompletionCommands = Array(
            context.state.snapshot().dropFirst(beforeLateCompletion)
        )
        #expect(!lateCompletionCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!lateCompletionCommands.contains { $0.hasPrefix("set_agent_lifecycle ") })
        #expect(!lateCompletionCommands.contains { $0.hasPrefix("set_status ") })
    }

    @Test func bypassCompletionUsesRequestScopedAttention() throws {
        let context = try AttentionHarness.makeContext(name: "request-scoped-attention")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "request-scoped-attention-session"
        let toolUseId = "bypass-question"
        let processIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        try AttentionHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let serverHandled = AttentionHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = AttentionHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLAUDE_PID"] = String(processIdentity.pid)

        func runHook(subcommand: String, eventName: String) -> AttentionHarness.ProcessRunResult {
            let result = AttentionHarness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(eventName)","tool_name":"AskUserQuestion","tool_use_id":"\#(toolUseId)","permission_mode":"bypassPermissions","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
            return result
        }

        let beforeNeedsInput = context.state.snapshot().count
        _ = runHook(subcommand: "pre-tool-use", eventName: "PreToolUse")
        let needsInputCommands = Array(context.state.snapshot().dropFirst(beforeNeedsInput))
        #expect(needsInputCommands.contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "feed.attention.begin",
                  let params = object["params"] as? [String: Any] else {
                return false
            }
            return params["request_id"] as? String == toolUseId
                && params["ppid"] as? Int == Int(processIdentity.pid)
                && params["ppid_start_seconds"] as? Int
                    == Int(processIdentity.startSeconds)
                && params["ppid_start_microseconds"] as? Int
                    == Int(processIdentity.startMicroseconds)
        })
        #expect(!needsInputCommands.contains { $0.hasPrefix("set_agent_lifecycle ") })
        #expect(!needsInputCommands.contains { $0.hasPrefix("set_status ") })
        #expect(!needsInputCommands.contains { $0.hasPrefix("notify_target_async ") })

        let beforeCompletion = context.state.snapshot().count
        _ = runHook(subcommand: "input-resolved", eventName: "PostToolUse")
        let completionCommands = Array(context.state.snapshot().dropFirst(beforeCompletion))
        #expect(completionCommands.contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "feed.attention.end",
                  let params = object["params"] as? [String: Any] else {
                return false
            }
            return params["request_id"] as? String == toolUseId
        })
        #expect(!completionCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!completionCommands.contains { $0.hasPrefix("set_agent_lifecycle ") })
        #expect(!completionCommands.contains { $0.hasPrefix("set_status ") })
    }

    @Test func unacknowledgedAttentionReleaseKeepsDurableBlocker() throws {
        let context = try AttentionHarness.makeContext(name: "attention-release-retry")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "attention-release-retry-session"
        let toolUseId = "attention-release-retry-tool"
        let now: TimeInterval = 4_102_444_800
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "needsInput",
                    "pendingBlockingToolUseIds": [toolUseId],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)

        let serverHandled = AttentionHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedAttentionEndSucceeds: false
        )
        var environment = AttentionHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = AttentionHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "input-resolved"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"\#(toolUseId)","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(context.state.snapshot().contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return object["method"] as? String == "feed.attention.end"
        })

        let record = try AttentionHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "needsInput")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [toolUseId])
    }

    @Test func attentionReleaseRespectsClaudeHookDeadline() throws {
        let context = try AttentionHarness.makeContext(name: "attention-release-deadline")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "attention-release-deadline-session"
        let toolUseId = "attention-release-deadline-tool"
        let now: TimeInterval = 4_102_444_800
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "needsInput",
                    "pendingBlockingToolUseIds": [toolUseId],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)
        let releaseGate = DispatchSemaphore(value: 0)
        let serverHandled = AttentionHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedAttentionEndGate: releaseGate
        )
        var environment = AttentionHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let startedAt = Date()
        let result = AttentionHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "input-resolved"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"\#(toolUseId)","cwd":"\#(context.root.path)"}"#
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        releaseGate.signal()

        #expect(elapsed < 5, "attention release exceeded the 5-second Claude hook deadline")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        let record = try AttentionHarness.sessionRecord(
            in: context.storeURL,
            sessionId: sessionId
        )
        #expect(record?["agentLifecycle"] as? String == "needsInput")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [toolUseId])
    }

    @Test func timedOutPermissionRequestRetiresItsCorrelatedBlocker() throws {
        let context = try AttentionHarness.makeContext(name: "timed-out-plan-blocker")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "timed-out-plan-blocker-session"
        let toolUseId = "timed-out-plan"
        try AttentionHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let serverHandled = AttentionHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedTerminalStatusesByPlan: ["Timed out plan": "timed_out"]
        )
        var environment = AttentionHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        for (subcommand, eventName) in [
            ("pre-tool-use", "PreToolUse"),
            ("permission-request", "PermissionRequest"),
        ] {
            let toolUseIdField = eventName == "PermissionRequest"
                ? ""
                : ",\"tool_use_id\":\"\(toolUseId)\""
            let result = AttentionHarness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(eventName)","tool_name":"ExitPlanMode"\#(toolUseIdField),"tool_input":{"plan":"Timed out plan"},"permission_mode":"plan","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }

        let record = try AttentionHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "running")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [])
    }

    @Test func permissionRequestsCorrelateByToolPayloadWithoutToolUseId() throws {
        let context = try AttentionHarness.makeContext(name: "permission-payload-correlation")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "permission-payload-correlation-session"
        try AttentionHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let serverHandled = AttentionHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = AttentionHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        func runPreToolUse(toolUseId: String, plan: String) {
            let result = AttentionHarness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", "pre-tool-use"],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_use_id":"\#(toolUseId)","tool_input":{"plan":"\#(plan)"},"permission_mode":"plan","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
        }

        func runPermissionRequest(plan: String) {
            let result = AttentionHarness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", "permission-request"],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"\#(plan)"},"permission_mode":"plan","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
        }

        runPreToolUse(toolUseId: "same-payload-first", plan: "Same plan")
        runPreToolUse(toolUseId: "different-payload", plan: "Different plan")
        runPreToolUse(toolUseId: "same-payload-second", plan: "Same plan")

        runPermissionRequest(plan: "Same plan")
        var record = try AttentionHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(
            record?["pendingBlockingToolUseIds"] as? [String]
                == ["different-payload", "same-payload-second"],
            "the first matching PreToolUse must be consumed without clearing a concurrent blocker"
        )

        runPermissionRequest(plan: "Different plan")
        record = try AttentionHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == ["same-payload-second"])

        runPermissionRequest(plan: "Same plan")
        record = try AttentionHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "running")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [])
    }

    @Test func ambiguousLongPayloadDoesNotResolveTheFirstBlocker() throws {
        let context = try AttentionHarness.makeContext(name: "ambiguous-long-payload")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "ambiguous-long-payload-session"
        try AttentionHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )
        let serverHandled = AttentionHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = AttentionHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let sharedPrefix = String(repeating: "p", count: 600)

        func runHook(
            subcommand: String,
            eventName: String,
            toolUseId: String?,
            plan: String
        ) -> AttentionHarness.ProcessRunResult {
            let toolUseIdField = toolUseId.map { ",\"tool_use_id\":\"\($0)\"" } ?? ""
            let result = AttentionHarness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(eventName)","tool_name":"ExitPlanMode"\#(toolUseIdField),"tool_input":{"plan":"\#(plan)"},"permission_mode":"plan","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            return result
        }

        _ = runHook(
            subcommand: "pre-tool-use",
            eventName: "PreToolUse",
            toolUseId: "long-first",
            plan: sharedPrefix + "-first"
        )
        _ = runHook(
            subcommand: "pre-tool-use",
            eventName: "PreToolUse",
            toolUseId: "long-second",
            plan: sharedPrefix + "-second"
        )
        let beforePermission = context.state.snapshot().count
        _ = runHook(
            subcommand: "permission-request",
            eventName: "PermissionRequest",
            toolUseId: nil,
            plan: sharedPrefix + "-second"
        )
        let permissionCommands = Array(context.state.snapshot().dropFirst(beforePermission))
        #expect(!permissionCommands.contains { $0.contains(#""method":"feed.attention.end""#) })
        let record = try AttentionHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(
            record?["pendingBlockingToolUseIds"] as? [String]
                == ["long-first", "long-second"]
        )
    }

    @Test func delayedPermissionRequestCannotResolveTheNextTurnBlocker() throws {
        let context = try AttentionHarness.makeContext(name: "stale-permission-turn")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "stale-permission-turn-session"
        let now: TimeInterval = 4_102_444_800
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [
                workspaceId: [
                    "sessionId": sessionId,
                    "turnId": "turn-2",
                    "updatedAt": now,
                ],
            ],
            "activeSessionsBySurface": [
                surfaceId: [
                    "sessionId": sessionId,
                    "turnId": "turn-2",
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)
        let serverHandled = AttentionHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedTerminalStatusesByPlan: ["same plan": "resolved"]
        )
        var environment = AttentionHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        func runHook(
            subcommand: String,
            eventName: String,
            turnId: String,
            toolUseId: String?
        ) {
            let toolUseIdField = toolUseId.map { ",\"tool_use_id\":\"\($0)\"" } ?? ""
            let result = AttentionHarness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","turn_id":"\#(turnId)","hook_event_name":"\#(eventName)","tool_name":"ExitPlanMode"\#(toolUseIdField),"tool_input":{"plan":"same plan"},"permission_mode":"plan","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
        }

        runHook(
            subcommand: "pre-tool-use",
            eventName: "PreToolUse",
            turnId: "turn-2",
            toolUseId: "turn-two-tool"
        )
        let beforeStalePermission = context.state.snapshot().count
        runHook(
            subcommand: "permission-request",
            eventName: "PermissionRequest",
            turnId: "turn-1",
            toolUseId: nil
        )
        let staleCommands = Array(context.state.snapshot().dropFirst(beforeStalePermission))
        #expect(!staleCommands.contains { $0.contains(#""method":"feed.attention.end""#) })
        let record = try AttentionHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == ["turn-two-tool"])
    }

    @Test func staleSessionEndDoesNotReleaseCurrentTurnBlocker() throws {
        let context = try AttentionHarness.makeContext(name: "stale-end-current-blocker")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "stale-end-current-blocker-session"
        let now: TimeInterval = 4_102_444_800
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "needsInput",
                    "pendingBlockingToolUseIds": ["current-turn-tool"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [
                workspaceId: [
                    "sessionId": sessionId,
                    "turnId": "turn-2",
                    "updatedAt": now,
                ],
            ],
            "activeSessionsBySurface": [
                surfaceId: [
                    "sessionId": sessionId,
                    "turnId": "turn-2",
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)

        let serverHandled = AttentionHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = AttentionHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = AttentionHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","hook_event_name":"SessionEnd","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(
            !context.state.snapshot().contains { command in
                guard let data = command.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return false }
                return object["method"] as? String == "feed.attention.end"
            },
            "a stale SessionEnd must not release blockers owned by the current turn"
        )
        let record = try AttentionHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "needsInput")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == ["current-turn-tool"])
    }
}
