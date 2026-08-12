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
    public static let progressStages = [
        "decode_audio",
        "measure_structure",
        "separate_stems",
        "detect_beat_grid",
        "detect_harmony",
        "align_lyrics",
        "write_analysis",
    ]

    /// Audio extensions this analysis runner accepts — the engine's shared
    /// `AudioProjectLayout.audioExtensions`, so what the host's `attach_song`
    /// accepts is exactly what `run_phase("analysis")` decodes.
    public static var audioExtensions: Set<String> { AudioProjectLayout.audioExtensions }

    public enum RunError: LocalizedError, Sendable, Equatable, CustomStringConvertible {
        case noDecoder
        case noSong(audioDir: String)
        case multipleSongs(audioDir: String, files: [String])
        case multipleLyrics(lyricsDir: String, files: [String])

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
            case .multipleLyrics(let lyricsDir, let files):
                return "Keep at most one lyrics file in \(lyricsDir) — found: "
                    + "\(files.joined(separator: ", "))."
            }
        }

        public var errorDescription: String? { description }
    }

    /// Result of a run — the persisted analysis plus the artifact URL, so the
    /// caller (the app's `run_phase` tool) can build a summary for the agent.
    public struct Outcome: Sendable {
        public let analysis: Analysis
        public let artifactURL: URL
        public let songFilename: String
    }

    struct StageDiagnostic: Codable, Sendable, Equatable {
        enum Status: String, Codable, Sendable {
            case succeeded
            case degraded
            case failed
            case unavailable
            case notApplicable = "not_applicable"
        }

        let stage: String
        let status: Status
        let detail: String
    }

    struct CanonicalOutcome: Sendable {
        let analysis: Analysis
        let structureResolution: Consolidator.StructureResolution
    }

    /// Discover the single song file in `<dataRoot>/audio/`. `nil`/empty → a
    /// `.noSong` blocker; more than one → a `.multipleSongs` error naming them.
    static func locateSong(dataRoot: URL) throws -> URL {
        let audioDir = dataRoot.appendingPathComponent("audio")
        let songs = AudioProjectLayout.songFiles(dataRoot: dataRoot)
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
    /// markers as evidence for nearby acoustic boundaries. Optional ML failures
    /// are persisted as stage diagnostics instead of being silently discarded.
    @discardableResult
    public static func run(
        dataRoot: URL,
        decoder: any AudioPCMDecoding,
        transcriber: (any AudioTranscribing)? = nil,
        separator: (any AudioStemSeparating)? = nil,
        beatDetector: (any AudioBeatDetecting)? = nil,
        chordRecognizer: (any AudioChordRecognizing)? = nil,
        progress: (@Sendable (PhaseProgress) -> Void)? = nil
    ) throws -> Outcome {
        let song = try locateSong(dataRoot: dataRoot)
        func report(_ stageIndex: Int) {
            progress?(
                PhaseProgress(
                    sourceFilename: song.lastPathComponent,
                    stageID: progressStages[stageIndex],
                    completedUnitCount: stageIndex,
                    totalUnitCount: progressStages.count,
                    nextStageID: progressStages.indices.contains(stageIndex + 1)
                        ? progressStages[stageIndex + 1]
                        : nil
                )
            )
        }
        report(0)
        let pcm = try decoder.decode(song)
        report(1)
        var raw = AudioAnalysisPipeline.run(pcm)
        var stages = ["load_audio", "rhythm", "structure", "features"]
        var diagnostics = [
            StageDiagnostic(stage: "native_dsp", status: .succeeded, detail: "Measured rhythm, structure candidates, and features."),
        ]
        var lyrics: String?
        var lyricsLoadError: String?
        do {
            lyrics = try loadLyrics(dataRoot: dataRoot)
            diagnostics.append(
                StageDiagnostic(
                    stage: "lyrics_input",
                    status: lyrics == nil ? .notApplicable : .succeeded,
                    detail: lyrics == nil ? "No lyrics were attached." : "Loaded the project lyrics."
                )
            )
        } catch {
            lyricsLoadError = error.localizedDescription
            diagnostics.append(StageDiagnostic(stage: "lyrics_input", status: .failed, detail: error.localizedDescription))
        }

        report(2)
        var stems: SeparatedStems?
        if let separator {
            let stemsDir = dataRoot.appendingPathComponent("analysis", isDirectory: true)
                .appendingPathComponent("stems", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: stemsDir, withIntermediateDirectories: true)
                let separated = try separator.separateStems(song, into: stemsDir)
                stems = separated
                stages.append("separation")
                diagnostics.append(StageDiagnostic(stage: "stem_separation", status: .succeeded, detail: "Created project-local stems."))
            } catch {
                diagnostics.append(StageDiagnostic(stage: "stem_separation", status: .failed, detail: error.localizedDescription))
            }
        } else {
            diagnostics.append(StageDiagnostic(stage: "stem_separation", status: .unavailable, detail: "No stem separator is registered."))
        }

        report(3)
        if let beatDetector {
            do {
                if let grid = try beatDetector.detectBeats(song, stems: stems),
                   !grid.beats.isEmpty, !grid.downbeats.isEmpty {
                    raw.beats = grid.beats.map { Energy.round3($0) }
                    raw.downbeats = grid.downbeats.map { Energy.round3($0) }
                    raw.downbeatSource = Analysis.DownbeatSource.beatTransformer.rawValue
                    if let bpm = grid.bpm, bpm > 0 { raw.bpm = Energy.round3(bpm) }
                    stages.append("neural_beats")
                    diagnostics.append(StageDiagnostic(stage: "neural_beat_grid", status: .succeeded, detail: "Replaced the DSP rhythm grid with the neural beat/downbeat grid."))
                } else {
                    diagnostics.append(StageDiagnostic(stage: "neural_beat_grid", status: .degraded, detail: "The detector returned no complete beat/downbeat grid; retained the DSP grid."))
                }
            } catch {
                diagnostics.append(StageDiagnostic(stage: "neural_beat_grid", status: .failed, detail: error.localizedDescription))
            }
        } else {
            diagnostics.append(StageDiagnostic(stage: "neural_beat_grid", status: .unavailable, detail: "No neural beat detector is registered; retained the DSP grid."))
        }

        report(4)
        var chords: [Chord] = []
        if let chordRecognizer {
            do {
                if let recognized = try chordRecognizer.recognizeChords(song, stems: stems),
                   !recognized.isEmpty {
                    chords = recognized.map {
                        Chord(start: Energy.round3($0.start), end: Energy.round3($0.end), label: $0.label)
                    }
                    stages.append("chords")
                    diagnostics.append(StageDiagnostic(stage: "chord_recognition", status: .succeeded, detail: "Measured the chord progression."))
                } else {
                    diagnostics.append(StageDiagnostic(stage: "chord_recognition", status: .degraded, detail: "The recognizer returned no chords."))
                }
            } catch {
                diagnostics.append(StageDiagnostic(stage: "chord_recognition", status: .failed, detail: error.localizedDescription))
            }
        } else {
            diagnostics.append(StageDiagnostic(stage: "chord_recognition", status: .unavailable, detail: "No chord recognizer is registered."))
        }

        report(5)
        var alignment: [AlignmentLine] = []
        var alignmentReport: LyricsAlignment.Result?
        if let lyrics, let transcriber {
            let vocals = stems?.vocals ?? song
            do {
                let words = try transcriber.transcribe(vocals, language: "auto")
                let tokens = words.map {
                    TranscriptToken(text: $0.text, start: $0.start, end: $0.end, score: $0.confidence)
                }
                let result = LyricsAlignment.alignDetailed(lyrics: lyrics, transcript: tokens)
                alignmentReport = result
                alignment = result.lines
                if result.hasReliableStructureEvidence {
                    stages.append("alignment")
                    diagnostics.append(StageDiagnostic(stage: "lyrics_alignment", status: .succeeded, detail: "Reliably anchored all \(result.markerCount) lyric section markers."))
                } else {
                    diagnostics.append(StageDiagnostic(stage: "lyrics_alignment", status: .degraded, detail: "Mapped \(result.mappedLineCount)/\(result.lyricLineCount) lyric lines and reliably anchored \(result.reliableMarkerCount)/\(result.markerCount) section markers."))
                }
            } catch {
                diagnostics.append(StageDiagnostic(stage: "lyrics_alignment", status: .failed, detail: error.localizedDescription))
            }
        } else if let lyricsLoadError {
            diagnostics.append(StageDiagnostic(stage: "lyrics_alignment", status: .unavailable, detail: "Lyrics input failed: \(lyricsLoadError)"))
        } else if lyrics == nil {
            diagnostics.append(StageDiagnostic(stage: "lyrics_alignment", status: .notApplicable, detail: "No lyrics were attached."))
        } else {
            diagnostics.append(StageDiagnostic(stage: "lyrics_alignment", status: .unavailable, detail: "Lyrics are present, but no transcriber is registered."))
        }

        report(6)
        let songPath = FrameInventory.relativePath(of: song, to: dataRoot)
        let project = FrameInventory.projectName(of: dataRoot) ?? FrameInventory.projectHome(of: dataRoot).lastPathComponent
        let canonical = try toCanonicalDetailed(
            raw, project: project, songPath: songPath,
            stems: stems.map { relativeStems($0, dataRoot: dataRoot) },
            lyricsAlignment: alignment, alignmentReport: alignmentReport,
            chords: chords, pipelineStages: stages,
            songSha256: sha256(song))

        let outDir = dataRoot.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("\(song.deletingPathExtension().lastPathComponent).json")
        let data = try encodeArtifact(
            canonical.analysis,
            structureResolution: canonical.structureResolution,
            stageDiagnostics: diagnostics
        )
        try data.write(to: outURL, options: .atomic)

        return Outcome(analysis: canonical.analysis, artifactURL: outURL, songFilename: song.lastPathComponent)
    }

    /// The project's provided lyrics (with `[Section]` markers / `(stage directions)`),
    /// read from the single lyric file in `<dataRoot>/lyrics/`. Returns nil when
    /// none was supplied and rejects ambiguous or unreadable input.
    static func loadLyrics(dataRoot: URL) throws -> String? {
        let dir = dataRoot.appendingPathComponent("lyrics", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]
        )
        var files: [URL] = []
        for entry in entries where lyricsExtensions.contains(entry.pathExtension.lowercased()) {
            if try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(entry)
            }
        }
        files.sort { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 1 else {
            throw RunError.multipleLyrics(lyricsDir: dir.path, files: files.map(\.lastPathComponent))
        }
        guard let file = files.first else { return nil }
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
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
    /// list is kept as a `structure_candidate`. Reliably aligned lyric markers
    /// can select and label nearby acoustic candidates but never create timing.
    /// `stems` is populated when separation ran; `key` carries the DSP
    /// pipeline's Krumhansl-Schmuckler result; `chords` carry the recognizer's chord
    /// progression when a chord model is registered (empty otherwise).
    static func toCanonical(
        _ raw: AudioAnalysis, project: String, songPath: String, stems: Stems? = nil,
        lyricsAlignment: [AlignmentLine] = [], chords: [Chord] = [],
        pipelineStages: [String] = ["load_audio", "rhythm", "structure", "features"],
        songSha256: String? = nil
    ) throws -> Analysis {
        try toCanonicalDetailed(
            raw,
            project: project,
            songPath: songPath,
            stems: stems,
            lyricsAlignment: lyricsAlignment,
            alignmentReport: nil,
            chords: chords,
            pipelineStages: pipelineStages,
            songSha256: songSha256
        ).analysis
    }

    static func toCanonicalDetailed(
        _ raw: AudioAnalysis, project: String, songPath: String, stems: Stems? = nil,
        lyricsAlignment: [AlignmentLine] = [], alignmentReport: LyricsAlignment.Result? = nil,
        chords: [Chord] = [],
        pipelineStages: [String] = ["load_audio", "rhythm", "structure", "features"],
        songSha256: String? = nil
    ) throws -> CanonicalOutcome {
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
        // Candidate provenance belongs to the detector series, never to a mutable section field.
        var candidateSeries = [
            Consolidator.CandidateSeries(source: StructureCandidate.Source.librosa.rawValue, sections: detected),
        ]
        if !detectedEssentia.isEmpty {
            candidateSeries.append(
                Consolidator.CandidateSeries(
                    source: StructureCandidate.Source.essentia.rawValue,
                    sections: detectedEssentia
                )
            )
        }
        let consolidation = Consolidator.consolidateDetailed(
            candidateSeries: candidateSeries,
            alignment: lyricsAlignment.isEmpty ? nil : lyricsAlignment,
            alignmentReport: alignmentReport,
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
        let analysis = try Analysis(
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
            pipelineStages: pipelineStages,
            songSha256: songSha256
        )
        return CanonicalOutcome(analysis: analysis, structureResolution: consolidation.resolution)
    }

    private static func sha256(_ url: URL) throws -> String {
        try FileDigest.sha256(of: url)
    }

    /// Persist matching the Python idiom: pretty-printed (2-space), snake_case
    /// aliases, `exclude_none`, sorted keys, trailing newline. `Codable`'s
    /// `.sortedKeys` and `encodeIfPresent` on the optional schema fields give
    /// the same stable, none-omitting output.
    static func encodeArtifact(
        _ analysis: Analysis,
        structureResolution: Consolidator.StructureResolution? = nil,
        stageDiagnostics: [StageDiagnostic] = []
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(analysis)
        guard structureResolution != nil || !stageDiagnostics.isEmpty else {
            var data = encoded
            data.append(0x0A)
            return data
        }
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        if let structureResolution {
            object["structure_resolution"] = try JSONSerialization.jsonObject(
                with: encoder.encode(structureResolution)
            )
        }
        if !stageDiagnostics.isEmpty {
            object["stage_diagnostics"] = try JSONSerialization.jsonObject(
                with: encoder.encode(stageDiagnostics)
            )
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)  // trailing newline, matching pipeline.py's write
        return data
    }
}
