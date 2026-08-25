import Foundation
import CMUXAgentLaunch

extension SessionRestorableAgentSnapshot {
    /// Uses an authoritative agent-hook checkpoint when process discovery
    /// represented the same Pi/OMP session by its JSONL path.
    func retargetedForResumeBinding(
        _ binding: SurfaceResumeBindingSnapshot?
    ) -> Self {
        guard let binding,
              binding.isAgentHookBinding,
              let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointId.isEmpty,
              ManagedAgentSessionIdentity.sessionIDsMatch(
                  kind: kind.rawValue,
                  lhs: sessionId,
                  rhs: checkpointId
              ) else {
            return self
        }
        guard sessionId != checkpointId else { return self }
        var retargeted = self
        retargeted.sessionId = checkpointId
        return retargeted
    }

    /// Builds the durable hook binding that can relaunch this agent session.
    ///
    /// The snapshot is the app's authoritative, structured identity for an agent. Keeping the
    /// binding derivation here gives session-save backfill and restore-time repair one command and
    /// working-directory policy instead of allowing each persistence owner to reconstruct it.
    func resumeBindingSnapshot() -> SurfaceResumeBindingSnapshot? {
        let resolvedWorkingDirectory = AgentResumeWorkingDirectory().resolve(
            kind: kind.rawValue,
            runtimeCwd: workingDirectory,
            launchWorkingDirectory: launchCommand?.workingDirectory
        )
        guard let command = resumeCommand(
            includeWorkingDirectoryPrefix: true,
            restoringWorkingDirectory: resolvedWorkingDirectory
        ) else {
            return nil
        }
        return SurfaceResumeBindingSnapshot(
            name: agentDisplayName,
            kind: kind.rawValue,
            command: command,
            cwd: resolvedWorkingDirectory,
            checkpointId: sessionId,
            source: "agent-hook",
            environment: launchCommand?.environment,
            launchCommand: launchCommand,
            permissionMode: permissionMode,
            autoResume: true
        )
    }
}
