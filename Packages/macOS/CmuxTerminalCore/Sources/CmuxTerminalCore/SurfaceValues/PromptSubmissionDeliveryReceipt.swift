public import Foundation

/// Delivers the eventual result of one queued compound prompt submission.
///
/// A caller can acknowledge admission immediately while retaining a receipt
/// that completes only when the queued paste-and-submit transaction is sent or
/// fails definitively. The stream is bounded to one result because a receipt
/// represents exactly one terminal transaction.
public final class PromptSubmissionDeliveryReceipt: Sendable {
    private let results: AsyncStream<PromptSubmissionSendResult>
    private let continuation: AsyncStream<PromptSubmissionSendResult>.Continuation

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
        continuation.yield(result)
        continuation.finish()
    }

    /// Waits for the terminal delivery outcome.
    ///
    /// A stream that ends without a result is treated as an unavailable
    /// surface so a transaction lane never remains occupied by a broken
    /// receipt.
    public func wait() async -> PromptSubmissionSendResult {
        for await result in results {
            return result
        }
        return .surfaceUnavailable
    }
}
