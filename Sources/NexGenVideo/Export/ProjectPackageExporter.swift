import Foundation

/// Writes a self-contained `.ngv` package: every resolvable media reference is copied
/// into the new bundle's `media/` directory and rewritten to a project-relative source
enum ProjectPackageExporter {

    struct Report: Equatable {
        /// Entry ids that were `.external` and are now bundled.
        var collected: [String] = []
        /// Already-internal media files copied across.
        var copiedInternal: Int = 0
        /// Entries whose source file couldn't be found, so they couldn't be included.
        var missing: [Missing] = []
        /// Total bytes copied into the new bundle.
        var totalBytes: Int64 = 0

        struct Missing: Equatable { var id: String; var name: String }
    }

    @discardableResult
    static func export(
        timeline: Timeline,
        manifest: MediaManifest,
        generationLog: GenerationLog,
        sourceProjectURL: URL?,
        to destURL: URL,
        stagingURL: URL? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Report {
        if isCancelled?() == true { throw CancellationError() }
        let fm = FileManager.default
        let parent = destURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = stagingURL ?? parent.appendingPathComponent(
            ".\(destURL.lastPathComponent).export-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: staging) }
        if let sourceProjectURL {
            try copyDirectory(
                from: sourceProjectURL,
                to: staging,
                isCancelled: isCancelled
            )
            if isCancelled?() == true { throw CancellationError() }
            try ProjectWorkingCopy.sanitizePackageStaging(staging, fm: fm)
        } else {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        let mediaDir = staging.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try? fm.removeItem(at: mediaDir)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        var report = Report()
        var newEntries: [MediaManifestEntry] = []
        var relativePathBySource: [String: String] = [:]   // dedup: absolute source path -> media/<file>
        let total = max(1, manifest.entries.count)

        for (index, entry) in manifest.entries.enumerated() {
            if isCancelled?() == true { throw CancellationError() }
            defer { progress?(Double(index + 1) / Double(total)) }

            guard let srcURL = sourceURL(for: entry.source, projectURL: sourceProjectURL),
                  fm.fileExists(atPath: srcURL.path) else {
                report.missing.append(.init(id: entry.id, name: entry.name))
                newEntries.append(entry)                    // keep the (dangling) reference as-is
                continue
            }

            let key = srcURL.standardizedFileURL.path
            let relativePath: String
            if let existing = relativePathBySource[key] {
                relativePath = existing
            } else {
                let dest = uniqueURL(in: mediaDir, preferredName: filename(for: entry, sourceURL: srcURL), fm: fm)
                try copyFile(from: srcURL, to: dest, isCancelled: isCancelled)
                relativePath = "\(Project.mediaDirectoryName)/\(dest.lastPathComponent)"
                relativePathBySource[key] = relativePath
                report.totalBytes += fileSize(dest, fm: fm)
                if case .project = entry.source { report.copiedInternal += 1 }
            }

            if case .external = entry.source { report.collected.append(entry.id) }
            var rewritten = entry
            rewritten.source = .project(relativePath: relativePath)
            newEntries.append(rewritten)
        }

        var newManifest = manifest
        newManifest.entries = newEntries

        let encoder = JSONEncoder()
        try encoder.encode(timeline).write(to: staging.appendingPathComponent(Project.timelineFilename))
        try encoder.encode(newManifest).write(to: staging.appendingPathComponent(Project.manifestFilename))
        try encoder.encode(generationLog).write(to: staging.appendingPathComponent(Project.generationLogFilename))

        if isCancelled?() == true { throw CancellationError() }
        let sourceKey = ProjectIdentity.existingKey(for: staging)
        try ProjectIdentity.regenerate(at: staging)
        guard let exportedKey = ProjectIdentity.existingKey(for: staging),
              exportedKey != sourceKey else {
            throw ProjectWorkingCopy.PersistError.identityNotRegenerated
        }

        if isCancelled?() == true { throw CancellationError() }
        try ProjectWorkingCopy.commitStagedPackage(staging, to: destURL, fm: fm)
        return report
    }

    // MARK: - Helpers

    private static func copyFile(
        from source: URL,
        to destination: URL,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw ToolError("The project export couldn't create a media copy.")
        }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        while true {
            if isCancelled?() == true { throw CancellationError() }
            guard let data = try reader.read(upToCount: 1_048_576), !data.isEmpty else {
                break
            }
            try writer.write(contentsOf: data)
        }
    }

    private static func copyDirectory(
        from source: URL,
        to destination: URL,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw ToolError("The project source couldn't be enumerated for export.")
        }
        for case let item as URL in enumerator {
            if isCancelled?() == true { throw CancellationError() }
            let relative = String(item.path.dropFirst(source.path.count + 1))
            let target = destination.appendingPathComponent(relative)
            let values = try item.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw ToolError("The project source contains a symbolic link.")
            }
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try copyFile(from: item, to: target, isCancelled: isCancelled)
            } else {
                throw ToolError("The project source contains an unsupported file.")
            }
        }
    }

    private static func sourceURL(for source: MediaSource, projectURL: URL?) -> URL? {
        switch source {
        case .external(let path):
            return URL(fileURLWithPath: path)
        case .project(let rel):
            guard let projectURL else { return nil }
            let root = projectURL.standardizedFileURL.resolvingSymlinksInPath()
            let candidate = projectURL.appendingPathComponent(rel)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.path == root.path
                    || candidate.path.hasPrefix(root.path + "/") else {
                return nil
            }
            return candidate
        }
    }

    private static func filename(for entry: MediaManifestEntry, sourceURL: URL) -> String {
        switch entry.source {
        case .project:
            return sourceURL.lastPathComponent                 // preserve existing internal name
        case .external:
            let ext = sourceURL.pathExtension
            let base = "import-\(entry.id.prefix(8))"
            return ext.isEmpty ? base : "\(base).\(ext)"
        }
    }

    /// Appends `-1`, `-2`, … to avoid clobbering an already-written file of the same name.
    private static func uniqueURL(in dir: URL, preferredName: String, fm: FileManager) -> URL {
        let candidate = dir.appendingPathComponent(preferredName)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ns = preferredName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            let url = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    private static func fileSize(_ url: URL, fm: FileManager) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
