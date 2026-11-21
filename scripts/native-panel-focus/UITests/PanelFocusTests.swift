import AppKit
import XCTest

final class PanelFocusTests: XCTestCase {
    private struct Refusal: LocalizedError {
        let errorDescription: String?
        init(_ reason: String) { errorDescription = reason }
    }

    private func require(_ value: Bool, _ message: String) throws { if !value { throw Refusal(message) } }

    private func wait(_ label: String, seconds: TimeInterval = 20, _ ready: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ready() }, object: nil)
        try require(XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed, label)
    }

    func testOwnOpenPanelShortcut() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["PANEL_PROBE_EVIDENCE"]), isDirectory: true)
        let home = URL(fileURLWithPath: try XCTUnwrap(env["CFFIXED_USER_HOME"]), isDirectory: true)
        try require(env["HOME"] == home.path && FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath() == home.standardizedFileURL.resolvingSymlinksInPath(),
                    "The test runner must use its isolated home")
        let file = dir.appendingPathComponent("ordinary-file.txt")
        try Data("This is the native file panel fixture.\n".utf8).write(to: file, options: .withoutOverwriting)
        func mark(_ name: String) throws { try Data().write(to: dir.appendingPathComponent(name), options: .withoutOverwriting) }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }
        func read(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(name))) as? [String: Any])
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["PANEL_PROBE_EVIDENCE": dir.path, "HOME": home.path, "CFFIXED_USER_HOME": home.path]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "de.h5ventures.nexgenvideo.acceptance.panel-focus-fixture")
        let expectedBundle = URL(fileURLWithPath: try XCTUnwrap(env["PANEL_PROBE_BUNDLE"])).standardizedFileURL.resolvingSymlinksInPath()
        try require(running.count == 1 && running[0].bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == expectedBundle,
                    "XCTest did not launch the sole expected fixture app")
        let show = app.buttons["show-fixture-panel"], buttons = app.windows.descendants(matching: .button)
        let choose = buttons.matching(identifier: "Choose"), cancel = buttons.matching(identifier: "Cancel")
        let sheets = app.sheets.matching(NSPredicate(format: "identifier == %@", "GoToWindow"))
        let fields = sheets.descendants(matching: .textField).matching(NSPredicate(format: "identifier == %@", "PathTextField"))
        func open() throws {
            try wait("Owned fixture window unavailable") { app.state == .runningForeground && show.isHittable }
            show.click()
            try wait("Unique standard Choose panel missing") { app.state == .runningForeground && choose.count == 1 && sheets.count == 0 }
        }
        func ownedSheet() -> Bool { sheets.count == 1 && fields.count == 1 && fields.element.isEnabled && fields.element.isHittable }
        var result: [String: Any] = ["decision": "inconclusive", "phase": "local baseline"]
        var observed: [[String: Any]] = []
        defer {
            result["observations"] = observed
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("observer.json"), options: .atomic)
                let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                evidence.name = "Fixture-bound panel observation"
                evidence.lifetime = .keepAlways
                add(evidence)
            }
        }
        try open()
        try mark("observe-local")
        try wait("The host did not post the bound M76 shortcut") { exists("local-posted.json") || exists("local-error.json") }
        let posted = try XCTUnwrap(try read("local-posted.json")["uptime"] as? Double)
        result["phase"] = "passive observation"
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        repeat {
            let began = ProcessInfo.processInfo.systemUptime
            let count = sheets.count
            let valid = count == 1 && ownedSheet()
            observed.append(["began": began, "ended": ProcessInfo.processInfo.systemUptime, "sheetCount": count,
                             "pathEditorInUniqueSheet": valid, "foreground": app.state == .runningForeground])
            if exists("local-host.json") { break }
            Thread.sleep(forTimeInterval: 0.15)
        } while ProcessInfo.processInfo.systemUptime < deadline
        let local = try read("local-host.json")
        let samples = try XCTUnwrap(local["samples"] as? [[String: Any]])
        let elapsed = try XCTUnwrap(local["elapsed"] as? Double)
        let last = try XCTUnwrap(samples.last?["uptime"] as? Double)
        try require(!samples.isEmpty && elapsed >= 10 && observed.count >= 2, "Incomplete observation interval")
        let began = try XCTUnwrap(observed.first?["began"] as? Double), ended = try XCTUnwrap(observed.last?["ended"] as? Double)
        try require(began <= posted + 3 && ended >= last - 1 && observed.allSatisfy { $0["foreground"] as? Bool == true },
                    "The observer did not cover the original focus wait in the foreground")
        result["phase"] = "cancel observed panel"
        if sheets.count == 1 {
            sheets.element.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            try wait("Owned Go to Folder sheet did not close") { sheets.count == 0 }
        }
        try require(app.state == .runningForeground && sheets.count == 0 && cancel.count == 1 && cancel.element.isHittable,
                    "Cannot identify the original panel's Cancel control")
        cancel.element.click()
        try wait("Host did not receive the real Cancel response") { exists("response-1.json") }
        try require(try read("response-1.json")["cancelled"] as? Bool == true, "Unexpected observed panel response")

        result["phase"] = "independent external positive control"
        try open()
        app.typeKey("g", modifierFlags: [.command, .shift])
        try wait("External control could not locate the unique path editor") { ownedSheet() }
        try mark("sample-control")
        try wait("Host could not sample the independently identified control sheet") { exists("control-host.json") }
        try require(ownedSheet() && app.state == .runningForeground, "External control lost its owned path editor")
        let field = fields.element
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(file.path)
        try wait("Path editor did not display the exact ordinary fixture") { ownedSheet() && field.value as? String == file.path }
        field.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        try wait("The path editor did not return to the original Choose panel") {
            app.state == .runningForeground && sheets.count == 0 && choose.count == 1 && choose.element.isEnabled && choose.element.isHittable
        }
        choose.element.click()
        try wait("Host did not receive the external selection") { exists("response-2.json") }
        let selected = try read("response-2.json")
        try require(selected["accepted"] as? Bool == true && selected["exactFile"] as? Bool == true, "Wrong external selection")
        let sawPath = observed.contains { $0["pathEditorInUniqueSheet"] as? Bool == true }
        let sawSheet = observed.contains { ($0["sheetCount"] as? Int ?? 0) != 0 }
        let sawFocus = samples.contains { $0["m76FocusPredicate"] as? Bool == true }
        result["phase"] = "completed"
        let visible = observed.filter { $0["pathEditorInUniqueSheet"] as? Bool == true }
        let concurrentFocus = samples.contains { sample in
            guard sample["m76FocusPredicate"] as? Bool == true, let time = sample["uptime"] as? Double else { return false }
            return visible.contains { row in
                guard let start = row["began"] as? Double, let end = row["ended"] as? Double else { return false }
                return time >= start - 0.2 && time <= end + 0.2
            }
        }
        if sawPath {
            if concurrentFocus { result["decision"] = "minimal-fixture-reached-M76-focus" }
            else if !sawFocus { result["decision"] = "sheet-visible-to-XCTest-but-M76-focus-unavailable" }
            else { result["decision"] = "focus-and-sheet-not-observed-concurrently" }
        } else if !sawSheet && !sawFocus {
            result["decision"] = "no-visible-sheet-after-local-shortcut-external-control-passed"
        } else {
            result["decision"] = "ambiguous-sheet-or-focus-observation"
        }
    }
}
