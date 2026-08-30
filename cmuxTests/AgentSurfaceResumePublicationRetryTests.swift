import Foundation
import Testing

@Suite("Agent surface resume publication retry")
struct AgentSurfaceResumePublicationRetryTests {
    private let desired: [String: Any] = [
        "kind": "claude",
        "checkpoint_id": "session-a",
        "source": "agent-hook",
        "command": "claude --resume session-a",
    ]

    @Test
    func recognizesAlreadyAppliedSession() {
        let decision = AgentSurfaceResumePublicationRetry().decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-a",
                    "source": "agent-hook",
                    "updated_at": 12.0,
                ],
            ],
            firstAttemptStartedAt: 10
        )

        guard case .alreadyApplied = decision else {
            Issue.record("Expected an already-applied decision")
            return
        }
    }

    @Test
    func retriesOnlyAgainstObservedOlderGeneration() {
        let decision = AgentSurfaceResumePublicationRetry().decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-old",
                    "source": "agent-hook",
                    "updated_at": 5.0,
                ],
            ],
            firstAttemptStartedAt: 10
        )

        guard case .retry(let params) = decision else {
            Issue.record("Expected a conditional retry")
            return
        }
        #expect(params["_cmux_expected_binding_updated_at"] as? Double == 5)
        #expect(params["_cmux_expect_missing_binding"] == nil)
    }

    @Test
    func missingBindingUsesMissingGenerationGuard() {
        let decision = AgentSurfaceResumePublicationRetry().decision(
            desiredParams: desired,
            currentPayload: ["resume_binding": NSNull()],
            firstAttemptStartedAt: 10
        )

        guard case .retry(let params) = decision else {
            Issue.record("Expected a missing-binding retry")
            return
        }
        #expect(params["_cmux_expect_missing_binding"] as? Bool == true)
        #expect(params["_cmux_expected_binding_updated_at"] == nil)
    }

    @Test
    func newerDifferentSessionSupersedesRetry() {
        let decision = AgentSurfaceResumePublicationRetry().decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-b",
                    "source": "agent-hook",
                    "updated_at": 15.0,
                ],
            ],
            firstAttemptStartedAt: 10
        )

        guard case .superseded = decision else {
            Issue.record("Expected the newer binding to suppress retry")
            return
        }
    }

    @Test
    func olderSameSessionRetriesMetadataConditionally() {
        let decision = AgentSurfaceResumePublicationRetry().decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-a",
                    "source": "agent-hook",
                    "updated_at": 5.0,
                ],
            ],
            firstAttemptStartedAt: 10
        )

        guard case .retry(let params) = decision else {
            Issue.record("Expected stale same-session metadata to retry")
            return
        }
        #expect(params["_cmux_expected_binding_updated_at"] as? Double == 5)
    }
}
