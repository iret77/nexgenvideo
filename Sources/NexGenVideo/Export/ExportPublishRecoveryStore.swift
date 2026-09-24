import Darwin
import Foundation

struct ExportFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func capture(_ url: URL) throws -> ExportFileIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (value.st_mode & S_IFMT) != S_IFLNK else {
            throw ToolError("Export paths cannot be symbolic links.")
        }
        return .init(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }
}

enum ExportPublishRecoveryStore {
    private struct SimulatedCrash: Error {}
    private struct SimulatedCommittedCleanupFailure: Error {}

    struct Publication: Sendable {
        let targetURL: URL
        let temporaryURL: URL
        let initialState: ExportQueue.PathState
        let initialIdentity: ExportFileIdentity?
        let publishedState: ExportQueue.PathState
        let publishedIdentity: ExportFileIdentity?
        let jobID: String
        let expectsDirectory: Bool
    }

    struct Result: Sendable {
        let publications: [Publication]

        func state(for url: URL) -> ExportQueue.PathState {
            publications.first {
                $0.targetURL.standardizedFileURL == url.standardizedFileURL
            }?.publishedState ?? .absent
        }

        func verifyPublished(
            isCancelled: @Sendable () -> Bool = { false }
        ) throws {
            for publication in publications {
                if isCancelled() { throw CancellationError() }
                guard try ExportPublishRecoveryStore.matches(
                    publication.targetURL,
                    state: publication.publishedState,
                    identity: publication.publishedIdentity,
                    isCancelled: isCancelled
                ) else {
                    throw ToolError("A published export changed before its evidence was recorded.")
                }
            }
        }
    }

    private struct Journal: Codable {
        enum Phase: String, Codable {
            case prepared
            case committed
        }

        struct Target: Codable {
            let targetPath: String
            let temporaryPath: String
            let backupPath: String
            let initialState: ExportQueue.PathState
            let initialIdentity: ExportFileIdentity?
            let publishedState: ExportQueue.PathState
            let publishedIdentity: ExportFileIdentity?
            let expectsDirectory: Bool
        }

        let schema: String
        let transactionID: String
        let jobID: String
        var phase: Phase
        let targets: [Target]
    }

    private static let schema = "nexgenvideo/export-publish-recovery/v1"
    private static let lock = NSLock()

    static var defaultRoot: URL {
        AppPaths.recovery.appendingPathComponent("ExportPublish", isDirectory: true)
    }

    static func recoverAll(
        root: URL = defaultRoot,
        failCommittedCleanupAfterBackupRemovalForTesting: Int? = nil,
        failCommittedJournalRemovalForTesting: Bool = false
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try recoverAllLocked(
            root: root,
            failCommittedCleanupAfterBackupRemovalForTesting:
                failCommittedCleanupAfterBackupRemovalForTesting,
            failCommittedJournalRemovalForTesting:
                failCommittedJournalRemovalForTesting
        )
    }

    static func publish(
        _ publications: [Publication],
        root: URL = defaultRoot,
        isCancelled: @Sendable () -> Bool = { false },
        crashAfterMutationForTesting: Int? = nil,
        failCommittedCleanupAfterBackupRemovalForTesting: Int? = nil,
        failCommittedJournalRemovalForTesting: Bool = false
    ) throws -> Result {
        guard let jobID = publications.first?.jobID,
              UUID(uuidString: jobID) != nil,
              publications.allSatisfy({ $0.jobID == jobID }),
              !publications.isEmpty else {
            throw ToolError("The export publication identity is invalid.")
        }
        let transactionID = UUID().uuidString.lowercased()
        let targets = try publications.map { publication in
            let target = publication.targetURL.standardizedFileURL
            let temporary = publication.temporaryURL.standardizedFileURL
            guard target.path.hasPrefix("/"),
                  temporary == ExportQueue.DestinationBinding.makeTemporaryURL(
                      url: target,
                      jobID: jobID
                  ).standardizedFileURL,
                  publication.initialState.exists == (publication.initialIdentity != nil),
                  publication.initialState.isDirectory == publication.expectsDirectory
                    || !publication.initialState.exists,
                  publication.publishedState.exists,
                  publication.publishedIdentity != nil,
                  publication.publishedState.isDirectory == publication.expectsDirectory else {
                throw ToolError("The export publication paths are not bound to this job.")
            }
            return Journal.Target(
                targetPath: target.path,
                temporaryPath: temporary.path,
                backupPath: backupURL(
                    target: target,
                    jobID: jobID,
                    transactionID: transactionID
                ).path,
                initialState: publication.initialState,
                initialIdentity: publication.initialIdentity,
                publishedState: publication.publishedState,
                publishedIdentity: publication.publishedIdentity,
                expectsDirectory: publication.expectsDirectory
            )
        }
        guard Set(targets.map(\.targetPath)).count == targets.count else {
            throw ToolError("An export cannot publish two results to the same destination.")
        }
        let boundPaths = targets.flatMap { [$0.targetPath, $0.temporaryPath, $0.backupPath] }
        guard Set(boundPaths).count == boundPaths.count else {
            throw ToolError("The export publication paths overlap.")
        }
        var journal = Journal(
            schema: schema,
            transactionID: transactionID,
            jobID: jobID,
            phase: .prepared,
            targets: targets
        )

        lock.lock()
        defer { lock.unlock() }
        try recoverAllLocked(root: root)
        if isCancelled() { throw CancellationError() }
        try ensureRoot(root)
        let journalURL = root.appendingPathComponent("\(transactionID).json")
        try write(journal, to: journalURL)
        do {
            let fm = FileManager.default
            var mutationCount = 0
            for target in journal.targets {
                guard try matches(
                    URL(fileURLWithPath: target.targetPath),
                    state: target.initialState,
                    identity: target.initialIdentity,
                    isCancelled: isCancelled
                ), try matches(
                    URL(fileURLWithPath: target.temporaryPath),
                    state: target.publishedState,
                    identity: target.publishedIdentity,
                    isCancelled: isCancelled
                ), try ExportQueue.PathState.capture(
                    URL(fileURLWithPath: target.backupPath),
                    isCancelled: isCancelled
                ) == .absent else {
                    throw ToolError("The export destination changed while publication was starting.")
                }
            }
            for target in journal.targets {
                if isCancelled() { throw CancellationError() }
                let targetURL = URL(fileURLWithPath: target.targetPath)
                let temporaryURL = URL(fileURLWithPath: target.temporaryPath)
                let backupURL = URL(fileURLWithPath: target.backupPath)
                guard try matches(
                    targetURL,
                    state: target.initialState,
                    identity: target.initialIdentity,
                    isCancelled: isCancelled
                ), try matches(
                    temporaryURL,
                    state: target.publishedState,
                    identity: target.publishedIdentity,
                    isCancelled: isCancelled
                ), try ExportQueue.PathState.capture(
                    backupURL,
                    isCancelled: isCancelled
                ) == .absent else {
                    throw ToolError("The export destination changed while publication was starting.")
                }
                if target.initialState.exists {
                    try fm.moveItem(at: targetURL, to: backupURL)
                    mutationCount += 1
                    if mutationCount == crashAfterMutationForTesting { throw SimulatedCrash() }
                }
                if isCancelled() { throw CancellationError() }
                try fm.moveItem(at: temporaryURL, to: targetURL)
                mutationCount += 1
                if mutationCount == crashAfterMutationForTesting { throw SimulatedCrash() }
            }
        } catch {
            let publicationError = error
            if error is SimulatedCrash { throw error }
            do {
                try recoverPrepared(journal, journalURL: journalURL)
            } catch {
                throw ToolError(
                    "Export publication failed and recovery is incomplete: "
                        + error.localizedDescription
                )
            }
            throw publicationError
        }

        journal.phase = .committed
        try write(journal, to: journalURL)
        try recoverCommitted(
            journal,
            journalURL: journalURL,
            failAfterBackupRemovalForTesting:
                failCommittedCleanupAfterBackupRemovalForTesting,
            failJournalRemovalForTesting: failCommittedJournalRemovalForTesting
        )
        return Result(publications: publications)
    }

    private static func recoverAllLocked(
        root: URL,
        failCommittedCleanupAfterBackupRemovalForTesting: Int? = nil,
        failCommittedJournalRemovalForTesting: Bool = false
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        try ensureRoot(root)
        let files = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ToolError("An export recovery record is not a regular file.")
            }
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
            try validate(journal, journalURL: url, root: root)
            switch journal.phase {
            case .prepared:
                try recoverPrepared(journal, journalURL: url)
            case .committed:
                try recoverCommitted(
                    journal,
                    journalURL: url,
                    failAfterBackupRemovalForTesting:
                        failCommittedCleanupAfterBackupRemovalForTesting,
                    failJournalRemovalForTesting: failCommittedJournalRemovalForTesting
                )
            }
        }
    }

    private static func recoverPrepared(_ journal: Journal, journalURL: URL) throws {
        let fm = FileManager.default
        var failures: [String] = []
        for target in journal.targets.reversed() {
            do {
                let targetURL = URL(fileURLWithPath: target.targetPath)
                let temporaryURL = URL(fileURLWithPath: target.temporaryPath)
                let backupURL = URL(fileURLWithPath: target.backupPath)
                var targetState = try ExportQueue.PathState.capture(targetURL)
                let backupState = try ExportQueue.PathState.capture(backupURL)
                let targetIsInitial = try matches(
                    targetURL,
                    state: target.initialState,
                    identity: target.initialIdentity
                )
                let targetIsPublished = try matches(
                    targetURL,
                    state: target.publishedState,
                    identity: target.publishedIdentity
                )
                let backupIsInitial = try matches(
                    backupURL,
                    state: target.initialState,
                    identity: target.initialIdentity
                )

                if target.initialState.exists {
                    if backupState.exists, !backupIsInitial {
                        try preserveConflict(backupURL, transactionID: journal.transactionID)
                    }
                    if !targetIsInitial {
                        if targetState.exists {
                            if targetIsPublished {
                                try fm.removeItem(at: targetURL)
                            } else {
                                try preserveConflict(targetURL, transactionID: journal.transactionID)
                            }
                            targetState = .absent
                        }
                        if backupIsInitial {
                            try fm.moveItem(at: backupURL, to: targetURL)
                            targetState = target.initialState
                        }
                    } else if backupIsInitial {
                        try fm.removeItem(at: backupURL)
                    }
                    guard try matches(
                        targetURL,
                        state: target.initialState,
                        identity: target.initialIdentity
                    ) else {
                        throw ToolError("The previous export could not be restored at \(targetURL.path).")
                    }
                } else {
                    if targetIsPublished {
                        try fm.removeItem(at: targetURL)
                    } else if targetState.exists {
                        try preserveConflict(targetURL, transactionID: journal.transactionID)
                    }
                    if backupState.exists {
                        try preserveConflict(backupURL, transactionID: journal.transactionID)
                    }
                }

                let temporaryState = try ExportQueue.PathState.capture(temporaryURL)
                if try matches(
                    temporaryURL,
                    state: target.publishedState,
                    identity: target.publishedIdentity
                ) {
                    try fm.removeItem(at: temporaryURL)
                } else if temporaryState.exists {
                    try preserveConflict(temporaryURL, transactionID: journal.transactionID)
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        guard failures.isEmpty else {
            throw ToolError(failures.joined(separator: " "))
        }
        try fm.removeItem(at: journalURL)
    }

    private static func recoverCommitted(
        _ journal: Journal,
        journalURL: URL,
        failAfterBackupRemovalForTesting: Int? = nil,
        failJournalRemovalForTesting: Bool = false
    ) throws {
        let fm = FileManager.default
        for target in journal.targets {
            let targetURL = URL(fileURLWithPath: target.targetPath)
            guard try matches(
                targetURL,
                state: target.publishedState,
                identity: target.publishedIdentity
            ) else {
                throw ToolError("A committed export changed before publish recovery completed.")
            }
        }
        var removedBackupCount = 0
        for target in journal.targets {
            let backupURL = URL(fileURLWithPath: target.backupPath)
            let backupState = try ExportQueue.PathState.capture(backupURL)
            if try matches(
                backupURL,
                state: target.initialState,
                identity: target.initialIdentity
            ), backupState.exists {
                try fm.removeItem(at: backupURL)
                removedBackupCount += 1
                if removedBackupCount == failAfterBackupRemovalForTesting {
                    throw SimulatedCommittedCleanupFailure()
                }
            } else if backupState.exists {
                try preserveConflict(backupURL, transactionID: journal.transactionID)
            }
            let temporaryURL = URL(fileURLWithPath: target.temporaryPath)
            let temporaryState = try ExportQueue.PathState.capture(temporaryURL)
            if try matches(
                temporaryURL,
                state: target.publishedState,
                identity: target.publishedIdentity
            ) {
                try fm.removeItem(at: temporaryURL)
            } else if temporaryState.exists {
                try preserveConflict(temporaryURL, transactionID: journal.transactionID)
            }
        }
        if failJournalRemovalForTesting {
            throw SimulatedCommittedCleanupFailure()
        }
        try fm.removeItem(at: journalURL)
    }

    private static func validate(_ journal: Journal, journalURL: URL, root: URL) throws {
        guard journal.schema == schema,
              UUID(uuidString: journal.transactionID) != nil,
              UUID(uuidString: journal.jobID) != nil,
              journalURL.deletingPathExtension().lastPathComponent == journal.transactionID,
              !journal.targets.isEmpty,
              Set(journal.targets.map(\.targetPath)).count == journal.targets.count else {
            throw ToolError("An export recovery record has an invalid identity.")
        }
        let boundPaths = journal.targets.flatMap {
            [$0.targetPath, $0.temporaryPath, $0.backupPath]
        }
        guard Set(boundPaths).count == boundPaths.count else {
            throw ToolError("An export recovery record contains overlapping paths.")
        }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard journalURL.deletingLastPathComponent().resolvingSymlinksInPath() == resolvedRoot else {
            throw ToolError("An export recovery record escaped its runtime store.")
        }
        for target in journal.targets {
            let targetURL = URL(fileURLWithPath: target.targetPath).standardizedFileURL
            let temporaryURL = URL(fileURLWithPath: target.temporaryPath).standardizedFileURL
            let expectedTemporary = ExportQueue.DestinationBinding.makeTemporaryURL(
                url: targetURL,
                jobID: journal.jobID
            ).standardizedFileURL
            let expectedBackup = backupURL(
                target: targetURL,
                jobID: journal.jobID,
                transactionID: journal.transactionID
            ).standardizedFileURL
            guard target.targetPath.hasPrefix("/"),
                  targetURL.deletingLastPathComponent().resolvingSymlinksInPath()
                    == targetURL.deletingLastPathComponent(),
                  temporaryURL == expectedTemporary,
                  URL(fileURLWithPath: target.backupPath).standardizedFileURL == expectedBackup,
                  target.initialState.exists == (target.initialIdentity != nil),
                  target.initialState.isDirectory == target.expectsDirectory
                    || !target.initialState.exists,
                  target.publishedState.exists,
                  target.publishedIdentity != nil,
                  target.publishedState.isDirectory == target.expectsDirectory else {
                throw ToolError("An export recovery record contains unbound paths.")
            }
        }
    }

    private static func backupURL(target: URL, jobID: String, transactionID: String) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).\(jobID).\(transactionID).backup"
        )
    }

    private static func preserveConflict(_ url: URL, transactionID: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let parent = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var index = 0
        while true {
            let suffix = index == 0 ? "" : " \(index + 1)"
            let name = ext.isEmpty
                ? "\(base) Recovered Conflict \(transactionID.prefix(8))\(suffix)"
                : "\(base) Recovered Conflict \(transactionID.prefix(8))\(suffix).\(ext)"
            let destination = parent.appendingPathComponent(name)
            if !fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: url, to: destination)
                return
            }
            index += 1
        }
    }

    private static func matches(
        _ url: URL,
        state: ExportQueue.PathState,
        identity: ExportFileIdentity?,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Bool {
        if isCancelled() { throw CancellationError() }
        let before = try ExportFileIdentity.capture(url)
        guard before == identity else { return false }
        let actual = try ExportQueue.PathState.capture(url, isCancelled: isCancelled)
        let after = try ExportFileIdentity.capture(url)
        return actual == state && after == identity && before == after
    }

    private static func ensureRoot(_ root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ToolError("The export recovery store is unavailable.")
        }
    }

    private static func write(_ journal: Journal, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: url, options: .atomic)
    }
}
