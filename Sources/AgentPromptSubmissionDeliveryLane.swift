import CmuxTerminalCore
import Foundation

/// Serializes complete agent prompt transactions through actual delivery.
///
/// The lane owns one admission turn at a time. A turn remains occupied while
/// a cold-surface or clipboard-deferred prompt waits on its delivery receipt,
/// so a later socket request cannot overtake bytes that were admitted first.
actor AgentPromptSubmissionDeliveryLane {
    enum Outcome: Sendable, Equatable {
        case admitted(AgentPromptSubmissionResult)
        case invalidWorkspace
        case invalidSurface
    }

    private var isOccupied = false
    private var waitingTurns: [CheckedContinuation<Void, Never>] = []

    /// Runs one MainActor admission and waits for its eventual terminal result.
    ///
    /// - Parameter admission: The MainActor operation that resolves and admits
    ///   the target. The supplied receipt must be completed by the terminal
    ///   surface after the compound write is sent or rejected.
    /// - Returns: The definitive socket-level outcome after delivery.
    func perform(
        _ admission: @escaping @MainActor @Sendable (
            PromptSubmissionDeliveryReceipt
        ) -> Outcome
    ) async -> Outcome {
        await acquireTurn()
        defer { releaseTurn() }

        let receipt = PromptSubmissionDeliveryReceipt()
        let admitted = await MainActor.run {
            admission(receipt)
        }
        guard case .admitted(let admittedResult) = admitted else {
            return admitted
        }
        guard case .submitted = admittedResult else {
            return admitted
        }
        return .admitted(
            Self.resolve(admittedResult, after: await receipt.wait())
        )
    }

    private func acquireTurn() async {
        guard isOccupied else {
            isOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waitingTurns.append(continuation)
        }
    }

    private func releaseTurn() {
        guard !waitingTurns.isEmpty else {
            isOccupied = false
            return
        }
        waitingTurns.removeFirst().resume()
    }

    private static func resolve(
        _ admitted: AgentPromptSubmissionResult,
        after delivery: PromptSubmissionSendResult
    ) -> AgentPromptSubmissionResult {
        guard case .submitted(
            let workspaceID,
            let surfaceID,
            let wasQueued
        ) = admitted else {
            return admitted
        }
        switch delivery {
        case .sent:
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                queued: wasQueued
            )
        case .queued:
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                queued: true
            )
        case .composerBusy:
            return .rejectedComposerBusy(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        case .agentScopeUnavailable:
            return .agentScopeUnavailable(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        case .unknownKey:
            return .invalidSubmitKey(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        case .inputQueueFull:
            return .inputQueueFull(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        case .surfaceUnavailable:
            return .surfaceUnavailable(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        case .processExited:
            return .processExited(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        }
    }
}
