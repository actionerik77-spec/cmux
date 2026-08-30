import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Session resume binding backfill regressions")
struct SessionResumeBindingBackfillRegressionTests {
    @Test @MainActor
    func relaunchOnlyOllamaRemainsBindingFreeAcrossRepeatedSaves() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.restoredAgentSnapshotsByPanelId[panel.id] = SessionRestorableAgentSnapshot(
            kind: .ollama,
            sessionId: "",
            workingDirectory: "/tmp/ollama-project",
            launchCommand: AgentLaunchCommandSnapshot(
                processDetectedLauncher: "ollama",
                executablePath: "/opt/homebrew/bin/ollama",
                arguments: ["/opt/homebrew/bin/ollama", "run", "qwen3:8b"],
                workingDirectory: "/tmp/ollama-project",
                source: "process"
            )
        )
        workspace.restoredAgentResumeStatesByPanelId[panel.id] = .observedAgentCommandRunning
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)

        for _ in 0..<2 {
            let snapshot = workspace.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: .empty
            )
            let terminal = try #require(snapshot.panels.first?.terminal)
            #expect(terminal.agent?.kind == .ollama)
            #expect(terminal.resumeBinding == nil)
            #expect(terminal.wasAgentRunning == true)
            #expect(workspace.unresolvedResumeBindingGapCount == 0)
        }
    }

    @Test
    func ignoredCustomAgentCwdDoesNotEnterBackfilledBinding() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "cwdless-agent",
            name: "CWD-less Agent",
            detect: CmuxVaultAgentDetectRule(processName: "cwdless-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}",
            cwd: .ignore
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom(registration.id),
            sessionId: "cwdless-session",
            workingDirectory: "/tmp/runtime-cwd",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: registration.id,
                executablePath: "/usr/local/bin/cwdless-agent",
                arguments: ["/usr/local/bin/cwdless-agent"],
                workingDirectory: "/tmp/launch-cwd",
                source: "process"
            ),
            registration: registration
        )

        let binding = try #require(snapshot.resumeBindingSnapshot())
        #expect(binding.cwd == nil)
        #expect(binding.launchCommand?.workingDirectory == nil)
        #expect(!binding.command.contains("/tmp/runtime-cwd"))
        #expect(!binding.command.contains("/tmp/launch-cwd"))

        var cwdTemplateSnapshot = snapshot
        cwdTemplateSnapshot.registration?.resumeCommand =
            "{{executable}} --session {{sessionId}} --cwd {{cwd}}"
        #expect(cwdTemplateSnapshot.resumeBindingSnapshot() == nil)
    }

    @Test @MainActor
    func discardingRestoredAgentClearsResumeBindingGap() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.restoredAgentSnapshotsByPanelId[panel.id] = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "discarded-session"
        )
        workspace.setResumeBindingGap(true, panelId: panel.id)
        #expect(workspace.unresolvedResumeBindingGapCount == 1)

        workspace.clearRestoredAgentSnapshot(panelId: panel.id)

        #expect(workspace.restoredAgentSnapshotsByPanelId[panel.id] == nil)
        #expect(workspace.unresolvedResumeBindingGapCount == 0)
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains {
                $0.key == Workspace.resumeBindingGapStatusKey
            }
        )
    }
}
