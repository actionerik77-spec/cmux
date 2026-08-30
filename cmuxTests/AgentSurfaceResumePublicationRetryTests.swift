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
    func preflightGuardsObservedGeneration() throws {
        let preflight = try #require(AgentSurfaceResumePublicationRetry().preflight(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-old",
                    "source": "agent-hook",
                    "updated_at": 5.0,
                ],
            ]
        ))

        #expect(preflight.generation == .updatedAt(5))
        #expect(preflight.params["_cmux_expected_binding_updated_at"] as? Double == 5)
        #expect(preflight.params["_cmux_expect_missing_binding"] == nil)
    }

    @Test
    func recognizesCommittedPublicationAsAlreadyApplied() {
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
            baselineGeneration: .updatedAt(5)
        )

        guard case .alreadyApplied = decision else {
            Issue.record("Expected an already-applied decision")
            return
        }
    }

    @Test
    func unchangedOlderGenerationRetriesConditionally() {
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
            baselineGeneration: .updatedAt(5)
        )

        guard case .retry(let params) = decision else {
            Issue.record("Expected a conditional retry")
            return
        }
        #expect(params["_cmux_expected_binding_updated_at"] as? Double == 5)
    }

    @Test
    func missingBindingUsesMissingGenerationGuard() throws {
        let retry = AgentSurfaceResumePublicationRetry()
        let preflight = try #require(retry.preflight(
            desiredParams: desired,
            currentPayload: ["resume_binding": NSNull()]
        ))
        #expect(preflight.generation == .missing)
        #expect(preflight.params["_cmux_expect_missing_binding"] as? Bool == true)

        let decision = retry.decision(
            desiredParams: desired,
            currentPayload: ["resume_binding": NSNull()],
            baselineGeneration: preflight.generation
        )
        guard case .retry(let params) = decision else {
            Issue.record("Expected a missing-binding retry")
            return
        }
        #expect(params["_cmux_expect_missing_binding"] as? Bool == true)
    }

    @Test
    func changedGenerationSupersedesRetry() {
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
            baselineGeneration: .updatedAt(5)
        )

        guard case .superseded = decision else {
            Issue.record("Expected the changed generation to suppress retry")
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
            baselineGeneration: .updatedAt(5)
        )

        guard case .retry(let params) = decision else {
            Issue.record("Expected stale same-session metadata to retry")
            return
        }
        #expect(params["_cmux_expected_binding_updated_at"] as? Double == 5)
    }
}
