import CMUXAgentLaunch
import Foundation

@MainActor
final class FeedTransientAttentionStore {
    nonisolated static let defaultMaximumEntryCount = 256

    struct Key: Hashable, Sendable {
        let source: String
        let sessionId: String
        let requestId: String
    }

    /// The lifecycle authority that can retire one transient attention entry.
    enum Owner: Hashable, Sendable {
        /// One exact local process generation, protected against PID reuse.
        case localProcess(AgentPIDProcessIdentity)
        /// The live remote workspace whose authenticated relay created it.
        /// Relay disconnect is recoverable, so this owner is retained until an
        /// authenticated end or workspace-close boundary proves completion.
        case remoteWorkspace(UUID)

        var localProcessIdentity: AgentPIDProcessIdentity? {
            guard case .localProcess(let identity) = self else { return nil }
            return identity
        }
    }

    struct Entry: Sendable {
        let target: FeedAttentionTarget
        let notificationCorrelationKey: String
        let owner: Owner
        /// The live terminal identity, which differs from `target.panelId` for
        /// a projected remote-tmux pane whose layout owner is its container.
        let liveSurfaceId: UUID?

        init(
            target: FeedAttentionTarget,
            notificationCorrelationKey: String,
            owner: Owner,
            liveSurfaceId: UUID? = nil
        ) {
            self.target = target
            self.notificationCorrelationKey = notificationCorrelationKey
            self.owner = owner
            self.liveSurfaceId = liveSurfaceId
        }
    }

    private struct StoredEntry {
        let entry: Entry
        let insertionOrder: UInt64
    }

    private let maximumEntryCount: Int
    private var entries: [Key: StoredEntry] = [:]
    private var nextInsertionOrder: UInt64 = 0

    init(
        maximumEntryCount: Int = defaultMaximumEntryCount
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func entry(for key: Key) -> Entry? {
        entries[key]?.entry
    }

    /// Inserts one request and returns any oldest entries evicted to preserve
    /// the hard registry bound. Duplicate request identities remain idempotent.
    @discardableResult
    func insert(_ entry: Entry, for key: Key) -> [Entry] {
        guard entries[key] == nil else { return [] }

        var evicted: [Entry] = []
        while entries.count >= maximumEntryCount,
              let oldestKey = entries.min(by: {
                  $0.value.insertionOrder < $1.value.insertionOrder
              })?.key,
              let oldest = removeValue(for: oldestKey) {
            evicted.append(oldest)
        }

        entries[key] = StoredEntry(
            entry: entry,
            insertionOrder: nextInsertionOrder
        )
        nextInsertionOrder &+= 1
        return evicted
    }

    func removeValue(for key: Key) -> Entry? {
        entries.removeValue(forKey: key)?.entry
    }

    func removeValues(ownerProcessIdentity: AgentPIDProcessIdentity) -> [Entry] {
        removeValues { _, entry in
            entry.owner == .localProcess(ownerProcessIdentity)
        }
    }

    func removeValues(workspaceId: UUID) -> [Entry] {
        removeValues { _, entry in
            entry.target.ownerId == workspaceId
                || entry.owner == .remoteWorkspace(workspaceId)
        }
    }

    func removeValues(surfaceId: UUID) -> [Entry] {
        removeValues { _, entry in
            entry.liveSurfaceId == surfaceId || entry.target.panelId == surfaceId
        }
    }

    func removeValues(
        source: String,
        sessionId: String,
        authenticatedRemoteWorkspaceId: UUID?
    ) -> [Entry] {
        removeValues { key, entry in
            guard key.source == source, key.sessionId == sessionId else {
                return false
            }
            guard let authenticatedRemoteWorkspaceId else { return true }
            return entry.owner == .remoteWorkspace(authenticatedRemoteWorkspaceId)
        }
    }

    func localProcessIdentities() -> Set<AgentPIDProcessIdentity> {
        Set(entries.values.compactMap { $0.entry.owner.localProcessIdentity })
    }

    private func removeValues(
        where predicate: (Key, Entry) -> Bool
    ) -> [Entry] {
        let matchingKeys = entries
            .filter { predicate($0.key, $0.value.entry) }
            .sorted { $0.value.insertionOrder < $1.value.insertionOrder }
            .map(\.key)
        return matchingKeys.compactMap(removeValue(for:))
    }
}

extension FeedCoordinator {
    /// Acquires attention for a blocker that intentionally does not create a
    /// durable Feed item (Claude's bypass-permissions question/plan fallback).
    /// The request is deduplicated by agent/session/tool identity, while the
    /// visible state uses the same per-target refcount as Feed decisions.
    @MainActor
    func beginTransientBlockingAttention(
        source: String,
        sessionId: String,
        requestId: String,
        workspaceId: UUID,
        surfaceId: UUID,
        owner: FeedTransientAttentionStore.Owner,
        title: String,
        subtitle: String,
        body: String
    ) -> Bool {
        let key = FeedTransientAttentionStore.Key(
            source: source,
            sessionId: sessionId,
            requestId: requestId
        )
        if case .localProcess(let ownerProcessIdentity) = owner,
           AgentPIDProcessIdentity(pid: ownerProcessIdentity.pid) != ownerProcessIdentity {
            return false
        }
        if let existing = transientAttentionStore.entry(for: key) {
            return existing.owner == owner
        }

        guard let liveTarget = AppDelegate.shared?.agentNotificationDeliveryTarget(
            claimedTabId: workspaceId,
            surfaceId: surfaceId
        ), let liveSurfaceId = liveTarget.surfaceId else { return false }
        let liveOwnerId = liveTarget.tabId
        let tabManager = AppDelegate.shared?.tabManagerFor(tabId: liveOwnerId)
            ?? AppDelegate.shared?.tabManagerFor(windowId: liveOwnerId)

        let event = WorkstreamEvent(
            sessionId: "\(source)-\(sessionId)",
            hookEventName: .askUserQuestion,
            source: source,
            workspaceId: liveOwnerId.uuidString,
            surfaceId: liveSurfaceId.uuidString,
            requestId: requestId
        )
        guard let target = surfaceBlockingDecisionAttention(
            event: event,
            resolved: (ownerId: liveOwnerId, surfaceId: liveSurfaceId),
            tabManager: tabManager
        ) else {
            return false
        }

        let correlationKey =
            TerminalNotification.transientAgentAttentionCorrelationPrefix + UUID().uuidString
        let evicted = transientAttentionStore.insert(
            FeedTransientAttentionStore.Entry(
                target: target,
                notificationCorrelationKey: correlationKey,
                owner: owner,
                liveSurfaceId: liveSurfaceId
            ),
            for: key
        )
        concludeTransientBlockingAttention(evicted)
        if case .localProcess(let ownerProcessIdentity) = owner {
            guard armTransientAttentionProcessWatcher(ownerProcessIdentity) else {
                if let entry = transientAttentionStore.removeValue(for: key) {
                    concludeTransientBlockingAttention([entry])
                }
                return false
            }
        }
        _ = AgentNotificationDelivery().enqueue(
            workspaceID: liveOwnerId,
            surfaceID: liveSurfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            category: .needsPermission,
            pending: false,
            coalesces: false,
            correlationKey: correlationKey
        )
        return true
    }

    /// Releases exactly one transient request. A missing or duplicate release
    /// is a no-op, and Feed-owned attention on the same pane remains refcounted.
    @MainActor
    func endTransientBlockingAttention(
        source: String,
        sessionId: String,
        requestId: String,
        authenticatedRemoteWorkspaceId: UUID? = nil
    ) -> Bool {
        let key = FeedTransientAttentionStore.Key(
            source: source,
            sessionId: sessionId,
            requestId: requestId
        )
        guard let existing = transientAttentionStore.entry(for: key) else {
            return false
        }
        if let authenticatedRemoteWorkspaceId,
           existing.owner != .remoteWorkspace(authenticatedRemoteWorkspaceId) {
            return false
        }
        guard let entry = transientAttentionStore.removeValue(for: key) else { return false }
        concludeTransientBlockingAttention([entry])
        return true
    }

    /// Releases every transient request in one current agent session. This is
    /// the turn-boundary reconciliation path and remains retryable even after
    /// durable blocker IDs have moved on to the next turn.
    @MainActor
    func endTransientBlockingAttention(
        source: String,
        sessionId: String,
        authenticatedRemoteWorkspaceId: UUID? = nil
    ) -> Bool {
        let entries = transientAttentionStore.removeValues(
            source: source,
            sessionId: sessionId,
            authenticatedRemoteWorkspaceId: authenticatedRemoteWorkspaceId
        )
        concludeTransientBlockingAttention(entries)
        return !entries.isEmpty
    }

    /// Releases every transient request owned by an exited agent process.
    /// Feed already uses a kqueue-backed watcher for durable decisions, so
    /// transient blockers share that same process-lifecycle authority.
    @MainActor
    func endTransientBlockingAttention(
        ownerProcessIdentity: AgentPIDProcessIdentity
    ) {
        concludeTransientBlockingAttention(
            transientAttentionStore.removeValues(
                ownerProcessIdentity: ownerProcessIdentity
            )
        )
    }

    /// Releases requests targeted at or relay-owned by a workspace that closed,
    /// balancing attention even when the hook callback vanished.
    @MainActor
    func endTransientBlockingAttention(workspaceId: UUID) {
        concludeTransientBlockingAttention(
            transientAttentionStore.removeValues(workspaceId: workspaceId)
        )
    }

    /// Releases requests whose terminal surface closed or whose remote
    /// terminal lifecycle ended while the workspace itself stayed open.
    @MainActor
    func endTransientBlockingAttention(surfaceId: UUID) {
        concludeTransientBlockingAttention(
            transientAttentionStore.removeValues(surfaceId: surfaceId)
        )
    }

    @MainActor
    func concludeTransientBlockingAttention(
        _ entries: [FeedTransientAttentionStore.Entry]
    ) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            concludeBlockingDecisionAttention(entry.target)
        }
        let correlationKeys = Set(entries.map(\.notificationCorrelationKey))
        TerminalMutationBus.shared.enqueueMainActorMutation {
            TerminalNotificationStore.shared.clearNotifications(
                correlationKeys: correlationKeys
            )
        }
        let releasedLocalOwners = Set(
            entries.compactMap { $0.owner.localProcessIdentity }
        )
        let retainedLocalOwners = transientAttentionStore.localProcessIdentities()
        for identity in releasedLocalOwners.subtracting(retainedLocalOwners) {
            disarmTransientAttentionProcessWatcher(identity)
        }
    }

    /// Watches one exact process generation. Numeric PID reuse cannot release
    /// attention owned by a later process because both the registry and watcher
    /// are keyed by the captured birth timestamp.
    @MainActor
    private func armTransientAttentionProcessWatcher(
        _ identity: AgentPIDProcessIdentity
    ) -> Bool {
        guard AgentPIDProcessIdentity(pid: identity.pid) == identity else { return false }
        if transientAttentionProcessWatchers[identity] != nil { return true }

        let source = DispatchSource.makeProcessSource(
            identifier: identity.pid,
            eventMask: .exit,
            queue: pidWatcherQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.endTransientBlockingAttention(
                    ownerProcessIdentity: identity
                )
            }
        }
        transientAttentionProcessWatchers[identity] = source
        source.resume()

        guard AgentPIDProcessIdentity(pid: identity.pid) == identity else {
            source.cancel()
            transientAttentionProcessWatchers.removeValue(forKey: identity)
            return false
        }
        return true
    }

    @MainActor
    private func disarmTransientAttentionProcessWatcher(
        _ identity: AgentPIDProcessIdentity
    ) {
        guard let source = transientAttentionProcessWatchers.removeValue(forKey: identity) else {
            return
        }
        source.cancel()
    }
}
