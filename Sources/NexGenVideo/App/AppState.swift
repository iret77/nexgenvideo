import SwiftUI
import UniformTypeIdentifiers

struct ProjectOpenOptions {
    var startTutorial = false
}

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    @ObservationIgnored
    private var backendObserver: NSObjectProtocol?

    private(set) var activeProject: VideoProject?

    private(set) var mcpService: MCPService?

    private init() {
        backendObserver = NotificationCenter.default.addObserver(
            forName: .agentBackendChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileMCPService()
            }
        }
    }

    isolated deinit {
        if let backendObserver {
            NotificationCenter.default.removeObserver(backendObserver)
        }
    }

    var isMCPRequiredByAgent: Bool {
        AgentBackendPreference.selected == .claudeCode
    }

    var isMCPEnabled: Bool {
        isMCPRequiredByAgent || MCPService.isEnabledPreference
    }

    func startMCPService() {
        guard mcpService == nil else { return }
        guard isMCPEnabled else {
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
        guard !isMCPRequiredByAgent else { return }
        MCPService.isEnabledPreference = enabled
        reconcileMCPService()
    }

    func setAgentBackend(_ backend: AgentBackend) {
        AgentBackendPreference.set(backend)
        reconcileMCPService()
    }

    func restartMCPService() {
        if let mcpService {
            mcpService.restart()
        } else {
            startMCPService()
        }
    }

    func reconcileMCPService() {
        if isMCPEnabled {
            startMCPService()
        } else {
            stopMCPService()
        }
    }

    /// Return to Home. `persist: true` (a real "go to Home" while the document stays open) saves the
    /// project first, since autosave-in-place is off. `persist: false` is the post-close teardown, where
    /// the Save/Don't-Save review has ALREADY decided — re-saving there fails on the just-released
    /// working copy, and the failed-save alert would block app termination on "Don't Save".
    func showHome(persist: Bool = true) {
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
        if persist, project.isDocumentEdited, let url = project.fileURL {
            // On failure (e.g. the format pack is unavailable), surface it and stay in the editor rather
            // than hiding a project with unsaved work.
            project.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                DispatchQueue.main.async {
                    if let error {
                        NSAlert(error: error).runModal()
                    } else {
                        presentHome()
                    }
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

    func upgradeActiveProjectPack() {
        guard let project = activeProject,
              let projectURL = project.fileURL,
              let workingRoot = project.editorViewModel.workingRoot else { return }
        guard case .bound(let source) = ProjectPluginSettings.bindingResolution(
            projectURL: workingRoot
        ) else {
            notify(
                message: "Save the project before upgrading its format pack",
                informative: "The current pack version must be pinned in the project first."
            )
            return
        }
        if case .bound(let saved) = ProjectPluginSettings.bindingResolution(
            projectURL: projectURL
        ), saved == source {
            schedulePackUpgrade(
                projectURL: projectURL,
                source: source
            )
            return
        }
        project.save(
            to: projectURL,
            ofType: VideoProject.typeIdentifier,
            for: .saveOperation
        ) { error in
            DispatchQueue.main.async {
                if let error {
                    NSAlert(error: error).runModal()
                } else {
                    self.schedulePackUpgrade(
                        projectURL: projectURL,
                        source: source
                    )
                }
            }
        }
    }

    private func schedulePackUpgrade(
        projectURL: URL,
        source: ProjectPackBinding
    ) {
        guard let target = PluginUpdateCenter.shared.targetByID[source.id],
              let installed = PluginLoader.installedInfo(
                  id: target.id,
                  version: target.version
              ),
              installed.info.projectSchema == target.projectSchema,
              target != source else {
            notify(
                message: "No format-pack upgrade is ready",
                informative: "Check Format Packs in Settings for updates."
            )
            return
        }
        if let reason = PluginGate.evaluate(
            info: installed.info,
            appVersion: AppVersion.marketing
        ) ?? PluginSignature.verify(
            bundleURL: installed.url,
            host: PluginSignature.hostSigningState()
        ) {
            notify(
                message: "This format-pack upgrade isn't usable",
                informative: reason.reason
            )
            return
        }
        guard ProjectPackMigration.upgradeKind(
                  source: source,
                  target: target
              ) == .bindingOnly
                || installed.info.migratesFrom.contains(source.projectSchema) else {
            notify(
                message: "This project can't be upgraded automatically",
                informative: "The installed pack doesn't declare a migration from "
                    + "\(source.projectSchema) to \(target.projectSchema)."
            )
            return
        }
        guard confirm(
            message: "Upgrade this project to \(source.id) \(target.version)",
            informative: "NexGenVideo will restart, upgrade a Recovery copy, and keep "
                + "the saved project untouched until you save.",
            action: "Upgrade and Restart"
        ) else { return }
        do {
            let request = try ProjectPackMigration.prepareSchedule(
                projectURL: projectURL,
                source: source,
                target: target
            )
            AppRelaunch.now {
                ProjectPackMigration.commit(request)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
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
        guard let format, !format.isEmpty else {
            presentNewProjectPanel(binding: nil)
            return
        }
        Task {
            let progress = PackInstallProgress(packID: format)
            progress.show()
            defer { progress.close() }
            switch await PluginUpdateCenter.shared.prepareNewProject(packID: format) {
            case .ready(let binding):
                progress.close()
                presentNewProjectPanel(binding: binding)
            case .restartRequired(let binding):
                progress.close()
                offerRestart(binding: binding)
            case .unavailable(let reason):
                progress.close()
                notify(
                    message: "Couldn't prepare the “\(format)” format",
                    informative: reason
                )
            }
        }
    }

    private func presentNewProjectPanel(binding: ProjectPackBinding?) {
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
                do {
                    if let binding {
                        try ProjectPluginSettings.setActivePlugin(
                            binding,
                            projectURL: url
                        )
                    }
                    // A fresh UUID prevents a new project from inheriting a namesake's recovery data.
                    try ProjectIdentity.regenerate(at: url)
                } catch {
                    NSDocumentController.shared.removeDocument(doc)
                    NSAlert(error: error).runModal()
                    return
                }
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

    func openProjectsFromSystem(_ urls: [URL]) async -> NSApplication.DelegateReply {
        var reply: NSApplication.DelegateReply = .success
        for url in urls {
            do {
                if try await openProjectAsync(at: url) == nil {
                    reply = .cancel
                }
            } catch {
                NSAlert(error: error).runModal()
                reply = .failure
            }
        }
        return reply
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
        let doc: VideoProject
        do {
            doc = try await VideoProject.load(from: resolved)
        } catch {
            if ProjectPackMigration.request(for: resolved) != nil {
                if offerPendingUpgradeCancellation(
                    projectURL: resolved,
                    reason: error.localizedDescription
                ) {
                    return try await openProjectAsync(
                        at: resolved,
                        register: register,
                        options: options
                    )
                }
                return nil
            }
            if ProjectPackMigration.legacyTarget(for: resolved) != nil {
                offerLegacyUpgradeCancellation(
                    projectURL: resolved,
                    reason: error.localizedDescription
                )
                return nil
            }
            throw error
        }
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

        case .unreadable:
            notify(
                message: "The project format settings are unreadable",
                informative: "Restore ngv.json from a known-good project version, then open the project again. "
                    + "The project stays closed so its workflow cannot be changed."
            )
            return false

        case .inconsistent(let expected, let resolved):
            notify(
                message: "The project format settings conflict",
                informative: "The project declares “\(expected)” in this session but resolves "
                    + "“\(resolved)” on disk. Restore ngv.json from a known-good project version."
            )
            return false

        case .settingsMissing(let expected):
            notify(
                message: "The project format settings are missing",
                informative: "This session still declares “\(expected)”. Restore ngv.json from "
                    + "a known-good project version, then open the project again."
            )
            return false

        case .needsRestart(let binding):
            if let request = ProjectPackMigration.request(for: projectURL) {
                return resolvePendingUpgradeRestart(
                    request,
                    projectURL: projectURL
                )
            }
            if let target = ProjectPackMigration.legacyTarget(
                for: projectURL
            ) {
                resolveLegacyUpgradeRestart(
                    target,
                    projectURL: projectURL
                )
                return false
            }
            offerRestart(binding: binding)
            return false

        case .legacyMigration(let target):
            guard confirm(
                message: "Upgrade this legacy \(target.id) project",
                informative: "NexGenVideo will migrate a Recovery copy to "
                    + "\(target.projectSchema). The saved project stays untouched until Save.",
                action: "Upgrade"
            ) else { return false }
            do {
                try ProjectPackMigration.scheduleLegacy(
                    projectURL: projectURL,
                    target: target
                )
                return true
            } catch {
                NSAlert(error: error).runModal()
                return false
            }

        case .missing(let id):
            guard confirm(
                message: "Install the “\(id)” format pack",
                informative: "Opening this project without it falls back to the generic workflow — and saving would keep it there.",
                action: "Install") else { return false }
            return await installPack(id: id, version: nil, for: projectURL)

        case .missingVersion(let id, let version):
            guard confirm(
                message: "Install “\(id)” \(version)",
                informative: "This project is pinned to that exact pack version. "
                    + "It stays closed until the version is installed.",
                action: "Install"
            ) else { return false }
            return await installPack(id: id, version: version, for: projectURL)

        case .incompatible(let id, let reason):
            if ProjectPackMigration.request(for: projectURL) != nil {
                return offerPendingUpgradeCancellation(
                    projectURL: projectURL,
                    reason: reason
                )
            }
            if ProjectPackMigration.legacyTarget(for: projectURL) != nil {
                offerLegacyUpgradeCancellation(
                    projectURL: projectURL,
                    reason: reason
                )
                return false
            }
            guard confirm(
                message: "Update the “\(id)” format pack",
                informative: "\(reason) The project stays closed until the pack runs on this build.",
                action: "Update") else { return false }
            return await installPack(id: id, version: nil, for: projectURL)
        }
    }

    private func resolvePendingUpgradeRestart(
        _ request: ProjectPackMigration.Request,
        projectURL: URL
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Finish upgrading this project"
        alert.accessoryView = Self.bodyText(
            "Restart to load \(request.target.id) \(request.target.version), "
                + "or cancel the pending project upgrade."
        )
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel Upgrade")
        alert.addButton(withTitle: "Keep Closed")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AppRelaunch.now {
                PluginLoader.requestVersionForNextLaunch(
                    id: request.target.id,
                    version: request.target.version
                )
            }
            return false
        case .alertSecondButtonReturn:
            return cancelPendingUpgrade(
                projectURL: projectURL,
                source: request.source
            )
        default:
            return false
        }
    }

    private func offerPendingUpgradeCancellation(
        projectURL: URL,
        reason: String
    ) -> Bool {
        guard let request = ProjectPackMigration.request(
            for: projectURL
        ) else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The project upgrade couldn't complete"
        alert.accessoryView = Self.bodyText(
            "\(reason) Cancel the upgrade to return to "
                + "\(request.source.id) \(request.source.version)."
        )
        alert.addButton(withTitle: "Cancel Upgrade")
        alert.addButton(withTitle: "Keep Closed")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }
        return cancelPendingUpgrade(
            projectURL: projectURL,
            source: request.source
        )
    }

    private func resolveLegacyUpgradeRestart(
        _ target: ProjectPackBinding,
        projectURL: URL
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Finish upgrading this legacy project"
        alert.accessoryView = Self.bodyText(
            "Restart to load \(target.id) \(target.version), "
                + "or cancel the pending upgrade."
        )
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel Upgrade")
        alert.addButton(withTitle: "Keep Closed")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AppRelaunch.now {
                PluginLoader.requestVersionForNextLaunch(
                    id: target.id,
                    version: target.version
                )
            }
        case .alertSecondButtonReturn:
            ProjectPackMigration.cancel(projectURL: projectURL)
        default:
            break
        }
    }

    private func offerLegacyUpgradeCancellation(
        projectURL: URL,
        reason: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The legacy project upgrade couldn't complete"
        alert.accessoryView = Self.bodyText(
            "\(reason) The saved legacy project is untouched."
        )
        alert.addButton(withTitle: "Cancel Upgrade")
        alert.addButton(withTitle: "Keep Closed")
        if alert.runModal() == .alertFirstButtonReturn {
            ProjectPackMigration.cancel(projectURL: projectURL)
        }
    }

    private func cancelPendingUpgrade(
        projectURL: URL,
        source: ProjectPackBinding
    ) -> Bool {
        ProjectPackMigration.cancel(projectURL: projectURL)
        switch ProjectPackGate.evaluate(projectURL: projectURL) {
        case .satisfied:
            return true
        case .needsRestart(_):
            offerRestart(binding: source)
        default:
            notify(
                message: "The project upgrade was cancelled",
                informative: "Reopen the project with "
                    + "\(source.id) \(source.version)."
            )
        }
        return false
    }

    /// Fetch + install the pack through the same catalog resolution the plugin picker uses, then
    /// re-run the gate — an install that only lands on disk still can't open the project.
    private func installPack(
        id: String,
        version: String?,
        for projectURL: URL
    ) async -> Bool {
        let progress = PackInstallProgress(packID: id)
        progress.show()
        // Explicit closes keep the panel from floating over an alert; the defer catches a future
        // early return that forgets one.
        defer { progress.close() }

        let manager = PluginManager()
        await manager.refresh()

        let entry = version.flatMap { requiredVersion in
            manager.catalog.first {
                $0.id == id && $0.version == requiredVersion
            }
        } ?? Self.catalogEntry(id: id, rows: manager.rows(activePluginName: nil))
        guard let entry else {
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
        case .unreadable:
            notify(
                message: "The project format settings are unreadable",
                informative: "Restore ngv.json from a known-good project version, then open the project again."
            )
            return false
        case .inconsistent:
            notify(
                message: "The project format settings conflict",
                informative: "Restore ngv.json from a known-good project version, then open the project again."
            )
            return false
        case .settingsMissing:
            notify(
                message: "The project format settings are missing",
                informative: "Restore ngv.json from a known-good project version, then open the project again."
            )
            return false
        case .needsRestart(let binding):
            offerRestart(binding: binding)
            return false
        case .legacyMigration:
            return await ensurePackAvailable(for: projectURL)
        case .missing, .missingVersion, .incompatible:
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

    private func offerRestart(binding: ProjectPackBinding) {
        guard confirm(
            message: "Restart NexGenVideo to load “\(binding.id)”",
            informative: "The pack is installed. A pack's code only goes live in a fresh process.",
            action: "Restart") else { return }
        AppRelaunch.now {
            PluginLoader.requestVersionForNextLaunch(
                id: binding.id,
                version: binding.version
            )
        }
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
        let width = AppTheme.ComponentSize.alertBodyTextWidth
        let style = NSMutableParagraphStyle()
        style.hyphenationFactor = 0
        style.lineBreakMode = .byWordWrapping
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let attributed = NSAttributedString(string: text, attributes: [
            .paragraphStyle: style,
            .font: font,
            .foregroundColor: AppTheme.Text.primary,
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
