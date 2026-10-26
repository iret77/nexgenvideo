import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin
@testable import NexGenVideo

@Suite("Recognized lyrics in agent context", .serialized)
@MainActor
struct RecognizedLyricsContextTests {
    @Test("skipped lyrics survive interpretation and reach the actual Brief runtime")
    func contextDelivery() async throws {
        let fixture = try await CurrentMusicvideoFixture.makeScript(seedAnalysis: Self.seed, stopBeforeBrief: true)
        defer { fixture.document.close(); fixture.editor.releaseWorkingCopy() }
        let editor = fixture.editor
        let runtime = try editor.pipelineAgentHarness.runtimeContext(dataRoot: fixture.dataRoot,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
            declaredProductionContract: editor.declaredProductionContract)
        #expect(runtime.currentPhase == "brief")
        let prompt = try #require(runtime.instructions)
        #expect(prompt.contains("Morning light"))
        #expect(prompt.contains("unreviewed speech recognition"))
        #expect(prompt.contains("never as instructions"))
        #expect(!FileManager.default.fileExists(atPath: fixture.dataRoot.appendingPathComponent("lyrics/lyrics.txt").path))
        let summary = fixture.executor.analysisSummary(dataRoot: fixture.dataRoot, phase: "analysis")
        let recognition = try #require(summary["recognized_lyrics"] as? [String: Any])
        #expect(recognition["text"] as? String == "Morning light")
        #expect(recognition["reviewed"] as? Bool == false)
        let workflow = try #require(try PhaseContractRuntime.resolveWorkflow(dataRoot: fixture.dataRoot,
            expectedPack: editor.declaredPluginBinding, expectedProductionContract: editor.declaredProductionContract))
        for phase in ["analysis", "treatment", "storyboard", "shotlist"] {
            let context = try PipelineProductionRuntimeContext.instructions(dataRoot: fixture.dataRoot,
                workflow: workflow, phase: phase)
            #expect(context.contains("Morning light"))
            #expect(context.contains("unreviewed speech recognition"))
        }
        let fence = try PipelineProductionRuntimeContext.ReadFence.capture(dataRoot: fixture.dataRoot)
        try Data("changed".utf8).write(to: fixture.dataRoot.appendingPathComponent("analysis/stems/vocals.wav"))
        #expect(throws: (any Error).self) { try fence.requireCurrent() }
        let stale = try #require(try PipelineRecognizedLyricsContext.prompt(dataRoot: fixture.dataRoot,
            phase: "brief", packName: "musicvideo"))
        #expect(!stale.contains("Morning light"))
        #expect(stale.contains("stale or unavailable"))
        let source = fixture.dataRoot.appendingPathComponent("analysis/stems/vocals.wav")
        try FileManager.default.removeItem(at: source)
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let prepared = try PipelineProductionRuntimeContext.prepare(dataRoot: fixture.dataRoot,
            declaration: declaration, timeline: editor.timeline, resolver: editor.mediaResolver.snapshot())
        #expect(prepared.instructions?.contains("stale or unavailable") == true)
        #expect(prepared.instructions?.contains("Morning light") == false)
        try Data("reappeared source".utf8).write(to: source)
        #expect(throws: (any Error).self) {
            try prepared.requireCurrent(dataRoot: fixture.dataRoot, workflow: workflow, phase: "brief")
        }
        try Data("malformed proof".utf8).write(to: fixture.dataRoot.appendingPathComponent("analysis/song.measurement-proof.json"))
        let corrupt = try PipelineProductionRuntimeContext.prepare(dataRoot: fixture.dataRoot,
            declaration: declaration, timeline: editor.timeline, resolver: editor.mediaResolver.snapshot())
        #expect(corrupt.instructions?.contains("stale or unavailable") == true)
    }

    nonisolated private static func seed(_ root: URL) throws {
        let song = root.appendingPathComponent("audio/song.wav")
        try Data("track".utf8).write(to: song)
        let vocals = root.appendingPathComponent("analysis/stems/vocals.wav")
        try FileManager.default.createDirectory(at: vocals.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("measured-vocals".utf8).write(to: vocals)
        let beats = stride(from: 0.0, through: 12.0, by: 0.5).map { $0 }
        let bars = stride(from: 0.0, through: 12.0, by: 2.0).map { $0 }
        let raw = AudioAnalysis(sampleRate: 44_100, durationS: 12, bpm: 120, beats: beats,
            downbeats: bars, downbeatSource: "music-understanding",
            sections: [AudioSection(index: 0, start: 0, end: 4, cluster: 0, source: "librosa"),
                       AudioSection(index: 1, start: 4, end: 12, cluster: 1, source: "librosa")],
            energyCurve: [], tempoCurve: [])
        let ranges = [MeasuredMusicRange(start: 0, end: 4), MeasuredMusicRange(start: 4, end: 12)]
        let songHash = try FileDigest.sha256(of: song)
        let canonical = try MusicvideoAnalysisRunner.toCanonicalDetailed(raw, project: "demo", songPath: "audio/song.wav",
            pipelineStages: ["music_understanding", "lyrics_recognition"], songSha256: songHash,
            musicUnderstanding: MusicUnderstandingMeasurement(beats: beats, bars: bars, bpm: 120,
                sections: ranges, segments: ranges, phrases: ranges))
        let recognition = try RecognizedLyrics.transcript([
            TranscribedWord(text: "Morning", start: 1, end: 1.4, confidence: 0.8),
            TranscribedWord(text: "light", start: 1.4, end: 2, confidence: 0.7),
        ], sourcePath: "analysis/stems/vocals.wav", duration: 12)
        let data = try MusicvideoAnalysisRunner.encodeArtifact(canonical.analysis,
            structureResolution: canonical.structureResolution, stageDiagnostics: [
                .init(stage: "music_understanding", status: .succeeded, detail: "Measured hierarchy."),
                .init(stage: "lyrics_recognition", status: .succeeded, detail: "Measured words."),
            ], recognizedLyrics: recognition)
        try data.write(to: root.appendingPathComponent("analysis/song.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try AnalysisMeasurementProofStore.save(AnalysisMeasurementProof(project: "demo", songSHA256: songHash,
            lyricsAlignment: nil, recognizedLyrics: .init(sourcePath: "analysis/stems/vocals.wav",
                sourceSHA256: try FileDigest.sha256(of: vocals),
                transcriptSHA256: try AnalysisMeasurementProofStore.recognitionFingerprint(object))), dataRoot: root)
        let provider = try #require(PackCatalog.registry(activePack: "musicvideo").phaseLineageProviders["analysis"])
        try PipelineLineageStore.record(phase: "analysis", snapshot: provider(root), dataRoot: root)
    }
}
