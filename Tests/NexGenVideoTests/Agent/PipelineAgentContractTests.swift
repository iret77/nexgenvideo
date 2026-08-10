import Foundation
import MusicvideoPlugin
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Pipeline agent contract")
struct PipelineAgentContractTests {
    private func scaffold() throws -> (URL, URL) {
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
        let settings = try JSONSerialization.data(
            withJSONObject: ["activePlugin": "musicvideo"]
        )
        try settings.write(to: home.appendingPathComponent("ngv.json"))
        return (dataRoot, cleanup)
    }

    @Test("every musicvideo phase has one order, gate, instructions, and executable path")
    func completeContract() throws {
        let pack = MusicvideoPack()
        PackCatalog.register(pack)
        let manifest = try #require(HardStepManifest.load(pack: pack))
        let failures = PipelineAgentContract.failures(
            registry: PackCatalog.registry(activePack: pack.name),
            manifest: manifest,
            phaseDocument: {
                try? PackKnowledge.phaseDoc(name: $0)
            }
        )

        #expect(failures.isEmpty, "Pipeline contract failures: \(failures)")
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

    @Test("current-phase tools are restricted to the phase that owns them")
    func currentPhaseCapabilitiesAreEnforced() throws {
        PackCatalog.register(MusicvideoPack())
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try Data("track".utf8).write(
            to: dataRoot.appendingPathComponent("audio/song.wav")
        )
        let manifest = try #require(
            HardStepManifest.load(pack: MusicvideoPack())
        )
        let lyrics = try #require(
            manifest.steps(for: "project_init").first {
                $0.kind == .lyrics
            }
        )
        try IntakeLedger.recordDecline(lyrics, dataRoot: dataRoot)
        let harness = PipelineAgentHarness()

        do {
            try harness.guardCurrentPhaseWork(
                tool: .generateImage,
                dataRoot: dataRoot
            )
            Issue.record("generate_image unexpectedly passed Project Init")
        } catch let error as ToolError {
            #expect(
                error.message.contains(
                    "is not part of the Project Init phase contract"
                )
            )
        }
    }

    @Test("future phase work is rejected even when its tool names a phase")
    func futurePhaseIsRejected() throws {
        PackCatalog.register(MusicvideoPack())
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try Data("track".utf8).write(
            to: dataRoot.appendingPathComponent("audio/song.wav")
        )
        let manifest = try #require(
            HardStepManifest.load(pack: MusicvideoPack())
        )
        let lyrics = try #require(
            manifest.steps(for: "project_init").first {
                $0.kind == .lyrics
            }
        )
        try IntakeLedger.recordDecline(lyrics, dataRoot: dataRoot)

        do {
            try PipelineAgentHarness().guardPhaseWork(
                phase: "analysis",
                dataRoot: dataRoot
            )
            Issue.record("analysis unexpectedly ran before Project Init approval")
        } catch let error as ToolError {
            #expect(
                error.message.contains(
                    "while \"project_init\" is the current phase"
                )
            )
        }
    }

    @Test("a phase-bound tool must belong to the current phase contract")
    func phaseBoundToolCapabilitiesAreEnforced() throws {
        PackCatalog.register(MusicvideoPack())
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try Data("track".utf8).write(
            to: dataRoot.appendingPathComponent("audio/song.wav")
        )
        let manifest = try #require(
            HardStepManifest.load(pack: MusicvideoPack())
        )
        let lyrics = try #require(
            manifest.steps(for: "project_init").first {
                $0.kind == .lyrics
            }
        )
        try IntakeLedger.recordDecline(lyrics, dataRoot: dataRoot)

        do {
            try PipelineAgentHarness().guardPhaseWork(
                tool: .runPhase,
                phase: "project_init",
                dataRoot: dataRoot
            )
            Issue.record("run_phase unexpectedly passed Project Init")
        } catch let error as ToolError {
            #expect(
                error.message.contains(
                    "is not part of the Project Init phase contract"
                )
            )
        }
    }

    @Test("an active workflow rejects unknown phases")
    func unknownPhaseIsRejected() throws {
        PackCatalog.register(MusicvideoPack())
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        do {
            try PipelineAgentHarness().guardPhaseWork(
                phase: "invented_phase",
                dataRoot: dataRoot
            )
            Issue.record("unknown phase unexpectedly passed")
        } catch let error as ToolError {
            #expect(error.message.contains("no registered phase"))
        }
    }

    @Test("unreadable project format settings block every harness entry")
    func unreadableFormatSettingsFailClosed() throws {
        PackCatalog.register(MusicvideoPack())
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let settings = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent("ngv.json")
        try Data("{broken".utf8).write(to: settings, options: .atomic)
        let harness = PipelineAgentHarness()

        do {
            try harness.guardPhaseWork(
                phase: "project_init",
                dataRoot: dataRoot,
                declaredPack: "musicvideo"
            )
            Issue.record("phase work unexpectedly ignored unreadable format settings")
        } catch let error as ToolError {
            #expect(error.message.contains("unreadable"))
        }

        do {
            _ = try harness.guardCurrentPhaseWork(
                tool: .generateImage,
                dataRoot: dataRoot,
                declaredPack: "musicvideo"
            )
            Issue.record("current-phase work unexpectedly ignored unreadable format settings")
        } catch let error as ToolError {
            #expect(error.message.contains("unreadable"))
        }

        try FileManager.default.removeItem(at: settings)
        do {
            try harness.guardPhaseWork(
                phase: "project_init",
                dataRoot: dataRoot,
                declaredPack: "musicvideo"
            )
            Issue.record("phase work unexpectedly ignored missing format settings")
        } catch let error as ToolError {
            #expect(error.message.contains("no format settings"))
        }
    }

    @Test("the canonical shot-list writer rejects contradictory chain state before versioning")
    func shotlistWriterEnforcesChainContract() throws {
        let (dataRoot, cleanup) = try scaffold()
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
            declaredPack: nil,
            enforceProductionPlans: false
        )
        #expect(latestShotlistVersion(dataRoot: dataRoot) == 1)

        shotlist.shots[1].keyframeStrategy = .start
        #expect(throws: ToolError.self) {
            _ = try PipelineShotlistWriter.write(
                shotlist,
                dataRoot: dataRoot,
                declaredPack: nil,
                enforceProductionPlans: false
            )
        }
        #expect(latestShotlistVersion(dataRoot: dataRoot) == 1)
    }

    @Test("current-phase tools require an explicit rewind after completion")
    func completedPipelineRejectsCurrentPhaseTools() throws {
        PackCatalog.register(MusicvideoPack())
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
                dataRoot: dataRoot
            )
            Issue.record("generate_video unexpectedly passed a complete pipeline")
        } catch let error as ToolError {
            #expect(error.message.contains("Explicitly rewind"))
        }
    }

    @Test("a phase artifact mutation rewinds that phase and every downstream gate")
    func mutationInvalidatesDownstreamGates() async throws {
        PackCatalog.register(MusicvideoPack())
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let registry = PackCatalog.registry(activePack: "musicvideo")
        let order = PhaseOrder.merged(packPlacements: registry.phasePlacements)
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        for phase in order {
            GatesOperations.approve(&gates, phase: phase)
        }
        try store.save(gates, to: PipelineLayout.gatesFile)

        let harness = PipelineAgentHarness()
        try await harness.recordPhaseMutation(phase: "storyboard", dataRoot: dataRoot)

        let updated = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        let boundary = try #require(order.firstIndex(of: "storyboard"))
        for phase in order[..<boundary] {
            #expect(updated.get(phase).approved, "\(phase) must stay approved")
        }
        for phase in order[boundary...] {
            #expect(!updated.get(phase).approved, "\(phase) must be invalidated")
            #expect(updated.get(phase).state == .pending)
        }
        let lineage = try #require(
            try PipelineLineageStore.loadIfPresent(dataRoot: dataRoot)
        )
        #expect(lineage.phases["storyboard"] != nil)
    }

    @Test("a lineage capture failure still invalidates the changed phase")
    func lineageFailureStillInvalidatesGates() async throws {
        PackCatalog.register(MusicvideoPack())
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let registry = PackCatalog.registry(activePack: "musicvideo")
        let order = PhaseOrder.merged(packPlacements: registry.phasePlacements)
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        for phase in order {
            GatesOperations.approve(&gates, phase: phase)
        }
        try store.save(gates, to: PipelineLayout.gatesFile)
        let storyboard = dataRoot.appendingPathComponent(
            PipelineLayout.storyboardCurrentFile
        )
        try FileManager.default.createDirectory(
            at: storyboard.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("unreadable".utf8).write(to: storyboard)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: storyboard.path
        )

        await #expect(throws: ToolError.self) {
            try await PipelineAgentHarness().recordPhaseMutation(
                phase: "storyboard",
                dataRoot: dataRoot
            )
        }

        let updated = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        let boundary = try #require(order.firstIndex(of: "storyboard"))
        for phase in order[boundary...] {
            #expect(!updated.get(phase).approved)
        }
    }

    @Test("phase work revalidates the immediate approved predecessor")
    func phaseWorkRejectsStalePredecessor() throws {
        PackCatalog.register(MusicvideoPack())
        let (dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let song = dataRoot.appendingPathComponent("audio/song.wav")
        try Data("song-v1".utf8).write(to: song)
        let analysisDirectory = dataRoot.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(
            at: analysisDirectory,
            withIntermediateDirectories: true
        )
        let analysis: [String: Any] = [
            "schema": analysisSchemaVersion,
            "project": "pipeline-contract",
            "song_path": "audio/song.wav",
            "song_sha256": try FileDigest.sha256(of: song),
            "beats": [0.0, 0.5, 1.0],
            "downbeats": [0.0, 2.0],
            "bpm": 120.0,
            "duration_s": 4.0,
            "sections": [[
                "index": 0,
                "start": 0.0,
                "end": 4.0,
                "cluster": 0,
            ]],
            "tempo_multiplier": 1.0,
            "interpretation": [
                "section_labels": [[
                    "index": "0",
                    "label": "intro",
                    "confidence": "1.000",
                ]],
                "anomalies": [],
                "overall_character": "Measured opening.",
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: analysis,
            options: [.prettyPrinted, .sortedKeys]
        ).write(
            to: analysisDirectory.appendingPathComponent("song.json")
        )
        let registry = PackCatalog.registry(activePack: "musicvideo")
        let provider = try #require(
            registry.phaseLineageProviders["analysis"]
        )
        try PipelineLineageStore.record(
            phase: "analysis",
            snapshot: try provider(dataRoot),
            dataRoot: dataRoot
        )
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try store.load(
            Gates.self,
            at: PipelineLayout.gatesFile
        )
        GatesOperations.approve(&gates, phase: "project_init")
        GatesOperations.approve(&gates, phase: "analysis")
        try store.save(gates, to: PipelineLayout.gatesFile)

        try Data("song-v2".utf8).write(to: song)

        #expect(throws: ToolError.self) {
            try PipelineAgentHarness().guardPhaseWork(
                phase: "brief",
                dataRoot: dataRoot
            )
        }
    }
}
