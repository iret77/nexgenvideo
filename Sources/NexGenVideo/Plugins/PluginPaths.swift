import Foundation
import NexGenEngine

/// Resolves immutable versioned installs and legacy flat bundles.
enum PluginPaths {
    static let bundleExtension = "ngvpack"

    /// `~/Library/Application Support/NexGenVideo/Plugins`. Created on demand.
    static var installDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("NexGenVideo", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    /// The legacy install location used before project version pinning.
    static func installURL(id: String) -> URL {
        installDirectory.appendingPathComponent(id).appendingPathExtension(bundleExtension)
    }

    static func versionDirectory(id: String) -> URL {
        installDirectory.appendingPathComponent(id, isDirectory: true)
    }

    static func installURL(id: String, version: String) -> URL {
        versionDirectory(id: id)
            .appendingPathComponent(version)
            .appendingPathExtension(bundleExtension)
    }

    static func installedBundle(id: String, version: String) -> URL? {
        let versioned = installURL(id: id, version: version)
        if FileManager.default.fileExists(atPath: versioned.path) { return versioned }
        let legacy = installURL(id: id)
        guard let info = PluginBundleInfo(bundleURL: legacy),
              info.id == id, info.version == version else { return nil }
        return legacy
    }

    /// Every installed `.ngvpack`, including legacy flat bundles, sorted by path.
    static func installedBundles() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: installDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var bundles = entries.filter { $0.pathExtension == bundleExtension }
        for directory in entries where directory.pathExtension.isEmpty {
            let versions = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            bundles.append(contentsOf: versions.filter { $0.pathExtension == bundleExtension })
        }
        return bundles.sorted { $0.path < $1.path }
    }

    /// A pack id safe to use as a path component: lowercase alphanumerics, `-`,
    /// `_`; non-empty; no separators or dots. Guards the catalog against a
    /// malicious `id` traversing out of the install directory.
    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isValidVersion(_ version: String) -> Bool {
        SemanticVersion(version) != nil && !version.contains("/")
    }
}
