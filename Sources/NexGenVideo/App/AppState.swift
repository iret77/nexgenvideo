import SwiftUI
import UniformTypeIdentifiers

struct ProjectOpenOptions {
    var startTutorial = false
}

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    private(set) var activeProject: VideoProject?

    private(set) var mcpService: MCPService?

    func startMCPService() {
        guard mcpService == nil else { return }
        guard MCPService.isEnabledPreference else {
            Log.mcp.notice("mcp disabled in settings; not starting")
            return
        }
        let service = MCPService(editorProvider: { [weak self] in
            self?.activeProject?.editorViewModel
        })
        service.start()
        mcpService = service
    }

    func stopMCPService() {
        mcpService?.stop()
        mcpService = nil
    }

    func setMCPEnabled(_ enabled: Bool) {
        MCPService.isEnabledPreference = enabled
        if enabled {
            startMCPService()
        } else {
            stopMCPService()
        }
    }

    func showHome() {
        guard let project = activeProject else {
            HomeWindowController.shared.showWindow(nil)
            return
        }
        let presentHome = {
            if let url = project.fileURL {
                ProjectRegistry.shared.register(url)
            }
            project.windowControllers.forEach { $0.window?.orderOut(nil) }
            if self.activeProject === project {
                self.activeProject = nil
            }
            HomeWindowController.shared.showWindow(nil)
        }
        if project.isDocumentEdited {
            project.autosave(withImplicitCancellability: false) { _ in
                DispatchQueue.main.async {
                    presentHome()
                }
            }
        } else {
            presentHome()
        }
    }

    func showEditor(for project: VideoProject) {
        activeProject = project
        HomeWindowController.shared.window?.orderOut(nil)
        project.showWindows()
    }

    func revealGeneratedAssetFromNotification(assetId: String?, projectURL: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let project = notificationTargetProject(assetId: assetId, projectURL: projectURL) else {
            if activeProject == nil {
                HomeWindowController.shared.showWindow(nil)
            }
            return
        }

        activeProject = project
        HomeWindowController.shared.window?.orderOut(nil)
        project.showWindows()
        project.windowControllers.first?.window?.makeKeyAndOrderFront(nil)

        guard let assetId,
              let asset = project.editorViewModel.mediaAssets.first(where: { $0.id == assetId }) else {
            return
        }

        let editor = project.editorViewModel
        editor.mediaPanelVisible = true
        editor.maximizedPanel = nil
        editor.focusedPanel = .media
        editor.selectMediaAsset(asset)
        editor.mediaPanelRevealAssetId = assetId
    }

    private func notificationTargetProject(assetId: String?, projectURL: URL?) -> VideoProject? {
        let openProjects = NSDocumentController.shared.documents.compactMap { $0 as? VideoProject }
        if let projectURL {
            return openProjects.first { Self.sameFile($0.fileURL, projectURL) }
        }
        if let assetId {
            return openProjects.first { project in
                project.editorViewModel.mediaAssets.contains { $0.id == assetId }
            }
        }
        return activeProject
    }

    private static func sameFile(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    // MARK: - Project lifecycle

    /// `format` is the chosen pack id (nil = generic), picked at the Welcome step. The editor reads the
    /// active format when its `projectURL` is set (in `makeWindowControllers`), so the package must be
    /// saved and `ngv.json` written BEFORE the windows are made — otherwise the project would open
    /// generic regardless of the choice. Hence: save → set format → show windows.
    func createNewProject(format: String? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectContentType]
        panel.nameFieldStringValue = Project.defaultProjectName
        panel.directoryURL = Project.storageDirectory
        panel.title = "New Project"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let doc = VideoProject()
            doc.fileURL = url
            doc.fileType = VideoProject.typeIdentifier
            NSDocumentController.shared.addDocument(doc)
            doc.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                if let error {
                    // Don't leave a hidden, window-less document registered — drop it and surface why.
                    NSDocumentController.shared.removeDocument(doc)
                    NSAlert(error: error).runModal()
                    return
                }
                if let format, !format.isEmpty {
                    ProjectPluginSettings.setActivePlugin(format, projectURL: url)
                }
                // Stamp a brand-new identity so this project can never share a working copy with a
                // deleted namesake that once lived at the same path — the whole class of "new project
                // inherited an old analysis" bug is closed at the source by a unique UUID.
                ProjectIdentity.regenerate(at: url)
                ProjectRegistry.shared.register(url)
                doc.makeWindowControllers()
                doc.showWindows()
            }
        }
    }

    func openProject(at url: URL, register: Bool = true, options: ProjectOpenOptions = .init()) {
        Task {
            do {
                try await openProjectAsync(at: url, register: register, options: options)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Returns nil when the project's format pack isn't available and the user didn't install it —
    /// the open is abandoned deliberately, so the caller must not treat it as an error.
    @discardableResult
    private func openProjectAsync(at url: URL, register: Bool = true, options: ProjectOpenOptions = .init()) async throws -> VideoProject? {
        let resolved = url.standardizedFileURL
        if let existing = showExistingProject(at: resolved, register: register, options: options) {
            return existing
        }
        // Before the document exists: a pack project opened without its pack would come up generic
        // and could be SAVED that way, normalizing it to the wrong shape.
        guard await ensurePackAvailable(for: resolved) else { return nil }
        let doc = try await VideoProject.load(from: resolved)
        if let existing = showExistingProject(at: resolved, register: register, options: options) {
            return existing
        }

        doc.makeWindowControllers()
        doc.showWindows()
        NSDocumentController.shared.addDocument(doc)
        if register { ProjectRegistry.shared.register(resolved) }
        apply(options, to: doc.editorViewModel)
        return doc
    }

    private func showExistingProject(at url: URL, register: Bool, options: ProjectOpenOptions) -> VideoProject? {
        if let existing = NSDocumentController.shared.documents
            .compactMap({ $0 as? VideoProject })
            .first(where: { Self.sameFile($0.fileURL, url) }) {
            showEditor(for: existing)
            if register { ProjectRegistry.shared.register(url) }
            apply(options, to: existing.editorViewModel)
            return existing
        }
        return nil
    }

    private func apply(_ options: ProjectOpenOptions, to editor: EditorViewModel) {
        if options.startTutorial {
            DispatchQueue.main.async { editor.tour.start(in: editor) }
        }
    }

    // MARK: - Format-pack gate

    /// Make sure the project's declared pack is live, offering to fetch it when it isn't. Returns
    /// false when the project must stay closed — declining is a plain choice, not an error.
    private func ensurePackAvailable(for projectURL: URL) async -> Bool {
        switch ProjectPackGate.evaluate(projectURL: projectURL) {
        case .satisfied:
            return true

        case .needsRestart(let id):
            offerRestart(id: id)
            return false

        case .missing(let id):
            guard confirm(
                message: "Install the “\(id)” format pack",
                informative: "Opening this project without it falls back to the generic workflow — and saving would keep it there.",
                action: "Install") else { return false }
            return await installPack(id: id, for: projectURL)

        case .incompatible(let id, let reason):
            guard confirm(
                message: "Update the “\(id)” format pack",
                informative: "\(reason) The project stays closed until the pack runs on this build.",
                action: "Update") else { return false }
            return await installPack(id: id, for: projectURL)
        }
    }

    /// Fetch + install the pack through the same catalog resolution the plugin picker uses, then
    /// re-run the gate — an install that only lands on disk still can't open the project.
    private func installPack(id: String, for projectURL: URL) async -> Bool {
        let progress = PackInstallProgress(packID: id)
        progress.show()
        // Explicit closes keep the panel from floating over an alert; the defer catches a future
        // early return that forgets one.
        defer { progress.close() }

        let manager = PluginManager()
        await manager.refresh()

        guard let entry = Self.catalogEntry(id: id, rows: manager.rows(activePluginName: nil)) else {
            progress.close()
            notify(message: "Couldn't install the “\(id)” format pack",
                   informative: manager.catalogState == .offline
                       ? "The plugin library is unreachable. Reconnect, then open the project again."
                       : "It isn't in the plugin library for this version of NexGenVideo.")
            return false
        }
        guard await manager.install(entry) else {
            progress.close()
            notify(message: "Couldn't install the “\(id)” format pack",
                   informative: manager.lastError ?? "The install didn't complete.")
            return false
        }
        progress.close()

        switch ProjectPackGate.evaluate(projectURL: projectURL) {
        case .satisfied:
            return true
        case .needsRestart:
            offerRestart(id: id)
            return false
        case .missing, .incompatible:
            notify(message: "Couldn't install the “\(id)” format pack",
                   informative: "It installed but didn't come online. Restart NexGenVideo and open the project again.")
            return false
        }
    }

    /// The catalog entry to install for `id`, reusing the picker's merged rows (version selection,
    /// app-version gate, update detection) instead of re-deriving any of it.
    private static func catalogEntry(id: String, rows: [PluginRow]) -> PluginCatalog.Entry? {
        guard let status = rows.first(where: { $0.id == id })?.status else { return nil }
        switch status {
        case .available(let entry): return entry
        case .incompatible(_, let reinstall): return reinstall
        // Installed yet not live (the gate sent us here) — only a newer build can change that.
        case .installed(_, let update): return update
        case .updatePendingRestart, .unavailable: return nil
        }
    }

    private func offerRestart(id: String) {
        guard confirm(
            message: "Restart NexGenVideo to load “\(id)”",
            informative: "The pack is installed. A pack's code only goes live in a fresh process.",
            action: "Restart") else { return }
        AppRelaunch.now()
    }

    private func confirm(message: String, informative: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.accessoryView = Self.bodyText(informative)
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The alert body as a label we own. `NSAlert.informativeText` hyphenates, which chops identifiers
    /// mid-word ("musi-cvideo") — unacceptable for a name the user has to recognize and retype.
    /// Hyphenation off, wrap on word boundaries only.
    static func bodyText(_ text: String) -> NSView {
        let width: CGFloat = 240
        let style = NSMutableParagraphStyle()
        style.hyphenationFactor = 0
        style.lineBreakMode = .byWordWrapping
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let attributed = NSAttributedString(string: text, attributes: [
            .paragraphStyle: style,
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        let label = NSTextField(labelWithAttributedString: attributed)
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.preferredMaxLayoutWidth = width
        let height = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        label.frame = NSRect(x: 0, y: 0, width: width, height: ceil(height))
        return label
    }

    private func notify(message: String, informative: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.accessoryView = Self.bodyText(informative)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func openProjectFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectContentType]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open Project"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            AppState.shared.openProject(at: url)
        }
    }

    private static let projectContentType: UTType = {
        UTType(Project.typeIdentifier)
            ?? UTType(filenameExtension: Project.fileExtension, conformingTo: .package)
            ?? .package
    }()

}
