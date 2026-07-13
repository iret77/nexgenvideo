import Foundation
import NexGenEngine

/// The real `analysis` phase runner (M8c). Locates the song in the project's
/// `audio/` dir, decodes it via the host-injected `AudioPCMDecoding`, runs the
/// native DSP pipeline, and persists the canonical `analysis/<song>.json`
/// artifact — mirroring the retired Python `analysis/pipeline.py::run_phase`
/// (persist path, filename, snake_case shape, `duration_s`/`bpm` rounding).
///
/// `dataRoot` is the project's `pipeline/` data root (what `EngineRegistry`
/// phase runners receive and what `ShowFormatters.showAnalysis` reads from):
/// audio lives at `<dataRoot>/audio/`, the artifact lands at
/// `<dataRoot>/analysis/<stem>.json`.
public enum MusicvideoAnalysisRunner {
    /// Audio extensions this analysis runner accepts — the engine's shared
    /// `AudioProjectLayout.audioExtensions`, so what the host's `attach_song`
    /// accepts is exactly what `run_phase("analysis")` decodes.
    public static var audioExtensions: Set<String> { AudioProjectLayout.audioExtensions }

    public enum RunError: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        case noDecoder
        case noSong(audioDir: String)
        case multipleSongs(audioDir: String, files: [String])

        public var description: String {
            switch self {
            case .noDecoder:
                return "No audio decoder is available. This build can't decode audio for analysis."
            case .noSong(let audioDir):
                return "Add the song to audio/ before running analysis — no audio file found in "
                    + "\(audioDir) (expected one .wav/.mp3/.m4a/.aiff/.flac/.aac)."
            case .multipleSongs(let audioDir, let files):
                return "Keep exactly one song in audio/ — found several in \(audioDir): "
                    + "\(files.joined(separator: ", ")). Remove all but the one to analyze."
            }
        }
    }

    /// Result of a run — the persisted analysis plus the artifact URL, so the
    /// caller (the app's `run_phase` tool) can build a summary for the agent.
    public struct Outcome: Sendable {
        public let analysis: Analysis
        public let artifactURL: URL
        public let songFilename: String
    }

    /// Discover the single song file in `<dataRoot>/audio/`. `nil`/empty → a
    /// `.noSong` blocker; more than one → a `.multipleSongs` error naming them.
    static func locateSong(dataRoot: URL) throws -> URL {
        let audioDir = dataRoot.appendingPathComponent("audio")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        let songs = entries
            .filter {
                let isFile = (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                return isFile && audioExtensions.contains($0.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        switch songs.count {
        case 0: throw RunError.noSong(audioDir: audioDir.path)
        case 1: return songs[0]
        default: throw RunError.multipleSongs(audioDir: audioDir.path, files: songs.map(\.lastPathComponent))
        }
    }

    /// Lyric file extensions the runner reads for forced alignment.
    public static let lyricsExtensions: Set<String> = ["txt", "md", "lrc"]

    /// Run the analysis phase for the project at `dataRoot`. `decoder` turns the
    /// song into PCM for the DSP baseline; the optional on-device ML seams
    /// (resolved by the pack from the registry) upgrade it: `separator` isolates
    /// vocals, `transcriber` reads them, `beatDetector` supplies a neural beat
    /// grid. Provided lyrics are force-aligned against the transcript
    /// (`LyricsAlignment`) so the Consolidator can take the alignment section
    /// markers as boundary truth. Every ML stage is best-effort — a missing or
    /// failing provider degrades to the DSP result, never a crash. Persists the
    /// canonical artifact and returns the outcome.
    @discardableResult
    public static func run(
        dataRoot: URL,
        decoder: any AudioPCMDecoding,
        transcriber: (any AudioTranscribing)? = nil,
        separator: (any AudioStemSeparating)? = nil,
        beatDetector: (any AudioBeatDetecting)? = nil,
        chordRecognizer: (any AudioChordRecognizing)? = nil
    ) throws -> Outcome {
        let song = try locateSong(dataRoot: dataRoot)
        let pcm = try decoder.decode(song)
        var raw = AudioAnalysisPipeline.run(pcm)
        var stages = ["load_audio", "rhythm", "structure", "features"]

        // Source separation (optional) — a cleaner signal for transcription + beats.
        var stems: SeparatedStems?
        if let separator {
            let stemsDir = dataRoot.appendingPathComponent("analysis", isDirectory: true)
                .appendingPathComponent("stems", isDirectory: true)
            try? FileManager.default.createDirectory(at: stemsDir, withIntermediateDirectories: true)
            if let separated = try? separator.separateStems(song, into: stemsDir) {
                stems = separated
                stages.append("separation")
            }
        }

        // Neural beat/downbeat detection (optional) — supersedes the DSP grid.
        if let beatDetector, let grid = try? beatDetector.detectBeats(song, stems: stems),
            !grid.beats.isEmpty {
            raw.beats = grid.beats.map { Energy.round3($0) }
            raw.downbeats = grid.downbeats.map { Energy.round3($0) }
            raw.downbeatSource = Analysis.DownbeatSource.beatTransformer.rawValue
            if let bpm = grid.bpm, bpm > 0 { raw.bpm = Energy.round3(bpm) }
            stages.append("neural_beats")
        }

        // Chord recognition (optional) — the harmonic planning signal. Computed whenever a
        // recognizer is registered; the brief's `enable_chord_analysis` gates downstream USE
        // (shotlist/prompt consumption), not the compute (analysis runs before the brief).
        var chords: [Chord] = []
        if let chordRecognizer, let recognized = try? chordRecognizer.recognizeChords(song, stems: stems),
            !recognized.isEmpty {
            chords = recognized.map {
                Chord(start: Energy.round3($0.start), end: Energy.round3($0.end), label: $0.label)
            }
            stages.append("chords")
        }

        // Forced lyric alignment (optional; needs both lyrics and a transcriber).
        var alignment: [AlignmentLine] = []
        if let transcriber, let lyrics = loadLyrics(dataRoot: dataRoot) {
            let vocals = stems?.vocals ?? song
            if let words = try? transcriber.transcribe(vocals, language: "en"), !words.isEmpty {
                let tokens = words.map {
                    TranscriptToken(text: $0.text, start: $0.start, end: $0.end, score: $0.confidence)
                }
                alignment = LyricsAlignment.align(lyrics: lyrics, transcript: tokens)
                if !alignment.isEmpty { stages.append("alignment") }
            }
        }

        let songPath = FrameInventory.relativePath(of: song, to: dataRoot)
        let project = FrameInventory.projectName(of: dataRoot) ?? FrameInventory.projectHome(of: dataRoot).lastPathComponent
        let analysis = try toCanonical(
            raw, project: project, songPath: songPath,
            stems: stems.map { relativeStems($0, dataRoot: dataRoot) },
            lyricsAlignment: alignment, chords: chords, pipelineStages: stages)

        let outDir = dataRoot.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("\(song.deletingPathExtension().lastPathComponent).json")
        let data = try encodeArtifact(analysis)
        try data.write(to: outURL, options: .atomic)

        return Outcome(analysis: analysis, artifactURL: outURL, songFilename: song.lastPathComponent)
    }

    /// The project's provided lyrics (with `[Section]` markers / `(stage directions)`),
    /// read from the single lyric file in `<dataRoot>/lyrics/`. Returns nil when the
    /// dir holds no readable, non-empty lyric file.
    static func loadLyrics(dataRoot: URL) -> String? {
        let dir = dataRoot.appendingPathComponent("lyrics", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        let files = entries
            .filter {
                let isFile = (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                return isFile && lyricsExtensions.contains($0.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            if let text = try? String(contentsOf: file, encoding: .utf8),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    /// Rewrite absolute stem paths to project-relative for the persisted `Stems`.
    static func relativeStems(_ stems: SeparatedStems, dataRoot: URL) -> Stems {
        func rel(_ url: URL?) -> String? { url.map { FrameInventory.relativePath(of: $0, to: dataRoot) } }
        return Stems(vocals: rel(stems.vocals), drums: rel(stems.drums), bass: rel(stems.bass), other: rel(stems.other))
    }

    /// Map the DSP-producible `AudioAnalysis` onto the canonical `Analysis` v2
    /// schema. Both structure detectors (librosa Foote-novelty + BIC-on-MFCC
    /// "essentia") feed the `Consolidator`, which snaps boundaries to the downbeat
    /// grid and flags cross-detector convergence/divergence; each detector's raw
    /// list is kept as a `structure_candidate`. When `lyricsAlignment` carries
    /// `[Section]` markers, those become the primary boundary truth (Consolidator
    /// Path A). `stems` is populated when separation ran; `key` carries the DSP
    /// pipeline's Krumhansl-Schmuckler result; `chords` carry the recognizer's chord
    /// progression when a chord model is registered (empty otherwise).
    static func toCanonical(
        _ raw: AudioAnalysis, project: String, songPath: String, stems: Stems? = nil,
        lyricsAlignment: [AlignmentLine] = [], chords: [Chord] = [],
        pipelineStages: [String] = ["load_audio", "rhythm", "structure", "features"]
    ) throws -> Analysis {
        func map(_ secs: [AudioSection], defaultSource: String) -> [AnalysisSection] {
            secs.map {
                AnalysisSection(
                    index: $0.index, start: $0.start, end: $0.end, cluster: $0.cluster,
                    label: $0.label, source: $0.source ?? defaultSource, confidence: $0.confidence
                )
            }
        }
        let detected = map(raw.sections, defaultSource: "librosa")
        let detectedEssentia = map(raw.sectionsEssentia, defaultSource: "essentia")
        // Both detectors feed the consolidator so its cross-source convergence
        // (single_source_boundary / boundary_divergence) is real, not a facade.
        var candidateLists = [detected]
        if !detectedEssentia.isEmpty { candidateLists.append(detectedEssentia) }
        let consolidation = Consolidator.consolidate(
            candidates: candidateLists,
            alignment: lyricsAlignment.isEmpty ? nil : lyricsAlignment,
            downbeats: raw.downbeats,
            durationS: raw.durationS
        )
        // Guarantee full coverage: downbeat snapping can pull the first boundary off 0 (e.g. to the
        // first downbeat at 0.5s) and the last off the track end — clamp the endpoints so no audio
        // falls outside a section.
        var sections = consolidation.sections
        if !sections.isEmpty {
            sections[0].start = 0.0
            sections[sections.count - 1].end = raw.durationS
        }
        let downbeatSource = Analysis.DownbeatSource(rawValue: raw.downbeatSource) ?? .librosaHeuristic
        let interpretation = consolidation.anomalies.isEmpty
            ? nil
            : Interpretation(anomalies: consolidation.anomalies.map {
                ["kind": $0.kind, "time": String(format: "%.3f", $0.time), "detail": $0.detail]
            })
        return try Analysis(
            project: project,
            songPath: songPath,
            sampleRate: raw.sampleRate,
            durationS: raw.durationS,
            bpm: raw.bpm,
            beats: raw.beats,
            downbeats: raw.downbeats,
            downbeatSource: downbeatSource,
            sections: sections,
            stems: stems,
            alignment: lyricsAlignment,
            structureCandidates: [StructureCandidate(source: .librosa, sections: detected)]
                + (detectedEssentia.isEmpty ? [] : [StructureCandidate(source: .essentia, sections: detectedEssentia)]),
            energyCurve: raw.energyCurve,
            tempoCurve: raw.tempoCurve,
            key: raw.key,
            chordProgression: chords,
            interpretation: interpretation,
            pipelineStages: pipelineStages
        )
    }

    /// Persist matching the Python idiom: pretty-printed (2-space), snake_case
    /// aliases, `exclude_none`, sorted keys, trailing newline. `Codable`'s
    /// `.sortedKeys` and `encodeIfPresent` on the optional schema fields give
    /// the same stable, none-omitting output.
    static func encodeArtifact(_ analysis: Analysis) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(analysis)
        data.append(0x0A)  // trailing newline, matching pipeline.py's write
        return data
    }
}
