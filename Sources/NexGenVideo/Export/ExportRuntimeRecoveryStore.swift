import Foundation

enum ExportRuntimeRecoveryStore {
    enum Kind: String, Codable, Sendable, Equatable {
        case xml
        case fcpxml
        case project
    }

    struct Lease: Sendable {
        let jobID: String
        let documentTemporaryURL: URL
        let companionTemporaryURL: URL?
        let packageStagingURL: URL?
    }

    private struct Record: Codable {
        struct Item: Codable {
            enum Role: String, Codable, Equatable {
                case document
                case companion
                case package
                case snapshot
            }

            let role: Role
            let targetPath: String?
            let paths: [String]
            let expectsDirectory: Bool
            var identity: ExportFileIdentity?
        }

        let schema: String
        let jobID: String
        let kind: Kind
        var items: [Item]
    }

    private static let schema = "nexgenvideo/export-runtime-recovery/v1"
    private static let lock = NSLock()

    static var defaultRoot: URL {
        AppPaths.recovery.appendingPathComponent("ExportRuntime", isDirectory: true)
    }

    static func begin(
        jobID: String,
        kind: Kind,
        snapshotURL: URL,
        destination: ExportQueue.DestinationBinding,
        companion: ExportQueue.DestinationBinding?,
        root: URL = defaultRoot
    ) throws -> Lease {
        guard UUID(uuidString: jobID) != nil,
              destination.jobID == jobID,
              companion.map({ $0.jobID == jobID }) ?? true else {
            throw ToolError("The export runtime identity is invalid.")
        }
        let packageStagingURL = kind == .project
            ? ExportQueue.DestinationBinding.makePackageStagingURL(
                url: destination.url,
                jobID: jobID
            )
            : nil
        var items = [Record.Item(
            role: kind == .project ? .package : .document,
            targetPath: destination.url.path,
            paths: kind == .project
                ? [packageStagingURL!.path, destination.temporaryURL.path]
                : [destination.temporaryURL.path],
            expectsDirectory: kind == .project,
            identity: nil
        )]
        if let companion {
            items.append(.init(
                role: .companion,
                targetPath: companion.url.path,
                paths: [companion.temporaryURL.path],
                expectsDirectory: true,
                identity: nil
            ))
        }
        items.append(.init(
            role: .snapshot,
            targetPath: nil,
            paths: [snapshotURL.standardizedFileURL.path],
            expectsDirectory: true,
            identity: try ExportFileIdentity.capture(snapshotURL)
        ))
        var record = Record(schema: schema, jobID: jobID, kind: kind, items: items)

        lock.lock()
        defer { lock.unlock() }
        try ensureRoot(root)
        let recordURL = root.appendingPathComponent("\(jobID).json")
        guard !FileManager.default.fileExists(atPath: recordURL.path) else {
            throw ToolError("An export runtime record already exists for this job.")
        }
        try validate(record, recordURL: recordURL, root: root)
        try write(record, to: recordURL)
        do {
            for index in record.items.indices where record.items[index].role != .snapshot {
                let item = record.items[index]
                let path = URL(fileURLWithPath: item.paths[0])
                guard try ExportQueue.PathState.capture(path) == .absent else {
                    throw ToolError("A partial export already exists for this job and destination.")
                }
                if item.expectsDirectory {
                    try FileManager.default.createDirectory(
                        at: path,
                        withIntermediateDirectories: false
                    )
                } else if !FileManager.default.createFile(atPath: path.path, contents: Data()) {
                    throw ToolError("The export runtime placeholder could not be created.")
                }
                record.items[index].identity = try ExportFileIdentity.capture(path)
                try write(record, to: recordURL)
            }
        } catch {
            do {
                try cleanup(record, recordURL: recordURL, removeSnapshot: false)
            } catch {
                throw ToolError(
                    "Export runtime preparation failed and cleanup is pending at \(recordURL.path): "
                        + error.localizedDescription
                )
            }
            throw error
        }
        return Lease(
            jobID: jobID,
            documentTemporaryURL: destination.temporaryURL,
            companionTemporaryURL: companion?.temporaryURL,
            packageStagingURL: packageStagingURL
        )
    }

    static func finish(
        jobID: String,
        removeSnapshot: Bool,
        root: URL = defaultRoot
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let recordURL = root.appendingPathComponent("\(jobID).json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return }
        var record = try load(recordURL, root: root)
        if removeSnapshot {
            try cleanup(record, recordURL: recordURL, removeSnapshot: true)
            return
        }
        let scratch = record.items.filter { $0.role != .snapshot }
        for item in scratch { try removeOwned(item) }
        record.items.removeAll { $0.role != .snapshot }
        try write(record, to: recordURL)
    }

    static func discardCompanion(jobID: String, root: URL = defaultRoot) throws {
        lock.lock()
        defer { lock.unlock() }
        let recordURL = root.appendingPathComponent("\(jobID).json")
        var record = try load(recordURL, root: root)
        guard let companion = record.items.first(where: { $0.role == .companion }) else {
            return
        }
        try removeOwned(companion)
        record.items.removeAll { $0.role == .companion }
        try write(record, to: recordURL)
    }

    static func recoverAll(
        excludingJobIDs: Set<String> = [],
        root: URL = defaultRoot
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        try ensureRoot(root)
        let records = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { $0.pathExtension == "json" }
        for recordURL in records.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let record = try load(recordURL, root: root)
                guard !excludingJobIDs.contains(record.jobID) else { continue }
                try cleanup(record, recordURL: recordURL, removeSnapshot: true)
            } catch {
                Log.export.warning(
                    "export runtime recovery remains pending at \(recordURL.path): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func cleanup(
        _ record: Record,
        recordURL: URL,
        removeSnapshot: Bool
    ) throws {
        for item in record.items where removeSnapshot || item.role != .snapshot {
            try removeOwned(item)
        }
        try FileManager.default.removeItem(at: recordURL)
    }

    private static func removeOwned(_ item: Record.Item) throws {
        guard let identity = item.identity else { return }
        let fm = FileManager.default
        for path in item.paths {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.deletingLastPathComponent().path) else {
                throw ToolError("The export runtime volume is unavailable.")
            }
            guard try ExportFileIdentity.capture(url) == identity else { continue }
            try fm.removeItem(at: url)
        }
    }

    private static func load(_ recordURL: URL, root: URL) throws -> Record {
        let values = try recordURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ToolError("An export runtime record is not a regular file.")
        }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
        try validate(record, recordURL: recordURL, root: root)
        return record
    }

    private static func validate(_ record: Record, recordURL: URL, root: URL) throws {
        guard record.schema == schema,
              UUID(uuidString: record.jobID) != nil,
              recordURL.deletingPathExtension().lastPathComponent == record.jobID,
              recordURL.deletingLastPathComponent().resolvingSymlinksInPath()
                == root.standardizedFileURL.resolvingSymlinksInPath(),
              !record.items.isEmpty,
              record.items.filter({ $0.role == .snapshot }).count == 1 else {
            throw ToolError("An export runtime record has an invalid identity.")
        }
        let snapshotOnly = record.items.count == 1
        let documentCount = record.items.filter { $0.role == .document }.count
        let companionCount = record.items.filter { $0.role == .companion }.count
        let packageCount = record.items.filter { $0.role == .package }.count
        let rolesValid = switch record.kind {
        case .xml: documentCount == 1 && companionCount == 0 && packageCount == 0
        case .fcpxml: documentCount == 1 && companionCount <= 1 && packageCount == 0
        case .project: documentCount == 0 && companionCount == 0 && packageCount == 1
        }
        guard snapshotOnly || rolesValid else {
            throw ToolError("An export runtime record has invalid roles.")
        }
        for item in record.items {
            guard !item.paths.isEmpty,
                  item.paths.allSatisfy({ $0.hasPrefix("/") }) else {
                throw ToolError("An export runtime record contains an invalid path.")
            }
            switch item.role {
            case .snapshot:
                guard let snapshotPath = item.paths.first,
                      let snapshotID = UUID(
                        uuidString: URL(fileURLWithPath: snapshotPath).lastPathComponent
                      )?.uuidString.lowercased(),
                      snapshotPath == ExportQueue.SourceBinding.snapshotRoot(
                        jobID: snapshotID
                      ).standardizedFileURL.path,
                      item.paths.count == 1,
                      item.targetPath == nil,
                      item.expectsDirectory else {
                    throw ToolError("An export runtime snapshot path is not job-bound.")
                }
            case .document, .companion:
                guard let targetPath = item.targetPath else {
                    throw ToolError("An export runtime destination is missing.")
                }
                let expected = ExportQueue.DestinationBinding.makeTemporaryURL(
                    url: URL(fileURLWithPath: targetPath),
                    jobID: record.jobID
                ).standardizedFileURL.path
                let target = URL(fileURLWithPath: targetPath).standardizedFileURL
                guard target.deletingLastPathComponent().resolvingSymlinksInPath()
                        == target.deletingLastPathComponent(),
                      item.paths == [expected],
                      item.expectsDirectory == (item.role == .companion) else {
                    throw ToolError("An export runtime partial is not job-bound.")
                }
            case .package:
                guard let targetPath = item.targetPath else {
                    throw ToolError("An export runtime package destination is missing.")
                }
                let target = URL(fileURLWithPath: targetPath)
                let temporary = ExportQueue.DestinationBinding.makeTemporaryURL(
                    url: target,
                    jobID: record.jobID
                ).standardizedFileURL.path
                let staging = ExportQueue.DestinationBinding.makePackageStagingURL(
                    url: target,
                    jobID: record.jobID
                ).standardizedFileURL.path
                guard target.deletingLastPathComponent().resolvingSymlinksInPath()
                        == target.deletingLastPathComponent(),
                      item.paths == [staging, temporary], item.expectsDirectory else {
                    throw ToolError("An export runtime package paths are not job-bound.")
                }
            }
        }
    }

    private static func ensureRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ToolError("The export runtime recovery store is unavailable.")
        }
    }

    private static func write(_ record: Record, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }
}
