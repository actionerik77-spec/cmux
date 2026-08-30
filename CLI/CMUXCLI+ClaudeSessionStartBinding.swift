import Foundation

extension CMUXCLI {
    /// Preserves only a matching rejected restore and retires any prior agent-hook owner.
    func reconcileRejectedClaudeRestoreBinding(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String,
        acceptedSessionId: String
    ) -> Bool {
        do {
            let payload = try client.sendV2(
                method: "surface.resume.get",
                params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                ]
            )
            switch payload["resume_binding"] {
            case .some(let binding as [String: Any]):
                guard normalizedHookValue(binding["source"] as? String) == "agent-hook" else {
                    return false
                }
                let currentSessionId = normalizedHookValue(binding["checkpoint_id"] as? String)
                let currentKind = normalizedHookValue(binding["kind"] as? String)?.lowercased()
                if (currentKind == nil || currentKind == "claude"),
                   currentSessionId == normalizedHookValue(acceptedSessionId) {
                    return true
                }
                let updatedAt = (binding["updated_at"] as? NSNumber)?.doubleValue
                _ = clearAgentSurfaceResumeBindingOutcome(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    sessionId: currentSessionId,
                    updatedAt: updatedAt?.isFinite == true ? updatedAt : nil
                )
                return false
            case .some(let value) where value is NSNull:
                return false
            default:
                return false
            }
        } catch {
            return false
        }
    }
}
