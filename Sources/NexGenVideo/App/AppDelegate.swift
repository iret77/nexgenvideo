import AppKit
import NexGenEngine

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainThreadHangWatchdog.shared.start()
        AppRelaunchSelfTest.checkpoint("delegate-started")

        // Activate the app (required when launched from CLI, not a .app bundle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppRelaunchSelfTest.checkpoint("app-activated")

        // Start Sparkle updater
        _ = Updater.shared
        AppRelaunchSelfTest.checkpoint("updater-ready")
        BpyRuntimeSelfTest.scheduleIfRequested()
        let isRelaunchSelfTest = AppRelaunchSelfTest.isRequested
        let relaunchIntent = AppRelaunchIntentStore.consumeForLaunch(
            isSelfTest: isRelaunchSelfTest || ExportActionsSelfTest.isRequested
        )
        if ExportActionsSelfTest.isRequested {
            ExportActionsSelfTest.armWatchdog()
            Task { @MainActor in
                await Task.yield()
                await ExportActionsSelfTest.runIfRequested()
            }
        } else if isRelaunchSelfTest {
            AppRelaunchSelfTest.checkpoint("home-controller-requested")
            let home = HomeWindowController.shared
            AppRelaunchSelfTest.checkpoint("home-controller-ready")
            home.showWindow(nil)
            AppRelaunchSelfTest.checkpoint("home-shown")
            Task { @MainActor in
                await Task.yield()
                await AppRelaunchSelfTest.runIfRequested()
            }
            AppRelaunchSelfTest.checkpoint("selftest-scheduled")
        } else if let intent = relaunchIntent {
            HomeWindowController.shared.showWindow(nil)
            Task { @MainActor in
                await Task.yield()
                AppState.shared.resume(intent)
            }
        } else {
            // Splash first (Photoshop pattern), then reveal Home — unless a project already opened
            // (e.g. a document launch), in which case the editor owns the screen.
            SplashScreenController.shared.showAtLaunch {
                if !AppState.shared.hasVisibleKeyProjectWindow {
                    HomeWindowController.shared.showWindow(nil)
                }
            }
        }
        Task.detached(priority: .utility) {
            do {
                try ExportPublishRecoveryStore.recoverAll()
            } catch {
                Log.export.error("publish recovery failed: \(error.localizedDescription)")
            }
            do {
                try ExportRuntimeRecoveryStore.recoverAll()
            } catch {
                Log.export.error("render recovery failed: \(error.localizedDescription)")
            }
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
        DispatchQueue.main.async { HangDiagnosticUI.launch() }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if AppRelaunchSelfTest.isRequested {
            AppRelaunchSelfTest.failUnexpectedOpenFiles(filenames)
        }
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

    @MainActor @objc func configureHangDiagnostics(_ sender: Any?) {
        HangDiagnosticRecorder.shared.configure()
    }

    @MainActor @objc func exportHangDiagnostics(_ sender: Any?) {
        HangDiagnosticUI.export()
    }

    @MainActor @objc func deleteHangDiagnostics(_ sender: Any?) {
        HangDiagnosticUI.delete()
    }

    private var runtimeTerminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !runtimeTerminationPending else { return .terminateCancel }
        runtimeTerminationPending = true
        let application = sender as? NexGenVideoApplication
        application?.terminationReplyPending = true
        Task { @MainActor in
            defer {
                runtimeTerminationPending = false
                application?.terminationReplyPending = false
            }
            if AppTerminationSelfTest.isRequested { await AppTerminationSelfTest.cleanupStarted() }
            let editors = NSDocumentController.shared.documents.compactMap { ($0 as? VideoProject)?.editorViewModel }
            for editor in editors {
                let registry = editor.agentService.reviewChildRegistry
                let reviewWasRunning = registry.activeRunID != nil
                let root = editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
                await editor.renderReviewRun.cancelActiveWork()
                await registry.cancelAll()
                if reviewWasRunning, let root {
                    await editor.pipelinePhaseRunCoordinator.waitUntilIdle(projectRoot: root)
                }
            }
            let completed = await BpyRuntimeHost.shared.shutdown()
            if completed {
                await finishConfirmedTermination()
                AppTerminationSelfTest.record("cleanup-done")
                sender.reply(toApplicationShouldTerminate: true)
            } else if BpyRuntimeHost.shared.canQuitWithReservedStorage {
                let alert = NSAlert()
                alert.messageText = "Quit with reserved location storage?"
                alert.informativeText = "The location runtime has stopped, but a storage operation has no confirmed completion. "
                    + "Quitting keeps its reserved storage intact. Restart the Mac before using locations again so NexGenVideo can safely recover it. Your saved project files are unchanged."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Quit and Keep Reserved Storage")
                alert.addButton(withTitle: "Cancel")
                let requested = alert.runModal() == .alertFirstButtonReturn
                let confirmed = requested && BpyRuntimeHost.shared.confirmQuitWithReservedStorage()
                if confirmed { await finishConfirmedTermination() }
                sender.reply(toApplicationShouldTerminate: confirmed)
                if requested && !confirmed {
                    sender.presentError(NSError(domain: "NexGenVideo.SpatialRuntime", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Location runtime activity changed. Finish the current operation, then try quitting again."]))
                }
            } else {
                sender.reply(toApplicationShouldTerminate: false)
                sender.presentError(NSError(domain: "NexGenVideo.SpatialRuntime", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: BpyRuntimeHost.shared.cleanupFailure
                        ?? "The location runtime could not close safely. Try quitting again."]))
            }
        }
        return .terminateLater
    }

    @MainActor private func finishConfirmedTermination() async {
        await AppState.shared.confirmProjectTerminationAndDrain()
        let editors = NSDocumentController.shared.documents.compactMap { ($0 as? VideoProject)?.editorViewModel }
        let drains = editors.map { editor in
            (editor.cancelProductionStartupForClose(), editor.generationBatchCoordinator.cancelForClose(preventNewWork: true))
        }
        for (startup, generation) in drains {
            await startup?.value
            await generation.value
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppTerminationSelfTest.record("will-terminate")
        BpyRuntimeSelfTest.applicationWillTerminate()
        HangDiagnosticRecorder.shared.stop()
        AppRelaunchSelfTest.applicationWillTerminate()
        AppRelaunch.applicationWillTerminate()
    }
}
