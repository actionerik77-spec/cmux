import Foundation

/// Chooses a safe second publication attempt after reconnecting to the control socket.
struct AgentSurfaceResumePublicationRetry {
    enum Decision {
        case alreadyApplied
        case retry(params: [String: Any])
        case superseded
    }

    func decision(
        desiredParams: [String: Any],
        currentPayload: [String: Any],
        firstAttemptStartedAt: TimeInterval
    ) -> Decision {
        switch currentPayload["resume_binding"] {
        case .some(let rawBinding as [String: Any]):
            guard let number = rawBinding["updated_at"] as? NSNumber else {
                return .superseded
            }
            let updatedAt = number.doubleValue
            guard updatedAt.isFinite else {
                return .superseded
            }
            if matchesDesiredSession(rawBinding, desiredParams: desiredParams),
               updatedAt >= firstAttemptStartedAt {
                return .alreadyApplied
            }
            guard updatedAt < firstAttemptStartedAt else {
                return .superseded
            }
            var retryParams = desiredParams
            retryParams["_cmux_expected_binding_updated_at"] = updatedAt
            return .retry(params: retryParams)
        case .some(let value) where value is NSNull:
            var retryParams = desiredParams
            retryParams["_cmux_expect_missing_binding"] = true
            return .retry(params: retryParams)
        default:
            return .superseded
        }
    }

    private func matchesDesiredSession(
        _ binding: [String: Any],
        desiredParams: [String: Any]
    ) -> Bool {
        ["kind", "checkpoint_id", "source"].allSatisfy { key in
            normalized(binding[key] as? String) == normalized(desiredParams[key] as? String)
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
