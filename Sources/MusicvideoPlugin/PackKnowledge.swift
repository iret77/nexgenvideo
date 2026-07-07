import Foundation
import NexGenEngine

/// Accessor over the musicvideo pack's bundled knowledge — the pattern YAMLs
/// (`MusicvideoPack/library/`), the neutralized phase docs (`MusicvideoPack/phases/`),
/// and the badge (`MusicvideoPack/badge.png`).
///
/// The pack ships these as `MusicvideoPlugin` target resources. At runtime the
/// directory that contains `MusicvideoPack/` is discovered robustly across every
/// layout we ship in: SwiftPM's generated `NexGenVideo_MusicvideoPlugin.bundle`
/// (dev/test/CI — whether next to the dylib, the test binary, or the app), and the
/// installed `.ngvpack` this dylib was loaded out of (the same generated bundle is
/// copied into `Contents/Resources`, or the resources are flattened there). File
/// paths are built directly and existence-checked — nothing relies on a specific
/// `Bundle.resourceURL` shape, and nothing reads from an absolute disk path.
public enum PackKnowledge {
    private final class BundleFinder {}

    private static let nestedBundleName = "NexGenVideo_MusicvideoPlugin.bundle"

    /// The directory that directly contains `MusicvideoPack/`, or nil if the pack's
    /// resources can't be located (callers then degrade gracefully — empty lists /
    /// thrown notFound, never a crash).
    static let packRoot: URL? = {
        let fm = FileManager.default
        func hasPack(_ dir: URL) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent("MusicvideoPack").path)
        }

        let selfBundle = Bundle(for: BundleFinder.self)
        // Directories that might directly hold MusicvideoPack/ (flattened) or the
        // nested SwiftPM resource bundle.
        var containers: [URL] = [
            selfBundle.resourceURL,
            selfBundle.bundleURL,
            selfBundle.bundleURL.deletingLastPathComponent(),
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
        ].compactMap { $0 }
        containers += Bundle.allBundles.compactMap { $0.resourceURL }
        containers += Bundle.allBundles.map { $0.bundleURL }
        containers += Bundle.allFrameworks.compactMap { $0.resourceURL }

        for container in containers {
            // Flattened: <container>/MusicvideoPack/…
            if hasPack(container) { return container }
            // Nested generated bundle: <container>/NexGenVideo_MusicvideoPlugin.bundle/…
            let nested = container.appendingPathComponent(nestedBundleName)
            guard fm.fileExists(atPath: nested.path) else { continue }
            if hasPack(nested) { return nested }
            let nestedResources = nested.appendingPathComponent("Contents/Resources")
            if hasPack(nestedResources) { return nestedResources }
            if let bundle = Bundle(url: nested), let res = bundle.resourceURL, hasPack(res) { return res }
        }
        return nil
    }()

    private static func packDir(_ subpath: String) -> URL? {
        packRoot?.appendingPathComponent("MusicvideoPack").appendingPathComponent(subpath)
    }

    /// URLs of every pattern-library YAML bundled with the pack.
    public static func patternLibraryURLs() -> [URL] {
        guard let dir = packDir("library") else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "yaml" }
    }

    public enum PhaseDocError: Swift.Error, Sendable {
        case notFound(String)
    }

    /// Loads a neutralized phase doc's markdown text by base name (e.g.
    /// `"analysis"` -> `phases/analysis.md`).
    public static func phaseDoc(name: String) throws -> String {
        guard let url = packDir("phases/\(name).md"),
              FileManager.default.fileExists(atPath: url.path) else {
            throw PhaseDocError.notFound(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The pack's badge art (`MusicvideoPack/badge.png`) — the self-contained gallery visual.
    public static func badgeURL() -> URL? {
        guard let url = packDir("badge.png"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Base names of every bundled phase doc, sorted.
    public static func phaseDocNames() -> [String] {
        guard let dir = packDir("phases") else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
}
