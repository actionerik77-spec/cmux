import Foundation

/// Category an agent hook attaches to a notification so the app can gate
/// delivery by user config. Mirrors the CLI's `ClaudeNotifyCategory`; serialized
/// into the `notify_target_async` payload's optional `c=<category>;p=<0|1>` meta.
enum AgentNotifyCategory: String {
    case turnComplete = "turn-complete"
    case needsPermission = "needs-permission"
    case idleReminder = "idle-reminder"
    case other
}

/// User policy for the "Claude finished a turn" notification.
enum AgentTurnCompleteMode: String {
    case whenIdle
    case always
    case never
}

/// Parsed `c=<category>;p=<0|1>[;a=<agent-kind-or-approval-id>][;n=<0|1>]`.
/// The historical Codex approval form uses `a=<approval-id>`, while newer
/// ordinary agent events use the same field for a validated agent slug. The
/// value shape disambiguates the two without changing either wire format.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    let approvalID: AgentApprovalCorrelationID?
    let agentKind: String?
    let isSubagent: Bool?

    init?(meta: String) {
        // Accept ONLY the canonical serialization the CLI emits (`c=` then
        // `p=`, optionally followed by `a=` then `n=`, this order, no
        // duplicates or extras). Anything else stays part of the legacy body.
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        guard (2...4).contains(fields.count),
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p=") else { return nil }
        guard let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))),
              known != .other else { return nil }
        switch fields[1].dropFirst(2) {
        case "1": self.pending = true
        case "0": self.pending = false
        default: return nil
        }
        var approvalID: AgentApprovalCorrelationID? = nil
        var agentKind: String? = nil
        var isSubagent: Bool? = nil
        var index = 2
        if index < fields.count, fields[index].hasPrefix("a=") {
            let value = String(fields[index].dropFirst(2))
            if let parsedApprovalID = AgentApprovalCorrelationID(rawValue: value) {
                guard known == .needsPermission else { return nil }
                approvalID = parsedApprovalID
            } else {
                guard Self.isValidAgentKindTag(value) else { return nil }
                agentKind = value
            }
            index += 1
        }
        if index < fields.count, fields[index].hasPrefix("n=") {
            switch fields[index].dropFirst(2) {
            case "1": isSubagent = true
            case "0": isSubagent = false
            default: return nil
            }
            index += 1
        }
        guard index == fields.count else { return nil }
        self.category = known
        self.approvalID = approvalID
        self.agentKind = agentKind
        self.isSubagent = isSubagent
    }

    /// Mirror of the CLI's `AgentHookNotifyCategory.isValidAgentKindTag` slug
    /// grammar: 1-64 characters of `[a-z0-9._-]`. Both sides must agree
    /// exactly or the meta folds back into the notification body.
    static func isValidAgentKindTag(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLowercase || character.isNumber
                    || character == "." || character == "_" || character == "-")
        }
    }
}

/// Pure delivery decision for agent-tagged notifications. Kept free of any I/O
/// so it can be exhaustively unit-tested against the decision table.
nonisolated func agentNotificationShouldDeliver(
    category: AgentNotifyCategory,
    pending: Bool,
    permissionEnabled: Bool,
    turnMode: AgentTurnCompleteMode,
    idleEnabled: Bool
) -> Bool {
    switch category {
    case .needsPermission:
        return permissionEnabled
    case .turnComplete:
        switch turnMode {
        case .always: return true
        case .never: return false
        case .whenIdle: return !pending
        }
    case .idleReminder:
        return idleEnabled && !pending
    case .other:
        // Legacy/uncategorized (codex, grok, antigravity, pre-meta clients):
        // deliver exactly as before.
        return true
    }
}
