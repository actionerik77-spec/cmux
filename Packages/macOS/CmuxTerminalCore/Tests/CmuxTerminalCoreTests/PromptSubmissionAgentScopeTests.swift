import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite struct PromptSubmissionAgentScopeTests {
    @Test func capturedScopeDistinguishesUnboundFromAProcess() {
        let lifecycleID = UUID()
        let unbound = PromptSubmissionAgentScope(
            nil,
            terminalLifecycleID: lifecycleID
        )
        let bound = PromptSubmissionAgentScope("agent:test")

        #expect(!unbound.matches(nil, terminalLifecycleID: lifecycleID))
        #expect(
            unbound.matches(
                "agent:test",
                terminalLifecycleID: lifecycleID
            )
        )
        #expect(
            !unbound.matches(
                "agent:test",
                terminalLifecycleID: UUID()
            )
        )
        #expect(
            bound.matches("agent:test", terminalLifecycleID: UUID())
        )
        #expect(!bound.matches(nil, terminalLifecycleID: UUID()))
    }
}
