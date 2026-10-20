import AppKit
import AVFoundation
import CryptoKit
import Foundation
@testable import MusicvideoPlugin
import NexGenEngine
import Testing
@testable import NexGenVideo

enum CurrentMusicvideoFixture {
    private static let catalogRegistrationLock = NSLock()

    static let phases = [
        "project_init", "analysis", "brief", "production_design", "treatment", "script",
        "storyboard", "shot_planning", "bible", "shotlist", "sanity", "frames", "render_review", "render",
    ]

    static func phaseBound(_ phase: String) -> Set<ToolName> {
        switch phase {
        case "script": return [.writeScript]
        case "storyboard": return [.writeStoryboardBundle, .assignStoryboardSketch]
        case "shot_planning": return [.writeShotPlanningDraft]
        case "render_review": return [.writeRenderReview]
        default: return PipelineAgentContract.executableTools[phase] ?? []
        }
    }

    static func supporting(_ phase: String) -> Set<ToolName> {
        switch phase {
        case "script", "shot_planning": return []
        case "storyboard": return [.compileStoryboardSketch, .compilePrompt, .generateImage, .prepareGenerationBatch, .importMedia]
        case "render_review": return [.compilePrompt, .getRenderReviewInputs]
        case "bible", "shotlist":
            return (PipelineAgentContract.currentPhaseCapabilities[phase] ?? []).union([.prepareProductionAssets])
        default: return PipelineAgentContract.currentPhaseCapabilities[phase] ?? []
        }
    }

    static var binding: ProjectPackBinding {
        get throws {
            try #require(ProjectPackBinding(id: "musicvideo", version: "0.6.0", projectSchema: "musicvideo/3.0.0"))
        }
    }

    @discardableResult
    static func load() throws -> ResolvedPhaseContract {
        let pack = MusicvideoPack()
        let binding = try binding
        try #require(pack.version == binding.version && EngineContract.current == 12)
        let prepared = try PhaseContractBundleLoader.prepareDirect(pack: pack)
        let registry = EngineRegistry()
        pack.register(registry)
        let resolved = try PhaseContractResolver.resolve(
            manifest: prepared.manifest,
            packVersion: prepared.identity.version,
            engineContract: prepared.identity.engineContract,
            resourceRoot: prepared.resourceRoot,
            hardSteps: prepared.hardSteps,
            registry: registry,
            historicalCompatibility: prepared.historicalCompatibility,
            projectSchema: binding.projectSchema
        )
        try PhaseContractRuntime.validateLockedMusicvideoIfNeeded(resolved, registry: registry)
        try #require(resolved.order == phases)
        _ = try HostWorkflowKey.resolve(binding: binding, contract: resolved)
        catalogRegistrationLock.lock()
        defer { catalogRegistrationLock.unlock() }
        let currentRegistered = PackCatalog.pack(named: pack.name).map {
            $0 is MusicvideoPack && $0.version == binding.version
        } ?? false
        if !currentRegistered {
            PackCatalog.register(pack)
        }
        PhaseContractStore.register(resolved)
        return resolved
    }

    @discardableResult
    static func activate(at projectURL: URL, initialize: Bool = true) throws -> ProjectPackBinding {
        try load()
        let binding = try binding
        try ProjectPluginSettings.setActivePlugin(binding, projectURL: projectURL)
        if initialize, let root = DataRootResolver.dataRoot(of: projectURL) {
            try initializeWorkflow(dataRoot: root)
        }
        return binding
    }

    static func initializeWorkflow(dataRoot: URL) throws {
        let workflow = try #require(try PhaseContractRuntime.resolveWorkflow(
            dataRoot: dataRoot, expectedPack: binding, expectedProductionContract: nil
        ))
        try PhaseContractRuntime.initializeWorkflowState(dataRoot: dataRoot, workflow: workflow)
    }

    static func seedAnalysis(dataRoot: URL, readableTrack: Bool = false) throws -> URL {
        let audio = dataRoot.appendingPathComponent("audio/song.wav")
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if readableTrack {
            try writeTrack(audio, durationSeconds: 12)
        } else {
            try Data("stub".utf8).write(to: audio)
        }
        let songHash = SHA256.hash(data: try Data(contentsOf: audio))
            .map { String(format: "%02x", $0) }
            .joined()
        let lyrics = "[Intro]\nopening line\n[Verse]\nverse line"
        let lyricsURL = dataRoot.appendingPathComponent("lyrics/lyrics.txt")
        try FileManager.default.createDirectory(
            at: lyricsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(lyrics.utf8).write(to: lyricsURL)
        let analysis = dataRoot.appendingPathComponent("analysis/song.json")
        try FileManager.default.createDirectory(
            at: analysis.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let alignmentSource = dataRoot.appendingPathComponent("analysis/stems/vocals.wav")
        try FileManager.default.createDirectory(
            at: alignmentSource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("measured-vocals".utf8).write(to: alignmentSource)
        let object: [String: Any] = [
            "schema": "analysis/v3",
            "project": "demo",
            "song_path": "audio/song.wav",
            "song_sha256": songHash,
            "sample_rate": 44_100,
            "duration_s": 12,
            "bpm": 120,
            "beats": [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
            "downbeats": [0.0, 2.0, 4.0],
            "sections": [
                [
                    "index": 0, "start": 0.0, "end": 4.0, "cluster": 0,
                    "label": "intro", "source": "measured_system_hierarchy", "confidence": 0.95,
                ],
                [
                    "index": 1, "start": 4.0, "end": 12.0, "cluster": 1,
                    "label": "verse", "source": "measured_system_hierarchy", "confidence": 0.95,
                ],
            ],
            "structure_candidates": [
                ["source": "librosa", "sections": [
                    ["index": 0, "start": 0.0, "end": 4.0, "cluster": 0],
                    ["index": 1, "start": 4.0, "end": 12.0, "cluster": 1],
                ]],
                ["source": "essentia", "sections": [
                    ["index": 0, "start": 0.0, "end": 4.0, "cluster": 0],
                    ["index": 1, "start": 4.0, "end": 12.0, "cluster": 1],
                ]],
            ],
            "structure_resolution": [
                "version": "adaptive-structure/v5",
                "status": "resolved",
                "method": "music_understanding_hierarchy",
                "detector_sources": ["apple_music_understanding"],
                "minimum_section_bars": 0,
                "candidate_boundary_count": 2,
                "consensus_boundary_count": 0,
                "alignment_marker_count": 2,
                "resolved_alignment_marker_count": 2,
                "alignment_timing_evidence": "recognized_speech",
                "accepted_boundary_count": 1,
                "discarded_boundary_count": 2,
                "boundary_evidence": [
                    [
                        "time": 0.0,
                        "kind": "system_hierarchy",
                        "detector_sources": ["apple_music_understanding"],
                        "lyric_marker": "intro",
                    ],
                    [
                        "time": 4.0,
                        "kind": "system_hierarchy",
                        "detector_sources": ["apple_music_understanding"],
                        "lyric_marker": "verse",
                    ],
                ],
                "hierarchy": [
                    "source": "apple_music_understanding",
                    "sections": [["start": 0.0, "end": 4.0], ["start": 4.0, "end": 12.0]],
                    "segments": [["start": 0.0, "end": 4.0], ["start": 4.0, "end": 12.0]],
                    "phrases": [["start": 0.0, "end": 4.0], ["start": 4.0, "end": 12.0]],
                ],
                "detail": "Measured system hierarchy.",
            ],
            "downbeat_source": "music-understanding",
            "pipeline_stages": ["structure", "music_understanding"],
            "stage_diagnostics": [[
                "stage": "music_understanding",
                "status": "succeeded",
                "detail": "Measured system hierarchy.",
            ], [
                "stage": "lyrics_alignment",
                "status": "succeeded",
                "detail": "Measured recognized-speech alignment.",
                "timing_evidence": "recognized_speech",
            ]],
            "alignment": [
                ["start": 0.0, "end": 1.0, "text": "opening line", "section_marker": "intro", "words": [
                    ["text": "opening", "start": 0.0, "end": 0.4, "score": 1.0],
                    ["text": "line", "start": 0.4, "end": 1.0, "score": 1.0],
                ]],
                ["start": 4.0, "end": 5.0, "text": "verse line", "section_marker": "verse", "words": [
                    ["text": "verse", "start": 4.0, "end": 4.4, "score": 1.0],
                    ["text": "line", "start": 4.4, "end": 5.0, "score": 1.0],
                ]],
            ],
            "interpretation": [
                "section_labels": [],
                "anomalies": [[
                    "kind": "boundary_divergence",
                    "time": "4.000",
                    "detail": "librosa vs essentia",
                ]],
                "overall_character": "",
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: analysis)
        try AnalysisMeasurementProofStore.save(
            AnalysisMeasurementProof(
                project: "demo",
                songSHA256: songHash,
                lyricsAlignment: AnalysisMeasurementProof.LyricsAlignmentProof(
                    sourcePath: "analysis/stems/vocals.wav",
                    sourceSHA256: try FileDigest.sha256(of: alignmentSource),
                    lyricsSHA256: AnalysisMeasurementProofStore.lyricsFingerprint(lyrics),
                    alignmentSHA256: try AnalysisMeasurementProofStore.alignmentFingerprint(
                        object
                    ),
                    timingEvidence: .recognizedSpeech,
                    timingMethod: nil,
                    markerCount: 2,
                    lyricTokenCount: 4,
                    matchedTokenCount: 4
                )
            ),
            dataRoot: dataRoot
        )
        try load()
        let provider = try #require(PackCatalog.registry(activePack: "musicvideo").phaseLineageProviders["analysis"])
        try PipelineLineageStore.record(phase: "analysis", snapshot: provider(dataRoot), dataRoot: dataRoot)
        return analysis
    }

    @MainActor
    static func makeScript(
        seedAnalysis: (URL) throws -> Void = { _ = try CurrentMusicvideoFixture.seedAnalysis(dataRoot: $0, readableTrack: true) },
        finalResolution: VideoResolution = .res1080p,
        stopBeforeBrief: Bool = false,
        beforeDesignWrite: (@MainActor (ProductionPlanningAcceptanceFixture.Context) async throws -> Void)? = nil,
        makeExecutor: (EditorViewModel) -> ToolExecutor = { ToolExecutor(editor: $0) }
    ) async throws -> ProductionPlanningAcceptanceFixture.Context {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Current musicvideo \(UUID().uuidString).ngv")
        let root = try ProjectScaffold.initProject(home: home, name: "demo", mode: .section,
            extraDirs: ["audio", "lyrics", "analysis"])
        try Fixtures.prepareProjectPackage(at: home)
        try activate(at: home)
        try seedAnalysis(root)
        let document = try await VideoProject.load(from: home)
        var ready = false
        defer { if !ready { document.close() } }
        _ = NSApplication.shared
        document.makeWindowControllers()
        await document.generationRestorationTask?.value
        let editor = document.editorViewModel
        let working = try #require(editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) })
        let context = ProductionPlanningAcceptanceFixture.Context(document: document, packageURL: home,
            dataRoot: working, executor: makeExecutor(editor))
        try await ProductionPlanningAcceptanceFixture.approve("project_init", in: context)
        try await ProductionPlanningAcceptanceFixture.run("write_analysis_interpretation", args: [
            "tempo_multiplier": 1.0,
            "section_labels": [["index": 0, "label": "intro", "confidence": 1.0],
                ["index": 1, "label": "verse", "confidence": 1.0]],
            "anomalies": [], "overall_character": "A measured opening followed by a verse.",
        ], in: context)
        try await ProductionPlanningAcceptanceFixture.approve("analysis", in: context)
        try PipelineStorySourceWriter.confirmGreenfield(editor: editor)
        let manifest = try #require(HardStepManifest.load(pack: MusicvideoPack()))
        for step in manifest.steps(for: "brief") where step.kind != .script {
            try IntakeLedger.recordDecline(step, dataRoot: working)
        }
        editor.agentService.abandonDialog()
        editor.pipelineAgentHarness.reset()
        await editor.refreshEngineState()
        if stopBeforeBrief { ready = true; return context }
        try await ProductionPlanningAcceptanceFixture.run("record_affect", args: [
            "detected": [["tag": "meditative", "weight": 1.0]], "basis": "inferred",
            "rationale": "Deterministic test interpretation of the measured track.",
        ], in: context)
        try await ProductionPlanningAcceptanceFixture.run("write_brief", args: [
            "mission": "single_release", "target_platform": "YouTube", "aspect_ratio": "16:9",
            "project_mode": "section", "concept_type": "abstract", "visual_medium": "live_action_realistic",
            "figures": "none", "lyrics_integration": "metaphorical", "final_resolution": finalResolution.rawValue,
        ], in: context)
        try await ProductionPlanningAcceptanceFixture.approve("brief", in: context)
        let reference = "production_design/refs/lighting.png"
        _ = try ProjectLocalFile.ensureDirectory("production_design/refs", dataRoot: working)
        try FullflowAcceptanceFixture.writeReference(to: working.appendingPathComponent(reference))
        try await beforeDesignWrite?(context)
        try await ProductionPlanningAcceptanceFixture.run("write_production_design", args: [
            "visual_medium": "live_action_realistic", "visual_medium_notes": "",
            "refs": [["path": reference, "note": "A quiet, clearly lit composition."]],
            "color_script": [], "lighting_anchor": "",
        ], in: context)
        try await ProductionPlanningAcceptanceFixture.approve("production_design", in: context)
        try await ProductionPlanningAcceptanceFixture.writeTreatmentAndScript(in: context)
        ready = true
        return context
    }
    @MainActor
    static func makeStoryboard() async throws -> ProductionPlanningAcceptanceFixture.Context {
        let context = try await makeScript()
        var ready = false
        defer { if !ready { context.document.close() } }
        try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
        _ = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: context)
        _ = try await ProductionPlanningAcceptanceFixture.attachSketches(in: context)
        ready = true
        return context
    }

    private static func writeTrack(_ url: URL, durationSeconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(44_100 * durationSeconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = Float(0.25 * sin(2 * Double.pi * 440 * Double(index) / 44_100))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

}
