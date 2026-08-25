/// Serializes the irreversible loginwindow call with Sleepy Mode cancellation.
///
/// Cancellation and invocation are actor messages, so they cannot interleave
/// between the final check and the C function call: whichever message the gate
/// accepts first owns the outcome. If cancellation wins, no lock is issued; if
/// invocation wins, the request began before lifecycle teardown.
actor SleepyLockInvocationGate {
    private var isCancelled = false

    /// Invokes an irreversible action only while this request is live.
    func invoke(_ action: @Sendable () -> Void) -> Bool {
        guard !isCancelled else { return false }
        action()
        return true
    }

    /// Revokes this request before it can invoke its action.
    func cancel() {
        isCancelled = true
    }
}
