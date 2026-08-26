import CmuxFoundation

/// Serializes the irreversible loginwindow call with Sleepy Mode cancellation.
///
/// The two atomic flags provide a linearization point without blocking an actor:
/// invocation claims the request first, then checks cancellation. If cancellation
/// wins before that claim, no lock is issued; if invocation claims first, the
/// request began before lifecycle teardown and is allowed to finish.
final class SleepyLockInvocationGate: @unchecked Sendable {
    // Safety: both values are immutable references to C11 atomic storage; all
    // mutable state is accessed through AtomicBooleanGate's atomic operations.
    private let didInvoke = AtomicBooleanGate(false)
    private let isCancelled = AtomicBooleanGate(false)

    /// Invokes an irreversible action only while this request is live.
    @discardableResult
    func invoke(_ action: @Sendable () -> Void) -> Bool {
        // Claim before loading cancellation so cancellation can never land
        // between the final check and the irreversible action.
        guard didInvoke.compareExchange(expected: false, desired: true),
              !isCancelled.loadAcquire() else { return false }
        action()
        return true
    }

    /// Revokes this request before it can invoke its action.
    func cancel() {
        isCancelled.storeRelease(true)
    }
}
