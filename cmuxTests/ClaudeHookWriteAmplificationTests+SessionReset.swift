import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension ClaudeHookWriteAmplificationTests {
    private typealias SessionResetHarness = ClaudeHookLiveDeliveryHarness

    @Test func clearSessionStartReleasesDisplacedBlockingAttention() throws {
        let context = try SessionResetHarness.makeContext(name: "clear-blocking-attention")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let oldSessionId = "pre-clear-blocking-session"
        let newSessionId = "post-clear-session"
        let processIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let serverHandled = SessionResetHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: (workspaceId: workspaceId, surfaceId: surfaceId),
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = SessionResetHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLAUDE_PID"] = String(processIdentity.pid)

        func runHook(subcommand: String, input: String) {
            let result = SessionResetHarness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: input
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }

        runHook(
            subcommand: "session-start",
            input: #"{"session_id":"\#(oldSessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        runHook(
            subcommand: "pre-tool-use",
            input: #"{"session_id":"\#(oldSessionId)","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"pre-clear-question","permission_mode":"bypassPermissions","cwd":"\#(context.root.path)"}"#
        )

        let beforeClear = context.state.snapshot().count
        runHook(
            subcommand: "session-start",
            input: #"{"session_id":"\#(newSessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        let clearCommands = Array(context.state.snapshot().dropFirst(beforeClear))
        #expect(clearCommands.contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "feed.attention.end",
                  let params = object["params"] as? [String: Any] else {
                return false
            }
            return params["source"] as? String == "claude"
                && params["session_id"] as? String == oldSessionId
                && params["all_requests"] as? Bool == true
        }, "a clear boundary must release blockers owned by the displaced session")
    }

    @Test func bypassAttentionRequiresDurableBlockingToolRegistration() throws {
        let context = try SessionResetHarness.makeContext(name: "failed-blocker-registration")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "failed-blocker-registration-session"
        let processIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        try SessionResetHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            processIdentity: processIdentity
        )

        let storeURL = context.storeURL
        let serverHandled = SessionResetHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            beforeSurfaceResolutionResponse: {
                let fileManager = FileManager()
                try? fileManager.removeItem(at: storeURL)
                try? fileManager.createDirectory(
                    at: storeURL,
                    withIntermediateDirectories: false
                )
            }
        )
        var environment = SessionResetHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLAUDE_PID"] = String(processIdentity.pid)

        let result = SessionResetHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"unregistered-question","permission_mode":"bypassPermissions","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(atPath: storeURL.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "the fixture must make durable blocker registration fail"
        )
        #expect(
            !context.state.snapshot().contains { command in
                guard let data = command.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return false }
                return object["method"] as? String == "feed.attention.begin"
            },
            "attention without a durable blocker cannot be correlated or released"
        )
    }

    @Test func bypassAttentionFallsBackWhenTransientEndpointIsUnavailable() throws {
        let context = try SessionResetHarness.makeContext(name: "legacy-attention-fallback")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "legacy-attention-fallback-session"
        let processIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        try SessionResetHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            processIdentity: processIdentity
        )
        let serverHandled = SessionResetHarness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedAttentionBeginSucceeds: false
        )
        var environment = SessionResetHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLAUDE_PID"] = String(processIdentity.pid)

        let result = SessionResetHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"legacy-fallback-question","permission_mode":"bypassPermissions","tool_input":{"questions":[{"question":"Continue?"}]},"cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(commands.contains { $0.hasPrefix("set_agent_lifecycle claude_code needsInput ") })
        #expect(commands.contains { $0.hasPrefix("set_status claude_code Needs input ") })
        #expect(commands.contains { $0.hasPrefix("notify_target_async ") })
    }
}
