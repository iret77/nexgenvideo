import Foundation
import NexGenEngine
import Testing

@testable import NexGenVideo

@MainActor
@Suite("Phase spend approval", .serialized)
struct PhaseSpendApprovalTests {
    private struct Fixture {
        let editor: EditorViewModel
        let dataRoot: URL
        let package: URL
    }

    private func pipelineEditor() throws -> Fixture {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase-approval-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: package)
        let pipeline = package.appendingPathComponent("pipeline", isDirectory: true)
        try FileManager.default.createDirectory(at: pipeline, withIntermediateDirectories: true)
        try Data("project: phase-approval\nmode: test\n".utf8).write(
            to: pipeline.appendingPathComponent("project.yaml")
        )
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingRoot = try #require(editor.workingRoot)
        let dataRoot = try #require(DataRootResolver.dataRoot(of: workingRoot))
        return Fixture(editor: editor, dataRoot: dataRoot, package: package)
    }

    private func cleanup(_ fixture: Fixture) {
        fixture.editor.releaseWorkingCopy()
        try? FileManager.default.removeItem(at: fixture.package)
    }

    private func writeGates(_ dataRoot: URL, briefApprovedAt: String?, frames: Gate = Gate()) throws {
        var gates: [String: Gate] = ["frames": frames]
        gates["brief"] = briefApprovedAt.map { Gate(approved: true, approvedAt: $0) } ?? Gate()
        try YAMLArtifactStore(dataRoot: dataRoot).save(
            Gates(project: "phase-approval", gates: gates),
            to: PipelineLayout.gatesFile
        )
    }

    private func option() -> SpendOption {
        SpendOption(
            modelId: "m1",
            modelName: "Model One",
            target: ResolvedGenerationTarget(
                modelId: "m1",
                provider: .fal,
                endpoint: "m1",
                binding: ProviderBinding(provider: .fal, transport: .api, kind: .generation,
                    providerRef: "m1", billing: .perCall)
            ),
            credits: nil,
            requiresCatalogAvailability: false
        )
    }

    private func scope(_ fixture: Fixture, phase: String) -> SpendPipelineScope {
        SpendPipelineScope(dataRoot: fixture.dataRoot, phase: phase, tool: .generateImage,
            declaredPack: nil, bindingResolution: .absent)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for the phase approval to settle")
    }

    @Test func approvalCoversItsPhaseUntilTheGateIsApprovedAndNeverRevives() throws {
        let fixture = try pipelineEditor()
        defer { cleanup(fixture) }
        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        let approvals = fixture.editor.phaseSpendApproval

        #expect(approvals.grant(phase: "frames", editor: fixture.editor) != nil)
        #expect(approvals.active(phase: "frames", editor: fixture.editor) != nil)
        #expect(approvals.active(phase: "render", editor: fixture.editor) == nil)
        #expect(approvals.current?.phase == "frames")

        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z",
            frames: Gate(approved: true, approvedAt: "2026-10-16T09:00:00Z"))
        #expect(approvals.active(phase: "frames", editor: fixture.editor) == nil)
        #expect(approvals.current == nil)

        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        #expect(approvals.active(phase: "frames", editor: fixture.editor) == nil)
    }

    @Test func rewindingAnEarlierPhaseEndsTheApproval() throws {
        let fixture = try pipelineEditor()
        defer { cleanup(fixture) }
        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        let approvals = fixture.editor.phaseSpendApproval
        _ = try #require(approvals.grant(phase: "frames", editor: fixture.editor))

        try writeGates(fixture.dataRoot, briefApprovedAt: nil)
        approvals.reconcile(editor: fixture.editor)
        #expect(approvals.current == nil)

        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T10:00:00Z")
        #expect(approvals.active(phase: "frames", editor: fixture.editor) == nil)
    }

    @Test func rewindingOrRevisingTheApprovedPhaseItselfEndsTheApproval() throws {
        let fixture = try pipelineEditor()
        defer { cleanup(fixture) }
        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        let approvals = fixture.editor.phaseSpendApproval
        _ = try #require(approvals.grant(phase: "frames", editor: fixture.editor))

        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z",
            frames: Gate(approved: false, notes: "Redo the hero frame", state: .needsRevision))
        #expect(approvals.active(phase: "frames", editor: fixture.editor) == nil)
        #expect(approvals.current == nil)
    }

    @Test func movingToAnotherPhaseEndsTheApproval() throws {
        let fixture = try pipelineEditor()
        defer { cleanup(fixture) }
        try writeGates(fixture.dataRoot, briefApprovedAt: nil)
        let approvals = fixture.editor.phaseSpendApproval
        _ = try #require(approvals.grant(phase: "brief", editor: fixture.editor))

        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        approvals.reconcile(editor: fixture.editor)
        #expect(approvals.current == nil)
        #expect(approvals.active(phase: "frames", editor: fixture.editor) == nil)
    }

    @Test func onlyAnOpenPhaseOfAPipelineProjectCanBeApproved() throws {
        let fixture = try pipelineEditor()
        defer { cleanup(fixture) }
        let approvals = fixture.editor.phaseSpendApproval
        #expect(approvals.grant(phase: "frames", editor: fixture.editor) == nil)

        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        #expect(approvals.grant(phase: "brief", editor: fixture.editor) == nil)
        #expect(approvals.current == nil)
    }

    @Test func withdrawEndsTheApprovalAndRunsAreListedUntilThen() throws {
        let fixture = try pipelineEditor()
        defer { cleanup(fixture) }
        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        let approvals = fixture.editor.phaseSpendApproval
        _ = try #require(approvals.grant(phase: "frames", editor: fixture.editor))
        approvals.recordRun(label: "Generate image", detail: "Model One via fal.ai", editor: fixture.editor)
        approvals.recordRun(label: "Batch of 3 requests", detail: "Views", editor: fixture.editor)
        #expect(approvals.current?.runs.map(\.label) == ["Generate image", "Batch of 3 requests"])

        approvals.withdraw(editor: fixture.editor)
        #expect(approvals.current == nil)
        #expect(approvals.active(phase: "frames", editor: fixture.editor) == nil)
    }

    // Relaunch persistence needs a host-side store the locked PROJECT_STORAGE.md does not allow yet;
    // this pins the storage seam such a store plugs into and that a grant stays with its project.
    @Test func approvalCrossesSessionsOnlyThroughItsStorageAndNeverToAnotherProject() throws {
        let fixture = try pipelineEditor()
        let other = try pipelineEditor()
        defer {
            cleanup(fixture)
            cleanup(other)
        }
        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        try writeGates(other.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        let storage = SessionPhaseSpendApprovalStorage()
        let first = PhaseSpendApprovalController(storage: storage)
        _ = try #require(first.grant(phase: "frames", editor: fixture.editor))

        let restored = PhaseSpendApprovalController(storage: storage)
        #expect(restored.active(phase: "frames", editor: fixture.editor) != nil)
        #expect(restored.active(phase: "frames", editor: other.editor) == nil)
        #expect(PhaseSpendApprovalController().active(phase: "frames", editor: fixture.editor) == nil)
    }

    @Test func agentToolsCannotGrantOrSeeThePhaseApproval() throws {
        for tool in ToolDefinitions.all {
            let text = (tool.description + String(describing: tool.inputSchema)).lowercased()
            #expect(!text.contains("approve all"))
            #expect(!text.contains("phase_approval"))
            #expect(!text.contains("phasespendapproval"))
        }
        #expect(!ToolName.allCases.contains { $0.rawValue.contains("phase") && $0.rawValue.contains("approv") })

        let fixture = try pipelineEditor()
        defer { cleanup(fixture) }
        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        let selected = option()
        var providerWasCalled = false
        _ = try fixture.editor.agentService.requestSpendApproval(
            SpendApproval(id: "no-phase-approval", recommendedOptionId: selected.id, options: [selected],
                actionLabel: "Generate image"),
            origin: .direct,
            editor: fixture.editor,
            pipelineScope: scope(fixture, phase: "frames"),
            execute: { _, _ in
                providerWasCalled = true
                return .ok("unexpected")
            }
        )

        #expect(fixture.editor.agentService.pendingSpendApproval?.id == "no-phase-approval")
        #expect(fixture.editor.agentService.pendingSpendPhase == "frames")
        #expect(fixture.editor.agentService.autoApprovingSpendPhase == nil)
        #expect(fixture.editor.phaseSpendApproval.current == nil)
        #expect(!providerWasCalled)
        fixture.editor.agentService.declineSpend()
    }

    @Test func anActiveApprovalStartsTheRunWithoutACardAndFallsBackToTheCardOnFailure() async throws {
        let fixture = try pipelineEditor()
        defer { cleanup(fixture) }
        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        _ = try #require(fixture.editor.phaseSpendApproval.grant(phase: "frames", editor: fixture.editor))
        let selected = option()
        var providerWasCalled = false
        let service = fixture.editor.agentService

        _ = try service.requestSpendApproval(
            SpendApproval(id: "phase-approved", recommendedOptionId: selected.id, options: [selected],
                actionLabel: "Generate image"),
            origin: .direct,
            editor: fixture.editor,
            pipelineScope: scope(fixture, phase: "frames"),
            execute: { _, _ in
                providerWasCalled = true
                return .ok("unexpected")
            }
        )
        #expect(service.autoApprovingSpendPhase == "frames")

        // This generic project has no Frames phase in its harness, so the run's own phase check
        // refuses it after the automatic approval: the card then appears with that reason.
        await waitUntil { service.autoApprovingSpendPhase == nil }
        #expect(!providerWasCalled)
        #expect(service.pendingSpendApproval?.id == "phase-approved")
        #expect(service.spendApprovalError?.contains("phase changed") == true)
        service.declineSpend()
    }

    @Test func anApprovalThatEndsBeforeTheAutomaticStartLeavesTheCard() async throws {
        let fixture = try pipelineEditor()
        defer { cleanup(fixture) }
        try writeGates(fixture.dataRoot, briefApprovedAt: "2026-10-16T08:00:00Z")
        let approvals = fixture.editor.phaseSpendApproval
        let original = try #require(approvals.grant(phase: "frames", editor: fixture.editor))
        let selected = option()
        var providerWasCalled = false
        let service = fixture.editor.agentService

        _ = try service.requestSpendApproval(
            SpendApproval(id: "approval-ended", recommendedOptionId: selected.id, options: [selected],
                actionLabel: "Generate image"),
            origin: .direct,
            editor: fixture.editor,
            pipelineScope: scope(fixture, phase: "frames"),
            execute: { _, _ in
                providerWasCalled = true
                return .ok("unexpected")
            }
        )
        #expect(service.autoApprovingSpendPhase == "frames")
        approvals.withdraw(editor: fixture.editor)
        let regranted = try #require(approvals.grant(phase: "frames", editor: fixture.editor))
        #expect(!approvals.isActive(original, editor: fixture.editor))
        #expect(approvals.isActive(regranted, editor: fixture.editor))

        // Reaching the approval would fail with "phase changed" in this fixture; a stale grant stops before it.
        await waitUntil { service.autoApprovingSpendPhase == nil }
        #expect(!providerWasCalled)
        #expect(service.pendingSpendApproval?.id == "approval-ended")
        #expect(service.spendApprovalError == nil)
        #expect(!service.spendApprovalIsRunning)
        #expect(approvals.current?.runs.isEmpty == true)
        service.declineSpend()
    }
}
