import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Production phase transitions")
struct ProductionPhaseTransitionTests {
    @Test("Native approval follows the current artifact without changing the workspace", arguments: [EditorViewModel.WorkspaceFocus.production, .edit])
    func nativeApprovalAdvancesSelection(focus: EditorViewModel.WorkspaceFocus) async throws {
        let (editor, home) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: home) }
        await editor.refreshEngineState()
        editor.selectProductionPhase("project_init")
        editor.setWorkspaceFocus(focus)
        let root = try #require(editor.workingRoot)

        try await NativeGateWriter.approve(projectDir: root, phase: "project_init",
            declaredPack: nil, executionCoordinator: editor.pipelinePhaseRunCoordinator)
        await editor.refreshEngineState()

        #expect(editor.projectState?.nextPhaseName == "brief")
        #expect(editor.productionSelectedPhase == "brief")
        #expect(editor.cockpitTab == .story)
        #expect(editor.workspaceFocus == focus)
    }

    @Test("Agent gate approval advances the selected phase through the shared refresh")
    func agentApprovalAdvancesSelection() async throws {
        let (editor, home) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: home) }
        await editor.refreshEngineState()
        editor.selectProductionPhase("project_init")
        let workingRoot = try #require(editor.workingRoot)
        let dataRoot = try #require(DataRootResolver.dataRoot(of: workingRoot))
        let request = await ToolExecutor(editor: editor).execute(name: "approve_gate", args: [
            "phase": "project_init", "project_dir": dataRoot.path,
        ])
        #expect(!request.isError, "\(ToolHarness.textOf(request))")
        let approval = try #require(editor.agentService.pendingGateApproval)
        #expect(approval.phase == "project_init")
        #expect(approval.dataRoot?.resolvingSymlinksInPath().path == dataRoot.resolvingSymlinksInPath().path)

        let resolved = await editor.agentService.resolveGate(.approved, approvalID: editor.agentService.pendingGateApproval?.id ?? "missing")
        let result = try #require(resolved)
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        await editor.refreshEngineState()

        #expect(editor.projectState?.nextPhaseName == "brief")
        #expect(editor.productionSelectedPhase == "brief")
        #expect(editor.cockpitTab == .story)
    }

    @Test("An approval preserves deliberate browsing of another phase")
    func approvalPreservesOtherSelection() async throws {
        let (editor, home) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: home) }
        await editor.refreshEngineState()
        editor.selectProductionPhase("bible")
        let root = try #require(editor.workingRoot)

        try await NativeGateWriter.approve(projectDir: root, phase: "project_init",
            declaredPack: nil, executionCoordinator: editor.pipelinePhaseRunCoordinator)
        await editor.refreshEngineState()

        #expect(editor.projectState?.nextPhaseName == "brief")
        #expect(editor.productionSelectedPhase == "bible")
        #expect(editor.cockpitTab == .bible)
    }

    private func fixture() throws -> (EditorViewModel, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase-transition-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: home)
        _ = try ProjectScaffold.initProject(home: home, name: "Phase transition", mode: .beat)
        let editor = EditorViewModel()
        editor.projectURL = home
        return (editor, home)
    }
}
