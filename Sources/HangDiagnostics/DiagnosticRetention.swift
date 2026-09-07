import Foundation

public enum DiagnosticRetention {
    public static func requiresExplicitDeletion(_ folder: URL) throws -> Bool {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return names.contains { name in
            name == "pinned.json" || name == "sample-request.json" || name == "exported.json"
                || name.hasPrefix("incident-") || name.hasSuffix(".stacks")
                || name.hasPrefix("replay-")
        }
    }

    public static func removableRecordings(_ folders: [URL], now: Date = Date()) throws -> [URL] {
        let disposable = try folders.filter { try !requiresExplicitDeletion($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let dated = try disposable.map { folder in
            (folder, try folder.resourceValues(forKeys: [.creationDateKey]).creationDate ?? now)
        }.sorted { $0.1 < $1.1 }
        return dated.enumerated().compactMap { index, entry in
            now.timeIntervalSince(entry.1) > 7 * 86400 || index < dated.count - 2 ? entry.0 : nil
        }
    }

    public static func checkStorageBudget(at root: URL) throws {
        var enumerationFailed = false
        guard let files = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw CocoaError(.fileReadUnknown) }
        var bytes = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { files.skipDescendants(); continue }
            if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
            guard bytes < 1024 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        }
        guard !enumerationFailed else { throw CocoaError(.fileReadUnknown) }
    }
}
