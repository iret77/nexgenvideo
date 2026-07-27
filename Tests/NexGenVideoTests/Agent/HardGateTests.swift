import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

/// Hard gates: a tool that does a phase's WORK is refused until every earlier phase's gate is approved,
/// so the agent can't run the analysis / draft the brief while an earlier gate is still open.
@MainActor
@Suite("Hard gates")
struct HardGateTests {

    @Test("advancingPhase maps work tools to their phase and leaves read-only / control tools ungated")
    func advancingPhaseMapping() {
        #expect(ToolName.runPhase.advancingPhase(args: ["phase": "analysis"]) == "analysis")
        #expect(ToolName.runPhase.advancingPhase(args: [:]) == nil)          // no phase → tool validates it
        #expect(ToolName.attachSong.advancingPhase(args: [:]) == "analysis")
        #expect(ToolName.recordAffect.advancingPhase(args: [:]) == "brief")
        #expect(ToolName.writeAnalysisInterpretation.advancingPhase(args: [:]) == "analysis")
        #expect(ToolName.writeBrief.advancingPhase(args: [:]) == "brief")
        #expect(ToolName.writeProductionDesign.advancingPhase(args: [:]) == "production_design")
        #expect(ToolName.writeTreatment.advancingPhase(args: [:]) == "treatment")
        #expect(ToolName.writeStoryboard.advancingPhase(args: [:]) == "storyboard")
        #expect(ToolName.writeBible.advancingPhase(args: [:]) == "bible")
        #expect(ToolName.writeShotlist.advancingPhase(args: [:]) == "shotlist")
        #expect(ToolName.runSanity.advancingPhase(args: [:]) == "sanity")
        #expect(ToolName.extractScene3dPovs.advancingPhase(args: [:]) == "bible")
        #expect(ToolName.saveFrameAudit.advancingPhase(args: [:]) == "frames")
        #expect(ToolName.nextRenderShot.advancingPhase(args: ["phase": "frames"]) == "frames")
        #expect(ToolName.recordRender.advancingPhase(args: ["phase": "frames"]) == "frames")
        #expect(ToolName.recordRender.advancingPhase(args: ["phase": "preview"]) == "render")
        #expect(ToolName.assembleTimeline.advancingPhase(args: [:]) == "render")
        #expect(ToolName.generateImage.usesCurrentPipelinePhase)
        #expect(ToolName.copyProjectFile.usesCurrentPipelinePhase)
        // Never gated: read-only, the approval tools themselves, init, and the backward rewind.
        #expect(ToolName.getProjectState.advancingPhase(args: [:]) == nil)
        #expect(ToolName.approveGate.advancingPhase(args: [:]) == nil)
        #expect(ToolName.initProject.advancingPhase(args: [:]) == nil)
        #expect(ToolName.rewind.advancingPhase(args: [:]) == nil)
    }

    @Test("only canonical artifact writers can capture phase lineage")
    func phaseMutationClassification() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        #expect(
            ToolName.writeBrief.writesPhaseArtifact(
                args: [:],
                dataRoot: root
            )
        )
        #expect(
            ToolName.recordRender.writesPhaseArtifact(
                args: ["phase": "final"],
                dataRoot: root
            )
        )
        #expect(
            !ToolName.recordRender.writesPhaseArtifact(
                args: ["phase": "preview"],
                dataRoot: root
            )
        )
        #expect(
            !ToolName.assembleTimeline.writesPhaseArtifact(
                args: [:],
                dataRoot: root
            )
        )
        #expect(
            ToolName.attachSong.invalidatesPhaseState(
                args: [:],
                dataRoot: root
            )
        )
        #expect(
            !ToolName.attachSong.writesPhaseArtifact(
                args: [:],
                dataRoot: root
            )
        )
        #expect(
            ToolName.recordAffect.invalidatesPhaseState(
                args: [:],
                dataRoot: root
            )
        )
        #expect(
            !ToolName.recordAffect.writesPhaseArtifact(
                args: [:],
                dataRoot: root
            )
        )
    }

    private func scaffold() throws -> (ToolHarness, String, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hard-gate-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo", mode: .beat)
        return (ToolHarness(enforceHardGates: true), dataRoot.path, tmp)
    }

    private func briefArgs(projectDir: String) -> [String: Any] {
        [
            "project_dir": projectDir,
            "mission": "single_release",
            "target_platform": "YouTube",
            "aspect_ratio": "16:9",
            "project_mode": "section",
            "concept_type": "narrative",
            "visual_medium": "live_action_realistic",
            "figures": "artist_only",
            "lyrics_integration": "literal",
        ]
    }

    @Test("a work tool is refused until the earlier gate is approved, then clears it")
    func workToolBlockedUntilPriorApproved() async throws {
        let (h, dir, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        // Fresh project, nothing approved: drafting the brief is refused, naming the first missing gate.
        let blocked = await h.runRaw("write_brief", args: briefArgs(projectDir: dir))
        #expect(blocked.isError)
        #expect(ToolHarness.textOf(blocked).contains("project_init"))

        // Approve the frontier (project_init) via the normal gate path (the harness taps the card).
        let approved = await h.runGate("approve_gate", args: ["project_dir": dir, "phase": "project_init"])
        #expect(approved.isError == false)

        // project_init no longer blocks the brief. (It may still fail for other reasons — a later prior
        // gate, or missing content — but never again on project_init.)
        let after = await h.runRaw("write_brief", args: briefArgs(projectDir: dir))
        #expect(!ToolHarness.textOf(after).contains("project_init"))
    }
}
