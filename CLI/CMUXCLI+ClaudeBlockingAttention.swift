import Foundation

extension CMUXCLI {
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
    ) {
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
                return
            }
            params["ppid"] = ownerPID
            params["ppid_start_seconds"] = ownerPIDStartSeconds
            params["ppid_start_microseconds"] = ownerPIDStartMicroseconds
        }
        _ = try? client.sendV2(
            method: "feed.attention.begin",
            params: params,
            responseTimeout: Self.claudeBlockingAttentionResponseTimeout
        )
    }

    @discardableResult
    func endClaudeBlockingAttention(
        client: SocketClient,
        sessionId: String,
        toolUseId: String?
    ) -> Bool {
        do {
            _ = try client.sendV2(
                method: "feed.attention.end",
                params: [
                    "source": "claude",
                    "session_id": sessionId,
                    "request_id": claudeBlockingAttentionRequestId(toolUseId: toolUseId),
                ],
                responseTimeout: Self.claudeBlockingAttentionResponseTimeout
            )
            return true
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
    func endClaudeBlockingAttentionForTurnBoundary(
        client: SocketClient,
        sessionId: String
    ) {
        // Send a session-scoped release even after an earlier boundary cleared
        // durable blocker IDs. If its first transport attempt failed, the next
        // current turn boundary can still reconcile app-owned attention.
        _ = try? client.sendV2(
            method: "feed.attention.end",
            params: [
                "source": "claude",
                "session_id": sessionId,
                "all_requests": true,
            ],
            responseTimeout: Self.claudeBlockingAttentionTurnBoundaryTimeout
        )
    }

    /// Clears the app-owned lifecycle/status that a Claude permission
    /// notification raised after the user answers the native PermissionRequest.
    /// Targeted wrappers no longer observe ordinary tools, so this response is
    /// the authoritative resume transition for that notification path.
    func resumeClaudeAfterPermissionRequest(
        client: SocketClient,
        parsedInput: ClaudeHookParsedInput,
        sessionStore: ClaudeHookSessionStore,
        routing: ClaudeHookRoutingContext,
        telemetry: CLISocketSentryTelemetry
    ) {
        guard let sessionId = parsedInput.sessionId else { return }
        let mappedSession = try? sessionStore.lookup(sessionId: sessionId)
        guard let mappedSession,
              mappedSession.agentLifecycle == .needsInput,
              mappedSession.pendingBlockingToolUseIds?.isEmpty != false else {
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

        _ = try? sessionStore.upsert(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: parsedInput.cwd,
            transcriptPath: parsedInput.transcriptPath,
            agentLifecycle: .running,
            clearPendingBlockingTools: true
        )
        _ = try? sendV1Command(
            "clear_notifications --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
            client: client
        )
        setAgentLifecycle(
            client: client,
            key: Self.claudeCodeStatusKey,
            lifecycle: .running,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        try? setClaudeStatus(
            client: client,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            value: String(localized: "agent.generic.status.running", defaultValue: "Running"),
            icon: "bolt.fill",
            color: "#4C8DFF",
            pid: mappedSession.pid ?? claudeAgentPID(from: ProcessInfo.processInfo.environment)
        )
    }
}
