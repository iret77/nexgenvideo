import AppKit
import NexGenEngine

@MainActor
enum AppHelpOwnerAcceptance {
    static func run(editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let before = editor.timeline
        var helpContents: [[String: Any]] = []
        for title in ["Keyboard Shortcuts", "MCP Instructions"] {
            try await AppNativeMenuAcceptance.choose(["Help", title], in: window, driver: driver)
            try await driver.wait("actual Help " + title) { HelpWindowController.shared.window?.isKeyWindow == true }
            guard let help = HelpWindowController.shared.window else { throw GateBlocked("The Help window did not open.") }
            let expected = title == "Keyboard Shortcuts" ? "Play / Pause" : "Server URL"
            var content: String?
            try await driver.wait("visible Help content for " + title) {
                content = visibleStaticTexts(in: help).first { $0.contains(expected) }
                return content != nil
            }
            guard let content else { throw GateBlocked("The requested Help content is not visible: " + title) }
            helpContents.append(["menu": title, "visibleContent": content])
            try driver.capture(title == "Keyboard Shortcuts" ? "shortcuts" : "mcp-help", target: help)
            try await AppNativeMenuAcceptance.close(help, driver: driver)
            try await driver.wait("return from Help") { window.isKeyWindow }
        }
        let tutorial = try await runTutorial(editor: editor, window: window, driver: driver)
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
        let result: [String: Any] = ["shortcutsAndMCP": true, "helpContents": helpContents, "tutorialOpenSkip": true,
            "tutorialNavigation": tutorial,
            "feedbackOpenedSendDisabled": true, "feedbackNotSent": true, "updateOpenedWithoutInstall": true,
            "diagnosticFinderExactDirectory": true, "diagnosticEntryDecisionsPreserveRecordings": true,
            "recordingsPreserved": true, "timelinePreserved": true]
        try driver.record("native-help-entrypoints", fields: result)
        return result
    }

    private static func runTutorial(editor: EditorViewModel, window: NSWindow,
                                    driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let workspace = editor.workspaceFocus, selection = editor.selectedClipIds
        let inspected = editor.inspectedObject, frame = editor.currentFrame, timeline = editor.timeline
        let media = Set(editor.mediaAssets.map(\.id))
        if editor.theaterActive {
            try await AppNativeMenuAcceptance.choose(["View", "Theater"], in: window, driver: driver)
            try await driver.wait("leave existing Theater before native entry") { !editor.theaterActive }
        }
        try await AppNativeMenuAcceptance.choose(["View", "Theater"], in: window, driver: driver)
        try await driver.wait("native Theater before Tutorial") { editor.theaterActive }
        try driver.capture("tutorial-theater-entry", target: window)
        try await AppNativeMenuAcceptance.choose(["Help", "Tutorial"], in: window, driver: driver)
        try await tourBookend("Tutorial", kind: .intro, buttons: ["Next", "Skip"], editor: editor, window: window, driver: driver)
        guard !editor.theaterActive, editor.tour.targetFrame == nil else { throw GateBlocked("Tutorial did not leave Theater for its visible introduction.") }
        try driver.capture("tutorial-intro", target: window)
        try AppNativeMenuAcceptance.accessibilityClick("Next", in: window, driver: driver)
        try await driver.wait("native Tutorial reaches the media workspace") {
            editor.tour.currentStep?.title == "Media panel"
                && tourGeometry(.panel(.media), editor: editor, window: window) != nil
        }
        let smartSearchVisible = AppNativeMenuAcceptance.buttons(in: window).contains { $0.title == "Smart Search" && $0.enabled }
        var required: [(String, TourTarget)] = [
            ("Media panel", .panel(.media)), ("Import footage", .element(.importButton)),
            ("Generate", .element(.generateButton)), ("Generation panel", .element(.generation)),
        ]
        if smartSearchVisible { required.append(("Smart search", .element(.smartSearch))) }
        required += [("Preview", .panel(.preview)), ("Screenshot a frame", .element(.screenshotButton)),
            ("Inspector", .panel(.inspector)), ("Timeline", .panel(.timeline)),
            ("Select a range", .element(.timelineRuler)), ("AI agent", .panel(.agent))]
        var observations: [[String: Any]] = []
        for (index, step) in required.enumerated() {
            if index > 0 { try AppNativeMenuAcceptance.accessibilityClick("Next", in: window, driver: driver) }
            observations.append(try await tourStep(step.0, target: step.1, index: index + 1, count: required.count,
                label: "tutorial-step-\(index + 1)", editor: editor, window: window, driver: driver))
            if index == 1 {
                try AppNativeMenuAcceptance.accessibilityClick("Back", in: window, driver: driver)
                _ = try await tourStep("Media panel", target: .panel(.media), index: 1, count: required.count,
                    label: "tutorial-back-media", editor: editor, window: window, driver: driver)
                try AppNativeMenuAcceptance.accessibilityClick("Next", in: window, driver: driver)
                _ = try await tourStep("Import footage", target: .element(.importButton), index: 2, count: required.count,
                    label: "tutorial-next-after-back", editor: editor, window: window, driver: driver)
            }
        }
        try AppNativeMenuAcceptance.accessibilityClick("Next", in: window, driver: driver)
        try await tourBookend("You're all set", kind: .outro,
            buttons: ["MCP Setup", "Keyboard Shortcuts", "Documentation", "Settings", "Start creating"],
            editor: editor, window: window, driver: driver)
        try driver.capture("tutorial-outro", target: window)
        try AppNativeMenuAcceptance.accessibilityClick("Start creating", in: window, driver: driver)
        try await driver.wait("native Tutorial Finish removes the overlay") { editor.tour.stepIndex == nil && editor.tour.targetFrame == nil }
        try driver.capture("tutorial-finished", target: window)
        try await AppNativeMenuAcceptance.choose(["Help", "Tutorial"], in: window, driver: driver)
        try await tourBookend("Tutorial", kind: .intro, buttons: ["Next", "Skip"], editor: editor, window: window, driver: driver)
        try driver.capture("tutorial", target: window)
        try AppNativeMenuAcceptance.accessibilityClick("Skip", in: window, driver: driver)
        try await driver.wait("native Tutorial Skip removes the overlay") { editor.tour.stepIndex == nil && editor.tour.targetFrame == nil }
        try driver.capture("tutorial-skipped", target: window)
        try await driver.click("editor.workspace." + workspace.rawValue, in: window, enabled: false)
        try await driver.wait("native return to the original workspace after Tutorial") { editor.workspaceFocus == workspace }
        guard editor.timeline == timeline, Set(editor.mediaAssets.map(\.id)) == media,
              editor.selectedClipIds == selection, editor.inspectedObject == inspected, editor.currentFrame == frame else {
            throw GateBlocked("Tutorial or returning to the original workspace changed the film, media or remembered selection.")
        }
        return ["fromNativeTheater": true, "backAndNext": true, "finishAndReopenSkip": true,
            "smartSearchInitiallyVisible": smartSearchVisible, "steps": observations,
            "originalWorkspaceRestoredByNativeAction": workspace.rawValue, "projectAndSelectionPreserved": true]
    }

    private static func tourBookend(_ title: String, kind: TourStep.Kind, buttons: [String], editor: EditorViewModel,
                                    window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try await driver.wait("visible Tutorial " + title) {
            let visible = visibleStaticTexts(in: window), controls = AppNativeMenuAcceptance.buttons(in: window)
            return window.isKeyWindow && editor.tour.currentStep?.kind == kind
                && visible.contains(where: { $0.contains(title) })
                && buttons.allSatisfy { title in controls.filter { $0.title == title && $0.enabled }.count == 1 }
        }
    }

    private static func tourStep(_ title: String, target: TourTarget, index: Int, count: Int, label: String,
                                 editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        var observation: [String: Any]?
        try await driver.wait("visible Tutorial target " + title) {
            let visible = visibleStaticTexts(in: window), controls = AppNativeMenuAcceptance.buttons(in: window)
            guard window.isKeyWindow, !editor.theaterActive, editor.tour.stepIndex == index,
                  editor.tour.currentStep?.kind == .spotlight(target), editor.tour.currentStep?.title == title,
                  visible.contains(where: { $0.contains(title) }), visible.contains(where: { $0.contains("Step \(index) of \(count)") }),
                  ["Next", "Back", "Skip"].allSatisfy({ title in controls.filter { $0.title == title && $0.enabled }.count == 1 }),
                  let geometry = tourGeometry(target, editor: editor, window: window) else { return false }
            observation = ["title": title, "index": index, "total": count, "visibleText": visible,
                "workspace": editor.workspaceFocus.rawValue, "geometry": geometry]
            return true
        }
        guard let observation else { throw GateBlocked("The actual Tutorial target was not observed: " + title) }
        try driver.capture(label, target: window)
        try driver.record(label, fields: observation)
        return observation
    }

    private static func tourGeometry(_ target: TourTarget, editor: EditorViewModel, window: NSWindow) -> [String: Any]? {
        guard let root = window.contentView,
              let split = AppNativeMenuAcceptance.views(root).compactMap({ $0.nextResponder as? EditorSplitViewController }).first,
              split.editor === editor,
              let spotlight = WorkspaceUIAcceptance.probeFrame(identifier: "tour.highlight", in: window) else { return nil }
        let source: NSView?
        switch target {
        case .panel(.agent): source = split.leafItem(for: .inspector)?.viewController.view
        case .panel(let panel): source = split.leafItem(for: panel)?.viewController.view
        case .element(let anchor): source = editor.tour.anchorViews[anchor]?.value
        }
        guard let source, source.window === window, !source.isHiddenOrHasHiddenAncestor,
              source.bounds.width > 1, source.bounds.height > 1 else { return nil }
        let actual = source.convert(source.bounds, to: root)
        guard root.bounds.contains(actual), source.visibleRect.contains(source.bounds) else { return nil }
        var expected = actual
        if target == .element(.timelineRuler) {
            expected.size.height = AppTheme.Layout.rulerHeight
            if !root.isFlipped { expected.origin.y = actual.maxY - expected.height }
        }
        guard [spotlight.minX, spotlight.minY, spotlight.width, spotlight.height].allSatisfy(\.isFinite),
              root.bounds.contains(spotlight),
              abs(spotlight.minX - expected.minX) <= 1, abs(spotlight.minY - expected.minY) <= 1,
              abs(spotlight.width - expected.width) <= 1, abs(spotlight.height - expected.height) <= 1 else { return nil }
        var result: [String: Any] = ["spotlight": rect(spotlight), "actualView": rect(actual)]
        let control: String?
        switch target {
        case .panel(.media), .element(.importButton): control = "media.action.Import"
        case .element(.generateButton): control = "media.action.Generate"
        case .element(.smartSearch): control = "media.index.download"
        case .element(.screenshotButton): control = "preview.capture-frame"
        default: control = nil
        }
        if let control {
            guard let observed = WorkspaceUIAcceptance.probeFrame(identifier: control, in: window),
                  observed.width > 1, observed.height > 1, actual.insetBy(dx: -1, dy: -1).contains(observed) else { return nil }
            result["actualControl"] = ["id": control, "frame": rect(observed)]
        }
        if target == .panel(.agent) {
            guard editor.productionActivityVisible,
                  let activity = WorkspaceUIAcceptance.probeFrame(identifier: "production.activity", in: window),
                  actual.insetBy(dx: -1, dy: -1).contains(activity), activity.midX > root.bounds.midX,
                  activity.width > 1, activity.height > 1 else { return nil }
            result["actualRightActivity"] = rect(activity)
        }
        return result
    }

    private static func rect(_ value: NSRect) -> [Double] {
        [value.minX, value.minY, value.width, value.height].map(Double.init)
    }

    private static func visibleStaticTexts(in window: NSWindow) -> [String] {
        guard window.isVisible, let root = window.contentView else { return [] }
        var pending: [any NSAccessibilityProtocol] = [root], visited = Set<ObjectIdentifier>()
        var result: [String] = []
        while let element = pending.popLast(), visited.count < 2048 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let frame = element.accessibilityFrame()
            if element.accessibilityRole() == .staticText, frame.width > 0, frame.height > 0,
               window.frame.contains(frame) {
                result += [element.accessibilityValue() as? String, element.accessibilityLabel(),
                           element.accessibilityTitle()].compactMap { $0 }
            }
            pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        return result
    }

}
