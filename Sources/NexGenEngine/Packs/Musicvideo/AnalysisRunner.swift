import Foundation

/// The real `analysis` phase runner (M8c). Locates the song in the project's
/// `audio/` dir, decodes it via the host-injected `AudioPCMDecoding`, runs the
/// native DSP pipeline, and persists the canonical `analysis/<song>.json`
/// artifact — mirroring the retired Python `analysis/pipeline.py::run_phase`
/// (persist path, filename, snake_case shape, `duration_s`/`bpm` rounding).
///
/// `dataRoot` is the project's `_studio/` data root (what `EngineRegistry`
/// phase runners receive and what `ShowFormatters.showAnalysis` reads from):
/// audio lives at `<dataRoot>/audio/`, the artifact lands at
/// `<dataRoot>/analysis/<stem>.json`.
public enum MusicvideoAnalysisRunner {
    /// Audio extensions this analysis runner accepts — the single source of truth reused by the
    /// host's `attach_song` tool so what it lets in is exactly what `run_phase("analysis")` decodes.
    public static let audioExtensions: Set<String> = ["wav", "mp3", "flac", "m4a", "aiff", "aac"]

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

    /// Where a run for the project at `dataRoot` writes its artifact — derived from the same
    /// single-song discovery the runner uses, so callers can read back EXACTLY the artifact a
    /// just-finished run produced (never "some analysis json", which could be stale).
    public static func expectedArtifactURL(dataRoot: URL) throws -> URL {
        let song = try locateSong(dataRoot: dataRoot)
        return dataRoot.appendingPathComponent("analysis")
            .appendingPathComponent("\(song.deletingPathExtension().lastPathComponent).json")
    }

    /// Run the analysis phase for the project at `dataRoot`, decoding via
    /// `decoder`, and persist the artifact. Returns the outcome.
    @discardableResult
    public static func run(dataRoot: URL, decoder: any AudioPCMDecoding) throws -> Outcome {
        let song = try locateSong(dataRoot: dataRoot)
        let pcm = try decoder.decode(song)
        let raw = AudioAnalysisPipeline.run(pcm)

        let songPath = FrameInventory.relativePath(of: song, to: dataRoot)
        let project = FrameInventory.projectName(of: dataRoot) ?? FrameInventory.projectHome(of: dataRoot).lastPathComponent
        let analysis = try toCanonical(raw, project: project, songPath: songPath)

        let outDir = dataRoot.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("\(song.deletingPathExtension().lastPathComponent).json")
        let data = try encodeArtifact(analysis)
        try data.write(to: outURL, options: .atomic)

        return Outcome(analysis: analysis, artifactURL: outURL, songFilename: song.lastPathComponent)
    }

    /// Map the DSP-producible `AudioAnalysis` onto the canonical `Analysis` v2
    /// schema. Only the v1-scope fields are populated; stems/alignment/key/
    /// chords stay empty (deferred), matching the pipeline's scope note.
    static func toCanonical(_ raw: AudioAnalysis, project: String, songPath: String) throws -> Analysis {
        let sections = raw.sections.map {
            AnalysisSection(
                index: $0.index, start: $0.start, end: $0.end, cluster: $0.cluster,
                label: $0.label, source: $0.source, confidence: $0.confidence
            )
        }
        let downbeatSource = Analysis.DownbeatSource(rawValue: raw.downbeatSource) ?? .librosaHeuristic
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
            energyCurve: raw.energyCurve,
            tempoCurve: raw.tempoCurve,
            pipelineStages: ["load_audio", "rhythm", "structure", "features"]
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
