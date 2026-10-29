import AppKit
import NexGenEngine

@MainActor
enum AppReloadFailureOwnerAcceptance {
    @MainActor private final class Observation {
        var attempts = 0
        var failure: String?
        var retryEntered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func holdRetry() async {
            retryEntered = true
            await withCheckedContinuation { continuation in
                if released { continuation.resume() }
                else { self.continuation = continuation }
            }
        }

        func release() {
            released = true
            let pending = continuation; continuation = nil; pending?.resume()
        }
    }

    static func run(savedPackage: URL, directory: URL, parent: NSWindow,
                    driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let package = directory.appendingPathComponent("Reload recovery.ngv", isDirectory: true)
        try FileManager.default.copyItem(at: savedPackage, to: package)
        let projectID = try ProjectIdentity.regenerate(at: package)
        let key = try ProjectIdentity.key(for: package)
        let timelineBytes = try Data(contentsOf: package.appendingPathComponent(Project.timelineFilename))
        let savedTimeline = try JSONDecoder().decode(Timeline.self, from: timelineBytes)
        let manifestBytes = try Data(contentsOf: package.appendingPathComponent(Project.manifestFilename))
        let savedManifest = try JSONDecoder().decode(MediaManifest.self, from: manifestBytes)
        let packageHashes = try AppSearchSaveAsOwnerAcceptance.packageHashes(package)
        _ = try ProjectWorkingCopy.open(key: key, packageURL: package)
        var recovered = savedTimeline; recovered.width += 16
        try ProjectWorkingCopy.checkpoint(key: key, snapshot: .init(timeline: JSONEncoder().encode(recovered),
            manifest: manifestBytes, generationLog: Data(contentsOf: package.appendingPathComponent(Project.generationLogFilename)),
            thumbnail: nil, chatSessionFiles: []))
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The recovery project has no window.") }
        let editor = document.editorViewModel, state = Observation()
        let originalReload = editor.onWorkingCopyReset
        editor.onWorkingCopyReset = { [weak document] home in
            guard let document else { return false }
            state.attempts += 1
            if state.attempts == 1 {
                do { try Data("deliberately unreadable first reload".utf8).write(to: home.appendingPathComponent(Project.timelineFilename)) }
                catch { state.failure = error.localizedDescription; return false }
                return await document.reloadEditableContents(from: home)
            }
            return await document.reloadEditableContents(from: home, beforeApply: { await state.holdRetry() })
        }
        defer {
            state.release(); editor.onWorkingCopyReset = originalReload
            document.close(); parent.makeKeyAndOrderFront(nil)
        }
        window.setContentSize(NSSize(width: 960, height: 640)); document.showWindows(); window.makeKeyAndOrderFront(nil)
        guard editor.recoveredUnsavedWork, editor.timeline == recovered,
              let oldGeneration = editor.openWorkingCopyGeneration else { throw GateBlocked("The real dirty working copy was not recovered.") }
        try await driver.wait("actual recovered-work alert") {
            window.attachedSheet.map { AppNativeMenuAcceptance.buttons(in: $0).contains(where: { $0.title == "Discard" && $0.enabled }) } == true
        }
        guard let recoveryAlert = window.attachedSheet else { throw GateBlocked("The recovered-work alert disappeared.") }
        try driver.capture("reload-recovered-alert", target: recoveryAlert)
        try AppNativeMenuAcceptance.accessibilityClick("Discard", in: recoveryAlert, driver: driver)
        try await driver.wait("first real reload failed") {
            state.attempts == 1 && editor.needsSavedProjectReload && !editor.recoveryDiscardInProgress && window.attachedSheet != nil
                && window.attachedSheet.map { AppNativeMenuAcceptance.buttons(in: $0).contains(where: { $0.title == "Retry reload" && $0.enabled }) } == true
        }
        guard state.failure == nil, let failureAlert = window.attachedSheet,
              try AppSearchSaveAsOwnerAcceptance.packageHashes(package) == packageHashes else {
            throw GateBlocked("The injected reload did not fail cleanly or changed saved bytes.")
        }
        try driver.capture("reload-failed-alert", target: failureAlert)
        try AppNativeMenuAcceptance.accessibilityClick("Cancel", in: failureAlert, driver: driver)
        try await driver.wait("persistent paused recovery surface") {
            window.attachedSheet == nil && visibleTexts(window).contains("Saved project could not be loaded")
        }
        let pausedTexts = visibleTexts(window)
        guard pausedTexts.contains("Editing and saving are paused to protect your saved project. Retry reload, or close and reopen this project."),
              AppNativeMenuAcceptance.buttons(in: window).contains(where: { $0.title == "Retry reload" && $0.enabled }),
              editor.isProjectEditingPaused, editor.timeline == recovered else {
            throw GateBlocked("Cancel left no visible explanation and usable recovery action.")
        }
        try driver.capture("reload-persistent-paused", target: window)
        window.makeFirstResponder(nil)
        for (code, text, modifiers) in [(UInt16(1), "s", NSEvent.ModifierFlags.command),
            (6, "z", .command), (6, "Z", [.command, .shift]), (34, "i", .command), (14, "e", .command)] {
            var waitsForSaveOutcome = false
            if text == "s" {
                guard window.isKeyWindow, let fileMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu else {
                    throw GateBlocked("The actual File menu is unavailable for Save validation.")
                }
                fileMenu.update()
                let saves = fileMenu.items.filter { $0.title == "Save" && $0.action == #selector(NSDocument.save(_:)) && !$0.isHidden }
                guard saves.count == 1, let save = saves.first, save.keyEquivalent == "s" else {
                    throw GateBlocked("The actual native Save command has no unique menu target.")
                }
                waitsForSaveOutcome = save.isEnabled
            }
            try await command(code, text: text, modifiers: modifiers, window: window, driver: driver)
            if waitsForSaveOutcome {
                try await driver.wait("actual native Save protection sheet after delivered command") { window.attachedSheet != nil }
            }
            if let alert = window.attachedSheet {
                let buttons = AppNativeMenuAcceptance.buttons(in: alert)
                if buttons.contains(where: { $0.title == "Retry reload" }) {
                    try AppNativeMenuAcceptance.accessibilityClick("Cancel", in: alert, driver: driver)
                } else {
                    let protection = "The saved project could not be reloaded. Retry reload or close and reopen the project before saving."
                    guard text == "s", visibleTexts(alert).contains(protection),
                          buttons.filter { $0.enabled }.map { $0.title } == ["OK"] else {
                        throw GateBlocked("A command opened an unexpected sheet while recovery was paused.")
                    }
                    try AppNativeMenuAcceptance.accessibilityClick("OK", in: alert, driver: driver)
                }
                try await driver.wait("return to persistent recovery after refused command") { window.attachedSheet == nil }
            }
            guard editor.isProjectEditingPaused, editor.timeline == recovered, !editor.showExportDialog,
                  !NSApp.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }),
                  try AppSearchSaveAsOwnerAcceptance.packageHashes(package) == packageHashes else {
                throw GateBlocked("A native command mutated or bypassed the paused project.")
            }
        }
        try driver.capture("reload-native-commands-blocked", target: window)
        try AppNativeMenuAcceptance.accessibilityClick("Retry reload", in: window, driver: driver)
        try await driver.wait("retry reached real loaded-content apply boundary") {
            state.retryEntered && visibleTexts(window).contains("Reloading saved project…")
                && AppNativeMenuAcceptance.buttons(in: window).contains(where: { $0.title == "Retry reload" && !$0.enabled })
        }
        guard visibleTexts(window).contains("Reloading saved project…"),
              AppNativeMenuAcceptance.buttons(in: window).contains(where: { $0.title == "Retry reload" && !$0.enabled }),
              editor.recoveryDiscardInProgress && editor.isProjectEditingPaused else {
            throw GateBlocked("The held real retry has no honest visible loading state.")
        }
        try driver.capture("reload-retry-loading", target: window)
        state.release()
        try await driver.wait("retry restores exactly the saved editable state", seconds: 30) {
            state.attempts == 2 && !editor.needsSavedProjectReload && !editor.recoveryDiscardInProgress
                && !editor.recoveredUnsavedWork && editor.timeline == savedTimeline && editor.mediaManifest == savedManifest
        }
        guard let generation = editor.openWorkingCopyGeneration, generation != oldGeneration,
              let working = editor.workingRoot, !editor.isProjectEditingPaused,
              try Data(contentsOf: working.appendingPathComponent(Project.timelineFilename)) == timelineBytes,
              try AppSearchSaveAsOwnerAcceptance.packageHashes(package) == packageHashes,
              ProjectIdentity.existingUUID(for: package) == projectID else { throw GateBlocked("Retry did not restore the same saved project bytes and identity.") }
        try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
        try driver.capture("reload-recovered-editor", target: window)
        let result: [String: Any] = ["projectID": projectID, "package": package.lastPathComponent,
            "packageHashes": packageHashes, "oldGeneration": oldGeneration.uuidString, "newGeneration": generation.uuidString,
            "reloadAttempts": state.attempts, "pausedTexts": pausedTexts, "blockedNativeKeys": ["s", "z", "Z", "i", "e"],
            "savedBytesPreserved": true, "realRetryRestoredSavedState": true,
            "faultInjection": "The first installed working-copy timeline is deliberately unreadable; the saved package stays intact."]
        try driver.record("persistent failed reload and native Retry", fields: result)
        return result
    }

    private static func visibleTexts(_ window: NSWindow) -> [String] {
        guard let root = window.contentView else { return [] }
        var pending: [any NSAccessibilityProtocol] = [root], visited = Set<ObjectIdentifier>(), result = Set<String>()
        while let element = pending.popLast(), visited.count < 2048 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let frame = element.accessibilityFrame()
            if frame.width > 0 && frame.height > 0 && window.frame.contains(frame) {
                for text in [element.accessibilityValue() as? String, element.accessibilityTitle(), element.accessibilityLabel()].compactMap({ $0 }) {
                    result.insert(text)
                }
            }
            pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        return result.sorted()
    }

    private static func command(_ code: UInt16, text: String, modifiers: NSEvent.ModifierFlags,
                                window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        @MainActor final class Delivery { var observed = false }
        let delivery = Delivery(), number = window.windowNumber
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            let matches = event.windowNumber == number && event.keyCode == code
            if matches { MainActor.assumeIsolated { delivery.observed = true } }
            return event
        }
        guard let monitor else { throw GateBlocked("The native command delivery monitor is unavailable.") }
        defer { NSEvent.removeMonitor(monitor) }
        try driver.pressKey(code, characters: text, modifiers: modifiers, in: window)
        try await driver.wait("actual key-up after paused command " + text) { delivery.observed }
        try driver.record("paused native command delivered", fields: ["code": code, "characters": text, "modifiers": modifiers.rawValue])
    }
}
