import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9693.
/// Repeated ordinary Claude tool calls must not turn an already-running
/// lifecycle observation into durable Feed telemetry or a session-file write.
@Suite(.serialized)
struct ClaudeHookWriteAmplificationTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    @Test func ordinaryToolUseWhileRunningDoesNotWriteDurableState() throws {
        let context = try Harness.makeContext(name: "pre-tool-write-amplification")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "ordinary-running-tool-session"
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
        ]
        let stateData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try stateData.write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(
            !context.state.snapshot().contains { command in
                command.contains(#""method":"feed.push""#)
                    || command.hasPrefix("set_status ")
                    || command.hasPrefix("set_agent_lifecycle ")
                    || command.hasPrefix("clear_notifications ")
            }
        )
        #expect(try Data(contentsOf: context.storeURL) == stateData)
    }

    @Test func legacyOrdinaryToolResumesAStaleBlockingSession() throws {
        let context = try Harness.makeContext(name: "legacy-ordinary-tool-transition")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "legacy-ordinary-tool-session"
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
                    "pendingBlockingToolUseIds": ["legacy-blocker"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let commands = context.state.snapshot()
        #expect(commands.contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "feed.attention.end",
                  let params = object["params"] as? [String: Any] else {
                return false
            }
            return params["session_id"] as? String == sessionId
                && params["all_requests"] as? Bool == true
        })
        #expect(commands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(commands.contains { $0.hasPrefix("set_agent_lifecycle claude_code running ") })
        #expect(commands.contains { $0.hasPrefix("set_status claude_code Running ") })
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "running")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [])
    }

    @Test func oversizedBlockingHookInputIsRejectedBeforeMutation() throws {
        let context = try Harness.makeContext(name: "oversized-blocking-hook-input")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "oversized-blocking-hook-session"
        _ = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let inputData = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionId,
            "hook_event_name": "PreToolUse",
            "tool_name": "ExitPlanMode",
            "tool_input": ["plan": String(repeating: "x", count: 1_100_000)],
            "permission_mode": "bypassPermissions",
            "cwd": context.root.path,
        ])
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: String(decoding: inputData, as: UTF8.self)
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(context.state.snapshot().isEmpty)
    }

    @Test(arguments: ["PostToolUse", "PostToolUseFailure"])
    func blockingToolCompletionClearsNeedsInputWithoutFeedTelemetry(
        hookEventName: String
    ) throws {
        let context = try Harness.makeContext(name: "input-resolved-\(hookEventName)")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "resolved-blocking-tool-session"
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

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "input-resolved"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(hookEventName)","tool_name":"AskUserQuestion","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let commands = context.state.snapshot()
        #expect(!commands.contains { $0.contains(#""method":"feed.push""#) })
        #expect(commands.contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return object["method"] as? String == "feed.attention.end"
        })
        #expect(!commands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!commands.contains { $0.hasPrefix("set_agent_lifecycle ") })
        #expect(!commands.contains { $0.hasPrefix("set_status ") })
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "running")
    }

    @Test func overlappingBlockingToolsClearNeedsInputOnlyAfterBothComplete() throws {
        let context = try Harness.makeContext(name: "overlapping-blocking-tools")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "overlapping-blocking-tool-session"
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
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        func runHook(
            subcommand: String,
            eventName: String,
            toolUseId: String
        ) -> Harness.ProcessRunResult {
            let result = Harness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(eventName)","tool_name":"AskUserQuestion","tool_use_id":"\#(toolUseId)","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
            return result
        }

        _ = runHook(subcommand: "pre-tool-use", eventName: "PreToolUse", toolUseId: "tool-b")
        _ = runHook(subcommand: "pre-tool-use", eventName: "PreToolUse", toolUseId: "tool-a")

        let pendingRecord = try Harness.sessionRecord(
            in: context.storeURL,
            sessionId: sessionId
        )
        #expect(pendingRecord?["agentLifecycle"] as? String == "needsInput")
        #expect(pendingRecord?["pendingBlockingToolUseIds"] as? [String] == ["tool-a", "tool-b"])

        let beforeFirstCompletion = context.state.snapshot().count
        _ = runHook(subcommand: "input-resolved", eventName: "PostToolUse", toolUseId: "tool-a")
        let firstCompletionCommands = Array(
            context.state.snapshot().dropFirst(beforeFirstCompletion)
        )
        #expect(!firstCompletionCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(
            !firstCompletionCommands.contains {
                $0.hasPrefix("set_agent_lifecycle claude_code running ")
            }
        )
        #expect(!firstCompletionCommands.contains { $0.hasPrefix("set_status claude_code ") })

        let stillPendingRecord = try Harness.sessionRecord(
            in: context.storeURL,
            sessionId: sessionId
        )
        #expect(stillPendingRecord?["agentLifecycle"] as? String == "needsInput")
        #expect(stillPendingRecord?["pendingBlockingToolUseIds"] as? [String] == ["tool-b"])

        let storeBeforeDuplicateCompletion = try Data(contentsOf: context.storeURL)
        let beforeDuplicateCompletion = context.state.snapshot().count
        _ = runHook(subcommand: "input-resolved", eventName: "PostToolUse", toolUseId: "tool-a")
        let duplicateCompletionCommands = Array(
            context.state.snapshot().dropFirst(beforeDuplicateCompletion)
        )
        #expect(!duplicateCompletionCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(
            !duplicateCompletionCommands.contains {
                $0.hasPrefix("set_agent_lifecycle claude_code running ")
            }
        )
        #expect(try Data(contentsOf: context.storeURL) == storeBeforeDuplicateCompletion)

        let beforeFinalCompletion = context.state.snapshot().count
        _ = runHook(subcommand: "input-resolved", eventName: "PostToolUse", toolUseId: "tool-b")
        let finalCompletionCommands = Array(
            context.state.snapshot().dropFirst(beforeFinalCompletion)
        )
        #expect(finalCompletionCommands.contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "feed.attention.end",
                  let params = object["params"] as? [String: Any] else {
                return false
            }
            return params["request_id"] as? String == "tool-b"
        })
        #expect(!finalCompletionCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!finalCompletionCommands.contains { $0.hasPrefix("set_agent_lifecycle ") })
        #expect(!finalCompletionCommands.contains { $0.hasPrefix("set_status ") })

        let resolvedRecord = try Harness.sessionRecord(
            in: context.storeURL,
            sessionId: sessionId
        )
        #expect(resolvedRecord?["agentLifecycle"] as? String == "running")
        #expect(resolvedRecord?["pendingBlockingToolUseIds"] as? [String] == [])
    }

    @Test func missingToolUseIdsKeepDistinctRequestScopedAttention() throws {
        let context = try Harness.makeContext(name: "missing-tool-use-id-attention")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "missing-tool-use-id-attention-session"
        let processIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLAUDE_PID"] = String(processIdentity.pid)

        func runHook(subcommand: String, eventName: String, plan: String) {
            let result = Harness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(eventName)","tool_name":"ExitPlanMode","tool_input":{"plan":"\#(plan)"},"permission_mode":"bypassPermissions","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }

        func attentionRequestIds(method: String, commands: [String]) -> [String] {
            commands.compactMap { command in
                guard let data = command.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["method"] as? String == method,
                      let params = object["params"] as? [String: Any] else {
                    return nil
                }
                return params["request_id"] as? String
            }
        }

        runHook(subcommand: "pre-tool-use", eventName: "PreToolUse", plan: "First plan")
        runHook(subcommand: "pre-tool-use", eventName: "PreToolUse", plan: "Second plan")

        let beginRequestIds = attentionRequestIds(
            method: "feed.attention.begin",
            commands: context.state.snapshot()
        )
        #expect(beginRequestIds.count == 2)
        let firstRequestId = try #require(beginRequestIds.first)
        let secondRequestId = try #require(beginRequestIds.dropFirst().first)
        #expect(firstRequestId != secondRequestId)

        var record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(
            record?["pendingBlockingToolUseIds"] as? [String]
                == [firstRequestId, secondRequestId].sorted()
        )

        let beforeFirstCompletion = context.state.snapshot().count
        runHook(subcommand: "input-resolved", eventName: "PostToolUse", plan: "First plan")
        let firstCompletionCommands = Array(
            context.state.snapshot().dropFirst(beforeFirstCompletion)
        )
        #expect(
            attentionRequestIds(
                method: "feed.attention.end",
                commands: firstCompletionCommands
            ) == [firstRequestId]
        )
        record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "needsInput")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [secondRequestId])

        let beforeSecondCompletion = context.state.snapshot().count
        runHook(subcommand: "input-resolved", eventName: "PostToolUse", plan: "Second plan")
        let secondCompletionCommands = Array(
            context.state.snapshot().dropFirst(beforeSecondCompletion)
        )
        #expect(
            attentionRequestIds(
                method: "feed.attention.end",
                commands: secondCompletionCommands
            ) == [secondRequestId]
        )
        record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "running")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [])
    }

    @Test func blockingCompletionCannotRecreateConsumedSession() throws {
        let context = try Harness.makeContext(name: "consumed-blocking-session")
        defer { context.cleanup() }
        let sessionId = "consumed-blocking-session"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            purgeSessionStoreOnFeedAttentionEnd: true
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        func runCompletion(sessionId: String, toolUseId: String) -> [String] {
            let commandStart = context.state.snapshot().count
            let result = Harness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", "input-resolved"],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"\#(toolUseId)","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
            return Array(context.state.snapshot().dropFirst(commandStart))
        }

        let consumedCommands = runCompletion(
            sessionId: sessionId,
            toolUseId: "legacy-tool"
        )
        #expect(
            consumedCommands.contains { $0.contains(#""method":"feed.attention.end""#) },
            "the seeded legacy record must be selected before the simulated purge"
        )
        #expect(
            try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId) == nil,
            "resolution must not recreate a session consumed while attention ends"
        )

        let missingCommands = runCompletion(
            sessionId: "missing-session",
            toolUseId: "unknown-tool"
        )
        #expect(
            !missingCommands.contains { $0.contains(#""method":"feed.attention.end""#) },
            "an unknown completion must not release attention without a durable owner"
        )
        #expect(
            try Harness.sessionRecord(
                in: context.storeURL,
                sessionId: "missing-session"
            ) == nil
        )
    }

}
