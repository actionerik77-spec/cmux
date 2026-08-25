public import Foundation
internal import os

/// Delivers the eventual result of one queued compound prompt submission.
///
/// A caller can acknowledge admission immediately while retaining a receipt
/// that completes only when the queued paste-and-submit transaction is sent or
/// fails definitively. The stream is bounded to one result because a receipt
/// represents exactly one terminal transaction.
public final class PromptSubmissionDeliveryReceipt: Sendable {
    private enum State {
        case pending
        case finished
        case cancelled
    }

    private let results: AsyncStream<PromptSubmissionSendResult>
    private let continuation: AsyncStream<PromptSubmissionSendResult>.Continuation
    // A short compare-and-set protects one-shot publication when a timeout or
    // surface teardown races the MainActor delivery callback.
    private let state = OSAllocatedUnfairLock<State>(initialState: .pending)

    /// Creates an unresolved delivery receipt.
    public init() {
        let stream = AsyncStream<PromptSubmissionSendResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        results = stream.stream
        continuation = stream.continuation
    }

    /// Completes the receipt with the terminal delivery outcome.
    ///
    /// The owning surface calls this exactly once when the compound
    /// transaction is sent or rejected after admission.
    public func finish(_ result: PromptSubmissionSendResult) {
        let shouldPublish = state.withLock { state in
            guard case .pending = state else { return false }
            state = .finished
            return true
        }
        guard shouldPublish else { return }
        continuation.yield(result)
        continuation.finish()
    }

    /// Cancels delivery and publishes a definitive unavailable outcome.
    public func cancel() {
        let shouldPublish = state.withLock { state in
            guard case .pending = state else { return false }
            state = .cancelled
            return true
        }
        guard shouldPublish else { return }
        continuation.yield(.surfaceUnavailable)
        continuation.finish()
    }

    /// Whether a timeout or teardown has already cancelled this transaction.
    public var isCancelled: Bool {
        state.withLock { state in
            if case .cancelled = state { return true }
            return false
        }
    }

    /// Waits for the terminal delivery outcome.
    ///
    /// A stream that ends without a result is treated as an unavailable
    /// surface so a transaction lane never remains occupied by a broken
    /// receipt.
    public func wait() async -> PromptSubmissionSendResult {
        if Task.isCancelled {
            cancel()
            return .surfaceUnavailable
        }
        return await withTaskCancellationHandler {
            for await result in results {
                return result
            }
            return .surfaceUnavailable
        } onCancel: {
            cancel()
        }
    }
}
