import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// M8c: the analysis phase runner plumbing — song discovery, decoder injection,
/// DSP run, and canonical `analysis/<song>.json` persistence.
///
/// The runner drives the full DSP pipeline (see AudioAnalysisTests), which
/// SIGTRAPs only under the swiftpm test runner — tracked in #118. The
/// end-to-end persistence tests that exercise the pipeline are parked the same
/// way; the pure plumbing tests (discovery, decoder-missing error, mapping,
/// encoding) that do NOT touch the DSP stay live.
@Suite("Musicvideo Analysis Runner", .serialized)
struct AnalysisRunnerPlumbingTests {
    /// A stub decoder returning a fixed buffer regardless of URL — lets the
    /// runner run without AVFoundation.
    struct StubDecoder: AudioPCMDecoding {
        let buffer: PCMBuffer
        func decode(_ url: URL) throws -> PCMBuffer { buffer }
    }

    /// A tiny deterministic click track (few beats), enough for a valid BPM.
    static func clickTrack(bpm: Double, seconds: Double, sr: Double = analysisSampleRate) -> PCMBuffer {
        let total = Int(seconds * sr)
        var signal = [Float](repeating: 0, count: total)
        let period = 60.0 / bpm
        let clickLen = Int(0.04 * sr)
        var t = 0.0
        while t < seconds {
            let start = Int(t * sr)
            for i in 0..<clickLen where start + i < total {
                let localT = Double(i) / sr
                signal[start + i] += Float(exp(-40.0 * localT) * sin(2 * Double.pi * 1000 * localT))
            }
            t += period
        }
        return PCMBuffer(samples: signal, sampleRate: sr)
    }

    static func makeProject(name: String = "Runner Test") throws -> URL {
        // Packs load at runtime now — register the loadable pack (idempotent) the
        // way the host's PluginLoader does, so `PackCatalog` resolves "musicvideo".
        PackCatalog.register(MusicvideoPack())
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("m8c-\(UUID().uuidString)")
        let dataRoot = try ProjectScaffold.initProject(
            home: home, name: name, mode: .beat,
            extraDirs: PackCatalog.projectDirs(activePack: "musicvideo")
        )
        return dataRoot
    }

    static func placeSong(_ filename: String, in dataRoot: URL) throws {
        let audioDir = dataRoot.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        // Zero-byte placeholder — the stub decoder ignores contents.
        FileManager.default.createFile(atPath: audioDir.appendingPathComponent(filename).path, contents: Data())
    }

    // MARK: - Song discovery (no DSP)

    @Test("no song in audio/ → actionable noSong error")
    func noSong() throws {
        let dataRoot = try Self.makeProject()
        #expect(throws: MusicvideoAnalysisRunner.RunError.self) {
            try MusicvideoAnalysisRunner.locateSong(dataRoot: dataRoot)
        }
    }

    @Test("exactly one song is located")
    func oneSong() throws {
        let dataRoot = try Self.makeProject()
        try Self.placeSong("track.mp3", in: dataRoot)
        let song = try MusicvideoAnalysisRunner.locateSong(dataRoot: dataRoot)
        #expect(song.lastPathComponent == "track.mp3")
    }

    @Test("multiple songs → multipleSongs error naming the files")
    func multipleSongs() throws {
        let dataRoot = try Self.makeProject()
        try Self.placeSong("a.mp3", in: dataRoot)
        try Self.placeSong("b.wav", in: dataRoot)
        do {
            _ = try MusicvideoAnalysisRunner.locateSong(dataRoot: dataRoot)
            Issue.record("expected multipleSongs error")
        } catch let error as MusicvideoAnalysisRunner.RunError {
            guard case .multipleSongs(_, let files) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(files == ["a.mp3", "b.wav"])
        }
    }

    @Test("non-audio files are ignored during discovery")
    func ignoresNonAudio() throws {
        let dataRoot = try Self.makeProject()
        try Self.placeSong("song.flac", in: dataRoot)
        try Self.placeSong("notes.txt", in: dataRoot)
        let song = try MusicvideoAnalysisRunner.locateSong(dataRoot: dataRoot)
        #expect(song.lastPathComponent == "song.flac")
    }

    // MARK: - Canonical mapping + encoding (no DSP)

    @Test("AudioAnalysis maps onto the canonical Analysis schema")
    func canonicalMapping() throws {
        let raw = AudioAnalysis(
            sampleRate: 22050, durationS: 12.0, bpm: 120.0,
            beats: [0.5, 1.0, 1.5], downbeats: [0.5], downbeatSource: "librosa-heuristic",
            sections: [AudioSection(index: 0, start: 0.0, end: 12.0, cluster: 0, source: "consolidated")],
            energyCurve: [EnergyPoint(t: 0, rms: 0.1)], tempoCurve: [TempoPoint(t: 0, bpm: 120)]
        )
        let analysis = try MusicvideoAnalysisRunner.toCanonical(raw, project: "P", songPath: "audio/song.mp3")
        #expect(analysis.schema == analysisSchemaVersion)
        #expect(analysis.project == "P")
        #expect(analysis.songPath == "audio/song.mp3")
        #expect(analysis.bpm == 120.0)
        #expect(analysis.beats == [0.5, 1.0, 1.5])
        #expect(analysis.downbeatSource == .librosaHeuristic)
        #expect(analysis.sections.count == 1)
        // Endpoints are clamped to the full track: no audio falls outside a section even after
        // downbeat snapping.
        #expect(analysis.sections.first?.start == 0.0)
        #expect(analysis.sections.first?.end == 12.0)
        #expect(analysis.pipelineStages == ["load_audio", "rhythm", "structure", "features"])
    }

    @Test("encoded artifact is snake_case, sorted, newline-terminated, and re-decodes")
    func encodingShape() throws {
        let analysis = try Analysis(
            project: "P", songPath: "audio/song.mp3", sampleRate: 22050, durationS: 12.0, bpm: 120.0,
            beats: [0.5, 1.0], downbeats: [0.5], downbeatSource: .librosaHeuristic,
            sections: [AnalysisSection(index: 0, start: 0.0, end: 12.0, cluster: 0, source: "consolidated")]
        )
        let data = try MusicvideoAnalysisRunner.encodeArtifact(analysis)
        #expect(data.last == 0x0A)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"song_path\""))
        #expect(text.contains("\"downbeat_source\""))
        // Slashes in song_path are not escaped.
        #expect(text.contains("audio/song.mp3"))
        let decoded = try JSONDecoder().decode(Analysis.self, from: data)
        #expect(decoded == analysis)
    }

    @Test("missing decoder surfaces an actionable error, not a crash")
    func missingDecoderError() {
        #expect(MusicvideoAnalysisRunner.RunError.noDecoder.description.contains("decode"))
    }

    @Test("registered phase without a decoder throws noDecoder before any DSP")
    func phaseWithoutDecoder() throws {
        let dataRoot = try Self.makeProject(name: "No Decoder")
        try Self.placeSong("x.mp3", in: dataRoot)
        let registry = PackCatalog.registry(activePack: "musicvideo")
        let runner = try #require(registry.phases["analysis"])
        #expect(throws: MusicvideoAnalysisRunner.RunError.self) { try runner(dataRoot) }
    }

    // MARK: - Forced-alignment wiring (no DSP)

    @Test("lyric alignment drives section boundaries (Consolidator Path A)")
    func alignmentDrivesSections() throws {
        let raw = AudioAnalysis(
            sampleRate: 22050, durationS: 30.0, bpm: 120.0,
            beats: [], downbeats: [0.0, 10.0, 20.0], downbeatSource: "librosa-heuristic",
            sections: [], energyCurve: [], tempoCurve: []
        )
        let alignment = [
            AlignmentLine(start: 0.2, end: 9.5, text: "opening line", sectionMarker: "verse1",
                          words: [AlignmentWord(text: "opening", start: 0.2, end: 1.0, score: 1.0)]),
            AlignmentLine(start: 10.1, end: 19.5, text: "the hook", sectionMarker: "chorus",
                          words: [AlignmentWord(text: "hook", start: 10.1, end: 11.0, score: 1.0)]),
        ]
        let a = try MusicvideoAnalysisRunner.toCanonical(
            raw, project: "P", songPath: "audio/s.mp3", lyricsAlignment: alignment)
        // Sections come from the alignment markers, not the (empty) DSP detector.
        #expect(!a.sections.isEmpty)
        #expect(a.sections.allSatisfy { $0.source == "alignment" })
        #expect(a.sections.contains { $0.label == "verse1" })
        #expect(a.sections.contains { $0.label == "chorus" })
        // The alignment itself is persisted for downstream (subtitles, section review).
        #expect(a.alignment.count == 2)
        #expect(a.sections.first?.start == 0.0 && a.sections.last?.end == 30.0)
    }

    @Test("stems are persisted project-relative")
    func stemsRelative() throws {
        let dataRoot = URL(fileURLWithPath: "/tmp/proj/pipeline", isDirectory: true)
        let abs = SeparatedStems(
            vocals: dataRoot.appendingPathComponent("analysis/stems/vocals.wav"),
            drums: dataRoot.appendingPathComponent("analysis/stems/drums.wav"))
        let rel = MusicvideoAnalysisRunner.relativeStems(abs, dataRoot: dataRoot)
        #expect(rel.vocals == "analysis/stems/vocals.wav")
        #expect(rel.drums == "analysis/stems/drums.wav")
        #expect(rel.bass == nil && rel.other == nil)

        let raw = AudioAnalysis(
            sampleRate: 22050, durationS: 12.0, bpm: 120.0, beats: [0.5], downbeats: [0.5],
            downbeatSource: "librosa-heuristic",
            sections: [AudioSection(index: 0, start: 0, end: 12, cluster: 0, source: "consolidated")],
            energyCurve: [], tempoCurve: [])
        let a = try MusicvideoAnalysisRunner.toCanonical(
            raw, project: "P", songPath: "audio/s.mp3", stems: rel,
            pipelineStages: ["load_audio", "rhythm", "structure", "features", "separation"])
        #expect(a.stems?.vocals == "analysis/stems/vocals.wav")
        #expect(a.pipelineStages.contains("separation"))
    }

    @Test("loadLyrics reads the single lyric file; empty dir → nil")
    func loadLyrics() throws {
        let dataRoot = try Self.makeProject(name: "Lyrics")
        #expect(MusicvideoAnalysisRunner.loadLyrics(dataRoot: dataRoot) == nil)
        let lyricsDir = dataRoot.appendingPathComponent("lyrics")
        try FileManager.default.createDirectory(at: lyricsDir, withIntermediateDirectories: true)
        try "[Verse 1]\nHello world".write(
            to: lyricsDir.appendingPathComponent("song.txt"), atomically: true, encoding: .utf8)
        #expect(MusicvideoAnalysisRunner.loadLyrics(dataRoot: dataRoot)?.contains("Hello world") == true)
    }
}

/// End-to-end runner tests that DRIVE THE DSP PIPELINE — parked identically to
/// AudioAnalysisTests (SIGTRAP under swiftpm runner, #118). Buffers are tiny to
/// minimize risk; ground truth is known by construction.
@Suite("Musicvideo Analysis Runner E2E", .serialized, .disabled("SIGTRAP under swiftpm runner — tracked in #118"))
struct AnalysisRunnerE2ETests {
    @Test("run writes analysis/<song>.json with the expected fields")
    func writesArtifact() throws {
        let dataRoot = try AnalysisRunnerPlumbingTests.makeProject(name: "Beat Song")
        try AnalysisRunnerPlumbingTests.placeSong("mysong.mp3", in: dataRoot)
        let decoder = AnalysisRunnerPlumbingTests.StubDecoder(
            buffer: AnalysisRunnerPlumbingTests.clickTrack(bpm: 120, seconds: 5)
        )

        let outcome = try MusicvideoAnalysisRunner.run(dataRoot: dataRoot, decoder: decoder)

        let expected = dataRoot.appendingPathComponent("analysis/mysong.json")
        #expect(outcome.artifactURL.standardizedFileURL == expected.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: expected.path))
        #expect(outcome.songFilename == "mysong.mp3")

        let data = try Data(contentsOf: expected)
        let analysis = try JSONDecoder().decode(Analysis.self, from: data)
        #expect(analysis.project == "Beat Song")
        #expect(analysis.songPath == "audio/mysong.mp3")
        #expect(abs(analysis.bpm - 120) <= 3, "bpm=\(analysis.bpm)")
        #expect(!analysis.beats.isEmpty)
        #expect(analysis.durationS > 0)
    }

    @Test("run through the registered phase runner uses the injected decoder")
    func viaRegisteredPhase() throws {
        let dataRoot = try AnalysisRunnerPlumbingTests.makeProject(name: "Via Phase")
        try AnalysisRunnerPlumbingTests.placeSong("clip.wav", in: dataRoot)

        let registry = PackCatalog.registry(activePack: "musicvideo")
        registry.registerAudioDecoder(
            AnalysisRunnerPlumbingTests.StubDecoder(buffer: AnalysisRunnerPlumbingTests.clickTrack(bpm: 100, seconds: 4))
        )
        let runner = try #require(registry.phases["analysis"])
        try runner(dataRoot)

        #expect(FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("analysis/clip.json").path))
    }

    /// A transcriber stub returning fixed timed words regardless of the audio.
    struct StubTranscriber: AudioTranscribing {
        let words: [TranscribedWord]
        func transcribe(_ audio: URL, language: String) throws -> [TranscribedWord] { words }
    }

    @Test("a registered transcriber + provided lyrics force-aligns into the artifact")
    func forcedAlignmentEndToEnd() throws {
        let dataRoot = try AnalysisRunnerPlumbingTests.makeProject(name: "Aligned")
        try AnalysisRunnerPlumbingTests.placeSong("song.wav", in: dataRoot)
        let lyricsDir = dataRoot.appendingPathComponent("lyrics")
        try FileManager.default.createDirectory(at: lyricsDir, withIntermediateDirectories: true)
        try "[Verse 1]\nmorning light is falling\n[Chorus]\nburning clear and bright"
            .write(to: lyricsDir.appendingPathComponent("song.txt"), atomically: true, encoding: .utf8)

        let words = [
            TranscribedWord(text: "morning", start: 1.0, end: 1.4), TranscribedWord(text: "light", start: 1.4, end: 1.7),
            TranscribedWord(text: "is", start: 1.7, end: 1.9), TranscribedWord(text: "falling", start: 1.9, end: 2.5),
            TranscribedWord(text: "burning", start: 5.0, end: 5.4), TranscribedWord(text: "clear", start: 5.4, end: 5.7),
            TranscribedWord(text: "and", start: 5.7, end: 5.9), TranscribedWord(text: "bright", start: 5.9, end: 6.4),
        ]
        let outcome = try MusicvideoAnalysisRunner.run(
            dataRoot: dataRoot,
            decoder: AnalysisRunnerPlumbingTests.StubDecoder(buffer: AnalysisRunnerPlumbingTests.clickTrack(bpm: 120, seconds: 8)),
            transcriber: StubTranscriber(words: words))

        #expect(outcome.analysis.alignment.count == 2)
        #expect(outcome.analysis.alignment.contains { $0.sectionMarker == "verse1" })
        #expect(outcome.analysis.pipelineStages.contains("alignment"))
        // Alignment markers drive the section boundaries.
        #expect(outcome.analysis.sections.allSatisfy { $0.source == "alignment" })
    }
}
