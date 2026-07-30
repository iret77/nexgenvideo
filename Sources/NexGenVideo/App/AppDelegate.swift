import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainThreadHangWatchdog.shared.start()

        // Activate the app (required when launched from CLI, not a .app bundle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Start Sparkle updater
        _ = Updater.shared

        // Splash first (Photoshop pattern), then reveal Home — unless a project already opened
        // (e.g. a document launch), in which case the editor owns the screen.
        SplashScreenController.shared.showAtLaunch {
            if AppState.shared.activeProject == nil {
                HomeWindowController.shared.showWindow(nil)
            }
        }
        Task.detached(priority: .utility) {
            Project.ensureStorageDirectory()
            ProjectStorageMigration.cleanUpProjectsFolder()
            // Retire idle working copies + caches (frees both stores). Open docs and still-present
            // recents are the "keep" set, keyed by each project's package UUID.
            let liveKeys = await MainActor.run { () -> Set<String> in
                // Read-only: never mint an id just to build the keep-set (that would rewrite every recent
                // package at launch). A recent without an id has no UUID-keyed data to spare anyway.
                let recents = ProjectRegistry.shared.entries
                    .filter { $0.isAccessible }
                    .compactMap { ProjectIdentity.existingKey(for: $0.url) }
                let open = NSDocumentController.shared.documents
                    .compactMap { ($0 as? VideoProject)?.fileURL }
                    .compactMap { ProjectIdentity.existingKey(for: $0) }
                return Set(recents + open)
            }
            ProjectWorkingCopy.sweepIdleProjectData(liveKeys: liveKeys)
        }

        AppNotifications.configure()

        AppState.shared.reconcileMCPService()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map(URL.init(fileURLWithPath:))
        Task {
            let reply = await AppState.shared.openProjectsFromSystem(urls)
            sender.reply(toOpenOrPrint: reply)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared.showHome()
        }
        return true
    }

    @MainActor
    @objc func newProject(_ sender: Any?) {
        AppState.shared.createNewProject()
    }

    @MainActor
    @objc func openProject(_ sender: Any?) {
        AppState.shared.openProjectFromPanel()
    }

    @MainActor
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @MainActor
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .shortcuts)
    }

    @MainActor
    @objc func showMCPInstructions(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .mcp)
    }

    @MainActor
    @objc func showFeedback(_ sender: Any?) {
        FeedbackWindowController.shared.show()
    }

    @MainActor
    @objc func revealDiagnostics(_ sender: Any?) {
        let directory = MainThreadHangWatchdog.diagnosticsDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(directory)
    }

    @MainActor
    @objc func showTutorial(_ sender: Any?) {
        guard let editor = AppState.shared.activeProject?.editorViewModel else { return }
        editor.tour.start(in: editor)
    }
}
