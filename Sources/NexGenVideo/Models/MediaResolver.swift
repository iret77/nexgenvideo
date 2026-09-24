import Foundation

/// Resolves asset IDs to file URLs using the media manifest.
final class MediaResolver: @unchecked Sendable {
    private let manifest: () -> MediaManifest
    private let projectURL: () -> URL?
    private let urlOverrides: [String: URL]

    init(
        manifest: @escaping () -> MediaManifest,
        projectURL: @escaping () -> URL?,
        urlOverrides: [String: URL] = [:]
    ) {
        self.manifest = manifest
        self.projectURL = projectURL
        self.urlOverrides = urlOverrides
    }

    var projectHome: URL? { projectURL() }

    func snapshot() -> MediaResolver {
        let entries = manifest()
        let home = projectURL()
        return MediaResolver(
            manifest: { entries },
            projectURL: { home },
            urlOverrides: urlOverrides
        )
    }

    func snapshot(overriding urls: [String: URL]) -> MediaResolver {
        let entries = manifest()
        let home = projectURL()
        return MediaResolver(
            manifest: { entries },
            projectURL: { home },
            urlOverrides: urls
        )
    }

    func resolveURL(for assetId: String) -> URL? {
        guard let url = expectedURL(for: assetId) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func expectedURL(for assetId: String) -> URL? {
        if let override = urlOverrides[assetId] { return override }
        return interchangeURL(for: assetId)
    }

    func interchangeURL(for assetId: String) -> URL? {
        guard let entry = entry(for: assetId) else { return nil }
        switch entry.source {
        case .external(let absolutePath):
            return URL(fileURLWithPath: absolutePath)
        case .project(let relativePath):
            guard let base = projectURL() else { return nil }
            let root = base.standardizedFileURL.resolvingSymlinksInPath()
            let candidate = base.appendingPathComponent(relativePath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard candidate.path.hasPrefix(root.path + "/") else { return nil }
            return candidate
        }
    }

    func isMissing(for assetId: String) -> Bool {
        guard let url = expectedURL(for: assetId) else { return true }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// Compute the set of asset IDs whose backing file is missing on disk, from a
    /// snapshot of manifest entries + the project base path
    static func missingAssetIds(entries: [MediaManifestEntry], projectPath: String?) -> Set<String> {
        var missing: Set<String> = []
        for entry in entries {
            let path: String?
            switch entry.source {
            case .external(let absolutePath):
                path = absolutePath
            case .project(let relativePath):
                path = projectPath.flatMap { projectPath in
                    let root = URL(fileURLWithPath: projectPath, isDirectory: true)
                        .standardizedFileURL
                        .resolvingSymlinksInPath()
                    let candidate = root.appendingPathComponent(relativePath)
                        .standardizedFileURL
                        .resolvingSymlinksInPath()
                    return candidate.path.hasPrefix(root.path + "/")
                        ? candidate.path
                        : nil
                }
            }
            guard let path, FileManager.default.fileExists(atPath: path) else {
                missing.insert(entry.id)
                continue
            }
        }
        return missing
    }

    func displayName(for assetId: String) -> String {
        entry(for: assetId)?.name ?? "Offline"
    }

    func interchangeFilename(for assetId: String) -> String {
        guard let entry = entry(for: assetId),
              let url = interchangeURL(for: assetId) else {
            return "Offline media"
        }
        return MediaFilename.display(
            originalFilename: entry.originalFilename,
            name: entry.name,
            storageURL: url
        )
    }

    func interchangeIdentity(for assetId: String) -> String? {
        guard let entry = entry(for: assetId) else { return nil }
        return interchangeIdentity(for: entry)
    }

    func interchangeMediaRefs(sharing identity: String) -> [String] {
        manifest().entries
            .filter { interchangeIdentity(for: $0) == identity }
            .map(\.id)
            .sorted()
    }

    func isProjectMedia(_ assetId: String) -> Bool {
        guard let entry = entry(for: assetId) else { return false }
        if case .project = entry.source { return true }
        return false
    }

    func expectedURLMap(for assetIds: Set<String>) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: assetIds.compactMap { id in
            expectedURL(for: id).map { (id, $0) }
        })
    }

    func entry(for assetId: String) -> MediaManifestEntry? {
        manifest().entries.first(where: { $0.id == assetId })
    }

    private func interchangeIdentity(for entry: MediaManifestEntry) -> String {
        switch entry.source {
        case .external(let path):
            let resolved = URL(fileURLWithPath: path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            return "external:\(resolved.path)"
        case .project(let relativePath):
            guard let home = projectURL()?.standardizedFileURL.resolvingSymlinksInPath() else {
                let normalized = URL(fileURLWithPath: "/", isDirectory: true)
                    .appendingPathComponent(relativePath)
                    .standardizedFileURL
                    .path
                return "project:\(normalized)"
            }
            let resolved = home.appendingPathComponent(relativePath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(home.path + "/") else { return "project:invalid:\(entry.id)" }
            return "project:/\(resolved.path.dropFirst(home.path.count + 1))"
        }
    }
}
