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

/// Parsed `c=<category>;p=<0|1>[;k=<correlation>]` meta segment. Returns `nil`
/// unless a known category and valid pending flag are present; an optional
/// bounded correlation key scopes cleanup to one agent notification.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    let correlationKey: String?

    init?(meta: String) {
        // Accept only the canonical serialization the CLI emits. Unknown,
        // reordered, duplicated, or malformed fields remain legacy body text.
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3,
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p=") else { return nil }
        guard let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))),
              known != .other else { return nil }
        switch fields[1].dropFirst(2) {
        case "1": self.pending = true
        case "0": self.pending = false
        default: return nil
        }
        self.category = known
        if fields.count == 3 {
            guard fields[2].hasPrefix("k=") else { return nil }
            let key = String(fields[2].dropFirst(2))
            guard !key.isEmpty,
                  key.utf8.count <= 256,
                  !key.contains(where: { $0 == ";" || $0 == "|" || $0.isWhitespace }) else {
                return nil
            }
            self.correlationKey = key
        } else {
            self.correlationKey = nil
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
