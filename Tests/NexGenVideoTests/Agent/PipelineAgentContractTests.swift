import Foundation
import MusicvideoPlugin
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Pipeline agent contract")
struct PipelineAgentContractTests {
    private var binding: ProjectPackBinding {
        get throws {
            try CurrentMusicvideoFixture.binding
        }
    }

    private func scaffold(activateCurrent: Bool = true) throws -> (URL, URL) {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pipeline-contract-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = cleanup.appendingPathComponent("project", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(
            home: home,
            name: "pipeline-contract",
            mode: .beat,
            extraDirs: ["audio", "lyrics", "analysis"]
        )
        if activateCurrent { try CurrentMusicvideoFixture.activate(at: home) }
        return (dataRoot, cleanup)
    }

    @Test("every musicvideo phase has one order, gate, instructions, and executable path")
    func completeContract() throws {
        let contract = try CurrentMusicvideoFixture.load()
        #expect(contract.order == CurrentMusicvideoFixture.phases)
        for phase in CurrentMusicvideoFixture.phases {
            let resolved = try #require(contract.phase(phase))
            #expect(resolved.declaration.roles.contains(.reviewGate))
            #expect(!resolved.declaration.selectors.writer.isEmpty)
            #expect(!resolved.declaration.selectors.gate.isEmpty)
            #expect(!resolved.declaration.selectors.artifact.isEmpty)
            #expect(resolved.phaseBoundCapabilities == CurrentMusicvideoFixture.phaseBound(phase))
            #expect(resolved.supportingCapabilities == CurrentMusicvideoFixture.supporting(phase))
            #expect(!(try contract.instructions(for: phase)).isEmpty)
        }
    }

    @Test("pack instructions are checked against the pack's declared capabilities")
    func declaredCapabilitiesOwnInstructionRequirements() throws {
        let pack = MusicvideoPack()
        let registry = EngineRegistry()
        pack.register(registry)
        let manifest = try #require(HardStepManifest.load(pack: pack))
        let documents = Dictionary(uniqueKeysWithValues:
            PipelineAgentContract.musicvideoPhases.map { phase in
                let name = PipelineAgentContract.phaseDocumentName(phase)
                let document = (try? PackKnowledge.phaseDoc(name: name)) ?? ""
                return (
                    name,
                    document.replacingOccurrences(of: "prepare_generation_batch", with: "")
                )
            }
        )
        let legacySupporting = PipelineAgentContract.currentPhaseCapabilities.mapValues {
            $0.subtracting([.prepareGenerationBatch])
        }

        let legacyFailures = PipelineAgentContract.failures(
            registry: registry,
            manifest: manifest,
            phaseBoundCapabilities: PipelineAgentContract.executableTools,
            supportingCapabilities: legacySupporting,
            phaseDocument: { documents[$0] }
        )
        #expect(
            !legacyFailures.contains {
                $0.contains("required tool prepare_generation_batch")
            }
        )

        let currentFailures = PipelineAgentContract.failures(
            registry: registry,
            manifest: manifest,
            phaseDocument: { documents[$0] }
        )
        #expect(
            currentFailures.contains {
                $0.contains("required tool prepare_generation_batch")
            }
        )
    }

    @Test("declared capabilities cannot bypass phase guards")
    func declaredCapabilitiesMustUseTheActualGuards() throws {
        let pack = MusicvideoPack()
        let registry = EngineRegistry()
        pack.register(registry)
        let manifest = try #require(HardStepManifest.load(pack: pack))
        let failures = PipelineAgentContract.failures(
            registry: registry, manifest: manifest,
            phaseBoundCapabilities: ["brief": [.writeStoryboard]],
            supportingCapabilities: ["bible": [.writeBrief]],
            phaseDocument: { _ in ToolName.allCases.map(\.rawValue).joined(separator: " ") }
        )
        #expect(failures.contains("write_storyboard is not hard-gated to brief"))
        #expect(failures.contains("bible grants write_brief, which isn't guarded as a current-phase tool"))
        #expect(failures.contains { $0.contains("phase-bound tool coverage differs") && $0.contains("write_brief") })
    }

    @Test("pipeline phase coverage is exact")
    func exactCoverage() {
        #expect(
            Set(PipelineAgentContract.executableTools.keys)
                == Set(PipelineAgentContract.musicvideoPhases.dropFirst())
        )
        #expect(
            PipelineAgentContract.musicvideoPhases
                == [
                    "project_init",
                    "analysis",
                    "brief",
                    "production_design",
                    "treatment",
                    "storyboard",
                    "bible",
                    "shotlist",
                    "sanity",
                    "frames",
                    "render",
                ]
        )
        #expect(
            Set(PipelineAgentContract.currentPhaseCapabilities.keys)
                == Set(PipelineAgentContract.musicvideoPhases)
        )
    }

    @Test("aggregate phase approval is owned only by the gate card")
    func aggregateApprovalHasOneOwner() throws {
        for name in [
            "analysis", "brief", "production-design", "treatment",
            "storyboard", "bible", "shotlist", "sanity", "frame", "render",
        ] {
            let document = try PackKnowledge.phaseDoc(name: name)
            #expect(document.contains("approve_gate"), "\(name) must request its gate")
            #expect(document.contains("directly"), "\(name) must route directly to the gate card")
            #expect(!document.contains("`approve` → set the gate"))
            #expect(!document.contains("On `approve`: set the gate"))
            #expect(!document.contains("- `approve_gate`"))
        }
    }

    @Test("approved Sanity rewinds before re-audit")
    func sanityResumeRewindsBeforeRunner() throws {
        let document = try PackKnowledge.phaseDoc(name: "sanity")
        let resume = try #require(document.range(
            of: "On `re-audit` → first call"
        ))
        let rewind = try #require(document.range(
            of: "rewind(project_dir, target_phase=\"sanity\")",
            range: resume.lowerBound..<document.endIndex
        ))
        let runner = try #require(document.range(
            of: "call `run_sanity`",
            range: rewind.upperBound..<document.endIndex
        ))
        #expect(rewind.lowerBound < runner.lowerBound)
    }

    @Test("Sanity accepts the gate-approved macOS 26 rhythm path")
    func sanityUsesAnalysisProvenanceContract() throws {
        let document = try PackKnowledge.phaseDoc(name: "sanity")
        #expect(document.contains("`beat-transformer` is the"))
        #expect(document.contains("canonical macOS 26 path"))
        #expect(document.contains("`native_dsp` and `neural_beat_grid` both"))
        #expect(!document.contains("analysis.downbeat_source != \"music-understanding\""))
        #expect(!document.contains("error\n     `NON_SYSTEM_RHYTHM`"))
    }

    @Test("Brief-owned production decisions are settled before approval")
    func briefOwnsDeferredDecisions() throws {
        let document = try PackKnowledge.phaseDoc(name: "brief")
        #expect(document.contains("finish before Brief approval"))
        #expect(document.contains("A later change requires an explicit Brief rewind"))
        #expect(!document.contains("budget_stop_eur"))
        #expect(document.contains("never a limit"))
        #expect(document.contains("A 4-second net shot therefore"))
        #expect(document.contains("orders 6 gross seconds"))
        #expect(!document.contains("DEFER these out of the brief interview"))
        #expect(!document.contains("freeze-frame handles"))
        #expect(!document.contains("redo it after K7"))
    }

    @Test("Frames and Render never stop for spend")
    func spendNeverStopsFramesOrRender() throws {
        let frame = try PackKnowledge.phaseDoc(name: "frame")
        let render = try PackKnowledge.phaseDoc(name: "render")
        for document in [frame, render] {
            #expect(document.contains("is a display, never a limit"))
            #expect(!document.contains("over_budget"))
            #expect(!document.contains("budget_stop_eur"))
            #expect(!document.contains("If `spend_complete=false`, stop as well"))
            #expect(!document.contains("Abort in the same way when"))
        }
    }

    @Test("Bible instructions keep approved images as identity truth")
    func bibleDoesNotRequestRecognitionTrait() throws {
        let document = try PackKnowledge.phaseDoc(name: "bible")
        #expect(document.contains("Do not ask for a single “recognition trait”"))
        #expect(document.contains("Canonical approved character"))
        #expect(!document.contains("frame builder appends it"))
        #expect(!document.contains("Ask the user explicitly per character"))
    }

    @Test("Image workflow defaults to Flare and reserves Sunburst for precision")
    func gptImage25WorkflowRouting() throws {
        let schemaRoutes = Set(FrameImageModel.allCases.map(\.rawValue).filter {
            $0.contains("gpt-image-2.5")
        })
        #expect(schemaRoutes == Set([
            "fal:fal-ai/gpt-image-2.5/flare/text-to-image",
            "fal:fal-ai/gpt-image-2.5/flare/edit",
            "fal:fal-ai/gpt-image-2.5/sunburst/text-to-image",
            "fal:fal-ai/gpt-image-2.5/sunburst/edit",
        ]))
        for phase in ["brief", "bible", "frame"] {
            let document = try PackKnowledge.phaseDoc(name: phase)
            #expect(document.contains("Flare"), "\(phase) must name the default route")
            #expect(document.contains("Sunburst"), "\(phase) must name the precision route")
            #expect(document.contains("list_models"), "\(phase) must use the live catalog")
        }
        let bible = try PackKnowledge.phaseDoc(name: "bible")
        let frame = try PackKnowledge.phaseDoc(name: "frame")
        #expect(bible.contains("does not approve a sheet"))
        #expect(frame.contains("vision audit still decide acceptance"))
    }

    @Test("Cover is a reachable post-pipeline utility, never a hidden phase")
    func coverIsPostPipelineUtility() throws {
        let document = try PackKnowledge.phaseDoc(name: "cover")
        #expect(document.contains("# Post-pipeline utility — Cover Images"))
        #expect(document.contains("It has no gate"))
        #expect(!document.contains("approve_gate"))
        #expect(!document.contains("`Bash`"))
        #expect(PipelineAgentContract.postPipelineUtilityCapabilities == Set([
            .compilePrompt,
            .generateImage,
            .prepareGenerationBatch,
            .importMedia,
        ]))
        #expect(!PipelineAgentContract.allowsPostPipelineUtilityTool(.generateVideo))
        #expect(!PipelineAgentContract.allowsPostPipelineUtilityTool(.recordRender))
        #expect(!PipelineAgentContract.allowsPostPipelineUtilityTool(.writeBible))
    }

    @Test("completed pipelines allow only the post-pipeline utility capability set")
    func completedPipelineCapabilitiesAreEnforced() throws {
        try CurrentMusicvideoFixture.load()
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        for phase in CurrentMusicvideoFixture.phases {
            gates.set(phase, Gate(approved: true, state: .approved))
        }
        try store.save(gates, to: PipelineLayout.gatesFile)
        let harness = PipelineAgentHarness()

        #expect(try harness.guardCurrentPhaseWork(
            tool: .generateImage,
            dataRoot: dataRoot,
            declaredPack: "musicvideo",
            declaredBinding: try binding
        ) == nil)
        do {
            _ = try harness.guardCurrentPhaseWork(
                tool: .generateVideo,
                dataRoot: dataRoot,
                declaredPack: "musicvideo",
                declaredBinding: try binding
            )
            Issue.record("generate_video unexpectedly passed the post-pipeline utility boundary")
        } catch let error as ToolError {
            #expect(error.message.contains("Explicitly rewind"))
        }
    }

    @Test("current-phase tools are restricted to the phase that owns them")
    func currentPhaseCapabilitiesAreEnforced() throws {
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try CurrentMusicvideoFixture.seedAnalysis(dataRoot: dataRoot, readableTrack: true)
        let harness = PipelineAgentHarness()
        try harness.guardPhaseWork(phase: "project_init", dataRoot: dataRoot,
            declaredPack: "musicvideo", declaredBinding: binding)
        #expect(throws: ToolError.self) {
            _ = try harness.guardCurrentPhaseWork(tool: .generateImage, dataRoot: dataRoot,
                declaredPack: "musicvideo", declaredBinding: binding)
        }
    }

    @Test("future phase work is rejected even when its tool names a phase")
    func futurePhaseIsRejected() throws {
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try CurrentMusicvideoFixture.seedAnalysis(dataRoot: dataRoot, readableTrack: true)
        let harness = PipelineAgentHarness()
        try harness.guardPhaseWork(phase: "project_init", dataRoot: dataRoot,
            declaredPack: "musicvideo", declaredBinding: binding)
        #expect(throws: GateBlocked.self) {
            try harness.guardPhaseWork(phase: "analysis", dataRoot: dataRoot,
                declaredPack: "musicvideo", declaredBinding: binding)
        }
    }

    @Test("a phase-bound tool must belong to the current phase contract")
    func phaseBoundToolCapabilitiesAreEnforced() throws {
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try CurrentMusicvideoFixture.seedAnalysis(dataRoot: dataRoot, readableTrack: true)
        let harness = PipelineAgentHarness()
        try harness.guardPhaseWork(phase: "project_init", dataRoot: dataRoot,
            declaredPack: "musicvideo", declaredBinding: binding)
        #expect(throws: ToolError.self) {
            try harness.guardPhaseWork(tool: .runPhase, phase: "project_init", dataRoot: dataRoot,
                declaredPack: "musicvideo", declaredBinding: binding)
        }
    }

    @Test("an active workflow rejects unknown phases")
    func unknownPhaseIsRejected() throws {
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try CurrentMusicvideoFixture.seedAnalysis(dataRoot: dataRoot, readableTrack: true)
        let harness = PipelineAgentHarness()
        try harness.guardPhaseWork(phase: "project_init", dataRoot: dataRoot,
            declaredPack: "musicvideo", declaredBinding: binding)
        #expect(throws: GateBlocked.self) {
            try harness.guardPhaseWork(phase: "invented_phase", dataRoot: dataRoot,
                declaredPack: "musicvideo", declaredBinding: binding)
        }
    }

    @Test("unreadable project format settings block every harness entry")
    func unreadableFormatSettingsFailClosed() throws {
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try CurrentMusicvideoFixture.seedAnalysis(dataRoot: dataRoot, readableTrack: true)
        let settings = FrameInventory.projectHome(of: dataRoot).appendingPathComponent("ngv.json")
        let original = try Data(contentsOf: settings)
        let harness = PipelineAgentHarness()
        try harness.guardPhaseWork(phase: "project_init", dataRoot: dataRoot,
            declaredPack: "musicvideo", declaredBinding: binding)
        try Data("{broken".utf8).write(to: settings, options: .atomic)
        #expect(throws: PhaseContractError.self) {
            try harness.guardPhaseWork(phase: "project_init", dataRoot: dataRoot,
                declaredPack: "musicvideo", declaredBinding: binding)
        }
        #expect(throws: PhaseContractError.self) {
            _ = try harness.guardCurrentPhaseWork(tool: .generateImage, dataRoot: dataRoot,
                declaredPack: "musicvideo", declaredBinding: binding)
        }
        try FileManager.default.removeItem(at: settings)
        #expect(throws: PhaseContractError.self) {
            try harness.guardPhaseWork(phase: "project_init", dataRoot: dataRoot,
                declaredPack: "musicvideo", declaredBinding: binding)
        }
        try original.write(to: settings, options: .atomic)
        try harness.guardPhaseWork(phase: "project_init", dataRoot: dataRoot,
            declaredPack: "musicvideo", declaredBinding: binding)
    }

    @Test("the canonical shot-list writer rejects contradictory chain state before versioning")
    func shotlistWriterEnforcesChainContract() throws {
        let (dataRoot, cleanup) = try scaffold(activateCurrent: false)
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let first = try Shot(
            id: "s001",
            section: "verse",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .performance,
            description: "Opening shot.",
            visualPrompt: "A locked opening composition.",
            mood: "measured",
            keyframeStrategy: .start
        )
        let chained = try Shot(
            id: "s002",
            section: "verse",
            timeStart: 4,
            timeEnd: 8,
            durationS: 4,
            type: .performance,
            description: "Continue from the prior frame.",
            visualPrompt: "The prior composition continues.",
            mood: "measured",
            keyframeStrategy: .none,
            seedanceInputMode: .keyframe,
            chainWithPreviousEnd: true
        )
        let song = try Song(
            title: "Track",
            audioPath: "audio/track.wav",
            analysisPath: "analysis/track.json",
            bpm: 120,
            durationS: 8
        )
        var shotlist = try Shotlist(
            schema_: shotlistSchemaVersion,
            mode: .section,
            project: "pipeline-contract",
            song: song,
            generated: "2026-07-26T00:00:00Z",
            generator: "test",
            shots: [first, chained]
        )

        _ = try PipelineShotlistWriter.write(
            shotlist,
            dataRoot: dataRoot,
            declaredPack: nil
        )
        #expect(latestShotlistVersion(dataRoot: dataRoot) == 1)

        shotlist.shots[1].keyframeStrategy = .start
        #expect(throws: ToolError.self) {
            _ = try PipelineShotlistWriter.write(
                shotlist,
                dataRoot: dataRoot,
                declaredPack: nil
            )
        }
        #expect(latestShotlistVersion(dataRoot: dataRoot) == 1)
    }

    @Test("current-phase tools require an explicit rewind after completion")
    func completedPipelineRejectsCurrentPhaseTools() throws {
        try CurrentMusicvideoFixture.load()
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let registry = PackCatalog.registry(activePack: "musicvideo")
        let order = PhaseOrder.merged(
            packPlacements: registry.phasePlacements
        )
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try store.load(
            Gates.self,
            at: PipelineLayout.gatesFile
        )
        for phase in order {
            GatesOperations.approve(&gates, phase: phase)
        }
        try store.save(gates, to: PipelineLayout.gatesFile)

        do {
            _ = try PipelineAgentHarness().guardCurrentPhaseWork(
                tool: .generateVideo,
                dataRoot: dataRoot,
                declaredPack: "musicvideo",
                declaredBinding: try binding
            )
            Issue.record("generate_video unexpectedly passed a complete pipeline")
        } catch let error as ToolError {
            #expect(error.message.contains("Explicitly rewind"))
        }
    }

    @Test("a phase artifact mutation rewinds that phase and every downstream gate")
    func mutationInvalidatesDownstreamGates() async throws {
        let context = try await CurrentMusicvideoFixture.makeStoryboard()
        defer {
            context.document.close()
            context.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: context.packageURL)
        }
        let order = CurrentMusicvideoFixture.phases
        let store = YAMLArtifactStore(dataRoot: context.dataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        for phase in order { GatesOperations.approve(&gates, phase: phase) }
        try store.save(gates, to: PipelineLayout.gatesFile)
        try await PipelineAgentHarness().recordPhaseMutation(phase: "storyboard", dataRoot: context.dataRoot,
            declaredPack: "musicvideo", declaredBinding: binding)
        let updated = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        let boundary = try #require(order.firstIndex(of: "storyboard"))
        for phase in order[..<boundary] { #expect(updated.get(phase).approved, "\(phase) must stay approved") }
        for phase in order[boundary...] {
            #expect(!updated.get(phase).approved, "\(phase) must be invalidated")
            #expect(updated.get(phase).state == .pending)
        }
        let lineage = try #require(try PipelineLineageStore.loadIfPresent(dataRoot: context.dataRoot))
        #expect(lineage.phases["storyboard"] != nil)
    }

    @Test("a lineage capture failure still invalidates the changed phase")
    func lineageFailureStillInvalidatesGates() async throws {
        let context = try await CurrentMusicvideoFixture.makeStoryboard()
        defer {
            context.document.close()
            context.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: context.packageURL)
        }
        let order = CurrentMusicvideoFixture.phases
        let store = YAMLArtifactStore(dataRoot: context.dataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        for phase in order { GatesOperations.approve(&gates, phase: phase) }
        try store.save(gates, to: PipelineLayout.gatesFile)
        try Data("unreadable".utf8).write(to: context.dataRoot.appendingPathComponent(StoryboardV2.currentPath))
        await #expect(throws: ToolError.self) {
            try await PipelineAgentHarness().recordPhaseMutation(phase: "storyboard", dataRoot: context.dataRoot,
                declaredPack: "musicvideo", declaredBinding: binding)
        }
        let updated = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        let boundary = try #require(order.firstIndex(of: "storyboard"))
        for phase in order[boundary...] { #expect(!updated.get(phase).approved) }
    }

    @Test("phase work revalidates the immediate approved predecessor")
    func phaseWorkRejectsStalePredecessor() async throws {
        let context = try await CurrentMusicvideoFixture.makeScript(stopBeforeBrief: true)
        defer {
            context.document.close()
            context.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: context.packageURL)
        }
        let harness = PipelineAgentHarness()
        try harness.guardPhaseWork(phase: "brief", dataRoot: context.dataRoot,
            declaredPack: "musicvideo", declaredBinding: binding)
        let song = try #require(AudioProjectLayout.songFiles(dataRoot: context.dataRoot).first)
        try Data("song-v2".utf8).write(to: song)
        #expect(throws: GateBlocked.self) {
            try harness.guardPhaseWork(phase: "brief", dataRoot: context.dataRoot,
                declaredPack: "musicvideo", declaredBinding: binding)
        }
    }

}
