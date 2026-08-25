import Darwin
import Foundation

extension TerminalController {
    /// Adds the accepted socket peer identity to transient-attention calls.
    /// The caller cannot forge this field: the dispatcher removes any
    /// user-supplied value and re-injects the PID captured at accept time.
    nonisolated func transientAttentionParams(
        method: String,
        params: [String: Any],
        peerProcessID: pid_t?
    ) -> [String: Any] {
        var sanitized = params
        sanitized.removeValue(forKey: "_cmux_peer_pid")
        guard method == "feed.attention.begin" || method == "feed.attention.end",
              let peerProcessID else {
            return sanitized
        }
        sanitized["_cmux_peer_pid"] = Int(peerProcessID)
        return sanitized
    }

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
        let authenticatedRemoteWorkspaceId: UUID?
        if remoteWorkspaceRaw != nil {
            guard let remoteWorkspaceId = transientAttentionUUID(remoteWorkspaceRaw),
                  let remoteWorkspace = controlTabForSidebarMutation(id: remoteWorkspaceId),
                  remoteWorkspace.isRemoteWorkspace,
                  AppDelegate.shared?.isRemoteTransientAttentionSurfaceAuthorized(
                      remoteWorkspaceID: remoteWorkspaceId,
                      claimedWorkspaceID: workspaceId,
                      surfaceID: surfaceId
                  ) == true else {
                return invalidTransientAttentionOwnerResult()
            }
            authenticatedRemoteWorkspaceId = remoteWorkspaceId
            owner = .remoteWorkspace(remoteWorkspaceId)
        } else {
            guard let ownerProcessIdentity = transientAttentionProcessIdentity(params) else {
                return invalidTransientAttentionOwnerResult()
            }
            if params["_cmux_peer_pid"] != nil {
                guard let peerPID = transientAttentionPeerPID(params),
                      transientAttentionPeerIsDescendant(
                          peerPID,
                          of: ownerProcessIdentity.pid
                      ) else {
                    return invalidTransientAttentionOwnerResult()
                }
            }
            authenticatedRemoteWorkspaceId = nil
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
            authenticatedRemoteWorkspaceId: authenticatedRemoteWorkspaceId,
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
            if !isLegacyRelease, params["_cmux_peer_pid"] != nil {
                guard let localProcessIdentity,
                      let peerPID = transientAttentionPeerPID(params),
                      transientAttentionPeerIsDescendant(
                          peerPID,
                          of: localProcessIdentity.pid
                      ) else {
                    return invalidTransientAttentionOwnerResult()
                }
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

    private func transientAttentionPeerPID(
        _ params: [String: Any]
    ) -> pid_t? {
        guard let rawPID = v2StrictIntAny(params["_cmux_peer_pid"]),
              rawPID > 0,
              rawPID <= Int(Int32.max) else {
            return nil
        }
        return pid_t(rawPID)
    }

    private func transientAttentionPeerIsDescendant(
        _ peerPID: pid_t,
        of ownerPID: pid_t
    ) -> Bool {
        guard peerPID > 0, ownerPID > 0 else { return false }
        var current = peerPID
        for _ in 0..<128 {
            if current == ownerPID { return true }
            if current <= 1 { return false }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
                return false
            }
            let parent = info.kp_eproc.e_ppid
            guard parent > 0, parent != current else { return false }
            current = parent
        }
        return false
    }
}
