internal import Foundation

extension ControlCommandCoordinator {
    /// Parses the two accepted spellings for a caller-owned group identity.
    /// `external_id` is the durable model name; `idempotency_key` is the
    /// standard retry-oriented alias. Supplying both is allowed only when they
    /// agree exactly after trimming.
    func workspaceGroupExternalID(
        _ params: [String: JSONValue]
    ) -> (value: String?, error: ControlCallResult?) {
        var values: [(String, String)] = []
        for key in ["external_id", "idempotency_key"] {
            guard let value = params[key], !workspaceGroupIdentityIsNull(value) else { continue }
            guard case .string(let raw) = value else {
                return (nil, .err(
                    code: "invalid_params",
                    message: workspaceGroupStrings().idempotencyKeyMustBeString,
                    data: .object(["field": .string(key)])
                ))
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return (nil, .err(
                    code: "invalid_params",
                    message: workspaceGroupStrings().idempotencyKeyMustNotBeEmpty,
                    data: .object(["field": .string(key)])
                ))
            }
            values.append((key, trimmed))
        }
        let uniqueValues = Set(values.map(\.1))
        guard uniqueValues.count <= 1 else {
            return (nil, .err(
                code: "invalid_params",
                message: workspaceGroupStrings().idempotencyKeysMustMatch,
                data: nil
            ))
        }
        return (values.first?.1, nil)
    }

    /// Returns whether a JSON value is the protocol's explicit null.
    private func workspaceGroupIdentityIsNull(_ value: JSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }
}
