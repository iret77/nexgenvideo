import Foundation
import NexGenEngine

/// Native validator for the same input conditions the analysis phase checks before execution.
public enum Preflight {
    static var audioExtensions: Set<String> { AudioProjectLayout.audioExtensions }
    static let imageExtensions = ProjectMediaExtensions.images

    public struct Result: Sendable, Equatable {
        public var project: String
        public var audioFiles: [String] = []
        public var lyricsPath: String?
        public var referenceImages: [String] = []
        public var blockers: [String] = []
        public var warnings: [String] = []

        public init(
            project: String, audioFiles: [String] = [], lyricsPath: String? = nil, referenceImages: [String] = [],
            blockers: [String] = [], warnings: [String] = []
        ) {
            self.project = project
            self.audioFiles = audioFiles
            self.lyricsPath = lyricsPath
            self.referenceImages = referenceImages
            self.blockers = blockers
            self.warnings = warnings
        }

        public var hasAudio: Bool { !audioFiles.isEmpty }
        public var hasLyrics: Bool { lyricsPath != nil }
        public var hasReferences: Bool { !referenceImages.isEmpty }

        /// Analysis may only start when there are no blockers.
        public var canStart: Bool { blockers.isEmpty }

        /// True when there are warnings the orchestrator should present to
        /// the user (ask before the expensive run).
        public var needsUserConfirmation: Bool { !warnings.isEmpty }
    }

    /// Human-readable project name for messages — the `project` field from
    /// `project.yaml`, falling back to the project home's folder name. Local,
    /// pack-owned port of `core/paths.py::display_name` (not shared with the
    /// engine core, to keep this work package's file touches scoped to the
    /// pack).
    static func displayName(projectDir: URL) -> String {
        let marker = projectDir.appendingPathComponent(DataRootResolver.projectMarker)
        if let text = try? String(contentsOf: marker, encoding: .utf8),
            let meta = try? YAMLCoding.decode(ProjectMeta.self, from: text), !meta.project.isEmpty
        {
            return meta.project
        }
        return projectDir.lastPathComponent
    }

    /// Checks a project's input artifacts before analysis. Port of
    /// `preflight.py::preflight`. `projectDir` is the project home (parent of
    /// `pipeline/`), matching Python's `project_dir` — audio/lyrics/import live
    /// as siblings of the data root, not inside it.
    public static func run(projectDir: URL) -> Result {
        var result = Result(project: displayName(projectDir: projectDir))
        let fm = FileManager.default

        // 1. Audio (hard blocker).
        result.audioFiles = AudioProjectLayout.songFiles(dataRoot: projectDir)
            .map(\.lastPathComponent)
        if result.audioFiles.isEmpty {
            result.blockers.append(
                "No audio file in audio/ (.wav/.mp3/.flac/.m4a/.aiff). "
                    + "Complete the Track intake before analysis."
            )
        }

        // 2. Lyrics (warning).
        let lyricsFile = projectDir.appendingPathComponent("lyrics").appendingPathComponent("lyrics.txt")
        let attrs = try? fm.attributesOfItem(atPath: lyricsFile.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if fm.fileExists(atPath: lyricsFile.path), size > 0 {
            result.lyricsPath = relativePath(of: lyricsFile, to: projectDir)
        } else {
            result.warnings.append(
                "No lyrics (lyrics/lyrics.txt missing or empty). Without lyrics no known-text alignment "
                    + "is possible. Measured structure remains timing truth, but section labels may "
                    + "be less certain. If the song has text, providing lyrics is worthwhile."
            )
        }

        // 3. Reference images (warning) — anywhere under import/.
        let importDir = projectDir.appendingPathComponent("import")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: importDir.path, isDirectory: &isDir), isDir.boolValue {
            if let enumerator = fm.enumerator(at: importDir, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let url as URL in enumerator {
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    if imageExtensions.contains(url.pathExtension.lowercased()) {
                        result.referenceImages.append(relativePath(of: url, to: projectDir))
                    }
                }
            }
        }
        result.referenceImages.sort()
        if result.referenceImages.isEmpty {
            result.warnings.append(
                "No reference images found in import/. Production design and bible then have to work "
                    + "without visual source material."
            )
        }

        return result
    }

    private static func relativePath(of url: URL, to base: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > baseComponents.count, Array(urlComponents.prefix(baseComponents.count)) == baseComponents else {
            return url.path
        }
        return urlComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }
}
