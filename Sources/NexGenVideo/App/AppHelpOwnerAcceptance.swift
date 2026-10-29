import AppKit
import NexGenEngine

@MainActor
enum AppHelpOwnerAcceptance {
    static func run(editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let before = editor.timeline
        for title in ["Keyboard Shortcuts", "MCP Instructions"] {
            try await AppNativeMenuAcceptance.choose(["Help", title], in: window, driver: driver)
            try await driver.wait("actual Help " + title) { HelpWindowController.shared.window?.isKeyWindow == true }
            guard let help = HelpWindowController.shared.window else { throw GateBlocked("The Help window did not open.") }
            try driver.capture(title == "Keyboard Shortcuts" ? "shortcuts" : "mcp-help", target: help)
            try await AppNativeMenuAcceptance.close(help, driver: driver)
            try await driver.wait("return from Help") { window.isKeyWindow }
        }
        try await AppNativeMenuAcceptance.choose(["Help", "Tutorial"], in: window, driver: driver)
        try await driver.wait("native tutorial opens") { editor.tour.stepIndex == 0 }
        try driver.capture("tutorial", target: window)
        try AppNativeMenuAcceptance.accessibilityClick("Skip", in: window, driver: driver)
        try await driver.wait("native tutorial dismissed") { editor.tour.stepIndex == nil }
        try await AppNativeMenuAcceptance.choose(["Help", "Send Feedback…"], in: window, driver: driver)
        try await driver.wait("actual feedback form") { FeedbackWindowController.shared.window?.isKeyWindow == true }
        guard let feedback = FeedbackWindowController.shared.window,
              AppNativeMenuAcceptance.buttons(in: feedback).contains(where: { $0.title == "Send" && !$0.enabled }) else {
            throw GateBlocked("The actual empty Feedback form does not expose a disabled Send action.")
        }
        try driver.capture("feedback-empty-not-sent", target: feedback)
        try await AppNativeMenuAcceptance.close(feedback, driver: driver)
        try await driver.wait("return from Feedback without sending") { window.isKeyWindow }
        let existingWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        try await AppNativeMenuAcceptance.choose(["NexGenVideo", "Check for Updates…"], in: window, driver: driver)
        try await driver.wait("actual updater surface", seconds: 30) {
            guard let update = NSApp.keyWindow else { return false }
            return update.isVisible && !existingWindows.contains(update.windowNumber)
        }
        guard let update = NSApp.keyWindow, !existingWindows.contains(update.windowNumber) else { throw GateBlocked("The updater did not present its real window.") }
        try driver.capture("update-check-no-install", target: update)
        let updateButtons = AppNativeMenuAcceptance.buttons(in: update)
        if let dismiss = ["Cancel", "Remind Me Later", "OK"].first(where: { title in
            updateButtons.contains { $0.title == title && $0.enabled }
        }) {
            try AppNativeMenuAcceptance.accessibilityClick(dismiss, in: update, driver: driver)
            try await driver.wait("updater dismissed without installing") { !update.isVisible }
        } else { try await AppNativeMenuAcceptance.close(update, driver: driver) }
        try await driver.wait("return from updater") { window.isKeyWindow }
        try await AppNativeMenuAcceptance.choose(["Help", "Reveal Diagnostics"], in: window, driver: driver)
        try await AppNativeMenuAcceptance.requireFinderDirectory(MainThreadHangWatchdog.diagnosticsDirectory, driver: driver)
        try await driver.wait("return from Diagnostics Finder") { window.isKeyWindow }
        let defaults = UserDefaults.standard, previousMode = defaults.object(forKey: "hangDiagnosticMode")
        let recordingBefore = HangDiagnosticRecorder.shared.isEnabled
        defer {
            if let previousMode { defaults.set(previousMode, forKey: "hangDiagnosticMode") }
            else { defaults.removeObject(forKey: "hangDiagnosticMode") }
        }
        let entriesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: HangDiagnosticRecorder.root.path)) ?? [])
        try await AppNativeMenuAcceptance.modalMenu(["Help", "Configure Hang Recording…"], in: window, driver: driver) { configure in
            try driver.capture("diagnostic-configure", target: configure)
            let choices = AppNativeMenuAcceptance.buttons(in: configure)
            let title = choices.contains(where: { $0.title == "Cancel" && $0.enabled }) ? "Cancel" : "Disable recording"
            try AppNativeMenuAcceptance.accessibilityClick(title, in: configure, driver: driver)
        }
        guard HangDiagnosticRecorder.shared.isEnabled == recordingBefore else { throw GateBlocked("Inspecting diagnostic settings changed recording activity.") }
        try await AppNativeMenuAcceptance.modalMenu(["Help", "Export Hang Recording…"], in: window, driver: driver) { export in
            try driver.capture("diagnostic-export-cancel", target: export)
            if export is NSSavePanel { try driver.pressKey(53, characters: "\u{1b}", in: export) }
            else {
                let choices = AppNativeMenuAcceptance.buttons(in: export)
                let title = choices.contains(where: { $0.title == "Cancel" && $0.enabled }) ? "Cancel" : "OK"
                try AppNativeMenuAcceptance.accessibilityClick(title, in: export, driver: driver)
            }
        }
        try await AppNativeMenuAcceptance.modalMenu(["Help", "Delete Hang Recordings…"], in: window, driver: driver) { deletion in
            try driver.capture("diagnostic-delete-cancel", target: deletion)
            try AppNativeMenuAcceptance.accessibilityClick("Cancel", in: deletion, driver: driver)
        }
        let entriesAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: HangDiagnosticRecorder.root.path)) ?? [])
        guard entriesBefore.isSubset(of: entriesAfter), HangDiagnosticRecorder.shared.isEnabled == recordingBefore,
              editor.timeline == before else { throw GateBlocked("Help or cancelled diagnostics changed the project or removed recordings.") }
        let result: [String: Any] = ["shortcutsAndMCP": true, "tutorialOpenSkip": true,
            "feedbackOpenedSendDisabled": true, "feedbackNotSent": true, "updateOpenedWithoutInstall": true,
            "diagnosticFinderExactDirectory": true, "diagnosticEntryDecisionsPreserveRecordings": true,
            "recordingsPreserved": true, "timelinePreserved": true]
        try driver.record("native-help-entrypoints", fields: result)
        return result
    }

}
