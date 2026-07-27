import AppKit
import AVFoundation
import CryptoKit

enum MediaPanelItemKey {
    static let folderPrefix = "folder-"

    static func folder(_ id: String) -> String {
        folderPrefix + id
    }

    static func folderId(from key: String) -> String? {
        guard key.hasPrefix(folderPrefix) else { return nil }
        return String(key.dropFirst(folderPrefix.count))
    }
}

private struct MediaImportPlan: Sendable {
    enum Parent: Sendable {
        case existingFolderId(String?)
        case plannedFolder(Int)
    }

    struct Folder: Sendable {
        let name: String
        let parent: Parent
    }

    struct File: Sendable {
        let url: URL
        let type: ClipType
        let name: String
        let parent: Parent
    }

    var folders: [Folder] = []
    var files: [File] = []
    var rejectedUnsupportedNames: [String] = []
    var rejectedLottieNames: [String] = []
    var scanFailure: MediaImportError?
}

private enum MediaImportScanner {
    struct Root: Sendable {
        let url: URL
        let parentFolderId: String?
    }

    static func scan(roots: [Root]) -> MediaImportPlan {
        var plan = MediaImportPlan()
        var visitedDirectories: Set<String> = []
        for root in roots {
            guard plan.scanFailure == nil else { break }
            let parent = MediaImportPlan.Parent.existingFolderId(root.parentFolderId)
            if isDirectory(root.url) {
                scanFolder(
                    at: root.url,
                    parent: parent,
                    visitedDirectories: &visitedDirectories,
                    into: &plan
                )
            } else {
                scanFile(at: root.url, parent: parent, isRootItem: true, into: &plan)
            }
        }
        return plan
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private static func scan(
        entries: [URL],
        parent: MediaImportPlan.Parent,
        visitedDirectories: inout Set<String>,
        into plan: inout MediaImportPlan
    ) {
        let sorted = entries.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        for entry in sorted {
            guard plan.scanFailure == nil else { break }
            if isDirectory(entry) {
                scanFolder(
                    at: entry,
                    parent: parent,
                    visitedDirectories: &visitedDirectories,
                    into: &plan
                )
            } else {
                scanFile(at: entry, parent: parent, isRootItem: false, into: &plan)
            }
        }
    }

    private static func scanFolder(
        at url: URL,
        parent: MediaImportPlan.Parent,
        visitedDirectories: inout Set<String>,
        into plan: inout MediaImportPlan
    ) {
        let identity = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard visitedDirectories.insert(identity).inserted else { return }
        let entries: [URL]
        do {
            entries = try directoryEntries(at: url)
        } catch {
            plan.scanFailure = .folderUnreadable(url.lastPathComponent, error.localizedDescription)
            return
        }
        let folderIndex = plan.folders.count
        plan.folders.append(.init(name: url.lastPathComponent, parent: parent))
        scan(
            entries: entries,
            parent: .plannedFolder(folderIndex),
            visitedDirectories: &visitedDirectories,
            into: &plan
        )
    }

    private static func directoryEntries(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    private static func scanFile(
        at url: URL,
        parent: MediaImportPlan.Parent,
        isRootItem: Bool,
        into plan: inout MediaImportPlan
    ) {
        guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else {
            if isRootItem { plan.rejectedUnsupportedNames.append(url.lastPathComponent) }
            return
        }
        if type == .lottie, !LottieVideoGenerator.isLottie(at: url) {
            plan.rejectedLottieNames.append(url.lastPathComponent)
            return
        }
        plan.files.append(.init(
            url: url,
            type: type,
            name: url.deletingPathExtension().lastPathComponent,
            parent: parent
        ))
    }
}

enum MediaImportError: LocalizedError, Equatable, Sendable {
    case projectMustBeSaved
    case unsupportedFile(String)
    case invalidLottie(String)
    case sourceUnavailable(String)
    case sourceNotFile(String)
    case folderUnreadable(String, String)
    case prepareFailed(String)
    case copyFailed(String, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .projectMustBeSaved:
            "Save the project before importing media."
        case .unsupportedFile(let name):
            "Can't import \"\(name)\" — unsupported file type."
        case .invalidLottie(let name):
            "Can't import \"\(name)\" — not a Lottie animation."
        case .sourceUnavailable(let name):
            "Can't import \"\(name)\" — the file is unavailable."
        case .sourceNotFile(let name):
            "Can't import \"\(name)\" — choose a file, not a folder."
        case .folderUnreadable(let name, let detail):
            "Can't import folder \"\(name)\" — its contents couldn't be read: \(detail)"
        case .prepareFailed(let detail):
            "Can't import media — the project media folder couldn't be prepared: \(detail)"
        case .copyFailed(let name, let detail):
            "Can't import \"\(name)\" — it couldn't be copied into the project: \(detail)"
        case .cancelled:
            "Media import canceled."
        }
    }
}

struct DurableMediaCopy: Sendable {
    let url: URL
    let created: Bool
    let digest: String
}

private struct PreparedMediaImport: Sendable {
    struct File: Sendable {
        let source: MediaImportPlan.File
        let url: URL
    }

    let files: [File]
    let createdURLs: [URL]
}

enum DurableMediaStore {
    private static let chunkBytes = 4 * 1024 * 1024

    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: chunkBytes), !data.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func copy(
        _ fileURL: URL,
        into mediaDirectory: URL,
        reusableByDigest: [String: URL],
        fileExtension: String? = nil
    ) throws -> DurableMediaCopy {
        let fm = FileManager.default
        let source = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let projectMedia = mediaDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try source.resourceValues(forKeys: [.isRegularFileKey])
        } catch {
            throw MediaImportError.sourceUnavailable(fileURL.lastPathComponent)
        }
        guard values.isRegularFile == true else {
            throw MediaImportError.sourceNotFile(fileURL.lastPathComponent)
        }
        if source.path == projectMedia.path || source.path.hasPrefix(projectMedia.path + "/") {
            return DurableMediaCopy(
                url: source,
                created: false,
                digest: try digest(of: source)
            )
        }

        let staging = mediaDirectory.appendingPathComponent(
            ".import-\(UUID().uuidString).partial",
            isDirectory: false
        )
        guard fm.createFile(atPath: staging.path, contents: nil) else {
            throw MediaImportError.copyFailed(
                fileURL.lastPathComponent,
                "the staging file couldn't be created"
            )
        }
        var completed = false
        defer {
            if !completed { try? fm.removeItem(at: staging) }
        }

        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: staging)
            defer {
                try? input.close()
                try? output.close()
            }
            var hasher = SHA256()
            while let data = try input.read(upToCount: chunkBytes), !data.isEmpty {
                if Task.isCancelled { throw CancellationError() }
                hasher.update(data: data)
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if let reusable = reusableByDigest[digest],
               fm.fileExists(atPath: reusable.path) {
                try fm.removeItem(at: staging)
                completed = true
                return DurableMediaCopy(url: reusable, created: false, digest: digest)
            }

            let ext = (fileExtension ?? fileURL.pathExtension).lowercased()
            let filename = ext.isEmpty ? digest : "\(digest).\(ext)"
            let destination = mediaDirectory.appendingPathComponent(filename)
            if fm.fileExists(atPath: destination.path) {
                guard try Self.digest(of: destination) == digest else {
                    throw MediaImportError.copyFailed(
                        fileURL.lastPathComponent,
                        "the content-addressed destination is corrupt"
                    )
                }
                try fm.removeItem(at: staging)
                completed = true
                return DurableMediaCopy(url: destination, created: false, digest: digest)
            }
            try fm.moveItem(at: staging, to: destination)
            completed = true
            return DurableMediaCopy(url: destination, created: true, digest: digest)
        } catch is CancellationError {
            throw MediaImportError.cancelled
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.copyFailed(
                fileURL.lastPathComponent,
                error.localizedDescription
            )
        }
    }
}

private enum MediaImportPreparer {
    typealias Progress = @Sendable (_ completed: Int, _ currentName: String) async -> Void

    static func rollback(
        _ createdURLs: [URL],
        mediaDirectory: URL
    ) {
        let root = mediaDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        for url in createdURLs.reversed() {
            let target = url.standardizedFileURL
                .resolvingSymlinksInPath()
            guard target.path.hasPrefix(root.path + "/"),
                  (try? target.resourceValues(
                      forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true else {
                continue
            }
            try? FileManager.default.removeItem(at: target)
        }
    }

    static func prepare(
        _ plan: MediaImportPlan,
        mediaDirectory: URL,
        existingMediaURLs: [URL],
        progress: Progress
    ) async throws -> PreparedMediaImport {
        var reusableByDigest: [String: URL] = [:]
        for url in existingMediaURLs {
            if Task.isCancelled { throw MediaImportError.cancelled }
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if stem.count == 64, stem.allSatisfy(\.isHexDigit) {
                reusableByDigest[stem] = reusableByDigest[stem] ?? url
            } else if let digest = try? DurableMediaStore.digest(of: url) {
                reusableByDigest[digest] = reusableByDigest[digest] ?? url
            }
        }

        var files: [PreparedMediaImport.File] = []
        var createdURLs: [URL] = []
        do {
            for (index, file) in plan.files.enumerated() {
                if Task.isCancelled { throw MediaImportError.cancelled }
                await progress(index, file.name)
                let copy = try DurableMediaStore.copy(
                    file.url,
                    into: mediaDirectory,
                    reusableByDigest: reusableByDigest
                )
                reusableByDigest[copy.digest] = copy.url
                files.append(.init(source: file, url: copy.url))
                if copy.created { createdURLs.append(copy.url) }
            }
            if Task.isCancelled { throw MediaImportError.cancelled }
            await progress(plan.files.count, "")
            return PreparedMediaImport(files: files, createdURLs: createdURLs)
        } catch {
            rollback(createdURLs, mediaDirectory: mediaDirectory)
            throw error
        }
    }
}

extension EditorViewModel {

    func prepareWorkingMediaDirectory() throws -> URL {
        guard let workingRoot, let key = openWorkingCopyKey else {
            throw MediaImportError.projectMustBeSaved
        }
        let mediaDir = workingRoot.appendingPathComponent(
            Project.mediaDirectoryName,
            isDirectory: true
        )
        do {
            try ProjectWorkingCopy.markDirty(key: key)
            try FileManager.default.createDirectory(
                at: mediaDir,
                withIntermediateDirectories: true
            )
            return mediaDir
        } catch {
            throw MediaImportError.prepareFailed(error.localizedDescription)
        }
    }

    func importMediaAsset(_ asset: MediaAsset, skipAppend: Bool = false) {
        if !skipAppend {
            mediaAssets.append(asset)
        }
        let entry = asset.toManifestEntry(projectURL: workingRoot)
        mediaManifest.entries.append(entry)
        Log.project.notice(
            "media imported asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)",
            telemetry: "Media asset imported",
            data: [
                "assetId": Telemetry.shortId(asset.id),
                "type": asset.type.rawValue,
                "skipAppend": skipAppend,
                "media": mediaAssets.count,
                "manifestEntries": mediaManifest.entries.count
            ]
        )
        onPipelineChanged?()
    }

    /// Resolve a drag pasteboard payload (one `nexgen-asset://<id>` per line).
    func assetsFromDragPayload(_ payload: String) -> [MediaAsset] {
        payload.split(separator: "\n").compactMap { line in
            guard let id = MediaTab.assetId(fromDragString: String(line)) else { return nil }
            // A document has no duration and nothing to draw — dropping one would make a clip no
            // player can render. Filtered here so the timeline never even offers the drop.
            return mediaAssets.first { $0.id == id && $0.type.isPlaceable }
        }
    }

    /// Source-second ranges carried by search-moment drags, keyed by asset id.
    func segmentsFromDragPayload(_ payload: String) -> [String: ClosedRange<Double>] {
        var segments: [String: ClosedRange<Double>] = [:]
        for line in payload.split(separator: "\n") {
            guard let id = MediaTab.assetId(fromDragString: String(line)),
                  let segment = MediaTab.assetSegment(fromDragString: String(line)) else { continue }
            segments[id] = segment
        }
        return segments
    }

    func dismissMediaPanelToast() {
        mediaPanelToast = nil
    }

    func cancelMediaImport() {
        mediaImportCancellationRequested = true
        mediaImportCancellation?()
        mediaImportTail?.cancel()
    }

    @discardableResult
    func addMediaAsset(from url: URL, folderId: String? = nil) -> MediaAsset? {
        do {
            return try addMediaAssetThrowing(from: url, folderId: folderId)
        } catch {
            reportMediaImportFailure(error)
            return nil
        }
    }

    @discardableResult
    func addMediaAssetThrowing(from url: URL, folderId: String? = nil) throws -> MediaAsset {
        guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else {
            throw MediaImportError.unsupportedFile(url.lastPathComponent)
        }
        if type == .lottie, !LottieVideoGenerator.isLottie(at: url) {
            throw MediaImportError.invalidLottie(url.lastPathComponent)
        }
        let name = url.deletingPathExtension().lastPathComponent
        let asset = MediaAsset(url: try durableProjectMediaURL(for: url), type: type, name: name)
        asset.folderId = folderId
        importMediaAsset(asset)
        Task { await finalizeImportedAsset(asset) }
        return asset
    }

    func durableProjectMediaURL(for fileURL: URL) throws -> URL {
        try copyIntoProjectMedia(fileURL).url
    }

    private func copyIntoProjectMedia(_ fileURL: URL) throws -> DurableMediaCopy {
        let mediaDir = try prepareWorkingMediaDirectory()
        var reusable: [String: URL] = [:]
        for asset in mediaAssets {
            let name = asset.url.deletingPathExtension().lastPathComponent.lowercased()
            if name.count == 64, name.allSatisfy(\.isHexDigit) {
                reusable[name] = reusable[name] ?? asset.url
            }
        }
        return try DurableMediaStore.copy(
            fileURL,
            into: mediaDir,
            reusableByDigest: reusable
        )
    }

    struct MediaImportSummary: Sendable {
        var assetCount: Int
        var folderCount: Int
        var failure: String?

        init(assetCount: Int, folderCount: Int, failure: String? = nil) {
            self.assetCount = assetCount
            self.folderCount = folderCount
            self.failure = failure
        }
    }

    /// Import files and folders from the open panel or a Finder drop as one undo step
    @discardableResult
    func importFinderItems(_ urls: [URL], into folderId: String?) async -> MediaImportSummary {
        let previous = mediaImportTail
        mediaImportSequence &+= 1
        let sequence = mediaImportSequence
        let task = Task { @MainActor in
            _ = await previous?.value
            return await performFinderImport(urls, into: folderId)
        }
        mediaImportTail = task

        let summary = await task.value
        if mediaImportSequence == sequence {
            mediaImportTail = nil
        }
        return summary
    }

    @discardableResult
    private func performFinderImport(_ urls: [URL], into folderId: String?) async -> MediaImportSummary {
        mediaImportCancellationRequested = false
        let before = mediaLibraryUndoSnapshot()
        let roots = urls.map { MediaImportScanner.Root(url: $0, parentFolderId: folderId) }

        let plan = await Task.detached(priority: .userInitiated) {
            MediaImportScanner.scan(roots: roots)
        }.value
        if let error = plan.scanFailure {
            reportMediaImportFailure(error)
            return MediaImportSummary(
                assetCount: 0,
                folderCount: 0,
                failure: error.localizedDescription
            )
        }
        if plan.files.isEmpty, plan.folders.isEmpty {
            return applyMediaImportPlan(
                plan,
                prepared: PreparedMediaImport(files: [], createdURLs: []),
                restoringFrom: before
            )
        }
        let mediaDirectory: URL
        do {
            mediaDirectory = try prepareWorkingMediaDirectory()
        } catch {
            reportMediaImportFailure(error)
            return MediaImportSummary(
                assetCount: 0,
                folderCount: 0,
                failure: error.localizedDescription
            )
        }
        guard !Task.isCancelled else {
            return MediaImportSummary(
                assetCount: 0,
                folderCount: 0,
                failure: MediaImportError.cancelled.localizedDescription
            )
        }

        mediaImportProgress = MediaImportProgress(
            completed: 0,
            total: plan.files.count,
            currentName: plan.files.first?.name
        )
        let existingMediaURLs = mediaAssets.map(\.url)
        let worker = Task.detached(priority: .userInitiated) {
            try await MediaImportPreparer.prepare(
                plan,
                mediaDirectory: mediaDirectory,
                existingMediaURLs: existingMediaURLs,
                progress: { [weak self] completed, currentName in
                    await MainActor.run {
                        self?.mediaImportProgress = MediaImportProgress(
                            completed: completed,
                            total: plan.files.count,
                            currentName: currentName.isEmpty ? nil : currentName
                        )
                    }
                }
            )
        }
        mediaImportCancellation = { worker.cancel() }
        let result = await worker.result
        let wasCancelled = mediaImportCancellationRequested
            || Task.isCancelled
        mediaImportCancellation = nil
        mediaImportCancellationRequested = false
        mediaImportProgress = nil

        if wasCancelled {
            if case .success(let prepared) = result {
                MediaImportPreparer.rollback(
                    prepared.createdURLs,
                    mediaDirectory: mediaDirectory
                )
            }
            return MediaImportSummary(
                assetCount: 0,
                folderCount: 0,
                failure: MediaImportError.cancelled.localizedDescription
            )
        }
        switch result {
        case .success(let prepared):
            return applyMediaImportPlan(plan, prepared: prepared, restoringFrom: before)
        case .failure(let error):
            let reported = (error as? MediaImportError) ?? .copyFailed(
                "media",
                error.localizedDescription
            )
            reportMediaImportFailure(reported)
            return MediaImportSummary(
                assetCount: 0,
                folderCount: 0,
                failure: reported.localizedDescription
            )
        }
    }

    @discardableResult
    private func applyMediaImportPlan(
        _ plan: MediaImportPlan,
        prepared: PreparedMediaImport,
        restoringFrom before: MediaLibraryUndoSnapshot
    ) -> MediaImportSummary {
        undoManager?.disableUndoRegistration()

        var folderIds = Array(repeating: "", count: plan.folders.count)
        var createdFolderCount = 0
        for (index, folder) in plan.folders.enumerated() {
            let parentId = parentFolderId(for: folder.parent, plannedFolderIds: folderIds)
            if let existing = mediaManifest.folders.first(where: {
                $0.name == folder.name && $0.parentFolderId == parentId
            }) {
                folderIds[index] = existing.id
            } else {
                folderIds[index] = createFolder(name: folder.name, in: parentId)
                createdFolderCount += 1
            }
        }

        var importedAssets: [MediaAsset] = []
        var knownURLs = Set(mediaAssets.map {
            $0.url.standardizedFileURL.resolvingSymlinksInPath().path
        })
        for preparedFile in prepared.files {
            let path = preparedFile.url.standardizedFileURL.resolvingSymlinksInPath().path
            guard knownURLs.insert(path).inserted else { continue }
            let file = preparedFile.source
            let folderId = parentFolderId(for: file.parent, plannedFolderIds: folderIds)
            let asset = MediaAsset(
                url: preparedFile.url,
                type: file.type,
                name: file.name
            )
            asset.folderId = folderId
            importedAssets.append(asset)
        }
        if !importedAssets.isEmpty {
            mediaAssets.append(contentsOf: importedAssets)
            mediaManifest.entries.append(
                contentsOf: importedAssets.map { $0.toManifestEntry(projectURL: workingRoot) }
            )
            Log.project.notice(
                "media import applied assets=\(importedAssets.count) folders=\(plan.folders.count)",
                telemetry: "Media import applied",
                data: [
                    "assets": importedAssets.count,
                    "folders": plan.folders.count,
                    "media": mediaAssets.count,
                    "manifestEntries": mediaManifest.entries.count
                ]
            )
        }
        undoManager?.enableUndoRegistration()
        if let name = plan.rejectedUnsupportedNames.last {
            mediaPanelToast = "Can't import \"\(name)\" — unsupported file type."
        } else if let name = plan.rejectedLottieNames.last {
            mediaPanelToast = "Can't import \"\(name)\" — not a Lottie animation."
        }

        let summary = MediaImportSummary(
            assetCount: importedAssets.count,
            folderCount: createdFolderCount
        )
        guard summary.assetCount != 0 || summary.folderCount != 0 else { return summary }
        let createdURLs = prepared.createdURLs
        let after = mediaLibraryUndoSnapshot()
        let stash = workingRoot?.appendingPathComponent(
            Project.mediaDirectoryName,
            isDirectory: true
        ).appendingPathComponent(
            ".import-undo-\(UUID().uuidString).partial",
            isDirectory: true
        )
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.restoreMediaImportSnapshot(
                before,
                inverse: after,
                createdURLs: createdURLs,
                stash: stash,
                actionName: "Import Media"
            )
        }
        undoManager?.setActionName("Import Media")
        for asset in importedAssets {
            Task { await finalizeImportedAsset(asset) }
        }
        return summary
    }

    private func restoreMediaImportSnapshot(
        _ snapshot: MediaLibraryUndoSnapshot,
        inverse: MediaLibraryUndoSnapshot,
        createdURLs: [URL],
        stash: URL?,
        actionName: String
    ) {
        let required = Set(snapshot.mediaAssets.map {
            $0.url.standardizedFileURL.path
        })
        if let stash, createdURLs.contains(where: {
            required.contains($0.standardizedFileURL.path)
        }) {
            for url in createdURLs where required.contains(
                url.standardizedFileURL.path
            ) {
                let staged = stash.appendingPathComponent(url.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: url.path),
                      FileManager.default.fileExists(atPath: staged.path) else {
                    continue
                }
                do {
                    try FileManager.default.moveItem(at: staged, to: url)
                } catch {
                    Log.project.error(
                        "media import redo restore failed: \(error.localizedDescription)"
                    )
                    return
                }
            }
        }

        applyMediaLibrarySnapshot(snapshot)

        if let stash {
            for url in createdURLs where !required.contains(
                url.standardizedFileURL.path
            ) && FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.createDirectory(
                        at: stash,
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(
                        at: url,
                        to: stash.appendingPathComponent(url.lastPathComponent)
                    )
                } catch {
                    Log.project.error(
                        "media import undo cleanup failed: \(error.localizedDescription)"
                    )
                }
            }
        }

        undoManager?.registerUndo(withTarget: self) { vm in
            vm.restoreMediaImportSnapshot(
                inverse,
                inverse: snapshot,
                createdURLs: createdURLs,
                stash: stash,
                actionName: actionName
            )
        }
        undoManager?.setActionName(actionName)
    }

    private func parentFolderId(for parent: MediaImportPlan.Parent, plannedFolderIds: [String]) -> String? {
        switch parent {
        case .existingFolderId(let id):
            id
        case .plannedFolder(let index):
            plannedFolderIds[index]
        }
    }

    @discardableResult
    func importPastedImageData(_ data: Data, fileExtension: String = "png") -> MediaAsset? {
        let filename = "pasted-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        let mediaDir: URL
        do {
            mediaDir = try prepareWorkingMediaDirectory()
        } catch {
            reportMediaImportFailure(error)
            return nil
        }
        let destURL = mediaDir.appendingPathComponent(filename)
        do {
            try data.write(to: destURL, options: .atomic)
            return try addMediaAssetThrowing(from: destURL)
        } catch {
            try? FileManager.default.removeItem(at: destURL)
            Log.project.error("importPastedImageData: write failed \(error.localizedDescription)")
            reportMediaImportFailure(error)
            return nil
        }
    }

    private func reportMediaImportFailure(_ error: Error) {
        let message = error.localizedDescription
        mediaPanelToast = MediaPanelToast(message: message)
        Log.project.error("media import failed error=\(message)")
    }

    func fitTextClipToContent(clipId: String) {
        guard let loc = findClip(id: clipId) else { return }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType == .text else { return }
        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        let natural = TextLayout.naturalSize(
            content: clip.textContent ?? " ",
            style: clip.textStyle ?? TextStyle(),
            maxWidth: CGFloat(canvasW) * 0.9,
            canvasHeight: CGFloat(canvasH)
        )
        let needW = Double(natural.width) / canvasW
        let needH = Double(natural.height) / canvasH
        let currentW = clip.transform.width
        let currentH = clip.transform.height
        if abs(needW - currentW) < 0.0001 && abs(needH - currentH) < 0.0001 { return }
        let tl = clip.transform.topLeft
        let cy = tl.y + currentH / 2
        let alignment = (clip.textStyle ?? TextStyle()).alignment
        let cx: Double
        switch alignment {
        case .left:
            cx = tl.x + needW / 2
        case .right:
            cx = (tl.x + currentW) - needW / 2
        case .center:
            cx = tl.x + currentW / 2
        }
        applyClipProperty(clipId: clipId, rebuild: false) {
            $0.transform = Transform(center: (cx, cy), width: needW, height: needH)
        }
    }

    func clipDisplayLabel(for clip: Clip) -> String {
        if clip.mediaType == .text {
            let content = clip.textContent ?? ""
            if content.isEmpty { return "Text" }
            // Timeline label bar is single-line.
            return content
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        if let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }), asset.isGenerating {
            return asset.name
        }
        return mediaResolver.displayName(for: clip.mediaRef)
    }

    /// missing on disk or present-but-unloadable (no permission, ejected volume)
    func isMediaOffline(_ mediaRef: String) -> Bool {
        offlineMediaRefs.contains(mediaRef)
            || unprocessableMediaRefs.contains(mediaRef)
            || missingMediaRefs.contains(mediaRef)
    }

    /// Present-but-unpreparable (e.g. failed to encode)
    func isMediaUnprocessable(_ mediaRef: String) -> Bool {
        unprocessableMediaRefs.contains(mediaRef) && !missingMediaRefs.contains(mediaRef)
    }

    /// Recompute `missingMediaRefs` off the main thread, then publish on the main actor.
    func refreshMissingMediaCache() {
        let entries = mediaManifest.entries
        let projectPath = workingRoot?.path
        missingMediaRefreshTask?.cancel()
        missingMediaRefreshTask = Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                MediaResolver.missingAssetIds(entries: entries, projectPath: projectPath)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.missingMediaRefs != missing {
                    self.missingMediaRefs = missing
                }
                self.missingMediaRefreshTask = nil
            }
        }
    }

    func isClipMediaOffline(_ clip: Clip) -> Bool {
        clip.mediaType != .text && isMediaOffline(clip.mediaRef)
    }

    func isClipMediaGenerating(_ clip: Clip) -> Bool {
        guard clip.mediaType != .text else { return false }
        return mediaAssets.first(where: { $0.id == clip.mediaRef })?.isGenerating ?? false
    }

    enum MediaSelectionDirection {
        case left, right, up, down

        func step(columnCount: Int) -> Int {
            switch self {
            case .left: -1
            case .right: +1
            case .up: -columnCount
            case .down: +columnCount
            }
        }

        var startsFromEnd: Bool { self == .left || self == .up }
    }

    func moveMediaSelection(direction: MediaSelectionDirection) {
        let ordered = mediaPanelOrderedItemIds
        guard !ordered.isEmpty else { return }
        let selectedKeys = mediaPanelSelectedKeys()

        let next: String
        if let anchor = ordered.last(where: { selectedKeys.contains($0) }),
           let idx = ordered.firstIndex(of: anchor) {
            let raw = idx + direction.step(columnCount: max(1, mediaPanelColumnCount))
            let target = max(0, min(ordered.count - 1, raw))
            guard target != idx else { return }
            next = ordered[target]
        } else {
            next = direction.startsFromEnd ? ordered[ordered.count - 1] : ordered[0]
        }

        selectMediaPanelItem(next)
    }

    private func mediaPanelSelectedKeys() -> Set<String> {
        var keys = selectedMediaAssetIds
        keys.formUnion(selectedFolderIds.map(MediaPanelItemKey.folder))
        return keys
    }

    func selectMediaPanelItem(_ key: String) {
        if let folderId = MediaPanelItemKey.folderId(from: key) {
            guard folder(id: folderId) != nil else { return }
            mediaPanelScrollTarget = key
            selectedFolderIds = [folderId]
            selectedMediaAssetIds.removeAll()
            return
        }
        guard let asset = mediaAssets.first(where: { $0.id == key }) else { return }
        mediaPanelScrollTarget = key
        selectMediaAsset(asset)
    }

    func renameMediaAsset(id: String, name: String) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        let oldName = asset.name
        asset.name = name
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            mediaManifest.entries[idx].name = name
        }
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.renameMediaAsset(id: id, name: oldName)
        }
        undoManager?.setActionName("Rename Asset")
    }

    func updateManifestMetadata(for asset: MediaAsset) {
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
            mediaManifest.entries[idx].duration = asset.duration
            mediaManifest.entries[idx].sourceWidth = asset.sourceWidth
            mediaManifest.entries[idx].sourceHeight = asset.sourceHeight
            mediaManifest.entries[idx].sourceFPS = asset.sourceFPS
            mediaManifest.entries[idx].hasAudio = asset.hasAudio
        }
    }

    /// Text is composited via `CALayer.render` — `AVAssetImageGenerator`
    /// doesn't evaluate `animationTool` on single-frame extraction.
    func captureCurrentFrameToMedia() {
        guard let currentItem = videoEngine?.player.currentItem else {
            Log.project.error("captureCurrentFrameToMedia: no preview item")
            return
        }

        let tab = activePreviewTab
        let isTimelineTab: Bool
        let frame: Int
        let nameBase: String
        switch tab {
        case .timeline:
            isTimelineTab = true
            frame = currentFrame
            nameBase = "Frame"
        case .mediaAsset(let id, _, let type):
            guard type == .video else { return }
            isTimelineTab = false
            frame = sourcePlayheadFrame
            nameBase = mediaAssets.first(where: { $0.id == id })?.name ?? "Frame"
        }

        let asset = currentItem.asset
        let timelineSnapshot = timeline
        let fps = timeline.fps
        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))

        let videoComposition = isTimelineTab ? currentItem.videoComposition : nil

        Task.detached {
            guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else {
                Log.project.error("captureCurrentFrameToMedia: no video track")
                return
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if let videoComposition {
                generator.videoComposition = videoComposition
                generator.maximumSize = canvas
            }

            let videoCG: CGImage
            do {
                videoCG = try await generator.image(at: time).image
            } catch {
                Log.project.error("captureCurrentFrameToMedia: generate failed \(error.localizedDescription)")
                return
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                let finalCG: CGImage
                if isTimelineTab {
                    let textRoot = TextLayerController.buildSnapshot(
                        timeline: timelineSnapshot,
                        canvasSize: canvas,
                        atFrame: frame
                    )
                    guard let composited = Self.compositeCapture(
                        video: videoCG, textRoot: textRoot, canvas: canvas
                    ) else {
                        Log.project.error("captureCurrentFrameToMedia: composite failed")
                        return
                    }
                    finalCG = composited
                } else {
                    finalCG = videoCG
                }
                let rep = NSBitmapImageRep(cgImage: finalCG)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    Log.project.error("captureCurrentFrameToMedia: png encode failed")
                    return
                }
                guard let mediaAsset = self.importPastedImageData(data, fileExtension: "png") else { return }
                mediaAsset.name = "\(nameBase) \(frame)"
                if let idx = self.mediaManifest.entries.firstIndex(where: { $0.id == mediaAsset.id }) {
                    self.mediaManifest.entries[idx].name = mediaAsset.name
                }
                self.moveAssetsToFolder(assetIds: [mediaAsset.id], folderId: self.mediaPanelCurrentFolderId)
            }
        }
    }

    static func compositeCapture(video: CGImage, textRoot: CALayer, canvas: CGSize) -> CGImage? {
        let width = Int(canvas.width)
        let height = Int(canvas.height)
        let colorSpace = video.colorSpace?.model == .rgb
            ? video.colorSpace!
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        context.draw(video, in: CGRect(origin: .zero, size: canvas))
        // CALayer.render ignores isGeometryFlipped; flip the context to land glyphs upright.
        context.saveGState()
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        textRoot.render(in: context)
        context.restoreGState()
        return context.makeImage()
    }

    func finalizeImportedAsset(_ asset: MediaAsset) async {
        Log.project.notice(
            "media finalize start asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)",
            telemetry: "Media asset finalize started",
            data: ["assetId": Telemetry.shortId(asset.id), "type": asset.type.rawValue]
        )
        await asset.loadMetadata()
        updateManifestMetadata(for: asset)
        refreshMissingMediaCache()
        searchIndex.schedule(asset)
        switch asset.type {
        case .video:
            mediaVisualCache.generateWaveform(for: asset)
            mediaVisualCache.generateVideoThumbnails(for: asset)
        case .audio:
            mediaVisualCache.generateWaveform(for: asset)
        case .image:
            mediaVisualCache.generateImageThumbnail(for: asset)
        case .text, .lottie, .document:
            break
        }
        Log.project.notice(
            "media finalize ok asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)",
            telemetry: "Media asset finalize finished",
            data: [
                "assetId": Telemetry.shortId(asset.id),
                "type": asset.type.rawValue,
                "duration": asset.duration,
                "width": asset.sourceWidth ?? 0,
                "height": asset.sourceHeight ?? 0,
                "fps": asset.sourceFPS ?? 0,
                "hasAudio": asset.hasAudio
            ]
        )
    }

    struct TextClipSpec {
        let trackIndex: Int
        let startFrame: Int
        let durationFrames: Int
        let content: String
        let style: TextStyle
        /// When nil the box is auto-fit to content and centered on the canvas.
        let transform: Transform?
        var captionGroupId: String? = nil
    }

    /// Batch variant of `addTextClip` for agent flows.
    /// Caller owns undo + track creation.
    @discardableResult
    func placeTextClips(_ specs: [TextClipSpec]) -> [String] {
        guard !specs.isEmpty else { return [] }
        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        var createdIds = [String?](repeating: nil, count: specs.count)

        let indicesByTrack = Dictionary(grouping: specs.indices, by: { specs[$0].trackIndex })
        for (_, indices) in indicesByTrack {
            let ordered = indices.sorted { specs[$0].startFrame < specs[$1].startFrame }
            for i in ordered {
                let spec = specs[i]
                guard timeline.tracks.indices.contains(spec.trackIndex) else { continue }
                let start = max(0, spec.startFrame)
                let duration = max(1, spec.durationFrames)
                clearRegion(trackIndex: spec.trackIndex, start: start, end: start + duration, prune: false)

                let resolved: Transform
                if let t = spec.transform {
                    resolved = t
                } else {
                    let natural = TextLayout.naturalSize(
                        content: spec.content, style: spec.style, maxWidth: CGFloat(canvasW) * 0.9, canvasHeight: CGFloat(canvasH)
                    )
                    let w = Double(natural.width) / canvasW
                    let h = Double(natural.height) / canvasH
                    resolved = Transform(topLeft: ((1 - w) / 2, (1 - h) / 2), width: w, height: h)
                }
                var clip = Clip(
                    mediaRef: "",
                    mediaType: .text,
                    sourceClipType: .text,
                    startFrame: start,
                    durationFrames: duration,
                    transform: resolved
                )
                clip.textContent = spec.content
                clip.textStyle = spec.style
                clip.captionGroupId = spec.captionGroupId
                timeline.tracks[spec.trackIndex].clips.append(clip)
                createdIds[i] = clip.id
            }
        }

        for i in Set(specs.map(\.trackIndex)) where timeline.tracks.indices.contains(i) {
            sortClips(trackIndex: i)
        }
        videoEngine?.syncTextLayers()
        return createdIds.compactMap { $0 }
    }

    @discardableResult
    func addTextClip(content: String = "Text", style: TextStyle = TextStyle()) -> String? {
        let durationFrames = max(1, secondsToFrame(seconds: Defaults.textDurationSeconds, fps: timeline.fps))

        // Index 0 is the topmost slot in the timeline UI.
        let trackIdx = insertTrack(at: 0, type: .video)

        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        let natural = TextLayout.naturalSize(content: content, style: style, maxWidth: CGFloat(canvasW) * 0.9, canvasHeight: CGFloat(canvasH))
        let w = Double(natural.width) / canvasW
        let h = Double(natural.height) / canvasH
        let transform = Transform(topLeft: ((1 - w) / 2, (1 - h) / 2), width: w, height: h)

        var clip = Clip(
            mediaRef: "",
            mediaType: .text,
            sourceClipType: .text,
            startFrame: max(0, currentFrame),
            durationFrames: durationFrames,
            transform: transform
        )
        clip.textContent = content
        clip.textStyle = style
        let clipId = clip.id

        timeline.tracks[trackIdx].clips.append(clip)
        sortClips(trackIndex: trackIdx)

        undoManager?.registerUndo(withTarget: self) { vm in
            if let loc = vm.findClip(id: clipId) {
                vm.timeline.tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
                vm.videoEngine?.syncTextLayers()
            }
        }
        undoManager?.setActionName("Add Text")

        selectedClipIds = [clipId]
        videoEngine?.syncTextLayers()
        return clipId
    }
}
