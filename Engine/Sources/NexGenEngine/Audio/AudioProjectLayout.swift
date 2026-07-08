import Foundation

/// Conventions for where a project keeps its single source song and its analysis
/// artifact. The engine owns this seam so the HOST (`attach_song`, the analysis
/// read-back in `run_phase`) shares one definition with any audio-driven format
/// pack — the host never has to link the pack to know what an audio file is or
/// where the analysis JSON lands.
public enum AudioProjectLayout {
    /// Audio file extensions treated as a project song — the single source of
    /// truth reused by the host's `attach_song` tool so what it accepts is
    /// exactly what a pack's analysis phase decodes.
    public static let audioExtensions: Set<String> = ["wav", "mp3", "flac", "m4a", "aiff", "aac"]

    /// The audio files sitting directly in `<dataRoot>/audio/`, sorted by name.
    public static func songFiles(dataRoot: URL) -> [URL] {
        let audioDir = dataRoot.appendingPathComponent("audio", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return entries
            .filter {
                let isFile = (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                return isFile && audioExtensions.contains($0.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Where an analysis run for the project at `dataRoot` writes its artifact —
    /// `analysis/<songStem>.json`, derived from the single song in `audio/`.
    /// `nil` when `audio/` holds zero or more than one song, so a read-back never
    /// guesses at a stale sibling.
    public static func expectedAnalysisArtifactURL(dataRoot: URL) -> URL? {
        let songs = songFiles(dataRoot: dataRoot)
        guard songs.count == 1, let song = songs.first else { return nil }
        return dataRoot.appendingPathComponent("analysis")
            .appendingPathComponent("\(song.deletingPathExtension().lastPathComponent).json")
    }
}
