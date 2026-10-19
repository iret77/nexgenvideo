import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
struct PipelineAgentDecisionContextTests {
    @Test func coreDialogUsesItsTrustedWorkflowAndRejectsConcurrentWork() throws {
        let fixture = try makeCore()
        defer { fixture.editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: fixture.home) }
        let dialog = clarification()
        try fixture.editor.pipelineAgentHarness.guardAgentDecision(dialog, editor: fixture.editor)
        let lease = try #require(fixture.editor.pipelinePhaseRunCoordinator.beginMutation(
            projectRoot: fixture.root, label: "brief"))
        #expect(throws: ToolError.self) {
            try fixture.editor.pipelineAgentHarness.guardAgentDecision(dialog, editor: fixture.editor)
        }
        fixture.editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: fixture.root, id: lease)
        try fixture.editor.pipelineAgentHarness.guardAgentDecision(dialog, editor: fixture.editor)
    }

    @Test func changedCoreDeclarationCannotFallBackToAnUnrestrictedDialog() throws {
        let fixture = try makeCore()
        defer { fixture.editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: fixture.home) }
        let working = try #require(fixture.editor.workingRoot)
        try ProjectPluginSettings.setProductionContract(nil, projectURL: working)
        #expect(throws: PhaseContractError.self) {
            try fixture.editor.pipelineAgentHarness.guardAgentDecision(clarification(), editor: fixture.editor)
        }
    }

    private func makeCore() throws -> (home: URL, root: URL, editor: EditorViewModel) {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Core decision \(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: home)
        let root = try ProjectScaffold.initProject(home: home, name: "Core decision", mode: .generic)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        try PhaseContractRuntime.initializeWorkflowState(dataRoot: root, workflow: HostWorkflowKey.core(.current))
        let editor = EditorViewModel(agentService: AgentService(backend: .claudeCode,
            refreshBackendStatusOnInit: false,
            runtimeReadinessOverride: { .upstream("The decision fixture does not launch an agent runtime.") }))
        editor.projectURL = home
        let workingRoot = try #require(editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) })
        let store = YAMLArtifactStore(dataRoot: workingRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&gates, phase: "project_init")
        try store.save(gates, to: PipelineLayout.gatesFile)
        #expect(editor.declaredProductionContract == .current)
        #expect(try ProjectStateBuilder.buildSnapshot(dataRoot: workingRoot,
            order: ProductionWorkflowV2.corePhases).nextPhase == "brief")
        return (home, workingRoot, editor)
    }

    private func clarification() -> AgentDialog {
        AgentDialog(id: "core-creative-choice", title: "Choose the visual direction", symbol: "film",
            intro: nil, costHint: nil, confirmLabel: "Continue", textField: nil, sections: [])
    }
}
