import Foundation

extension ClaudeHookSessionStore {
    private static let maximumPermissionRequestCount = 64

    /// Records one ordinary PermissionRequest without changing the agent
    /// lifecycle. Claude omits `tool_use_id`, so an omitted ID receives a
    /// bounded synthetic marker used only for the pending-owner count.
    @discardableResult
    func registerPermissionRequest(
        sessionId: String,
        toolUseId: String?
    ) throws -> String? {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else {
            return nil
        }
        let requestId = normalizedBlockingToolIdentifier(toolUseId)
            ?? "cmux-permission-\(UUID().uuidString.lowercased())"
        return try withLockedState { state in
            guard var record = state.sessions[sessionId] else { return nil }
            var pending = record.pendingPermissionRequestIds ?? []
            if pending.contains(requestId) {
                guard record.permissionNotificationMode != .sessionAggregate else {
                    return requestId
                }
                record.permissionNotificationMode = .sessionAggregate
                record.updatedAt = Date.now.timeIntervalSince1970
                state.sessions[sessionId] = record
                return requestId
            }
            guard pending.count < Self.maximumPermissionRequestCount else { return nil }
            pending.append(requestId)
            record.pendingPermissionRequestIds = pending
            record.permissionNotificationMode = .sessionAggregate
            record.updatedAt = Date.now.timeIntervalSince1970
            state.sessions[sessionId] = record
            return requestId
        }
    }

    @discardableResult
    func beginPermissionRequest(
        sessionId: String,
        toolUseId: String?
    ) throws -> Bool {
        try registerPermissionRequest(sessionId: sessionId, toolUseId: toolUseId) != nil
    }

    @discardableResult
    func finishPermissionRequest(
        sessionId: String,
        toolUseId: String?
    ) throws -> Bool {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId),
              let toolUseId = normalizedBlockingToolIdentifier(toolUseId) else {
            return false
        }
        return try withLockedState { state in
            guard var record = state.sessions[sessionId],
                  var pending = record.pendingPermissionRequestIds,
                  let index = pending.firstIndex(of: toolUseId) else {
                return false
            }
            pending.remove(at: index)
            record.pendingPermissionRequestIds = pending.isEmpty ? nil : pending
            record.updatedAt = Date.now.timeIntervalSince1970
            state.sessions[sessionId] = record
            return true
        }
    }

    func markPermissionNotificationAggregation(sessionId: String) throws {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else { return }
        try withLockedState { state in
            guard var record = state.sessions[sessionId],
                  record.permissionNotificationMode != .sessionAggregate else {
                return
            }
            record.permissionNotificationMode = .sessionAggregate
            record.updatedAt = Date.now.timeIntervalSince1970
            state.sessions[sessionId] = record
        }
    }

    func permissionNotificationState(
        sessionId: String
    ) throws -> ClaudePermissionNotificationState {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else {
            return .legacyUncorrelated
        }
        return try withLockedState { state in
            guard let record = state.sessions[sessionId],
                  record.permissionNotificationMode == .sessionAggregate else {
                return .legacyUncorrelated
            }
            let hasPendingOwner = record.pendingPermissionRequestIds?.isEmpty == false
                || record.pendingBlockingToolUseIds?.isEmpty == false
            return hasPendingOwner ? .pending : .settled
        }
    }
}
