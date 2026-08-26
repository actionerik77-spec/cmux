import Foundation

/// The agent-process scope captured when a compound prompt is admitted.
///
/// ``unbound`` is distinct from an absent scope snapshot: an admitted mobile
/// compatibility transaction may run while no process identity is available,
/// but it must not replay into a different process that binds before delivery.
public enum PromptSubmissionAgentScope: Sendable, Equatable {
    /// No authoritative agent process identity existed at admission time.
    case unbound(terminalLifecycleID: UUID)
    /// The identified process scope that owned the admission.
    case bound(String)

    /// Creates a captured scope from the current optional process identity.
    public init(
        _ scope: String?,
        terminalLifecycleID: UUID = UUID()
    ) {
        if let scope {
            self = .bound(scope)
        } else {
            self = .unbound(terminalLifecycleID: terminalLifecycleID)
        }
    }

    /// Whether the current process identity can safely receive the admission.
    ///
    /// - Parameters:
    ///   - currentScope: The process scope currently published by the agent
    ///     tracker.
    ///   - terminalLifecycleID: The surface lifecycle currently receiving the
    ///     transaction.
    public func matches(
        _ currentScope: String?,
        terminalLifecycleID: UUID
    ) -> Bool {
        switch self {
        case .unbound(let capturedLifecycleID):
            // A nil scope is not proof that the original agent still owns the
            // terminal. The compatibility path may cross the initial tracker
            // publication, but only within the same terminal lifecycle.
            return currentScope != nil
                && capturedLifecycleID == terminalLifecycleID
        case .bound(let scope):
            return currentScope == scope
        }
    }
}
