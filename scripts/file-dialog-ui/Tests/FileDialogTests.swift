import AppKit
import CryptoKit
import XCTest

final class FileDialogTests: XCTestCase {
    private struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ reason: String) { errorDescription = reason }
    }

    private struct Fixture: Decodable {
        let scenario: String
        let scale: Int?
        let evidence: URL
        let app: URL
        let home: URL
        let report: URL
        let track: URL?
        let lyrics: URL?
        let fixtureRoot: URL?
    }

    private enum Step {
        case open(URL)
        case cancel
        case recovery(String)
        case clay
        case directory(URL)
        case save(URL)
    }

    private func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw Failure(reason) }
    }

    private func wait(_ reason: String, seconds: Double = 20, _ ready: () throws -> Bool) throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if try ready() { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while ProcessInfo.processInfo.systemUptime < end
        throw Failure(reason)
    }

    private func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    private func confinedFile(_ url: URL, below root: URL) throws -> URL {
        let file = canonical(url)
        try require(canonical(root).path == root.standardizedFileURL.path && file.path.hasPrefix(canonical(root).path + "/")
                    && (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                    "The scenario file is outside its fixture or unavailable")
        return file
    }

    private func recoveryFile(_ suffix: String, fixture: Fixture) throws -> URL {
        let recovery = fixture.home.appendingPathComponent("Library/Application Support/NexGenVideo/Recovery")
        let copies = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
        let files = copies.map { $0.appendingPathComponent("pipeline/" + suffix) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        try require(files.count == 1, "The scenario needs one matching project fixture")
        return try confinedFile(files[0], below: recovery)
    }

    private func derivedClay(_ fixture: Fixture) throws -> URL {
        let proof = try confinedFile(fixture.evidence.appendingPathComponent("production-spatial-shot-proof.json"), below: fixture.evidence)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: proof)) as? [String: Any])
        let id = try XCTUnwrap((expected["id"] as? String).flatMap(UUID.init(uuidString:))).uuidString.lowercased()
        let root = fixture.home.appendingPathComponent("Library/Application Support/NexGenVideo/Recovery")
        try require(canonical(root).path == root.standardizedFileURL.path, "The recovery directory moved")
        let fm = FileManager.default
        var matches: [URL] = []
        for project in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let blockout = project.appendingPathComponent("pipeline/execution/blockout")
            guard canonical(blockout).path.hasPrefix(canonical(root).path + "/"), fm.fileExists(atPath: blockout.path) else { continue }
            for namespace in try fm.contentsOfDirectory(at: blockout, includingPropertiesForKeys: nil) {
                let folder = namespace.appendingPathComponent("shot-" + id)
                let member = folder.appendingPathComponent("sequence.v1.json")
                guard fm.fileExists(atPath: member.path) else { continue }
                let source = try confinedFile(member, below: root)
                if try Data(contentsOf: source) == Data(contentsOf: proof) {
                    matches.append(try confinedFile(folder.appendingPathComponent("clay.mov"), below: root))
                }
            }
        }
        try require(matches.count == 1, "Ambiguous shot derivation")
        let outputs = try XCTUnwrap(expected["outputs"] as? [[String: Any]])
        let clips = outputs.filter { $0["filename"] as? String == "clay.mov" }
        try require(clips.count == 1, "Missing original clay output")
        let digest = SHA256.hash(data: try Data(contentsOf: matches[0], options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        try require(clips[0]["sha256"] as? String == digest, "Clay output differs from its source derivation")
        return matches[0]
    }

    private func scenario(_ fixture: Fixture) throws -> [Step] {
        let base = fixture.evidence
        let scale = fixture.scale ?? 100
        let effect = Step.recovery("bible/refs/native-effect.wav")
        switch fixture.scenario {
        case "musicvideo-intake":
            return [.save(base.appendingPathComponent("Native Music Video.ngv")), .open(base.appendingPathComponent("Track.wav"))]
        case "private-audio", "filmreview", "performance":
            let isPrivate = fixture.scenario == "private-audio"
            let suffix = fixture.scenario == "performance" ? "-performance" : ""
            let directory = isPrivate ? base : base.appendingPathComponent("scale-\(scale)-owner-v2-musicvideo" + suffix)
            let startup = isPrivate ? directory : directory.appendingPathComponent("startup")
            let movie = Step.open(directory.appendingPathComponent(isPrivate ? "private-song-moving-source.mov" : "Moving shapes with tone.mov"))
            var steps: [Step]
            if isPrivate {
                steps = [.open(try XCTUnwrap(fixture.track))]
                if let lyrics = fixture.lyrics { steps.append(.open(lyrics)) }
            } else {
                steps = [.save(startup.appendingPathComponent("Native Music Video.ngv")), .open(directory.appendingPathComponent("owner-song.wav"))]
            }
            steps += [.cancel, .open(startup.appendingPathComponent("Stage.png")), movie, movie, movie, .cancel, movie]
            if isPrivate { steps += [.cancel, movie] }
            return steps + [effect, .save(directory.appendingPathComponent("owner-v2-film.mp4"))]
        case "appnle":
            let directory = base.appendingPathComponent("app-nle-owner-\(scale)")
            let original = directory.appendingPathComponent("Original portrait.ngv"), copy = directory.appendingPathComponent("Independent copy.ngv")
            return [.save(original), .open(directory.appendingPathComponent("Moving shapes with tone.mov")),
                    .open(directory.appendingPathComponent("Second moving source.mov")), .save(directory.appendingPathComponent("Portrait 30fps.mp4")),
                    .save(copy), .directory(original), .directory(copy), .directory(copy)]
        case "genericnle":
            let dir = base.appendingPathComponent("generic-nle-\(scale)")
            let look = Step.open(dir.appendingPathComponent("second-look/Look.cube"))
            let render = base.appendingPathComponent("post-rendered-\(scale)")
            return [.open(dir.appendingPathComponent("Original warm moving shot.mov")), .cancel, .open(dir.appendingPathComponent("Invalid.cube")),
                    .open(dir.appendingPathComponent("first-look/Look.cube")), look, .save(dir.appendingPathComponent("Final cut.mp4")), look,
                    .open(base.appendingPathComponent("color-reference-\(scale)/Cool comparison reference.mov")),
                    .open(render.appendingPathComponent("Foreground.png")), .open(render.appendingPathComponent("Background.png"))]
        case "settings":
            return [.cancel, .directory(base.appendingPathComponent("settings-owner-\(scale)"))]
        case "packresume-start":
            return [.open(base.appendingPathComponent("Retained original song.wav")), .cancel,
                    .open(base.appendingPathComponent("legacy-approved/Stage.png"))]
        case "packresume-finish":
            let project = base.appendingPathComponent("fixture/Pinned original format.ngv")
            let movie = Step.open(project.appendingPathComponent("media/Retained original moving shot.mov"))
            return [movie, movie, movie, .directory(project)]
        case "bpy":
            var steps: [Step] = []
            let movie = Step.open(base.appendingPathComponent("complete-shot/clay.mov"))
            let light = Step.recovery("production_design/refs/lighting.png")
            for _ in [100, 125, 150] { steps += [.cancel, movie, movie, movie, light, light, light] }
            for size in [100, 125, 150] { steps.append(.save(base.appendingPathComponent("native-blockout-plan-\(size)-export.mov"))) }
            for size in [100, 125, 150] { steps += [.clay, .save(base.appendingPathComponent("native-blockout-import-\(size)-export.mov"))] }
            let panorama = Step.open(base.appendingPathComponent("native-owner-panorama.png"))
            for _ in [100, 125, 150] { steps += [.open(base.appendingPathComponent("native-owner-non-panorama.png")), panorama, panorama] }
            return steps
        default:
            throw Failure("Unknown file dialog scenario")
        }
    }

    @MainActor func testScenarioFileSelection() throws {
        continueAfterFailure = false
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["NGV_FILE_DIALOG_TEST_CONFIG"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: config)))
        try require(canonical(FileManager.default.homeDirectoryForCurrentUser).path == canonical(fixture.home).path, "Unexpected XCTest home")
        let app = XCUIApplication(url: fixture.app)
        let pidFile = fixture.report.appendingPathComponent("dialog-native.pid")
        let identifier = "de.h5ventures.nexgenvideo"
        let runnerWasFrontmost = NSRunningApplication.current.isActive
        if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
            NSApplication.shared.yieldActivation(toApplicationWithBundleIdentifier: identifier)
        }
        // The supervisor starts the selected executable and retains its actual exit status.
        try Data().write(to: fixture.report.appendingPathComponent("dialog-test-ready"), options: .withoutOverwriting)
        try wait("The supervised application was not started") { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        func isTarget() -> Bool {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            return running.count == 1 && running[0].processIdentifier == pid
                && running[0].bundleURL.map { canonical($0).path } == canonical(fixture.app).path
        }
        func activeTarget() throws {
            try require(isTarget() && app.state == .runningForeground && app.alerts.count == 0,
                        "The intended foreground application or modal context changed")
        }
        try wait("The supervised app did not register its bundle") { isTarget() }
        let target = try XCTUnwrap(NSRunningApplication(processIdentifier: pid))
        try require(target.bundleURL.map { canonical($0).path } == canonical(fixture.app).path,
                    "The supervised app bundle changed before activation")
        if !target.isActive {
            NSApplication.shared.yieldActivation(to: target)
            _ = target.activate(options: [])
        }
        try wait("The supervised app did not reach the foreground") {
            try require(isTarget(), "The supervised app exited during activation")
            return target.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        let foreground = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        try require(foreground.processIdentifier == pid && isTarget(), "The foreground app changed")
        let activation: [String: Any] = ["pid": Int(pid), "runnerWasFrontmost": runnerWasFrontmost,
                                         "foregroundPID": Int(foreground.processIdentifier), "bundle": try XCTUnwrap(target.bundleURL).path]
        try JSONSerialization.data(withJSONObject: activation).write(
            to: fixture.report.appendingPathComponent("dialog-activation.json"), options: .withoutOverwriting)
        let steps = try scenario(fixture)
        let sheets = app.sheets.matching(identifier: "GoToWindow")
        for (offset, step) in steps.enumerated() {
            let index = offset + 1
            let prefix = "file-panel-\(index)-"
            func file(_ name: String) -> URL { fixture.report.appendingPathComponent(prefix + name) }
            try wait("The expected native file panel did not appear", seconds: 1800) {
                if FileManager.default.fileExists(atPath: file("visible.json").path) { return true }
                if !isTarget() { throw Failure("The supervised application exited before the next panel") }
                return false
            }
            var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file("visible.json"))) as? [String: Any])
            let isSave: Bool
            let url: URL?
            switch step {
            case .cancel: isSave = false; url = nil
            case .save(let value):
                try require(canonical(value.deletingLastPathComponent()).path == canonical(fixture.evidence).path
                            || canonical(value.deletingLastPathComponent()).path.hasPrefix(canonical(fixture.evidence).path + "/"),
                            "Unexpected save directory")
                try require(!FileManager.default.fileExists(atPath: value.path), "Export destination already exists")
                isSave = true; url = value
            case .open(let value):
                let root = (value == fixture.track || value == fixture.lyrics) ? try XCTUnwrap(fixture.fixtureRoot) : fixture.evidence
                isSave = false; url = try confinedFile(value, below: root)
            case .recovery(let suffix): isSave = false; url = try recoveryFile(suffix, fixture: fixture)
            case .clay: isSave = false; url = try derivedClay(fixture)
            case .directory(let value):
                let folder = canonical(value)
                try require(folder.path.hasPrefix(canonical(fixture.evidence).path + "/")
                            && (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true, "Invalid scenario directory")
                isSave = false; url = folder
            }
            let action = isSave ? "save" : (url == nil ? "cancel" : "open")
            try require(receipt["pid"] as? Int == Int(pid) && receipt["step"] as? Int == index
                        && receipt["action"] as? String == action && (receipt["window"] as? Int ?? 0) > 0,
                        "The native panel does not match the fixed scenario")
            try activeTarget()
            try require(sheets.count == 0, "Unexpected Go to Folder sheet")
            if let url {
                if isSave {
                    let names = app.textFields.matching(identifier: "saveAsNameTextField")
                    try wait("The Save dialog has no unique filename") { names.count == 1 && names.element.isHittable }
                    let field = names.element
                    field.click()
                    field.typeKey("a", modifierFlags: .command)
                    field.typeText(url.lastPathComponent)
                    try wait("The Save dialog did not display the export name") {
                        let name = field.value as? String
                        return name == url.lastPathComponent || name == url.deletingPathExtension().lastPathComponent
                    }
                    receipt["filename"] = url.lastPathComponent
                }
                try activeTarget()
                app.typeKey("g", modifierFlags: [.command, .shift])
                let fields = sheets.descendants(matching: .textField).matching(identifier: "PathTextField")
                try wait("Missing unique native Go to Folder editor") { sheets.count == 1 && fields.count == 1 && fields.element.isHittable }
                let field = fields.element
                let path = (isSave ? url.deletingLastPathComponent() : url).path
                try activeTarget()
                field.click()
                field.typeKey("a", modifierFlags: .command)
                let board = NSPasteboard.general
                var pasteChange: Int?
                defer { if let pasteChange, board.changeCount == pasteChange { board.clearContents() } }
                if isSave {
                    field.typeText(path)
                } else {
                    board.clearContents()
                    try require(board.setString(path, forType: .string), "The native file path could not be copied")
                    pasteChange = board.changeCount
                    try activeTarget()
                    field.typeKey("v", modifierFlags: .command)
                }
                do {
                    try wait("The native path editor shows a different value") { field.value as? String == path }
                } catch {
                    let value = field.value
                    let failure: [String: Any] = ["pid": Int(pid), "step": index, "window": try XCTUnwrap(receipt["window"] as? Int),
                        "expected": path, "value": (value as? String) as Any? ?? NSNull(),
                        "valueType": String(describing: type(of: value)), "hittable": field.isHittable]
                    try JSONSerialization.data(withJSONObject: failure).write(to: file("path-failure.json"), options: .atomic)
                    throw error
                }
                receipt["typed"] = try XCTUnwrap(field.value as? String)
                receipt["pathField"] = field.identifier
                receipt["pathInput"] = isSave ? "typeText" : "commandV"
                field.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
                try wait("The Go to Folder editor did not close") { sheets.count == 0 }
            }
            try JSONSerialization.data(withJSONObject: receipt).write(to: file("input.json"), options: .atomic)
            try wait("The app did not observe the expected selection") { FileManager.default.fileExists(atPath: file("observed").path) }
            try activeTarget()
            try require(sheets.count == 0, "The path editor is still open")
            if !isSave {
                let observed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file("observed"))) as? [String: Any])
                let panelNumber = try XCTUnwrap(receipt["window"] as? Int)
                try require(observed["pid"] as? Int == Int(pid) && observed["step"] as? Int == index
                            && observed["window"] as? Int == panelNumber && observed["action"] as? String == action,
                            "The observed file panel changed")
                if let url {
                    try require(observed["selected"] as? String == url.path, "The open panel has not selected the intended file")
                } else {
                    try require(observed["selected"] == nil && receipt["typed"] == nil, "Unexpected input for Cancel")
                }
                try activeTarget()
                try require(sheets.count == 0, "A new path editor appeared before the file panel action")
                let windows = try XCTUnwrap(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                                       kCGNullWindowID) as? [[String: Any]])
                let targetWindows = windows.filter {
                    ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
                        && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
                }.compactMap { $0[kCGWindowNumber as String] as? Int }
                let current = targetWindows.first == panelNumber && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                let cancel = url == nil
                if current { app.typeKey(cancel ? XCUIKeyboardKey.escape.rawValue : XCUIKeyboardKey.return.rawValue, modifierFlags: []) }
                let key = cancel ? "sentEscape" : "sentReturn"
                let proof: [String: Any] = ["window": panelNumber, "visibleTargetWindows": targetWindows, key: current]
                try JSONSerialization.data(withJSONObject: proof)
                    .write(to: file(cancel ? "cancel-action.json" : "default-action.json"), options: .atomic)
                try require(current, "The observed file panel is no longer the frontmost target window")
                continue
            }
            let buttons = app.windows.descendants(matching: .button)
            func visibleButtons() -> [XCUIElement] {
                buttons.matching(identifier: "Save").allElementsBoundByIndex.filter { $0.isEnabled && $0.isHittable }
            }
            try wait("The native dialog action is missing or ambiguous") { visibleButtons().count == 1 }
            try activeTarget()
            let matches = visibleButtons()
            try require(matches.count == 1, "The native dialog action changed")
            matches[0].click()
        }
        try Data(String(steps.count).utf8).write(to: fixture.report.appendingPathComponent("dialog-test-steps"), options: .withoutOverwriting)
    }
}
