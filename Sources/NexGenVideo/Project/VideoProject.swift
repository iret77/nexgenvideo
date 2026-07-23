import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

private struct ProjectEditableContents: Sendable {
    var timeline: Timeline
    var manifest: MediaManifest?
    var generationLog: GenerationLog?
    var thumbnail: Data?
}

private struct ProjectPackageContents: Sendable {
    var timeline: Timeline
    var manifest: MediaManifest?
    var generationLog: GenerationLog?
    var thumbnail: Data?
    var workingCopyKey: String
    var workingCopy: ProjectWorkingCopy.OpenResult
}

private struct ProjectPackageSnapshot: Sendable {
    var timeline: Data
    var manifest: Data?
    var generationLog: Data?
    var thumbnail: Data?
    var chatSessionFiles: [(name: String, data: Data)]
    var workingCopyKey: String?
    var mintNewIdentity: Bool
}

final class VideoProject: NSDocument {

    static let typeIdentifier = Project.typeIdentifier

    let editorViewModel = EditorViewModel()

    /// Decoded off-main in read(), applied on main in makeWindowControllers.
    private nonisolated(unsafe) var loadedTimeline: Timeline?
    private nonisolated(unsafe) var loadedManifest: MediaManifest?
    private nonisolated(unsafe) var loadedGenerationLog: GenerationLog?
    private nonisolated(unsafe) var loadedThumbnail: Data?
    private nonisolated(unsafe) var loadedWorkingCopyKey: String?
    private nonisolated(unsafe) var loadedWorkingCopy: ProjectWorkingCopy.OpenResult?

    /// Captured on main thread before writes may continue off-main.
    private nonisolated(unsafe) var snapshotTimeline: Data?
    private nonisolated(unsafe) var snapshotManifest: Data?
    private nonisolated(unsafe) var snapshotGenerationLog: Data?
    private nonisolated(unsafe) var snapshotThumbnail: Data?
    private nonisolated(unsafe) var snapshotChatSessionFiles: [(name: String, data: Data)] = []
    private nonisolated(unsafe) var snapshotSourceProjectURL: URL?
    private nonisolated(unsafe) var snapshotWorkingCopyKey: String?
    private nonisolated(unsafe) var snapshotMintNewIdentity = false
    private nonisolated(unsafe) var snapshotPreparedForWrite = false
    private nonisolated(unsafe) var snapshotCaptureError: Error?
    private var checkpointFailurePresented = false

    // MARK: - Persistence

    // Only ⌘S / the close+quit review writes the package (working-copy model, docs/PROJECT_STORAGE.md) —
    // `true` silently rewrote it during editing AND suppressed the standard unsaved-changes prompt.
    override class var autosavesInPlace: Bool { false }

    @MainActor
    static func load(from url: URL) async throws -> VideoProject {
        let contents = try await Task.detached(priority: .userInitiated) {
            try readProjectPackage(at: url)
        }.value
        let doc = VideoProject()
        doc.fileURL = url
        doc.fileType = typeIdentifier
        doc.applyLoadedContents(contents)
        return doc
    }

    override func read(from url: URL, ofType typeName: String) throws {
        applyLoadedContents(try Self.readProjectPackage(at: url))
    }

    private nonisolated func applyLoadedContents(_ contents: ProjectPackageContents) {
        loadedTimeline = contents.timeline
        loadedManifest = contents.manifest
        loadedGenerationLog = contents.generationLog
        loadedThumbnail = contents.thumbnail
        loadedWorkingCopyKey = contents.workingCopyKey
        loadedWorkingCopy = contents.workingCopy
        Log.project.notice(
            "read ok tracks=\(self.loadedTimeline?.tracks.count ?? 0)",
            telemetry: "Project read",
            data: [
                "tracks": loadedTimeline?.tracks.count ?? 0,
                "clips": loadedTimeline?.tracks.reduce(0) { $0 + $1.clips.count } ?? 0,
                "media": loadedManifest?.entries.count ?? 0,
                "hasGenerationLog": loadedGenerationLog != nil
            ]
        )
    }

    private nonisolated static func readProjectPackage(at url: URL) throws -> ProjectPackageContents {
        if ProjectIdentity.existingKey(for: url) == nil {
            try ProjectWorkingCopy.validateForOpen(url)
            _ = try readEditableContents(at: url)
        }
        let key = try ProjectIdentity.key(for: url)
        let workingCopy = try ProjectWorkingCopy.open(key: key, packageURL: url)
        let contents = try readEditableContents(at: workingCopy.home)

        return ProjectPackageContents(
            timeline: contents.timeline,
            manifest: contents.manifest,
            generationLog: contents.generationLog,
            thumbnail: contents.thumbnail,
            workingCopyKey: key,
            workingCopy: workingCopy
        )
    }

    private nonisolated static func readEditableContents(
        at root: URL
    ) throws -> ProjectEditableContents {
        let data = try requiredData(Project.timelineFilename, in: root)
        let timeline: Timeline
        do {
            timeline = try JSONDecoder().decode(Timeline.self, from: data)
        } catch {
            Log.project.error("read: timeline decode failed: \(String(describing: error))")
            throw error
        }

        let manifest: MediaManifest?
        if let manifestData = try optionalData(Project.manifestFilename, in: root) {
            do {
                manifest = try JSONDecoder().decode(MediaManifest.self, from: manifestData)
            } catch {
                Log.project.error("read manifest decode failed bytes=\(manifestData.count) error=\(error)")
                throw CocoaError(.fileReadCorruptFile)
            }
        } else {
            manifest = nil
        }

        let generationLog: GenerationLog?
        if let logData = try optionalData(Project.generationLogFilename, in: root) {
            do {
                generationLog = try JSONDecoder().decode(
                    GenerationLog.self,
                    from: logData
                )
            } catch {
                Log.project.error(
                    "read generation log decode failed bytes=\(logData.count) error=\(error)"
                )
                throw CocoaError(.fileReadCorruptFile)
            }
        } else {
            generationLog = nil
        }
        _ = try ChatSessionStore.loadThrowing(from: root)
        let thumbnail = try optionalData(Project.thumbnailFilename, in: root)

        return ProjectEditableContents(
            timeline: timeline,
            manifest: manifest,
            generationLog: generationLog,
            thumbnail: thumbnail
        )
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        // Backstop for any path that reaches an open document without its format pack — the Home
        // window and the Open panel are gated in `AppState`, but a Finder double-click goes straight
        // through NSDocumentController. Without its pack the session runs on the GENERIC phase set
        // (musicvideo's analysis phase simply absent), so writing that shape over the package would
        // normalize a project the user can no longer tell was damaged. Refuse instead: the package on
        // disk stays the last good one, and the banner already says the workflow is inactive.
        if Thread.isMainThread, let blocked = MainActor.assumeIsolated({ packUnavailable(savingTo: url) }) {
            completionHandler(blocked)
            return
        }
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            fileModificationDate = date
        }

        captureSaveSnapshot()
        if let snapshotCaptureError {
            completionHandler(snapshotCaptureError)
            return
        }
        snapshotSourceProjectURL = fileURL
        snapshotMintNewIdentity = saveOperation == .saveAsOperation || saveOperation == .saveToOperation
        let savedWorkingCopyKey = snapshotWorkingCopyKey
        let clearsWorkingCopy = saveOperation != .saveToOperation
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            if error == nil, clearsWorkingCopy, let savedWorkingCopyKey {
                ProjectWorkingCopy.markSaved(key: savedWorkingCopyKey)
            }
            completionHandler(error)
        }
    }

    /// The project's format pack must be ACTIVE before its package may be rewritten. Anything other
    /// than `.satisfied` — not installed, refused by the load gate, or an update awaiting relaunch —
    /// means the session is running on the generic phase set, and persisting that shape would quietly
    /// reshape the project.
    @MainActor
    private func packUnavailable(savingTo url: URL) -> Error? {
        switch ProjectPackGate.evaluate(
            projectURL: editorViewModel.workingRoot ?? fileURL ?? url
        ) {
        case .satisfied:
            return nil
        case .missing(let id), .needsRestart(let id):
            return PackUnavailableError(packID: id, detail: nil)
        case .incompatible(let id, let reason):
            return PackUnavailableError(packID: id, detail: reason)
        }
    }

    override func write(to url: URL, ofType typeName: String) throws {
        if !snapshotPreparedForWrite {
            guard Thread.isMainThread else {
                Log.project.error("save: snapshot not prepared for off-main write()")
                throw CocoaError(.fileWriteUnknown)
            }
            MainActor.assumeIsolated {
                captureSaveSnapshot()
                snapshotSourceProjectURL = fileURL
            }
        }
        if let snapshotCaptureError {
            throw snapshotCaptureError
        }
        defer {
            snapshotPreparedForWrite = false
            snapshotSourceProjectURL = nil
            snapshotMintNewIdentity = false
        }
        guard let data = snapshotTimeline else {
            Log.project.error("save: snapshotTimeline missing at write()")
            throw CocoaError(.fileWriteUnknown)
        }

        try Self.writeProjectPackage(
            ProjectPackageSnapshot(
                timeline: data,
                manifest: snapshotManifest,
                generationLog: snapshotGenerationLog,
                thumbnail: snapshotThumbnail,
                chatSessionFiles: snapshotChatSessionFiles,
                workingCopyKey: snapshotWorkingCopyKey,
                mintNewIdentity: snapshotMintNewIdentity
            ),
            to: url,
            sourceURL: snapshotSourceProjectURL
        )
    }

    private func captureSaveSnapshot() {
        do {
            snapshotTimeline = try JSONEncoder().encode(editorViewModel.timeline)
            snapshotManifest = try JSONEncoder().encode(editorViewModel.mediaManifest)
            snapshotGenerationLog = try JSONEncoder().encode(editorViewModel.generationLog)
            var chatFiles: [(name: String, data: Data)] = []
            for session in editorViewModel.agentService.sessions where !session.messages.isEmpty {
                guard let data = ChatSessionStore.encodeSession(session) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                chatFiles.append((name: "\(session.id.uuidString).json", data: data))
            }
            snapshotChatSessionFiles = chatFiles
            snapshotThumbnail = captureThumbnail()
            snapshotCaptureError = nil
        } catch {
            snapshotCaptureError = error
        }
        snapshotWorkingCopyKey = editorViewModel.openWorkingCopyKey
        if snapshotWorkingCopyKey == nil, editorViewModel.projectURL != nil {
            snapshotCaptureError = ProjectWorkingCopy.PersistError.noWorkingCopy(
                key: editorViewModel.workingCopyKey ?? "unknown"
            )
        }
        snapshotPreparedForWrite = true
    }

    private func checkpointWorkingCopy() {
        guard let key = editorViewModel.openWorkingCopyKey else { return }
        do {
            var chatFiles: [(name: String, data: Data)] = []
            for session in editorViewModel.agentService.sessions where !session.messages.isEmpty {
                guard let data = ChatSessionStore.encodeSession(session) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                chatFiles.append((name: "\(session.id.uuidString).json", data: data))
            }
            let snapshot = ProjectWorkingCopy.Checkpoint(
                timeline: try JSONEncoder().encode(editorViewModel.timeline),
                manifest: try JSONEncoder().encode(editorViewModel.mediaManifest),
                generationLog: try JSONEncoder().encode(editorViewModel.generationLog),
                thumbnail: cachedThumbnail,
                chatSessionFiles: chatFiles
            )
            try ProjectWorkingCopy.checkpoint(key: key, snapshot: snapshot)
            checkpointFailurePresented = false
        } catch {
            Log.project.error("working-copy checkpoint failed: \(error.localizedDescription)")
            if !checkpointFailurePresented {
                checkpointFailurePresented = true
                presentError(error)
            }
        }
    }

    private nonisolated static func requiredData(_ name: String, in packageURL: URL) throws -> Data {
        do {
            return try Data(contentsOf: packageURL.appendingPathComponent(name, isDirectory: false), options: [.mappedIfSafe])
        } catch {
            Log.project.error("read: missing \(name) in package")
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private nonisolated static func optionalData(_ name: String, in packageURL: URL) throws -> Data? {
        let url = packageURL.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private nonisolated static func writeProjectPackage(_ snapshot: ProjectPackageSnapshot, to packageURL: URL, sourceURL: URL?) throws {
        if let key = snapshot.workingCopyKey {
            try ProjectWorkingCopy.checkpoint(
                key: key,
                snapshot: ProjectWorkingCopy.Checkpoint(
                    timeline: snapshot.timeline,
                    manifest: snapshot.manifest,
                    generationLog: snapshot.generationLog,
                    thumbnail: snapshot.thumbnail,
                    chatSessionFiles: snapshot.chatSessionFiles
                )
            )
            try ProjectWorkingCopy.persist(
                key: key,
                to: packageURL,
                mintNewIdentity: snapshot.mintNewIdentity
            )
            return
        }

        let fm = FileManager.default
        let parent = packageURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(packageURL.lastPathComponent).save-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: staging) }
        if let sourceURL, !sameFile(sourceURL, packageURL) {
            try fm.copyItem(at: sourceURL, to: staging)
            try ProjectWorkingCopy.sanitizePackageStaging(staging, fm: fm)
        } else {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        try snapshot.timeline.write(
            to: staging.appendingPathComponent(Project.timelineFilename),
            options: .atomic
        )
        if let manifest = snapshot.manifest {
            try manifest.write(
                to: staging.appendingPathComponent(Project.manifestFilename),
                options: .atomic
            )
        }
        if let log = snapshot.generationLog {
            try log.write(
                to: staging.appendingPathComponent(Project.generationLogFilename),
                options: .atomic
            )
        }
        if let thumbnail = snapshot.thumbnail {
            try thumbnail.write(
                to: staging.appendingPathComponent(Project.thumbnailFilename),
                options: .atomic
            )
        }
        try writeChatDirectory(snapshot.chatSessionFiles, to: staging, fm: fm)
        if snapshot.mintNewIdentity {
            let oldKey = ProjectIdentity.existingKey(for: staging)
            try ProjectIdentity.regenerate(at: staging)
            guard let newKey = ProjectIdentity.existingKey(for: staging),
                  newKey != oldKey else {
                throw ProjectWorkingCopy.PersistError.identityNotRegenerated
            }
        }
        try ProjectWorkingCopy.commitStagedPackage(staging, to: packageURL, fm: fm)
    }

    private nonisolated static func writeChatDirectory(_ files: [(name: String, data: Data)], to packageURL: URL, fm: FileManager) throws {
        let chatURL = packageURL.appendingPathComponent(ChatSessionStore.dirName, isDirectory: true)
        if fm.fileExists(atPath: chatURL.path) {
            try fm.removeItem(at: chatURL)
        }
        try fm.createDirectory(at: chatURL, withIntermediateDirectories: true)
        for file in files {
            try file.data.write(to: chatURL.appendingPathComponent(file.name, isDirectory: false), options: .atomic)
        }
    }

    private nonisolated static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        editorViewModel.isDocumentEdited = isDocumentEdited
        if change == .changeDone || change == .changeUndone || change == .changeRedone {
            checkpointWorkingCopy()
        }
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        editorViewModel.isDocumentEdited = isDocumentEdited
    }

    override var displayName: String! {
        get { fileURL?.deletingPathExtension().lastPathComponent ?? Project.defaultProjectName }
        set { super.displayName = newValue }
    }

    override var fileURL: URL? {
        get { super.fileURL }
        set {
            let oldURL = super.fileURL
            super.fileURL = newValue
            if let oldURL, let newURL = newValue,
               oldURL.standardizedFileURL != newURL.standardizedFileURL {
                MainActor.assumeIsolated {
                    ProjectRegistry.shared.updateURL(from: oldURL, to: newURL)
                    // Save As retargets the whole project: re-point the editor at the new package so
                    // media destinations and the working-copy key follow it (fileURL changes AFTER
                    // write(), so the new package already holds the just-persisted pipeline), then
                    // retire the old location's working copy.
                    // Save-As leaves the old package in place (its id is still readable → discard the now-
                    // orphaned copy). A move/rename leaves nothing at oldURL, so existingKey is nil and we
                    // discard nothing — the live copy stays under the unchanged UUID key.
                    let oldKey = ProjectIdentity.existingKey(for: oldURL)
                    editorViewModel.projectURL = newURL
                    editorViewModel.agentService.loadSessions(
                        from: editorViewModel.workingCopyHome
                    )
                    if let oldKey,
                       let activeKey = editorViewModel.openWorkingCopyKey,
                       activeKey == editorViewModel.workingCopyKey,
                       oldKey != activeKey {
                        ProjectWorkingCopy.discard(key: oldKey)
                    }
                }
            }
        }
    }

    // MARK: - Close

    override func close() {
        // Clean close (any save/don't-save prompt already resolved) → drop the working copy so the next
        // launch doesn't mistake it for crash-surviving unsaved work.
        editorViewModel.releaseWorkingCopy()
        super.close()
        DispatchQueue.main.async {
            if AppState.shared.activeProject === self {
                // The review already resolved save/don't-save — navigate Home WITHOUT re-saving (a save
                // here fails on the released working copy and its alert would block app termination).
                AppState.shared.showHome(persist: false)
            }
        }
    }

    // MARK: - Window setup

    /// First-launch default: a fraction of the VISIBLE screen (menu bar + Dock excluded), capped at
    /// `projectDefault` on big displays and floored at `projectMin`, ~16:10 — enough height for the
    /// timeline + panels while always fitting the desktop.
    nonisolated static func defaultProjectContentSize(visible: NSRect) -> NSSize {
        let cap = AppTheme.Window.projectDefault
        let floor = AppTheme.Window.projectMin
        // The visible frame is a hard ceiling: on a desktop smaller than `projectMin`
        // the floor would otherwise push the window past the screen edge.
        let w = min(max(visible.width * 0.88, floor.width), cap.width, visible.width)
        let h = min(max(visible.height * 0.92, floor.height), cap.height, visible.height)
        return NSSize(width: w, height: h)
    }

    /// Shrink + nudge a window frame so it never exceeds or falls off the visible screen.
    nonisolated static func clampToScreen(_ frame: NSRect, visible: NSRect) -> NSRect {
        WindowGeometry.clampToScreen(frame, visible: visible)
    }

    override func makeWindowControllers() {
        cachedThumbnail = loadedThumbnail
        loadedThumbnail = nil
        if let loaded = loadedTimeline {
            editorViewModel.timeline = loaded
            loadedTimeline = nil
        }
        editorViewModel.applyDefaultWorkspaceFocus()
        editorViewModel.undoManager = undoManager
        if let loadedWorkingCopyKey, let loadedWorkingCopy, let fileURL {
            editorViewModel.adoptWorkingCopy(
                loadedWorkingCopy,
                key: loadedWorkingCopyKey,
                packageURL: fileURL
            )
            self.loadedWorkingCopyKey = nil
            self.loadedWorkingCopy = nil
        } else {
            editorViewModel.projectURL = fileURL
        }
        editorViewModel.agentService.loadSessions(from: editorViewModel.workingCopyHome)
        editorViewModel.onWorkingCopyReset = { [weak self] home in
            self?.reloadEditableContents(from: home)
        }
        editorViewModel.agentService.onSessionsChanged = { [weak self] in
            self?.updateChangeCount(.changeDone)
        }
        // A pipeline change lives only in the working copy until saved — mark the document edited so
        // ⌘S persists it into the package and the user is warned before closing without saving.
        editorViewModel.onPipelineChanged = { [weak self] in
            self?.updateChangeCount(.changeDone)
        }

        let editorView = EditorWindowContentView()
            .environment(editorViewModel)
        let hostingController = NSHostingController(rootView: editorView.tint(AppTheme.Accent.primary))
        // fullSizeContentView adds a titlebar-height safe-area inset; without dropping it the layout
        // slides down a full row (an empty strip above TitleBarView, panel headers hidden behind it).
        // TitleBarView must occupy the real titlebar row — traffic lights overlay its leading inset.
        hostingController.safeAreaRegions = []

        let window = NSWindow(contentViewController: hostingController)
        // Autosave "-v4": bumping the key discards stale too-short frames saved by an earlier build, so
        // the tall default (92% of the visible screen) applies again on next launch. A saved frame always
        // wins over a changed default — bumping the key is the only way to retire a bad one.
        let restored = window.setFrameUsingName("NexGenVideoWindow-v4")
        window.setFrameAutosaveName("NexGenVideoWindow-v4")
        // Compute the visible frame AFTER restore so a frame saved on a different or
        // since-changed display clamps against the screen it actually lands on, not the
        // window's initial screen.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Screen-aware minimum: never force the window larger than the desktop it opens on.
        window.minSize = NSSize(width: min(AppTheme.Window.projectMin.width, visible.width),
                                height: min(AppTheme.Window.projectMin.height, visible.height))
        if restored {
            window.setFrame(
                WindowGeometry.restoredFrame(window.frame, minimum: window.minSize, visible: visible),
                display: false
            )
        } else {
            window.setContentSize(Self.defaultProjectContentSize(visible: visible))
            window.center()
        }
        window.appearance = NSAppearance(named: .darkAqua)
        // FCP-style chrome: hide the system title, extend content beneath the transparent titlebar —
        // TitleBarView owns that row (name · Edit|Produce · pipeline health).
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // Background-drag fought the timeline: dragging a clip also dragged the whole window (both
        // moved at once). The window still drags by its transparent titlebar row.
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(AppTheme.Background.surfaceColor)

        let controller = EditorWindowController(editorViewModel: editorViewModel, window: window)
        controller.shouldCascadeWindows = true
        controller.installKeyMonitor()
        addWindowController(controller)

        window.standardWindowButton(.documentIconButton)?.isHidden = true

        AppState.shared.showEditor(for: self)

        if let manifest = loadedManifest {
            editorViewModel.mediaManifest = manifest
            loadedManifest = nil
            restoreAssetsFromManifest()
        }
        if let log = loadedGenerationLog {
            editorViewModel.generationLog = log
            loadedGenerationLog = nil
        } else {
            editorViewModel.seedGenerationLogFromAssets()
        }
        editorViewModel.searchIndex.projectOpened()
        editorViewModel.updateTelemetryContext()
        Telemetry.breadcrumb(
            "Project opened",
            category: "project",
            data: editorViewModel.telemetrySnapshot()
        )
    }

    private func reloadEditableContents(from home: URL) {
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.readEditableContents(at: home) }
            }.value
            guard let self, self.editorViewModel.workingCopyHome == home else { return }
            switch result {
            case .success(let contents):
                self.editorViewModel.timeline = contents.timeline
                self.editorViewModel.mediaManifest = contents.manifest ?? MediaManifest()
                self.editorViewModel.generationLog = contents.generationLog ?? GenerationLog()
                self.cachedThumbnail = contents.thumbnail
                self.editorViewModel.agentService.loadSessions(from: home)
                self.editorViewModel.mediaAssets.removeAll()
                self.restoreAssetsFromManifest()
            case .failure(let error):
                Log.project.error(
                    "discard recovery reload failed: \(error.localizedDescription)"
                )
                self.presentError(error)
            }
        }
    }

    // MARK: - Thumbnail

    private var cachedThumbnail: Data?
    private var thumbnailInFlight = false
    private nonisolated static let thumbnailMaxPixelSize = 640

    private func captureThumbnail() -> Data? {
        if let cached = cachedThumbnail { return cached }
        guard !thumbnailInFlight else { return nil }
        thumbnailInFlight = true
        Task { [weak self] in
            await self?.generateThumbnail()
        }
        return nil
    }

    /// Picks the first usable video-track clip and generates a jpeg
    private func generateThumbnail() async {
        defer { thumbnailInFlight = false }

        struct Candidate { let url: URL; let isVideo: Bool; let trimStartFrame: Int }
        var candidates: [Candidate] = []
        for track in editorViewModel.timeline.tracks where track.type == .video {
            for clip in track.clips {
                guard clip.mediaType == .image || clip.mediaType == .video,
                      let url = editorViewModel.mediaResolver.expectedURL(for: clip.mediaRef) else { continue }
                candidates.append(Candidate(
                    url: url,
                    isVideo: clip.mediaType == .video,
                    trimStartFrame: clip.trimStartFrame
                ))
            }
        }
        let fps = editorViewModel.timeline.fps
        guard !candidates.isEmpty else { return }

        let maxPixelSize = Self.thumbnailMaxPixelSize
        let data: Data? = await Task.detached(priority: .utility) {
            for candidate in candidates {
                if candidate.isVideo {
                    // Async `loadTracks` / `image(at:)` — no blocking semaphore wait.
                    let asset = AVURLAsset(url: candidate.url)
                    guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { continue }
                    let generator = AVAssetImageGenerator(asset: asset)
                    // Aspect-preserving box; frame is ~640px on the long edge.
                    generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                    generator.appliesPreferredTrackTransform = true
                    let time = CMTime(value: CMTimeValue(candidate.trimStartFrame), timescale: CMTimeScale(max(fps, 1)))
                    guard let cgImage = try? await generator.image(at: time).image else { continue }
                    return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                } else if let image = ImageEncoder.thumbnail(url: candidate.url, maxPixelSize: maxPixelSize),
                          let data = ImageEncoder.encodeJPEG(image, quality: 0.7) {
                    return data
                }
            }
            return nil
        }.value

        guard let data else { return }
        cachedThumbnail = data
        guard let workingCopyHome = editorViewModel.workingCopyHome else { return }
        let thumbURL = workingCopyHome.appendingPathComponent(
            Project.thumbnailFilename,
            isDirectory: false
        )
        try? await Task.detached(priority: .utility) {
            try data.write(to: thumbURL, options: .atomic)
        }.value
    }

    // MARK: - Media restore

    private func restoreAssetsFromManifest() {
        let cache = editorViewModel.mediaVisualCache
        let resolver = editorViewModel.mediaResolver
        var restored = 0
        var missing = 0
        var missingRefs: Set<String> = []
        for entry in editorViewModel.mediaManifest.entries {
            guard let url = resolver.expectedURL(for: entry.id) else {
                Log.project.warning("restore: could not resolve URL for entry id=\(entry.id) name=\(entry.name)")
                missing += 1
                missingRefs.insert(entry.id)
                continue
            }
            let asset = MediaAsset(entry: entry, resolvedURL: url)
            editorViewModel.mediaAssets.append(asset)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Log.project.warning("restore: media file missing id=\(entry.id) name=\(entry.name) path=\(url.path)")
                missing += 1
                missingRefs.insert(entry.id)
                continue
            }
            restored += 1
            if asset.type == .audio || asset.type == .video {
                cache.generateWaveform(for: asset)
            }
            if asset.type == .video {
                cache.generateVideoThumbnails(for: asset)
            }
            if asset.type == .image {
                cache.generateImageThumbnail(for: asset)
            }
            Task { await asset.loadMetadata() }
        }
        editorViewModel.missingMediaRefs = missingRefs
        Log.project.notice(
            "restore ok restored=\(restored) missing=\(missing)",
            telemetry: "Media restored",
            data: ["restored": restored, "missing": missing, "manifestEntries": editorViewModel.mediaManifest.entries.count]
        )
    }
}
