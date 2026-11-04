import AppKit
import CryptoKit
import XCTest

final class UserJourneyTests: XCTestCase {
    private var app: XCUIApplication!
    private var config: [String: Any] = [:]
    private var stages: [[String: Any]] = []
    private var actions: [[String: Any]] = []
    private var output: URL!
    private var sequence = 0
    private var answeredDiagnosticsConsent = false

    private struct Failure: Error { let message: String }

    private var windowButtons: XCUIElementQuery { app.windows.descendants(matching: .button) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        config = try json(URL(fileURLWithPath: "/tmp/nexgenvideo-external-gui-config.json"))
        output = URL(fileURLWithPath: try string("evidence"), isDirectory: true)
        app = XCUIApplication(url: URL(fileURLWithPath: try string("app")))
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [:]
        try require(NSRunningApplication.runningApplications(withBundleIdentifier: "de.h5ventures.nexgenvideo").isEmpty,
                    "Another NexGenVideo process is already running in this job")
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            _ = try? evidence("final-state")
            app.terminate()
        }
        if output != nil {
            try write(["schema": "nexgenvideo/external-gui-journey/1", "stages": stages,
                       "actions": actions], to: output.appendingPathComponent("journey.json"))
        }
    }

    func testGenericEditingThroughInstalledApp() throws {
        try launch()
        try home()
        try stage("home")

        try menu("NexGenVideo", "Settings…")
        let scale = try string("scaleLabel")
        let settings = app.windows["Settings"]
        let pickers = settings.popUpButtons.matching(NSPredicate(format: "label == %@", "Interface text, Interface text size"))
        try wait("unique Interface text size control") { pickers.count == 1 }
        let picker = pickers.element(boundBy: 0)
        try click(picker, "Interface text size")
        try click(app.menuItems[scale], scale)
        try wait("selected interface text size") { String(describing: picker.value ?? "").contains(scale) }
        try stage("settings", fields: ["scaleLabel": scale])
        try click(settings.buttons[XCUIIdentifierCloseWindow], "native Settings close")
        try wait("Settings closed") { !settings.exists }

        try menu("File", "New")
        let project = URL(fileURLWithPath: try string("project"))
        try savePanel(name: project.deletingPathExtension().lastPathComponent, previous: "Untitled Project",
                      directory: project.deletingLastPathComponent())
        try editor(project)
        let empty = try snapshot("new-project", project: project)
        try require(clips(empty).isEmpty, "The new generic project contains clips")
        let declaration = try json(project.appendingPathComponent("ngv.json"))
        try require(UUID(uuidString: declaration["id"] as? String ?? "") != nil,
                    "The new generic project has no valid project identity")
        try require(["activePlugin", "activePluginVersion", "activePluginProjectSchema"].allSatisfy { declaration[$0] == nil },
                    "New generic project unexpectedly declares a format pack")
        try stage("new-project")

        try menu("View", "Edit Workspace")
        try menu("File", "Import Media…")
        let source = URL(fileURLWithPath: try string("source"))
        try openPanel(source)
        let sourceTitle = source.deletingPathExtension().lastPathComponent
        let assetLabel = app.staticTexts[sourceTitle]
        try wait("imported readable source title") { assetLabel.exists && assetLabel.isHittable }
        try key("s", modifiers: .command)
        try wait("saved media manifest") { (try? self.manifest(project).count) == 1 }
        let entries = try manifest(project)
        try require(entries.first?["originalFilename"] as? String == source.lastPathComponent,
                    "Import did not persist the original filename")
        let imported = try snapshot("media-import", project: project)
        try require(clips(imported).isEmpty, "Library import silently inserted a timeline clip")
        try stage("media-import")

        try click(assetLabel, sourceTitle)
        let clearRange = windowButtons["Clear Range"]
        try wait("source range controls") { clearRange.exists }
        try require(!clearRange.isEnabled, "A newly imported full source has an enabled Clear Range control")
        let clearRangeEnabled = clearRange.isEnabled
        try click(windowButtons["Insert"], "Insert")
        try key("s", modifiers: .command)
        try wait("inserted clip saved") { (try? self.clips(self.timeline(project)).count) == 1 }
        let inserted = try snapshot("source-insert", project: project)
        try require(integer(inserted["fps"]) == 30 && integer(inserted["width"]) == 320
                    && integer(inserted["height"]) == 180, "First source settings did not reach the timeline")
        try require(integer(clips(inserted).first?["durationFrames"]) == 120,
                    "The source was not inserted at its full duration")
        try stage("source-insert", fields: ["clearRangeEnabled": clearRangeEnabled])

        try menu("View", "Edit Workspace")
        try focusTimeline()
        try key("a", modifiers: .command)
        for _ in 0..<30 { try key(XCUIKeyboardKey.rightArrow.rawValue) }
        try menu("Edit", "Split at Playhead")
        try key("s", modifiers: .command)
        try wait("split persisted as two clips") { (try? self.clips(self.timeline(project)).count) == 2 }
        let split = try snapshot("timeline-split", project: project)
        let pieces = clips(split).sorted { integer($0["startFrame"]) < integer($1["startFrame"]) }
        try require(pieces.map { integer($0["startFrame"]) } == [0, 30]
                    && pieces.map { integer($0["durationFrames"]) } == [30, 90],
                    "Split did not preserve the exact 30/90-frame source ranges")
        try require(pieces.map { integer($0["trimStartFrame"]) } == [0, 30]
                    && pieces.map { integer($0["trimEndFrame"]) } == [90, 0],
                    "Split changed the source in/out frames")
        try stage("timeline-split")

        try key("z", modifiers: .command)
        try key("s", modifiers: .command)
        try wait("Undo restored the exact timeline") {
            guard let value = try? self.timeline(project) else { return false }
            return NSDictionary(dictionary: value).isEqual(to: inserted)
        }
        _ = try snapshot("timeline-undo", project: project)
        try stage("timeline-undo")

        let document = try documentWindow(project)
        try click(document.buttons[XCUIIdentifierCloseWindow], "native document close")
        try wait("document closed") { !document.exists }
        try stage("close")
        app.terminate()
        try launch()
        try home()
        try menu("File", "Open…")
        try openPanel(project)
        try editor(project)
        let reopened = try snapshot("reopen", project: project)
        try require(NSDictionary(dictionary: reopened).isEqual(to: inserted), "Reopen changed the saved timeline")
        try require(NSDictionary(dictionary: try json(project.appendingPathComponent("ngv.json"))).isEqual(to: declaration),
                    "Reopen changed the project identity or format declaration")
        try stage("reopen")

        try menu("File", "Export…")
        let exportStart = windowButtons["export.start"]
        try click(exportStart, "Export")
        let movie = URL(fileURLWithPath: try string("movie"))
        try savePanel(name: movie.lastPathComponent, previous: "export.mp4", directory: movie.deletingLastPathComponent())
        try wait("completed export with Reveal enabled", timeout: 180) {
            let reveal = self.windowButtons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                                                               "export.job.", ".reveal"))
            return reveal.allElementsBoundByIndex.contains { $0.exists && $0.isEnabled }
                && FileManager.default.fileExists(atPath: movie.path)
        }
        try stage("export", fields: ["movieSHA256": try digest(movie)])
    }

    private func home() throws {
        try wait("normal Home or diagnostics consent", timeout: 60) {
            self.app.staticTexts["Welcome to NexGenVideo"].exists || !self.diagnosticsConsentDialogs().isEmpty
        }
        let consents = diagnosticsConsentDialogs()
        if !consents.isEmpty {
            try require(consents.count == 1 && !answeredDiagnosticsConsent,
                        "Diagnostics consent is ambiguous or did not retain the preceding choice")
            let consent = consents[0]
            for choice in ["Record with replay content", "Record structure only", "Disable recording"] {
                try require(consent.buttons[choice].exists, "Missing native diagnostics consent choice: " + choice)
            }
            _ = try evidence("startup-diagnostics-consent")
            try click(consent.buttons["Disable recording"], "Disable recording")
            try wait("diagnostics consent closed") { self.diagnosticsConsentDialogs().isEmpty }
            answeredDiagnosticsConsent = true
        }
        try wait("normal Home window", timeout: 60) { self.app.staticTexts["Welcome to NexGenVideo"].exists }
        let whatsNew = windowButtons["home.whats-new.continue"]
        if whatsNew.exists { try click(whatsNew, "Continue") }
        try require(windowButtons["home.settings"].exists, "Home settings entry is absent")
    }

    private func diagnosticsConsentDialogs() -> [XCUIElement] {
        let title = "Record UI hang diagnostics"
        return app.dialogs.allElementsBoundByIndex.filter {
            $0.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).count == 1
        }
    }

    private func launch() throws {
        try write(["app": try string("app"), "requestedAt": ISO8601DateFormatter().string(from: Date())],
                  to: output.appendingPathComponent("launch-request.json"))
        app.launch()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "de.h5ventures.nexgenvideo")
        try require(running.count == 1 && running[0].bundleURL?.standardizedFileURL.path == (try string("app")),
                    "XCTest launched a different app bundle")
    }

    private func editor(_ project: URL) throws {
        try wait("normal editor document", timeout: 60) {
            self.projectWindows(project).count == 1
        }
    }

    private func documentWindow(_ project: URL) throws -> XCUIElement {
        let windows = projectWindows(project)
        try require(windows.count == 1, "Expected one exact project window")
        return windows.element(boundBy: 0)
    }

    private func projectWindows(_ project: URL) -> XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "title == %@",
            "NexGenVideo — \(project.deletingPathExtension().lastPathComponent)"))
    }

    private func focusTimeline() throws {
        let header = app.groups["Track controls"]
        try wait("native timeline track controls") { header.exists && !header.frame.isEmpty }
        try require(header.frame.height > 48, "Timeline focus point could intersect the 24-point ruler")
        let point = CGPoint(x: header.frame.maxX + 24, y: header.frame.midY)
        try require(app.windows.allElementsBoundByIndex.contains { $0.frame.contains(point) },
                    "Timeline canvas lies outside the visible document")
        actions.append(["kind": "click", "target": "canvas beside Track controls", "x": point.x, "y": point.y])
        let coordinate = header.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 24, dy: 0))
        coordinate.click()
    }

    private func menu(_ title: String, _ item: String) throws {
        try click(app.menuBars.menuBarItems[title], title)
        try click(app.menuItems[item], item)
    }

    private func visibleInputs(_ query: XCUIElementQuery) -> [XCUIElement] {
        query.allElementsBoundByIndex.filter { $0.exists && $0.isEnabled && $0.isHittable }
    }

    private func savePanel(name: String, previous: String, directory: URL) throws {
        let values = [previous, (previous as NSString).deletingPathExtension, previous + ".ngv"]
        let fields = app.textFields.matching(NSPredicate(format: "identifier == %@", "saveAsNameTextField"))
        try wait("unique native save name") { self.visibleInputs(fields).count == 1 }
        let visible = visibleInputs(fields)
        try require(visible.count == 1, "The native save filename is ambiguous or missing")
        let field = visible[0]
        try require(values.contains(field.value as? String ?? ""), "The native save filename differs from the expected default")
        try click(field, "save name: " + previous)
        try key("a", modifiers: .command, in: field)
        try type(name, in: field)
        try wait("edited native save filename") {
            guard let value = field.value as? String else { return false }
            return value == name || value == (name as NSString).deletingPathExtension
        }
        try goTo(directory)
        try click(windowButtons["Save"], "Save")
        try wait("save panel closed") { !self.windowButtons["Save"].exists }
    }

    private func openPanel(_ file: URL) throws {
        try wait("native Open button") { self.windowButtons["Open"].exists }
        try goTo(file)
        try click(windowButtons["Open"], "Open")
        try wait("open panel closed") { !self.windowButtons["Open"].exists }
    }

    private func goTo(_ url: URL) throws {
        let sheets = app.sheets.matching(NSPredicate(format: "identifier == %@", "GoToWindow"))
        try require(sheets.count == 0, "A native Go to Folder sheet is already open")
        try key("g", modifiers: [.command, .shift])
        try wait("unique native Go to Folder sheet") { sheets.count == 1 }
        let fields = sheets.element(boundBy: 0).textFields.matching(NSPredicate(format: "identifier == %@", "PathTextField"))
        try wait("unique native Go to Folder editor") { fields.count == 1 }
        let field = fields.element(boundBy: 0)
        try click(field, "Go to Folder path editor")
        try key("a", modifiers: .command, in: field)
        try type(url.path, in: field)
        try wait("typed destination in native path editor") { field.value as? String == url.path }
        try key(XCUIKeyboardKey.return.rawValue, in: field)
        try wait("Go to Folder dismissed") { sheets.count == 0 }
    }

    private func click(_ element: XCUIElement, _ name: String) throws {
        try wait(name) { element.exists && element.isEnabled && element.isHittable }
        actions.append(["kind": "click", "target": name, "frame": NSStringFromRect(element.frame)])
        element.click()
    }

    private func key(_ key: String, modifiers: XCUIElement.KeyModifierFlags = [], in element: XCUIElement? = nil) throws {
        actions.append(["kind": "key", "key": key, "modifiers": modifiers.rawValue])
        if let element { element.typeKey(key, modifierFlags: modifiers) }
        else { app.typeKey(key, modifierFlags: modifiers) }
    }

    private func type(_ text: String, in element: XCUIElement) throws {
        actions.append(["kind": "text", "text": text, "identifier": element.identifier, "label": element.label])
        element.typeText(text)
    }

    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        try require(XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed, "Timed out: " + label)
    }

    private func require(_ value: Bool, _ message: String) throws {
        guard value else {
            _ = try? evidence("failure")
            throw Failure(message: message)
        }
    }

    private func evidence(_ name: String) throws -> [String: String] {
        sequence += 1
        let base = String(format: "%03d-", sequence) + name
        let screenshot = XCUIScreen.main.screenshot()
        let imageURL = output.appendingPathComponent(base + ".png")
        try screenshot.pngRepresentation.write(to: imageURL, options: .atomic)
        let tree = app.debugDescription
        let treeURL = output.appendingPathComponent(base + "-accessibility.txt")
        try tree.write(to: treeURL, atomically: true, encoding: .utf8)
        let image = XCTAttachment(screenshot: screenshot)
        image.name = base; image.lifetime = .keepAlways; add(image)
        let accessibility = XCTAttachment(string: tree)
        accessibility.name = base + "-accessibility"; accessibility.lifetime = .keepAlways; add(accessibility)
        return ["screenshot": imageURL.lastPathComponent, "screenshotSHA256": try digest(imageURL),
                "accessibility": treeURL.lastPathComponent, "accessibilitySHA256": try digest(treeURL)]
    }

    private func stage(_ name: String, fields: [String: Any] = [:]) throws {
        var row: [String: Any] = ["stage": name, "time": ISO8601DateFormatter().string(from: Date()),
                                 "evidence": try evidence(name), "actionCount": actions.count]
        row.merge(fields) { _, new in new }
        stages.append(row)
        try write(["schema": "nexgenvideo/external-gui-journey/1", "stages": stages,
                   "actions": actions], to: output.appendingPathComponent("journey.json"))
    }

    private func snapshot(_ name: String, project: URL) throws -> [String: Any] {
        let value = try timeline(project)
        for file in ["project.json", "media.json", "ngv.json"] {
            let source = project.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: source.path) {
                try Data(contentsOf: source).write(to: output.appendingPathComponent(name + "-" + file), options: .atomic)
            }
        }
        return value
    }

    private func timeline(_ project: URL) throws -> [String: Any] { try json(project.appendingPathComponent("project.json")) }
    private func manifest(_ project: URL) throws -> [[String: Any]] {
        try json(project.appendingPathComponent("media.json"))["entries"] as? [[String: Any]] ?? []
    }
    private func clips(_ value: [String: Any]) -> [[String: Any]] {
        (value["tracks"] as? [[String: Any]] ?? []).flatMap { $0["clips"] as? [[String: Any]] ?? [] }
    }
    private func integer(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? -1 }
    private func json(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure(message: "Expected JSON object: " + url.lastPathComponent)
        }
        return value
    }
    private func string(_ key: String) throws -> String {
        guard let value = config[key] as? String, !value.isEmpty else { throw Failure(message: "Missing configuration: " + key) }
        return value
    }
    private func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    private func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }
}
