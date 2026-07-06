import Foundation

/// Accessor over the musicvideo pack's bundled knowledge — the 23 pattern
/// YAMLs (`Resources/MusicvideoPack/library/`) and the 12 neutralized phase
/// docs (`Resources/MusicvideoPack/phases/`). Both ship as `Bundle.module`
/// resources (see the `NexGenEngine` target's `resources:` rule in
/// `Package.swift`).
public enum PackKnowledge {
    private final class BundleFinder {}

    /// SwiftPM's generated `Bundle.module` accessor fatalErrors when the
    /// resource bundle isn't where it expects (some test-runner layouts) —
    /// a hard SIGTRAP that kills the whole test process. This resolver
    /// searches the known locations and returns nil instead of trapping.
    static let resourceBundle: Bundle? = {
        let name = "NexGenVideo_NexGenEngine"
        var candidates = [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
        ]
        // xctest layouts place library resource bundles next to the test bundle.
        candidates.append(Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent())
        for candidate in candidates {
            guard let url = candidate?.appendingPathComponent("\(name).bundle"),
                  let bundle = Bundle(url: url) else { continue }
            return bundle
        }
        return nil
    }()
    /// URLs of every pattern-library YAML bundled with the pack. Port of
    /// `patterns_schema.py::patterns_dir` + the `*.yaml` glob in
    /// `load_all_patterns` — Swift has no on-disk package directory to list,
    /// so this enumerates `Bundle.module`'s resource URLs instead.
    public static func patternLibraryURLs() -> [URL] {
        guard let dir = Self.resourceBundle?.resourceURL?.appendingPathComponent("MusicvideoPack/library") else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "yaml" }
    }

    public enum PhaseDocError: Swift.Error, Sendable {
        case notFound(String)
    }

    /// Loads a neutralized phase doc's markdown text by base name (e.g.
    /// `"analysis"` -> `phases/analysis.md`).
    public static func phaseDoc(name: String) throws -> String {
        guard let url = Self.resourceBundle?.url(forResource: name, withExtension: "md", subdirectory: "MusicvideoPack/phases")
        else {
            throw PhaseDocError.notFound(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Base names of every bundled phase doc, sorted.
    public static func phaseDocNames() -> [String] {
        guard let dir = Self.resourceBundle?.resourceURL?.appendingPathComponent("MusicvideoPack/phases") else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
}
