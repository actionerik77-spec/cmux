import CryptoKit
import Foundation

extension ClaudeHookSessionStore {
    struct BlockingToolCorrelation: Codable, Equatable {
        let payloadSignature: String
        let toolUseId: String
        /// The Claude turn that registered this payload, when available.
        let turnId: String?
    }

    struct BlockingToolRegistration: Equatable {
        let owner: ClaudeHookSessionRecord
        let requestId: String
    }

    enum BlockingToolSelection: Equatable {
        case selected(requestId: String?)
        case ignoreUnmatched
    }

    enum BlockingToolResolution: Equatable {
        case resolved
        case ignoreUnmatched
    }

    private static let maximumBlockingToolCorrelationCount = 256
    /// Caps the canonical fallback payload so a synchronous hook cannot spend
    /// unbounded time and memory serializing model-controlled tool input.
    private static let maximumBlockingToolPayloadSignatureBytes = 64 * 1024
    private static let maximumBlockingToolPayloadSignatureDepth = 4
    private static let maximumBlockingToolPayloadSignatureCollectionCount = 16
    private static let maximumBlockingToolPayloadSignatureStringBytes = 512
    private static let maximumBlockingToolPayloadSignatureKeyBytes = 128

    /// Returns the session displaced by a pane-scoped active-session boundary.
    /// Legacy workspace-only slots are accepted only when their recorded pane
    /// matches, so cleanup cannot release attention owned by a sibling split.
    func activeBlockingAttentionSessionId(
        workspaceId: String,
        surfaceId: String?
    ) throws -> String? {
        guard let workspaceId = normalizedBlockingToolIdentifier(workspaceId) else {
            return nil
        }
        let surfaceId = normalizedBlockingToolIdentifier(surfaceId)
        return try withLockedState { state in
            if let surfaceId,
               let active = state.activeSessionsBySurface[surfaceId] {
                return active.sessionId
            }
            guard let active = state.activeSessionsByWorkspace[workspaceId] else {
                return nil
            }
            if let surfaceId {
                guard let record = state.sessions[active.sessionId],
                      normalizedBlockingToolIdentifier(record.surfaceId) == surfaceId else {
                    return nil
                }
            }
            return active.sessionId
        }
    }

    /// Atomically records a blocking Claude tool and its Needs input lifecycle.
    /// Hooks without Claude's `tool_use_id` receive a durable synthetic request
    /// ID so concurrent legacy blockers still own distinct transient attention.
    func recordBlockingToolNeedsInput(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        agentPID: Int?,
        toolUseId: String?,
        turnId: String? = nil,
        rawObject: [String: Any]?,
        lastSubtitle: String,
        lastBody: String
    ) throws -> BlockingToolRegistration? {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else { return nil }
        return try withLockedState { state in
            let now = Date.now.timeIntervalSince1970
            var record = state.sessions[sessionId] ?? ClaudeHookSessionRecord(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                startedAt: now,
                updatedAt: now
            )
            updateBlockingToolRecord(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                lifecycle: .needsInput,
                lastSubtitle: lastSubtitle,
                lastBody: lastBody,
                now: now
            )
            if let agentPID {
                updateProcessIdentity(&record, pid: agentPID)
            }
            let requestId = normalizedBlockingToolIdentifier(toolUseId)
                ?? "cmux-fallback-\(UUID().uuidString.lowercased())"
            let pending = (record.pendingBlockingToolUseIds ?? []) + [requestId]
            record.pendingBlockingToolUseIds = normalizedBlockingToolUseIds(pending)
            if let payloadSignature = blockingToolPayloadSignature(from: rawObject) {
                var correlations = (record.pendingBlockingToolCorrelations ?? [])
                    .filter { $0.toolUseId != requestId }
                correlations.append(BlockingToolCorrelation(
                    payloadSignature: payloadSignature,
                    toolUseId: requestId,
                    turnId: normalizedBlockingToolIdentifier(turnId)
                ))
                if correlations.count > Self.maximumBlockingToolCorrelationCount {
                    let overflowCount =
                        correlations.count - Self.maximumBlockingToolCorrelationCount
                    let evictedToolUseIds = Set(
                        correlations.prefix(overflowCount).map(\.toolUseId)
                    )
                    correlations.removeFirst(overflowCount)
                    record.pendingBlockingToolUseIds = normalizedBlockingToolUseIds(
                        (record.pendingBlockingToolUseIds ?? []).filter {
                            !evictedToolUseIds.contains($0)
                        }
                    )
                }
                record.pendingBlockingToolCorrelations = correlations
            }
            if let pendingIds = record.pendingBlockingToolUseIds,
               pendingIds.count > Self.maximumBlockingToolCorrelationCount {
                var retainedIds = Set(
                    pendingIds
                        .filter { $0 != requestId }
                        .suffix(Self.maximumBlockingToolCorrelationCount - 1)
                )
                retainedIds.insert(requestId)
                record.pendingBlockingToolUseIds = Array(retainedIds).sorted()
                record.pendingBlockingToolCorrelations =
                    record.pendingBlockingToolCorrelations?
                    .filter { retainedIds.contains($0.toolUseId) }
            }
            state.sessions[sessionId] = record
            return BlockingToolRegistration(owner: record, requestId: requestId)
        }
    }

    /// Selects the durable request that a completion must release without
    /// consuming it. The caller removes attention first, then commits the
    /// matching state transition only after the app acknowledges that release.
    /// Missing sessions are ignored rather than treated as legacy records.
    func selectBlockingToolInput(
        sessionId: String,
        toolUseId: String?,
        rawObject: [String: Any]?,
        turnId: String? = nil
    ) throws -> BlockingToolSelection {
        let explicitRequestId = normalizedBlockingToolIdentifier(toolUseId)
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else {
            return .ignoreUnmatched
        }
        return try withLockedState { state in
            guard let record = state.sessions[sessionId] else {
                return .ignoreUnmatched
            }
            guard let storedPending = record.pendingBlockingToolUseIds else {
                // Records written before correlation use the shared legacy key.
                return .selected(requestId: explicitRequestId)
            }
            let pending = normalizedBlockingToolUseIds(storedPending)
            guard let requestId = correlatedBlockingToolUseId(
                explicitToolUseId: explicitRequestId,
                rawObject: rawObject,
                record: record,
                incomingTurnId: turnId
            ), pending.contains(requestId) else {
                return .ignoreUnmatched
            }
            return .selected(requestId: requestId)
        }
    }

    /// Atomically resolves only the matching blocking tool. A non-nil pending
    /// array enables correlated completion, including an empty array retained
    /// as a tombstone so a later duplicate PostToolUse cannot fall back to the
    /// legacy session-wide path. Records predating correlation keep `nil`;
    /// records removed after selection are not recreated during resolution.
    func resolveBlockingToolInput(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        toolUseId: String?,
        turnId: String? = nil
    ) throws -> BlockingToolResolution {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else {
            return .ignoreUnmatched
        }
        return try withLockedState { state in
            let now = Date.now.timeIntervalSince1970
            guard var record = state.sessions[sessionId] else {
                return .ignoreUnmatched
            }

            let resolution = resolveBlockingTool(
                in: &record,
                toolUseId: toolUseId,
                turnId: turnId,
                now: now
            )
            guard resolution == .resolved else { return resolution }
            updateBlockingToolRecord(
                &record,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                lifecycle: record.pendingBlockingToolUseIds?.isEmpty == false
                    ? .needsInput
                    : .running,
                lastSubtitle: nil,
                lastBody: nil,
                now: now
            )
            state.sessions[sessionId] = record
            return .resolved
        }
    }

    /// Retires a PermissionRequest after Feed reaches a terminal response
    /// without rewriting delivery routing. Feed owns visible attention for
    /// this path; the store only prevents a denied or timed-out tool from
    /// poisoning a later blocker.
    func resolveBlockingToolPermissionRequest(
        sessionId: String,
        toolUseId: String?,
        rawObject: [String: Any]?,
        turnId: String? = nil
    ) throws -> BlockingToolResolution {
        guard let sessionId = normalizedBlockingToolIdentifier(sessionId) else {
            return .resolved
        }
        return try withLockedState { state in
            guard var record = state.sessions[sessionId] else {
                return .ignoreUnmatched
            }
            let resolution = resolveBlockingTool(
                in: &record,
                toolUseId: correlatedBlockingToolUseId(
                    explicitToolUseId: toolUseId,
                    rawObject: rawObject,
                    record: record,
                    incomingTurnId: turnId
                ),
                turnId: turnId,
                now: Date.now.timeIntervalSince1970
            )
            guard resolution == .resolved else { return resolution }
            state.sessions[sessionId] = record
            return .resolved
        }
    }

    private func resolveBlockingTool(
        in record: inout ClaudeHookSessionRecord,
        toolUseId: String?,
        turnId: String?,
        now: TimeInterval
    ) -> BlockingToolResolution {
        if let storedPending = record.pendingBlockingToolUseIds {
            let pending = normalizedBlockingToolUseIds(storedPending)
            guard let toolUseId = normalizedBlockingToolIdentifier(toolUseId),
                  pending.contains(toolUseId),
                  blockingToolTurnMatches(
                      storedTurnId: record.pendingBlockingToolCorrelations?.first {
                          $0.toolUseId == toolUseId
                      }?.turnId,
                      incomingTurnId: turnId
                  ) else {
                return .ignoreUnmatched
            }
            let remaining = pending.filter { $0 != toolUseId }
            record.pendingBlockingToolUseIds = remaining
            record.pendingBlockingToolCorrelations =
                (record.pendingBlockingToolCorrelations ?? [])
                .filter { $0.toolUseId != toolUseId }
            record.agentLifecycle = remaining.isEmpty ? .running : .needsInput
            record.updatedAt = now
            return .resolved
        }

        // Legacy records lack IDs, so the only safe behavior is the historic
        // session-wide resolution. New correlated records never return to nil.
        record.pendingBlockingToolCorrelations = nil
        record.agentLifecycle = .running
        record.updatedAt = now
        return .resolved
    }

    private func updateBlockingToolRecord(
        _ record: inout ClaudeHookSessionRecord,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String?,
        lifecycle: AgentHibernationLifecycleState,
        lastSubtitle: String?,
        lastBody: String?,
        now: TimeInterval
    ) {
        record.workspaceId = workspaceId
        if let surfaceId = normalizedBlockingToolIdentifier(surfaceId) {
            record.surfaceId = surfaceId
        }
        if let cwd = normalizedBlockingToolIdentifier(cwd) {
            record.cwd = cwd
        }
        if let transcriptPath = normalizedBlockingToolIdentifier(transcriptPath) {
            record.transcriptPath = transcriptPath
        }
        record.agentLifecycle = lifecycle
        if let lastSubtitle = normalizedBlockingToolIdentifier(lastSubtitle) {
            record.lastSubtitle = lastSubtitle
        }
        if let lastBody = normalizedBlockingToolIdentifier(lastBody) {
            record.lastBody = lastBody
        }
        record.updatedAt = now
    }

    private func normalizedBlockingToolUseIds(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { normalizedBlockingToolIdentifier($0) })).sorted()
    }

    private func correlatedBlockingToolUseId(
        explicitToolUseId: String?,
        rawObject: [String: Any]?,
        record: ClaudeHookSessionRecord,
        incomingTurnId: String?
    ) -> String? {
        if let explicitToolUseId = normalizedBlockingToolIdentifier(explicitToolUseId) {
            guard blockingToolTurnMatches(
                storedTurnId: record.pendingBlockingToolCorrelations?.first {
                    $0.toolUseId == explicitToolUseId
                }?.turnId,
                incomingTurnId: incomingTurnId
            ) else {
                return nil
            }
            return explicitToolUseId
        }
        guard record.pendingBlockingToolUseIds != nil,
              let payloadSignature = blockingToolPayloadSignature(from: rawObject) else {
            return nil
        }
        let pending = Set(normalizedBlockingToolUseIds(
            record.pendingBlockingToolUseIds ?? []
        ))
        return record.pendingBlockingToolCorrelations?.first {
            $0.payloadSignature == payloadSignature
                && pending.contains($0.toolUseId)
                && blockingToolTurnMatches(
                    storedTurnId: $0.turnId,
                    incomingTurnId: incomingTurnId
                )
        }?.toolUseId
    }

    private func blockingToolTurnMatches(
        storedTurnId: String?,
        incomingTurnId: String?
    ) -> Bool {
        guard let storedTurnId = normalizedBlockingToolIdentifier(storedTurnId) else {
            return true
        }
        guard let incomingTurnId = normalizedBlockingToolIdentifier(incomingTurnId) else {
            return false
        }
        return storedTurnId == incomingTurnId
    }

    private func blockingToolPayloadSignature(
        from rawObject: [String: Any]?
    ) -> String? {
        guard let rawObject else { return nil }
        let rawToolName = rawObject["tool_name"] ?? rawObject["toolName"]
        let toolName = normalizedBlockingToolIdentifier(rawToolName as? String)
        let toolInput = rawObject["tool_input"] ?? rawObject["toolInput"] ?? NSNull()
        guard toolName?.utf8.count ?? 0 <= Self.maximumBlockingToolPayloadSignatureKeyBytes,
              blockingToolPayloadValueIsBounded(toolInput, depth: 0) else {
            return nil
        }
        let canonicalPayload: [String: Any] = [
            "tool_input": toolInput,
            "tool_name": toolName ?? NSNull(),
        ]
        guard JSONSerialization.isValidJSONObject(canonicalPayload),
              let data = try? JSONSerialization.data(
                  withJSONObject: canonicalPayload,
                  options: [.sortedKeys]
              ), data.count <= Self.maximumBlockingToolPayloadSignatureBytes else {
            return nil
        }
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    /// Rejects values that would be truncated before fallback correlation.
    /// A truncated signature could make two distinct blockers look identical;
    /// an explicit tool ID remains the only safe path for oversized payloads.
    private func blockingToolPayloadValueIsBounded(
        _ value: Any,
        depth: Int
    ) -> Bool {
        if let string = value as? String {
            return string.utf8.count <= Self.maximumBlockingToolPayloadSignatureStringBytes
        }
        if value is Bool || value is NSNumber || value is NSNull { return true }
        guard depth < Self.maximumBlockingToolPayloadSignatureDepth else {
            return false
        }
        if let dictionary = value as? [String: Any] {
            guard dictionary.count <= Self.maximumBlockingToolPayloadSignatureCollectionCount else {
                return false
            }
            return dictionary.allSatisfy { key, value in
                key.utf8.count <= Self.maximumBlockingToolPayloadSignatureKeyBytes
                    && blockingToolPayloadValueIsBounded(value, depth: depth + 1)
            }
        }
        if let array = value as? [Any] {
            guard array.count <= Self.maximumBlockingToolPayloadSignatureCollectionCount else {
                return false
            }
            return array.allSatisfy {
                blockingToolPayloadValueIsBounded($0, depth: depth + 1)
            }
        }
        return false
    }

    private func normalizedBlockingToolIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
