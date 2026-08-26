import Foundation

extension ClaudeHookSessionStore {
    private static let maximumPermissionRequestCount = 64
    private static let maximumPermissionNotificationRequestCount = 256

    /// Records one ordinary PermissionRequest without changing the agent
    /// lifecycle. Claude's PermissionRequest payload does not include
    /// `tool_use_id`, so an omitted ID receives a bounded synthetic marker.
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
            let requestAlreadyPending = pending.contains(requestId)
            let notificationAlreadyTracked =
                record.pendingPermissionNotificationRequestIds?.contains(requestId) == true
                || record.pendingPermissionNotificationCleanupRequestIds?.contains(requestId) == true
            if requestAlreadyPending && notificationAlreadyTracked {
                return requestId
            }
            guard requestAlreadyPending || pending.count < Self.maximumPermissionRequestCount,
                  enqueuePermissionNotificationRequestId(requestId, in: &record) else {
                return nil
            }
            if !requestAlreadyPending {
                pending.append(requestId)
                record.pendingPermissionRequestIds = pending
            }
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
            removePermissionNotificationRequestId(toolUseId, from: &record)
            record.updatedAt = Date.now.timeIntervalSince1970
            state.sessions[sessionId] = record
            return true
        }
    }

    /// Atomically assigns the oldest unmatched PermissionRequest to one delayed
    /// Claude Notification hook. The cleanup list remains durable until the app
    /// acknowledges that exact correlation key.
    func claimPermissionNotificationRequestId(sessionId: String) throws -> String? {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else {
            return nil
        }
        return try withLockedState { state in
            guard var record = state.sessions[sessionId],
                  var pending = record.pendingPermissionNotificationRequestIds,
                  !pending.isEmpty else {
                return nil
            }
            let requestId = pending.removeFirst()
            var cleanup = record.pendingPermissionNotificationCleanupRequestIds ?? []
            guard cleanup.contains(requestId)
                || cleanup.count < Self.maximumPermissionNotificationRequestCount else {
                return nil
            }
            if !cleanup.contains(requestId) {
                cleanup.append(requestId)
            }
            record.pendingPermissionNotificationRequestIds = pending.isEmpty ? nil : pending
            record.pendingPermissionNotificationCleanupRequestIds = cleanup
            record.updatedAt = Date.now.timeIntervalSince1970
            state.sessions[sessionId] = record
            return requestId
        }
    }

    /// Retires exact notification cleanup markers only after the app confirms
    /// their correlated rows are gone. A transport timeout leaves them retryable.
    func acknowledgePermissionNotificationCleanup(
        sessionId: String,
        requestIds: Set<String>
    ) throws {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId),
              !requestIds.isEmpty else {
            return
        }
        try withLockedState { state in
            guard var record = state.sessions[sessionId],
                  let cleanup = record.pendingPermissionNotificationCleanupRequestIds else {
                return
            }
            let remaining = cleanup.filter { !requestIds.contains($0) }
            guard remaining != cleanup else { return }
            record.pendingPermissionNotificationCleanupRequestIds = remaining.isEmpty
                ? nil
                : remaining
            record.updatedAt = Date.now.timeIntervalSince1970
            state.sessions[sessionId] = record
        }
    }

    @discardableResult
    func enqueuePermissionNotificationRequestId(
        _ requestId: String,
        in record: inout ClaudeHookSessionRecord
    ) -> Bool {
        guard let requestId = normalizedBlockingToolIdentifier(requestId) else {
            return false
        }
        var pending = record.pendingPermissionNotificationRequestIds ?? []
        guard !pending.contains(requestId) else { return true }
        guard pending.count < Self.maximumPermissionNotificationRequestCount else {
            return false
        }
        pending.append(requestId)
        record.pendingPermissionNotificationRequestIds = pending
        return true
    }

    func removePermissionNotificationRequestId(
        _ requestId: String,
        from record: inout ClaudeHookSessionRecord
    ) {
        guard let requestId = normalizedBlockingToolIdentifier(requestId),
              let pending = record.pendingPermissionNotificationRequestIds else {
            return
        }
        let remaining = pending.filter { $0 != requestId }
        record.pendingPermissionNotificationRequestIds = remaining.isEmpty ? nil : remaining
    }
}
