import Darwin
import Foundation

extension TerminalController {
    /// Ephemeral attention is a UI mutation, so these methods intentionally run
    /// on the control socket's main-actor lane. They never activate or focus the
    /// app, and unlike `feed.push` they perform no durable Feed/event writes.
    func v2FeedTransientAttentionBegin(params: [String: Any]) -> V2CallResult {
        guard let source = transientAttentionString(params["source"], maxBytes: 80),
              let sessionId = transientAttentionString(params["session_id"], maxBytes: 512),
              let requestId = transientAttentionString(params["request_id"], maxBytes: 512),
              let workspaceId = transientAttentionUUID(params["workspace_id"]),
              let surfaceId = transientAttentionUUID(params["surface_id"]),
              let title = transientAttentionString(params["title"], maxBytes: 512)
        else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "feed.attention.error.beginRequired",
                    defaultValue: "feed.attention.begin requires source, session_id, request_id, workspace_id, surface_id, and title"
                ),
                data: nil
            )
        }
        let remoteWorkspaceRaw = params["_cmux_remote_workspace_id"]
        let owner: FeedTransientAttentionStore.Owner
        if remoteWorkspaceRaw != nil {
            guard let remoteWorkspaceId = transientAttentionUUID(remoteWorkspaceRaw),
                  let remoteWorkspace = controlTabForSidebarMutation(id: remoteWorkspaceId),
                  remoteWorkspace.isRemoteWorkspace else {
                return invalidTransientAttentionOwnerResult()
            }
            owner = .remoteWorkspace(remoteWorkspaceId)
        } else {
            guard let ownerProcessIdentity = transientAttentionProcessIdentity(params) else {
                return invalidTransientAttentionOwnerResult()
            }
            owner = .localProcess(ownerProcessIdentity)
        }
        let subtitle = transientAttentionString(params["subtitle"], maxBytes: 512) ?? ""
        let body = transientAttentionString(params["body"], maxBytes: 4_096) ?? ""
        let active = FeedCoordinator.shared.beginTransientBlockingAttention(
            source: source,
            sessionId: sessionId,
            requestId: requestId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            owner: owner,
            title: title,
            subtitle: subtitle,
            body: body
        )
        return .ok(["active": active])
    }

    func v2FeedTransientAttentionEnd(params: [String: Any]) -> V2CallResult {
        guard let source = transientAttentionString(params["source"], maxBytes: 80),
              let sessionId = transientAttentionString(params["session_id"], maxBytes: 512)
        else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "feed.attention.error.endRequired",
                    defaultValue: "feed.attention.end requires source, session_id, and either request_id or all_requests: true"
                ),
                data: nil
            )
        }
        let remoteWorkspaceRaw = params["_cmux_remote_workspace_id"]
        let isLegacyRelease = params["legacy_release"] as? Bool == true
        let localProcessIdentity = transientAttentionProcessIdentity(params)
        let authenticatedRemoteWorkspaceId: UUID?
        let authenticatedLocalProcessIdentity: AgentPIDProcessIdentity?
        if remoteWorkspaceRaw != nil {
            guard let remoteWorkspaceId = transientAttentionUUID(remoteWorkspaceRaw),
                  let remoteWorkspace = controlTabForSidebarMutation(id: remoteWorkspaceId),
                  remoteWorkspace.isRemoteWorkspace else {
                return invalidTransientAttentionOwnerResult()
            }
            authenticatedRemoteWorkspaceId = remoteWorkspaceId
            authenticatedLocalProcessIdentity = nil
        } else {
            guard isLegacyRelease || localProcessIdentity != nil else {
                return invalidTransientAttentionOwnerResult()
            }
            authenticatedRemoteWorkspaceId = nil
            authenticatedLocalProcessIdentity = localProcessIdentity
        }
        if isLegacyRelease {
            return .ok(["ended": false])
        }
        let ended: Bool
        if (params["all_requests"] as? Bool) == true {
            ended = FeedCoordinator.shared.endTransientBlockingAttention(
                source: source,
                sessionId: sessionId,
                authenticatedRemoteWorkspaceId: authenticatedRemoteWorkspaceId,
                authenticatedLocalProcessIdentity: authenticatedLocalProcessIdentity
            )
        } else {
            guard let requestId = transientAttentionString(
                params["request_id"],
                maxBytes: 512
            ) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "feed.attention.error.endRequired",
                        defaultValue: "feed.attention.end requires source, session_id, and either request_id or all_requests: true"
                    ),
                    data: nil
                )
            }
            ended = FeedCoordinator.shared.endTransientBlockingAttention(
                source: source,
                sessionId: sessionId,
                requestId: requestId,
                authenticatedRemoteWorkspaceId: authenticatedRemoteWorkspaceId,
                authenticatedLocalProcessIdentity: authenticatedLocalProcessIdentity
            )
        }
        return .ok(["ended": ended])
    }

    private func invalidTransientAttentionOwnerResult() -> V2CallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "feed.attention.error.invalidOwnerIdentity",
                defaultValue: "feed.attention owner identity is invalid"
            ),
            data: nil
        )
    }

    private func transientAttentionString(_ rawValue: Any?, maxBytes: Int) -> String? {
        guard let value = rawValue as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxBytes else { return nil }
        return trimmed
    }

    private func transientAttentionUUID(_ rawValue: Any?) -> UUID? {
        guard let value = transientAttentionString(rawValue, maxBytes: 64) else { return nil }
        return UUID(uuidString: value)
    }

    private func transientAttentionProcessIdentity(
        _ params: [String: Any]
    ) -> AgentPIDProcessIdentity? {
        guard let ownerPID = v2StrictIntAny(params["ppid"]),
              let startSeconds = v2StrictIntAny(params["ppid_start_seconds"]),
              let startMicroseconds = v2StrictIntAny(params["ppid_start_microseconds"]),
              ownerPID > 0,
              ownerPID <= Int(Int32.max),
              startSeconds >= 0,
              (0..<1_000_000).contains(startMicroseconds) else {
            return nil
        }
        return AgentPIDProcessIdentity(
            pid: pid_t(ownerPID),
            startSeconds: Int64(startSeconds),
            startMicroseconds: Int64(startMicroseconds)
        )
    }
}
