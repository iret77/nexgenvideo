import Darwin
import Foundation
import NexGenEngine

/// Owns the live Recovery copy that atomically replaces the package on Save.
enum ProjectWorkingCopy {
    private static let pipelineDir = DataRootResolver.pipelineDirname   // "pipeline"
    private static let completeSentinel = ".ngv-materialized"
    private static let dirtyMarker = ".ngv-dirty"
    private static let generationMarker = ".ngv-open-generation"
    private static let internalNames = Set([
        completeSentinel,
        dirtyMarker,
        generationMarker,
    ])

    static func home(_ key: String) -> URL { AppPaths.workingCopy(projectId: key) }

    struct OpenResult: Sendable {
        let home: URL
        let recoveredUnsaved: Bool
        let generation: UUID
    }

    struct Checkpoint: Sendable {
        let timeline: Data
        let manifest: Data?
        let generationLog: Data?
        let thumbnail: Data?
        let chatSessionFiles: [(name: String, data: Data)]
    }

    @discardableResult
    static func open(key: String, packageURL: URL?) throws -> OpenResult {
        let fm = FileManager.default
        let existing = home(key)
        if isComplete(existing, fm: fm),
           fm.fileExists(atPath: existing.appendingPathComponent(dirtyMarker).path) {
            guard let packageURL,
                  ProjectPluginSettings.bindingResolution(projectURL: packageURL)
                    == ProjectPluginSettings.bindingResolution(projectURL: existing) else {
                throw PersistError.recoveredFormatMismatch
            }
            migrateSchemas(in: home(key))
            return OpenResult(
                home: home(key),
                recoveredUnsaved: true,
                generation: try claim(key: key)
            )
        }
        let materialized = try materialize(key: key, packageURL: packageURL)
        migrateSchemas(in: materialized)
        return OpenResult(
            home: materialized,
            recoveredUnsaved: false,
            generation: try claim(key: key)
        )
    }

    private static func migrateSchemas(in home: URL) {
        let dataRoot = home.appendingPathComponent(pipelineDir)
        guard FileManager.default.fileExists(
            atPath: dataRoot.appendingPathComponent(DataRootResolver.projectMarker).path) else { return }
        do {
            for result in try SchemaMigrator.migrateProject(dataRoot: dataRoot) {
                Log.project.notice(
                    "migrated \(result.artifact): \(result.from) -> \(result.to) (backup: \(result.backup?.lastPathComponent ?? "-"))")
            }
        } catch {
            Log.project.error("schema migration skipped: \(String(describing: error))")
        }
    }

    @discardableResult
    static func rematerialize(key: String, packageURL: URL?) throws -> URL {
        let generation = currentGeneration(key: key)
        let result = try materialize(key: key, packageURL: packageURL)
        if let generation {
            try writeClaim(generation, key: key)
        }
        return result
    }

    @discardableResult
    static func materialize(key: String, packageURL: URL?) throws -> URL {
        let fm = FileManager.default
        let recovery = AppPaths.ensure(AppPaths.recovery)
        let destination = home(key)
        let staging = recovery.appendingPathComponent(
            ".materialize-\(key)-\(UUID().uuidString)", isDirectory: true)
        do {
            guard let packageURL else {
                throw PersistError.incompletePackage(package: "Unsaved project")
            }
            try validatePackage(packageURL, fm: fm)
            try fm.copyItem(at: packageURL, to: staging)
            try normalizePipelineLayout(in: staging, fm: fm)
            try Data().write(
                to: staging.appendingPathComponent(completeSentinel),
                options: .atomic
            )
            try installWorkingCopy(staging, at: destination, key: key, fm: fm)
            return destination
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func checkpoint(key: String, snapshot: Checkpoint) throws {
        let fm = FileManager.default
        let root = home(key)
        guard isComplete(root, fm: fm) else {
            throw PersistError.noWorkingCopy(key: key)
        }
        try markDirty(key: key)
        try snapshot.timeline.write(
            to: root.appendingPathComponent(Project.timelineFilename),
            options: .atomic
        )
        try writeOptional(snapshot.manifest, named: Project.manifestFilename, in: root, fm: fm)
        try writeOptional(
            snapshot.generationLog,
            named: Project.generationLogFilename,
            in: root,
            fm: fm
        )
        if let thumbnail = snapshot.thumbnail {
            try thumbnail.write(
                to: root.appendingPathComponent(Project.thumbnailFilename),
                options: .atomic
            )
        }
        try replaceChatDirectory(snapshot.chatSessionFiles, in: root, fm: fm)
    }

    static func markDirty(key: String) throws {
        let fm = FileManager.default
        let root = home(key)
        guard isComplete(root, fm: fm) else {
            throw PersistError.noWorkingCopy(key: key)
        }
        try Data().write(to: root.appendingPathComponent(dirtyMarker), options: .atomic)
    }

    static func transact(
        key: String,
        markDirty: Bool = true,
        mutate: (URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        let current = home(key)
        guard isComplete(current, fm: fm) else {
            throw PersistError.noWorkingCopy(key: key)
        }
        let staging = AppPaths.ensure(AppPaths.recovery).appendingPathComponent(
            ".transaction-\(key)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fm.copyItem(at: current, to: staging)
            try mutate(staging)
            if markDirty {
                try Data().write(
                    to: staging.appendingPathComponent(dirtyMarker),
                    options: .atomic
                )
            }
            try validatePackage(staging, fm: fm)
            try installWorkingCopy(staging, at: current, key: key, fm: fm)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    @discardableResult
    static func transactChange(
        key: String,
        markDirty: Bool = true,
        validateCurrent: (URL) throws -> Void = { _ in },
        mutate: (URL) throws -> Bool
    ) throws -> Bool {
        let fm = FileManager.default
        let current = home(key)
        guard isComplete(current, fm: fm) else {
            throw PersistError.noWorkingCopy(key: key)
        }
        let staging = AppPaths.ensure(AppPaths.recovery).appendingPathComponent(
            ".transaction-\(key)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fm.copyItem(at: current, to: staging)
            let changed = try mutate(staging)
            guard changed else {
                try fm.removeItem(at: staging)
                return false
            }
            if markDirty {
                try Data().write(
                    to: staging.appendingPathComponent(dirtyMarker),
                    options: .atomic
                )
            }
            try validatePackage(staging, fm: fm)
            try validateCurrent(current)
            try installWorkingCopy(staging, at: current, key: key, fm: fm)
            return true
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func transactProject<Output>(
        at projectRoot: URL,
        markDirty: Bool = false,
        validateCurrent: (URL) throws -> Void = { _ in },
        mutate: (URL) throws -> Output
    ) throws -> Output {
        let fm = FileManager.default
        let root = projectRoot.standardizedFileURL
        let values = try root.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PersistError.incompletePackage(package: root.lastPathComponent)
        }
        let staging = root.deletingLastPathComponent().appendingPathComponent(
            ".transaction-\(root.lastPathComponent)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fm.copyItem(at: root, to: staging)
            let result = try mutate(staging)
            if markDirty {
                try Data().write(
                    to: staging.appendingPathComponent(dirtyMarker),
                    options: .atomic
                )
                try validatePackage(staging, fm: fm)
            }
            try validateCurrent(root)
            _ = try fm.replaceItemAt(root, withItemAt: staging)
            return result
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func transactPipeline<Output>(
        at dataRoot: URL,
        validateCurrent: (URL) throws -> Void = { _ in },
        mutate: (URL) throws -> Output
    ) throws -> Output {
        let fm = FileManager.default
        let root = dataRoot.standardizedFileURL
        let values = try root.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              root.lastPathComponent == pipelineDir else {
            throw PersistError.incompletePackage(package: root.lastPathComponent)
        }
        let projectHome = root.deletingLastPathComponent()
        let stagingHome = projectHome.deletingLastPathComponent().appendingPathComponent(
            ".pipeline-transaction-\(projectHome.lastPathComponent)-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingRoot = stagingHome.appendingPathComponent(
            pipelineDir,
            isDirectory: true
        )
        do {
            try cloneProjectReadView(
                from: projectHome,
                to: stagingHome,
                fm: fm
            )
            let result = try mutate(stagingRoot)
            try validateCurrent(projectHome)
            _ = try fm.replaceItemAt(root, withItemAt: stagingRoot)
            try? fm.removeItem(at: stagingHome)
            return result
        } catch {
            try? fm.removeItem(at: stagingHome)
            throw error
        }
    }

    private static func cloneProjectReadView(
        from source: URL,
        to destination: URL,
        fm: FileManager
    ) throws {
        guard try source.resourceValues(
            forKeys: [.volumeSupportsFileCloningKey]
        ).volumeSupportsFileCloning == true else {
            throw PersistError.readViewCloneUnavailable(
                package: source.lastPathComponent,
                detail: "The project volume doesn't support copy-on-write file clones."
            )
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw PersistError.readViewCloneUnavailable(
                package: source.lastPathComponent,
                detail: "The project files couldn't be enumerated."
            )
        }
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        let canonicalDestination = destination.resolvingSymlinksInPath()
            .standardizedFileURL
        let prefix = canonicalSource.path.hasSuffix("/")
            ? canonicalSource.path
            : canonicalSource.path + "/"
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                let relativePath = item.lastPathComponent
                throw PersistError.symbolicLink(path: relativePath)
            }
            let canonicalItem = item.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalItem.path.hasPrefix(prefix) else {
                throw PersistError.readViewCloneUnavailable(
                    package: source.lastPathComponent,
                    detail: "A project path escaped the read-view clone."
                )
            }
            let relativePath = String(canonicalItem.path.dropFirst(prefix.count))
            let target = canonicalDestination.appendingPathComponent(relativePath)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard values.isRegularFile == true else {
                throw PersistError.readViewCloneUnavailable(
                    package: source.lastPathComponent,
                    detail: "The project contains an unsupported file at \(relativePath)."
                )
            }
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let status = canonicalItem.path.withCString { sourcePath in
                target.path.withCString { targetPath in
                    clonefile(sourcePath, targetPath, UInt32(CLONE_NOFOLLOW_ANY))
                }
            }
            guard status == 0 else {
                let detail = String(cString: strerror(errno))
                throw PersistError.readViewCloneUnavailable(
                    package: source.lastPathComponent,
                    detail: "Copy-on-write cloning failed at \(relativePath): \(detail)"
                )
            }
        }
        if let enumerationError {
            throw PersistError.readViewCloneUnavailable(
                package: source.lastPathComponent,
                detail: "The project files couldn't be enumerated: "
                    + enumerationError.localizedDescription
            )
        }
    }

    static func markSaved(key: String) {
        try? FileManager.default.removeItem(at: home(key).appendingPathComponent(dirtyMarker))
    }

    static func persist(
        key: String,
        to packageURL: URL,
        mintNewIdentity: Bool = false,
        validateSourceBeforeCommit: (URL) throws -> Void = { _ in }
    ) throws {
        let fm = FileManager.default
        let source = home(key)
        guard isComplete(source, fm: fm) else {
            throw PersistError.noWorkingCopy(key: key)
        }
        let parent = packageURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(packageURL.lastPathComponent).save-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fm.copyItem(at: source, to: staging)
            try sanitizePackageStaging(staging, fm: fm)
            try normalizePipelineLayout(in: staging, fm: fm)
            if mintNewIdentity {
                let oldKey = ProjectIdentity.existingKey(for: staging)
                try ProjectIdentity.regenerate(at: staging)
                guard let newKey = ProjectIdentity.existingKey(for: staging),
                      newKey != oldKey else {
                    throw PersistError.identityNotRegenerated
                }
            }
            try commitStagedPackage(
                staging,
                to: packageURL,
                fm: fm,
                validateBeforeCommit: {
                    try validateSourceBeforeCommit(source)
                }
            )
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    enum PersistError: LocalizedError {
        case noWorkingCopy(key: String)
        case incompletePackage(package: String)
        case identityNotRegenerated
        case recoveredFormatMismatch
        case readViewCloneUnavailable(package: String, detail: String)
        case symbolicLink(path: String)

        var errorDescription: String? {
            switch self {
            case .noWorkingCopy(let key):
                return "Couldn't save the project: no complete working copy for \(key). "
                    + "Your work is still on disk — quit without saving and report this."
            case .incompletePackage(let package):
                return "Couldn't save \(package) because the project copy is incomplete. "
                    + "The last saved package was left untouched."
            case .identityNotRegenerated:
                return "Couldn't create an independent identity for the project copy. "
                    + "The original project was left untouched."
            case .recoveredFormatMismatch:
                return "Couldn't recover unsaved work because its exact format-pack binding "
                    + "doesn't match the saved project. The saved project and recovery copy were left untouched."
            case .readViewCloneUnavailable(let package, let detail):
                return "Couldn't prepare \(package) for the pipeline phase. \(detail) "
                    + "No project files were changed."
            case .symbolicLink(let path):
                return "The project contains a symbolic link at \(path). "
                    + "NexGenVideo projects must be self-contained."
            }
        }
    }

    static func discard(key: String) {
        try? FileManager.default.removeItem(at: home(key))
    }

    @discardableResult
    static func discard(key: String, ifGeneration generation: UUID) -> Bool {
        guard currentGeneration(key: key) == generation else { return false }
        do {
            try FileManager.default.removeItem(at: home(key))
            return true
        } catch {
            return false
        }
    }

    private static func claim(key: String) throws -> UUID {
        let generation = UUID()
        try writeClaim(generation, key: key)
        return generation
    }

    private static func writeClaim(_ generation: UUID, key: String) throws {
        try Data(generation.uuidString.utf8).write(
            to: home(key).appendingPathComponent(generationMarker),
            options: .atomic
        )
    }

    private static func currentGeneration(key: String) -> UUID? {
        let url = home(key).appendingPathComponent(generationMarker)
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        return UUID(uuidString: raw)
    }

    private static let idleKeys: Set<URLResourceKey> = [.contentAccessDateKey, .contentModificationDateKey]

    /// Time since a store entry was last touched — the later of last access and last modification, so a
    /// project merely reopened (read, not written) still counts as recently used. Unknown dates → fresh.
    private static func idle(_ url: URL, now: Date) -> TimeInterval {
        let v = try? url.resourceValues(forKeys: idleKeys)
        let last = max(v?.contentAccessDate ?? .distantPast, v?.contentModificationDate ?? .distantPast)
        return last == .distantPast ? 0 : now.timeIntervalSince(last)
    }

    /// Retire idle working copies from the Recovery store so it can't grow without bound. A clean close
    /// already discards a project's copy; only a crash leaves one behind. "Idle" means untouched — no
    /// read OR write — past `graceInterval`. A project that's open or recent (its key in `liveKeys`) is
    /// always spared; the age gate is the real safety. Deliberately never inspects a source path, so a
    /// file the user merely MOVED is never mistaken for deleted. Runs off the main thread at launch.
    static func sweepIdleProjectData(liveKeys: Set<String>, graceInterval: TimeInterval = 14 * 24 * 3600) {
        purgeKeyedStore(AppPaths.recovery, liveKeys: liveKeys, graceInterval: graceInterval)
        // Quarantined salvage (unsentineled copies set aside during materialize) is scratch — age it out.
        purgeAged(AppPaths.recovery.appendingPathComponent(".quarantine", isDirectory: true),
                  graceInterval: graceInterval)
        // The Caches tier (generation staging, decode/proxy scratch) is expendable and the OS may purge
        // it anyway — retire idle project-keyed entries on the same schedule as the working copies.
        purgeKeyedStore(AppPaths.projectCachesRoot, liveKeys: liveKeys, graceInterval: graceInterval)
    }

    /// Purge idle `p-…` entries from a project-keyed store, sparing anything in `liveKeys`. Testable in
    /// isolation via a temp `store`.
    static func purgeKeyedStore(_ store: URL, liveKeys: Set<String>, graceInterval: TimeInterval) {
        let fm = FileManager.default
        let now = Date()
        guard let items = try? fm.contentsOfDirectory(
            at: store, includingPropertiesForKeys: Array(idleKeys), options: [.skipsHiddenFiles]) else { return }
        for item in items {
            let key = item.lastPathComponent
            guard key.hasPrefix("p-") else { continue }          // a project store entry, not a stray
            if liveKeys.contains(key) { continue }               // open or recent — its data is live
            if idle(item, now: now) > graceInterval {
                try? fm.removeItem(at: item)
                Log.project.notice("swept idle project data \(key) in \(store.lastPathComponent)")
            }
        }
    }

    private static func purgeAged(_ dir: URL, graceInterval: TimeInterval) {
        let fm = FileManager.default
        let now = Date()
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(idleKeys), options: []) else { return }
        for item in items where idle(item, now: now) > graceInterval { try? fm.removeItem(at: item) }
    }

    private static func isComplete(_ root: URL, fm: FileManager) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(completeSentinel).path)
            && fm.fileExists(atPath: root.appendingPathComponent(Project.timelineFilename).path)
    }

    private static func validatePackage(_ package: URL, fm: FileManager) throws {
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: package.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fm.fileExists(
                atPath: package.appendingPathComponent(Project.timelineFilename).path
        ) else {
            throw PersistError.incompletePackage(package: package.lastPathComponent)
        }
        try validateNoSymbolicLinks(in: package, fm: fm)
    }

    static func validateForOpen(_ package: URL) throws {
        try validatePackage(package, fm: .default)
    }

    private static func validateNoSymbolicLinks(
        in root: URL,
        fm: FileManager
    ) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw PersistError.incompletePackage(package: root.lastPathComponent)
        }
        for case let item as URL in enumerator {
            if try item.resourceValues(forKeys: Set(keys)).isSymbolicLink == true {
                throw PersistError.symbolicLink(
                    path: item.path.replacingOccurrences(
                        of: root.path + "/",
                        with: ""
                    )
                )
            }
        }
    }

    private static func normalizePipelineLayout(in root: URL, fm: FileManager) throws {
        let legacy = root.appendingPathComponent(
            DataRootResolver.legacyPipelineDirname,
            isDirectory: true
        )
        let current = root.appendingPathComponent(pipelineDir, isDirectory: true)
        guard legacy.standardizedFileURL != current.standardizedFileURL,
              fm.fileExists(atPath: legacy.path) else { return }
        if fm.fileExists(atPath: current.path) {
            try fm.removeItem(at: legacy)
        } else {
            try fm.moveItem(at: legacy, to: current)
        }
    }

    private static func installWorkingCopy(
        _ staging: URL,
        at destination: URL,
        key: String,
        fm: FileManager
    ) throws {
        guard fm.fileExists(atPath: destination.path) else {
            try fm.moveItem(at: staging, to: destination)
            return
        }
        if !isComplete(destination, fm: fm) {
            let quarantineRoot = AppPaths.ensure(
                AppPaths.recovery.appendingPathComponent(".quarantine", isDirectory: true)
            )
            let quarantine = quarantineRoot.appendingPathComponent(
                "\(key)-\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.moveItem(at: destination, to: quarantine)
            do {
                try fm.moveItem(at: staging, to: destination)
                Log.project.notice(
                    "quarantined an incomplete working copy to \(quarantine.lastPathComponent)"
                )
            } catch {
                try? fm.moveItem(at: quarantine, to: destination)
                throw error
            }
            return
        }
        _ = try fm.replaceItemAt(destination, withItemAt: staging)
    }

    private static func replaceDirectory(
        at destination: URL,
        with staging: URL,
        fm: FileManager
    ) throws {
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    private static func writeOptional(
        _ data: Data?,
        named name: String,
        in root: URL,
        fm: FileManager
    ) throws {
        let destination = root.appendingPathComponent(name)
        if let data {
            try data.write(to: destination, options: .atomic)
        } else if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
    }

    private static func replaceChatDirectory(
        _ files: [(name: String, data: Data)],
        in root: URL,
        fm: FileManager
    ) throws {
        let destination = root.appendingPathComponent(
            ChatSessionStore.dirName,
            isDirectory: true
        )
        let staging = root.appendingPathComponent(
            ".chat-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in files {
                try file.data.write(
                    to: staging.appendingPathComponent(file.name),
                    options: .atomic
                )
            }
            try replaceDirectory(at: destination, with: staging, fm: fm)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func sanitizePackageStaging(
        _ root: URL,
        fm: FileManager = .default
    ) throws {
        try validateNoSymbolicLinks(in: root, fm: fm)
        let topLevel = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        for item in topLevel {
            let name = item.lastPathComponent
            guard internalNames.contains(name) || name.hasPrefix(".chat-") else { continue }
            try fm.removeItem(at: item)
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw PersistError.incompletePackage(package: root.lastPathComponent)
        }
        var partials: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            let name = item.lastPathComponent
            let isKnownPartial = name.hasSuffix(".partial")
                && (name.hasPrefix(".import-") || name.hasPrefix(".song-"))
            guard isKnownPartial else { continue }
            partials.append(item)
            if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                enumerator.skipDescendants()
            }
        }
        for item in partials.sorted(by: { $0.path.count > $1.path.count }) {
            try fm.removeItem(at: item)
        }
    }

    static func commitStagedPackage(
        _ staging: URL,
        to destination: URL,
        fm: FileManager = .default,
        validateBeforeCommit: () throws -> Void = {}
    ) throws {
        try validatePackage(staging, fm: fm)
        try validateBeforeCommit()
        try replaceDirectory(at: destination, with: staging, fm: fm)
        try validatePackage(destination, fm: fm)
    }
}
