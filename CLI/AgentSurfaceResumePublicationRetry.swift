import Foundation

/// Chooses a safe second publication attempt from app-owned binding generations.
struct AgentSurfaceResumePublicationRetry {
    enum BindingGeneration: Equatable {
        case missing
        case updatedAt(Double)
    }

    struct Preflight {
        let params: [String: Any]
        let generation: BindingGeneration
    }

    enum Decision {
        case alreadyApplied
        case retry(params: [String: Any])
        case superseded
    }

    func preflight(
        desiredParams: [String: Any],
        currentPayload: [String: Any]
    ) -> Preflight? {
        guard let current = currentBinding(in: currentPayload) else { return nil }
        return Preflight(
            params: guardedParams(desiredParams, generation: current.generation),
            generation: current.generation
        )
    }

    func decision(
        desiredParams: [String: Any],
        currentPayload: [String: Any],
        baselineGeneration: BindingGeneration
    ) -> Decision {
        guard let current = currentBinding(in: currentPayload) else {
            return .superseded
        }
        if let binding = current.binding,
           matchesDesiredSession(binding, desiredParams: desiredParams),
           current.generation != baselineGeneration {
            return .alreadyApplied
        }
        guard current.generation == baselineGeneration else {
            return .superseded
        }
        return .retry(params: guardedParams(desiredParams, generation: baselineGeneration))
    }

    private func currentBinding(
        in payload: [String: Any]
    ) -> (generation: BindingGeneration, binding: [String: Any]?)? {
        switch payload["resume_binding"] {
        case .some(let binding as [String: Any]):
            guard let number = binding["updated_at"] as? NSNumber else { return nil }
            let updatedAt = number.doubleValue
            guard updatedAt.isFinite else { return nil }
            return (.updatedAt(updatedAt), binding)
        case .some(let value) where value is NSNull:
            return (.missing, nil)
        default:
            return nil
        }
    }

    private func guardedParams(
        _ desiredParams: [String: Any],
        generation: BindingGeneration
    ) -> [String: Any] {
        var params = desiredParams
        switch generation {
        case .missing:
            params["_cmux_expect_missing_binding"] = true
            params.removeValue(forKey: "_cmux_expected_binding_updated_at")
        case .updatedAt(let updatedAt):
            params["_cmux_expected_binding_updated_at"] = updatedAt
            params.removeValue(forKey: "_cmux_expect_missing_binding")
        }
        return params
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
