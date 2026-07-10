import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

private struct ProjectPackageContents: Sendable {
    var timeline: Timeline
    var manifest: MediaManifest?
    var generationLog: GenerationLog?
}

private struct ProjectPackageSnapshot: Sendable {
    var timeline: Data
    var manifest: Data?
    var generationLog: Data?
    var thumbnail: Data?
    var chatSessionFiles: [(name: String, data: Data)]
    var workingCopyKey: String?
}

final class VideoProject: NSDocument {

    static let typeIdentifier = Project.typeIdentifier

    let editorViewModel = EditorViewModel()

    /// Decoded off-main in read(), applied on main in makeWindowControllers.
    private nonisolated(unsafe) var loadedTimeline: Timeline?
    private nonisolated(unsafe) var loadedManifest: MediaManifest?
    private nonisolated(unsafe) var loadedGenerationLog: GenerationLog?

    /// Captured on main thread before writes may continue off-main.
    private nonisolated(unsafe) var snapshotTimeline: Data?
    private nonisolated(unsafe) var snapshotManifest: Data?
    private nonisolated(unsafe) var snapshotGenerationLog: Data?
    private nonisolated(unsafe) var snapshotThumbnail: Data?
    private nonisolated(unsafe) var snapshotChatSessionFiles: [(name: String, data: Data)] = []
    private nonisolated(unsafe) var snapshotSourceProjectURL: URL?
    private nonisolated(unsafe) var snapshotWorkingCopyKey: String?
    private nonisolated(unsafe) var snapshotPreparedForWrite = false

    // MARK: - Persistence

    override class var autosavesInPlace: Bool { true }

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
        let data = try requiredData(Project.timelineFilename, in: url)
        let timeline: Timeline
        do {
            timeline = try JSONDecoder().decode(Timeline.self, from: data)
        } catch {
            Log.project.error("read: timeline decode failed: \(String(describing: error))")
            throw error
        }

        let manifest: MediaManifest?
        if let manifestData = try optionalData(Project.manifestFilename, in: url) {
            do {
                manifest = try JSONDecoder().decode(MediaManifest.self, from: manifestData)
            } catch {
                Log.project.error("read manifest decode failed bytes=\(manifestData.count) error=\(error)")
                throw CocoaError(.fileReadCorruptFile)
            }
        } else {
            manifest = nil
        }

        let generationLog = try optionalData(Project.generationLogFilename, in: url)
            .flatMap { try? JSONDecoder().decode(GenerationLog.self, from: $0) }

        return ProjectPackageContents(
            timeline: timeline,
            manifest: manifest,
            generationLog: generationLog
        )
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            fileModificationDate = date
        }

        captureSaveSnapshot()
        snapshotSourceProjectURL = fileURL
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
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
        defer {
            snapshotPreparedForWrite = false
            snapshotSourceProjectURL = nil
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
                workingCopyKey: snapshotWorkingCopyKey
            ),
            to: url,
            sourceURL: snapshotSourceProjectURL
        )
    }

    private func captureSaveSnapshot() {
        snapshotTimeline = try? JSONEncoder().encode(editorViewModel.timeline)
        snapshotManifest = try? JSONEncoder().encode(editorViewModel.mediaManifest)
        snapshotGenerationLog = try? JSONEncoder().encode(editorViewModel.generationLog)
        snapshotThumbnail = captureThumbnail()
        snapshotChatSessionFiles = editorViewModel.agentService.sessions
            .filter { !$0.messages.isEmpty }
            .compactMap { session in
                ChatSessionStore.encodeSession(session).map { (name: "\(session.id.uuidString).json", data: $0) }
            }
        snapshotWorkingCopyKey = editorViewModel.workingCopyKey
        snapshotPreparedForWrite = true
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
        let fm = FileManager.default
        try createPackageDirectory(at: packageURL, fm: fm)
        try snapshot.timeline.write(to: packageURL.appendingPathComponent(Project.timelineFilename), options: .atomic)
        if let manifest = snapshot.manifest {
            try manifest.write(to: packageURL.appendingPathComponent(Project.manifestFilename), options: .atomic)
        }
        if let log = snapshot.generationLog {
            try log.write(to: packageURL.appendingPathComponent(Project.generationLogFilename), options: .atomic)
        }
        if let thumbnail = snapshot.thumbnail {
            try thumbnail.write(to: packageURL.appendingPathComponent(Project.thumbnailFilename), options: .atomic)
        } else {
            try copyPreservedFile(Project.thumbnailFilename, from: sourceURL, to: packageURL, fm: fm)
        }
        try writeChatDirectory(snapshot.chatSessionFiles, to: packageURL, fm: fm)
        try copyMediaDirectoryIfNeeded(from: sourceURL, to: packageURL, fm: fm)
        // Carry the active-format marker (ngv.json) across Save As / swap, else a copied pack project
        // reopens as generic while still holding its pack-specific pipeline data.
        try copyPreservedFile(ProjectPluginSettings.filename, from: sourceURL, to: packageURL, fm: fm)
        // Sync the engine's live working copy (bible, shotlist, renders, …) into the package so the
        // project is self-contained. Handles "Save As"/swap too: the pipeline lands in whatever
        // package URL NSDocument is writing to, not just an in-place save.
        if let key = snapshot.workingCopyKey {
            try ProjectWorkingCopy.persist(key: key, to: packageURL)
        }
    }

    private nonisolated static func createPackageDirectory(at url: URL, fm: FileManager) throws {
        var isDirectory = ObjCBool(false)
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
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

    private nonisolated static func copyPreservedFile(_ name: String, from sourceURL: URL?, to packageURL: URL, fm: FileManager) throws {
        guard let sourceURL, !sameFile(sourceURL, packageURL) else { return }
        let source = sourceURL.appendingPathComponent(name, isDirectory: false)
        guard fm.fileExists(atPath: source.path) else { return }
        let destination = packageURL.appendingPathComponent(name, isDirectory: false)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private nonisolated static func copyMediaDirectoryIfNeeded(from sourceURL: URL?, to packageURL: URL, fm: FileManager) throws {
        guard let sourceURL, !sameFile(sourceURL, packageURL) else { return }
        let source = sourceURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        let destination = packageURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        guard fm.fileExists(atPath: source.path) else { return }
        try fm.copyItem(at: source, to: destination)
    }

    private nonisolated static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        editorViewModel.isDocumentEdited = isDocumentEdited
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
                AppState.shared.showHome()
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
        let h = min(max(visible.height * 0.90, floor.height), cap.height, visible.height)
        return NSSize(width: w, height: h)
    }

    /// Shrink + nudge a window frame so it never exceeds or falls off the visible screen.
    nonisolated static func clampToScreen(_ frame: NSRect, visible: NSRect) -> NSRect {
        var f = frame
        f.size.width = min(f.size.width, visible.width)
        f.size.height = min(f.size.height, visible.height)
        f.origin.x = min(max(f.origin.x, visible.minX), visible.maxX - f.size.width)
        f.origin.y = min(max(f.origin.y, visible.minY), visible.maxY - f.size.height)
        return f
    }

    override func makeWindowControllers() {
        if let loaded = loadedTimeline {
            editorViewModel.timeline = loaded
            loadedTimeline = nil
        }
        editorViewModel.applyDefaultWorkspaceFocus()
        editorViewModel.undoManager = undoManager
        editorViewModel.projectURL = fileURL
        editorViewModel.agentService.loadSessions(from: fileURL)
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
        // Autosave "-v2": bumping the key resets stale frames saved before screen-aware sizing.
        let restored = window.setFrameUsingName("NexGenVideoWindow-v2")
        window.setFrameAutosaveName("NexGenVideoWindow-v2")
        // Compute the visible frame AFTER restore so a frame saved on a different or
        // since-changed display clamps against the screen it actually lands on, not the
        // window's initial screen.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Screen-aware minimum: never force the window larger than the desktop it opens on.
        window.minSize = NSSize(width: min(AppTheme.Window.projectMin.width, visible.width),
                                height: min(AppTheme.Window.projectMin.height, visible.height))
        if restored {
            // A frame from a since-changed (larger) display must never exceed this desktop.
            window.setFrame(Self.clampToScreen(window.frame, visible: visible), display: false)
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
        guard let packageURL = fileURL else { return }
        let thumbURL = packageURL.appendingPathComponent(Project.thumbnailFilename, isDirectory: false)
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
