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
    private var geometrySamples: [[String: Any]] = []
    private var geometryPhases: [String: [[String: Any]]] = [:]
    private var evidenceSchema: String {
        switch config["scenario"] as? String ?? "" {
        case "transport": return "nexgenvideo/external-transport/1"
        case "normal-fresh-musicvideo": return "nexgenvideo/external-fresh-musicvideo/1"
        default: return "nexgenvideo/external-gui-journey/1"
        }
    }

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
            try write(["schema": evidenceSchema, "stages": stages,
                       "actions": actions], to: output.appendingPathComponent("journey.json"))
        }
    }

    func testGenericEditingThroughInstalledApp() throws {
        try require(config["scenario"] == nil, "The normal journey received another scenario")
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
        try click(sourceInsert(in: project), "Insert")
        try key("s", modifiers: .command)
        try wait("inserted clip saved") { (try? self.clips(self.timeline(project)).count) == 1 }
        let inserted = try snapshot("source-insert", project: project)
        try require(integer(inserted["fps"]) == 30 && integer(inserted["width"]) == 320
                    && integer(inserted["height"]) == 180, "First source settings did not reach the timeline")
        try require(integer(clips(inserted).first?["durationFrames"]) == 120,
                    "The source was not inserted at its full duration")
        try stage("source-insert", fields: ["clearRangeEnabled": clearRangeEnabled])

        try menu("View", "Edit Workspace")
        try focusTimeline(project)
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

    func testNormalFreshMusicvideoThroughInstalledApp() throws {
        try require(config["scenario"] as? String == "normal-fresh-musicvideo", "Missing explicit fresh Musicvideo scenario")
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NexGenVideo/Plugins", isDirectory: true)
        let initial = FileManager.default.fileExists(atPath: library.path)
            ? try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            : []
        try require(initial.isEmpty, "The supposedly fresh profile already contains packs")
        try write(["installedEntries": initial.count, "observedAt": ISO8601DateFormatter().string(from: Date())],
                  to: output.appendingPathComponent("profile-before-launch.json"))
        try launch()
        try home()
        try stage("fresh-profile", fields: ["installedEntries": initial.count])
        try stage("home")
        try menu("NexGenVideo", "Settings…")
        let settings = app.windows["Settings"]
        let pickers = settings.popUpButtons.matching(NSPredicate(format: "label == %@", "Interface text, Interface text size"))
        try wait("unique Interface text size control") { pickers.count == 1 }
        let picker = pickers.element(boundBy: 0)
        let scale = try string("scaleLabel")
        try click(picker, "Interface text size")
        try click(app.menuItems[scale], scale)
        try wait("selected interface text size") { String(describing: picker.value ?? "").contains(scale) }
        try stage("settings", fields: ["scaleLabel": scale, "selectedValue": String(describing: picker.value ?? "")])
        try click(settings.buttons[XCUIIdentifierCloseWindow], "native Settings close")
        try wait("Settings closed") { !settings.exists }
        try menu("File", "New")
        let bootstrap = URL(fileURLWithPath: try string("bootstrapProject"))
        try savePanel(name: bootstrap.deletingPathExtension().lastPathComponent, previous: "Untitled Project",
                      directory: bootstrap.deletingLastPathComponent())
        try editor(bootstrap)
        try click(windowButtons["Project settings"], "Project settings")
        try click(windowButtons["Choose Plugin…"], "Choose Plugin…")
        try wait("normal Format Plugins catalog card", timeout: 90) {
            self.app.staticTexts["Format Plugins"].exists && self.windowButtons["Activate"].isHittable
        }
        try stage("catalog-card")
        try click(windowButtons["Activate"], "Activate Music Video")
        let bundle = library.appendingPathComponent("musicvideo/0.6.0.ngvpack", isDirectory: true)
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        try wait("downloaded exact Musicvideo pack", timeout: 120) { FileManager.default.fileExists(atPath: infoURL.path) }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), options: [], format: nil) as? [String: Any]
        try require(info?["NGVPackID"] as? String == "musicvideo"
                    && info?["CFBundleShortVersionString"] as? String == "0.6.0"
                    && info?["NGVProjectSchema"] as? String == "musicvideo/3.0.0"
                    && info?["NGVMinAppVersion"] as? String == "1.8.0", "The public catalog installed a different pack")
        try wait("plugin picker closed") { !self.app.staticTexts["Format Plugins"].exists }
        try key("s", modifiers: .command)
        try wait("activated exact project binding") {
            guard let value = try? self.json(bootstrap.appendingPathComponent("ngv.json")) else { return false }
            return value["activePlugin"] as? String == "musicvideo" && value["activePluginVersion"] as? String == "0.6.0"
                && value["activePluginProjectSchema"] as? String == "musicvideo/3.0.0"
        }
        let bootstrapBinding = try json(bootstrap.appendingPathComponent("ngv.json"))
        try write(bootstrapBinding, to: output.appendingPathComponent("bootstrap-binding.json"))
        try stage("installed-and-activated", fields: ["packID": "musicvideo", "version": "0.6.0", "schema": "musicvideo/3.0.0"])
        let window = try documentWindow(bootstrap)
        try click(window.buttons[XCUIIdentifierCloseWindow], "native bootstrap close")
        try wait("bootstrap closed") { !window.exists }
        try home()
        let newProject = windowButtons.matching(NSPredicate(format: "label == %@", "New Project"))
        try wait("Home New Project") { newProject.count == 1 }
        try click(newProject.element(boundBy: 0), "Home New Project")
        try wait("normal format selection") { self.app.staticTexts["Choose a format"].exists }
        let music = windowButtons.matching(NSPredicate(format: "label CONTAINS %@", "Music Video"))
        try wait("unique Music Video format") { music.count == 1 && music.element(boundBy: 0).isHittable }
        try click(music.element(boundBy: 0), "Music Video")
        try click(windowButtons["Create"], "Create Music Video project")
        let project = URL(fileURLWithPath: try string("project"))
        try savePanel(name: project.deletingPathExtension().lastPathComponent, previous: "Untitled Project",
                      directory: project.deletingLastPathComponent())
        try editor(project)
        try key("s", modifiers: .command)
        let binding = try json(project.appendingPathComponent("ngv.json"))
        try require(binding["activePlugin"] as? String == "musicvideo" && binding["activePluginVersion"] as? String == "0.6.0"
                    && binding["activePluginProjectSchema"] as? String == "musicvideo/3.0.0", "Fresh creation did not retain the exact catalog binding")
        try write(binding, to: output.appendingPathComponent("fresh-binding.json"))
        try stage("new-musicvideo-project", fields: ["packID": "musicvideo", "version": "0.6.0", "schema": "musicvideo/3.0.0"])
        try click(windowButtons["Project settings"], "Project settings")
        try click(windowButtons["Start production"], "Start production")
        try wait("first required Track intake", timeout: 90) {
            self.app.staticTexts["Track"].exists && self.windowButtons["Choose…"].exists
                && self.windowButtons["Choose…"].isEnabled && self.windowButtons["Attach track"].exists
                && !self.windowButtons["Attach track"].isEnabled
        }
        try require(!windowButtons["Attach lyrics"].exists, "Track was bypassed before any assignment")
        let audio = (try? FileManager.default.contentsOfDirectory(at: project.appendingPathComponent("audio"),
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        try require(audio.isEmpty, "The installation check unexpectedly assigned a track")
        try stage("track-intake", fields: ["chooseEnabled": windowButtons["Choose…"].isEnabled,
            "attachEnabled": windowButtons["Attach track"].isEnabled, "trackUploaded": !audio.isEmpty])
    }

    func testTimelineTransportThroughInstalledApp() throws {
        try require(config["scenario"] as? String == "transport", "Missing explicit transport scenario")
        guard let fixture = config["transportFixture"] as? [String: Any],
              let hashes = fixture["projectFiles"] as? [String: String] else {
            throw Failure(message: "Missing independently verified transport fixture")
        }
        try require(integer(fixture["fps"]) == 30 && integer(fixture["endFrame"]) == 120
                    && integer(fixture["sourceFrames"]) == 120, "Unexpected transport endpoint oracle")
        let project = URL(fileURLWithPath: try string("project"))
        try verifyTransportFiles(project, hashes: hashes)
        try require(try digest(URL(fileURLWithPath: string("source"))) == fixture["sourceSHA256"] as? String,
                    "The transport source bytes changed")
        try launch()
        try home()
        try menu("NexGenVideo", "Settings…")
        let settings = app.windows["Settings"]
        let pickers = settings.popUpButtons.matching(NSPredicate(format: "label == %@", "Interface text, Interface text size"))
        try wait("unique transport text size picker") { pickers.count == 1 }
        let picker = pickers.element(boundBy: 0)
        let scale = try string("scaleLabel")
        try click(picker, "Interface text size")
        try click(app.menuItems[scale], scale)
        try wait("transport interface text size") { String(describing: picker.value ?? "").contains(scale) }
        try click(settings.buttons[XCUIIdentifierCloseWindow], "native Settings close")
        try wait("transport Settings closed") { !settings.exists }
        try menu("File", "Open…")
        try openPanel(project)
        try editor(project)
        try focusTimeline(project)
        let window = try documentWindow(project)
        try menu("View", "Edit Workspace")
        try menu("View", "Layout")
        try click(app.menuItems["Default"], "Default layout")
        let preview = window.staticTexts.matching(NSPredicate(format: "label == %@", "Film Preview"))
        try wait("unique visible Film Preview title") {
            self.visibleInputs(preview).count == 1
        }
        try transportGeometryPair("before", window: window)
        try click(visibleInputs(preview)[0], "Film Preview focus")
        try menu("View", "Maximize Focused Panel")
        try transportGeometryPair("maximized", window: window)
        try transportSurface("maximized-timeline-preview", window: window)
        try key(XCUIKeyboardKey.escape.rawValue)
        try transportGeometryPair("restored", window: window)
        try menu("View", "Theater")
        let exit = try transportButton("Exit Theater", window: window)
        try require(exit.isHittable, "The actual Theater exit is absent")
        try transportSurface("theater-timeline", window: window)
        try click(exit, "Exit Theater")
        try wait("public Theater exit") { !exit.exists || !exit.isHittable }
        try click(window.buttons[XCUIIdentifierCloseWindow], "native transport document close")
        try wait("transport document closed") { !window.exists }
        try verifyTransportFiles(project, hashes: hashes)
    }

    private func verifyTransportFiles(_ project: URL, hashes: [String: String]) throws {
        try require(Set(hashes.keys) == Set(["project.json", "media.json", "ngv.json"]), "Incomplete transport project bytes")
        for (name, expected) in hashes {
            try require(try digest(project.appendingPathComponent(name)) == expected, "Transport changed " + name)
        }
    }

    private func transportGeometryPair(_ phase: String, window: XCUIElement) throws {
        let deadline = Date().addingTimeInterval(20)
        var first = try transportGeometrySnapshot(phase, window: window)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let second = try transportGeometrySnapshot(phase, window: window)
            let a = try JSONSerialization.data(withJSONObject: first["nodes"]!, options: [.sortedKeys])
            let b = try JSONSerialization.data(withJSONObject: second["nodes"]!, options: [.sortedKeys])
            if a == b {
                geometryPhases[phase] = [first, second]
                try write(["schema": "nexgenvideo/public-preview-geometry/1", "phases": geometryPhases],
                          to: output.appendingPathComponent("geometry.json"))
                return
            }
            first = second
        }
        throw Failure(message: "The public preview hierarchy did not settle for " + phase)
    }

    private func transportGeometrySnapshot(_ phase: String, window: XCUIElement) throws -> [String: Any] {
        let capture = try evidence("preview-geometry-" + phase)
        try require(window.sheets.count == 0 && app.alerts.count == 0 && app.dialogs.count == 0,
                    "A modal surface blocks the preview geometry")
        var nodes: [[String: Any]] = []
        func walk(_ element: XCUIElement, path: String, parent: String?, depth: Int) throws {
            try require(depth <= 40 && nodes.count < 3000, "The public accessibility hierarchy is unbounded")
            let frame = element.frame
            let coordinates = [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
            let kind: String
            switch element.elementType {
            case .window: kind = "window"
            case .group: kind = "group"
            case .splitGroup: kind = "splitGroup"
            case .button: kind = "button"
            case .staticText: kind = "staticText"
            default: kind = "other-" + String(element.elementType.rawValue)
            }
            nodes.append(["path": path, "parent": parent.map { $0 as Any } ?? NSNull(), "type": kind,
                          "title": element.title, "label": element.label,
                          "value": element.value as? String ?? "", "identifier": element.identifier,
                          "enabled": element.isEnabled, "hittable": element.isHittable,
                          "frame": coordinates.allSatisfy(\.isFinite) ? coordinates : [],
                          "invalidFrame": coordinates.allSatisfy(\.isFinite) ? "" : frame.debugDescription])
            for (index, child) in element.children(matching: .any).allElementsBoundByIndex.enumerated() {
                try walk(child, path: path + "/" + String(index), parent: path, depth: depth + 1)
            }
        }
        try walk(window, path: "w", parent: nil, depth: 0)
        let anchors = try [("staticText", "Film Preview"), ("button", "Go to Start"), ("button", "Go to End")].map { anchor in
            let (kind, label) = anchor
            let matches = nodes.filter { node in
                node["type"] as? String == kind && node["label"] as? String == label
                    && node["enabled"] as? Bool == true && node["hittable"] as? Bool == true
            }
            try require(matches.count == 1, "The public preview anchor is missing or ambiguous: " + label)
            return matches[0]["path"] as! String
        }
        let common = nodes.filter { node in
            guard let path = node["path"] as? String, path != "w" else { return false }
            return anchors.allSatisfy { $0.hasPrefix(path + "/") }
        }
        let minimal = common.filter { node in
            let path = node["path"] as! String
            return !common.contains { other in
                (other["path"] as! String).hasPrefix(path + "/")
            }
        }
        try require(minimal.count == 1, "The public preview has no unique minimal common container")
        let observation: [String: Any] = ["phase": phase, "time": Date().timeIntervalSince1970,
                                        "nodes": nodes, "selectedPreviewPath": minimal[0]["path"] as! String,
                                        "modalCounts": ["sheets": window.sheets.count, "alerts": app.alerts.count, "dialogs": app.dialogs.count],
                                        "evidence": capture, "actionCount": actions.count]
        geometrySamples.append(observation)
        try write(["schema": "nexgenvideo/public-preview-geometry-samples/1", "samples": geometrySamples],
                  to: output.appendingPathComponent("geometry-samples.json"))
        return observation
    }

    private func transportButton(_ label: String, window: XCUIElement) throws -> XCUIElement {
        let query = window.buttons.matching(NSPredicate(format: "label == %@", label))
        try wait("unique visible " + label) { self.visibleInputs(query).count == 1 }
        let button = visibleInputs(query)[0]
        try require(finiteFrame(button.frame) && window.frame.contains(button.frame), "Transport control escaped its window")
        return button
    }

    private func transportSurface(_ surface: String, window: XCUIElement) throws {
        let start = try transportButton("Go to Start", window: window)
        let end = try transportButton("Go to End", window: window)
        try require(start.frame.maxX < end.frame.minX, "Transport endpoint order is reversed")
        let initial = try transportCursor(window, start: start)
        let frame = initial["frame"] as? Int ?? -1
        if frame == 0 {
            try click(transportButton("Next Frame", window: window), "transport preparation Next Frame")
            _ = try stableTransportCursor(1, window: window, start: start)
        } else if frame == 120 {
            try click(transportButton("Previous Frame", window: window), "transport preparation Previous Frame")
            _ = try stableTransportCursor(119, window: window, start: start)
        }
        let prepared = try transportCursor(window, start: start)
        let preparedFrame = prepared["frame"] as? Int ?? -1
        try require(preparedFrame > 0 && preparedFrame < 120, "Transport did not begin at a real interior cursor")
        for (ordinal, target) in [0, 120, 0].enumerated() {
            let button = target == 120 ? end : start
            let before = try transportCursor(window, start: start)
            try require(before["frame"] as? Int != target, "An endpoint action would be a no-op")
            let control = publicTransportElement(button)
            let preceding = try evidence(surface + "-before-" + String(ordinal))
            try click(button, target == 120 ? "Go to End" : "Go to Start")
            let after = try stableTransportCursor(target, window: window, start: start)
            try stage(surface + "-" + String(ordinal), fields: [
                "surface": surface, "endpointOrdinal": ordinal, "targetFrame": target,
                "before": before, "after": after, "control": control, "beforeEvidence": preceding,
                "window": publicTransportElement(window), "paused": true
            ])
        }
    }

    private func stableTransportCursor(_ expected: Int, window: XCUIElement, start: XCUIElement) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(20)
        var stableSince: Date?
        var observations = 0
        var result: [String: Any] = [:]
        while Date() < deadline {
            result = try transportCursor(window, start: start)
            if result["frame"] as? Int == expected {
                if stableSince == nil { stableSince = Date(); observations = 0 }
                observations += 1
                if let since = stableSince, Date().timeIntervalSince(since) >= 0.5 && observations >= 2 {
                    result["stableSeconds"] = Date().timeIntervalSince(since)
                    result["observations"] = observations
                    return result
                }
            } else { stableSince = nil; observations = 0 }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try require(false, "The public cursor did not reach stable frame " + String(expected))
        return result
    }

    private func transportCursor(_ window: XCUIElement, start: XCUIElement) throws -> [String: Any] {
        _ = try transportButton("Play", window: window)
        try require(visibleInputs(window.buttons.matching(NSPredicate(format: "label == %@", "Pause"))).isEmpty,
                    "Transport must remain paused")
        var candidates: [(XCUIElement, [Int], String)] = []
        for text in window.staticTexts.allElementsBoundByIndex {
            let frame = text.frame
            guard text.exists && text.isHittable && finiteFrame(frame) && window.frame.contains(frame)
                    && frame.maxX <= start.frame.minX
                    && abs(frame.midY - start.frame.midY) <= max(frame.height, start.frame.height) / 2 else { continue }
            let values = [text.label, text.value as? String ?? ""].filter { !$0.isEmpty }
            let parsed = values.compactMap { transportTimecodes($0) }
            guard let tokens = parsed.first else { continue }
            try require(parsed.allSatisfy { $0 == tokens }, "Public cursor label and value disagree")
            candidates.append((text, tokens, values[0]))
        }
        candidates.sort { $0.0.frame.minX < $1.0.frame.minX }
        try require(candidates.count == 1 || candidates.count == 2, "Public cursor and duration layout is ambiguous")
        guard let current = candidates.first else { throw Failure(message: "No public cursor field") }
        if candidates.count == 2 {
            try require(current.1.count == 1 && candidates[1].1 == [120]
                        && current.0.frame.maxX <= candidates[1].0.frame.minX, "Cursor and duration fields overlap or disagree")
        } else {
            try require(current.1.count == 1 || current.1 == [current.1[0], 120], "Combined cursor and duration disagree")
        }
        return ["frame": current.1[0], "role": "left-current-cursor", "field": publicTransportElement(current.0),
                "startControl": publicTransportElement(start),
                "candidates": candidates.map { ["element": publicTransportElement($0.0), "tokens": $0.1] }]
    }

    private func transportTimecodes(_ value: String) -> [Int]? {
        let tokens = value.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(tokens.count) else { return nil }
        var frames: [Int] = []
        for token in tokens {
            let parts = token.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4 && parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }) else { return nil }
            let values = parts.compactMap { Int($0) }
            guard values.count == 4 && values[1] < 60 && values[2] < 60 && values[3] < 30 else { return nil }
            frames.append(((values[0] * 60 + values[1]) * 60 + values[2]) * 30 + values[3])
        }
        return frames
    }

    private func finiteFrame(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
    }

    private func publicTransportElement(_ element: XCUIElement) -> [String: Any] {
        ["label": element.label, "value": element.value as? String ?? "", "identifier": element.identifier,
         "enabled": element.isEnabled, "hittable": element.isHittable,
         "frame": [element.frame.minX, element.frame.minY, element.frame.width, element.frame.height]]
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

    private func focusTimeline(_ project: URL) throws {
        let window = try documentWindow(project)
        let windowFrame = window.frame
        let candidates = window.scrollViews.allElementsBoundByIndex.filter { pane in
            let viewport = pane.frame.intersection(windowFrame)
            guard viewport.minX.isFinite && viewport.minY.isFinite && viewport.width.isFinite
                    && viewport.height.isFinite && viewport.width > 48 && viewport.height > 48 else { return false }
            return pane.scrollBars.allElementsBoundByIndex.contains {
                let bar = $0.frame.intersection(viewport)
                return !bar.isEmpty && bar.width.isFinite && bar.height.isFinite && bar.width > bar.height
            }
        }
        try require(candidates.count == 1, "The document has no unique visible timeline scroll area")
        let canvas = candidates[0]
        let frame = canvas.frame
        let viewport = frame.intersection(windowFrame)
        let point = CGPoint(x: viewport.minX + 24, y: viewport.midY)
        try require(viewport.contains(point) && point.y > viewport.minY + 24
                    && canvas.scrollBars.allElementsBoundByIndex.allSatisfy { !$0.frame.contains(point) },
                    "The timeline focus point intersects its ruler, scrollbars or clipped bounds")
        recordAction(["kind": "click", "target": "visible timeline canvas", "x": point.x, "y": point.y,
                        "windowFrame": NSStringFromRect(windowFrame), "canvasFrame": NSStringFromRect(frame),
                        "visibleViewport": NSStringFromRect(viewport)])
        let coordinate = canvas.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY))
        coordinate.click()
        try wait("timeline preview after canvas focus") {
            window.staticTexts["Film Preview"].exists && window.staticTexts["Film Preview"].isHittable
        }
        _ = try evidence("timeline-canvas-focus")
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

    private func sourceInsert(in project: URL) throws -> XCUIElement {
        let window = try documentWindow(project)
        let panes = window.scrollViews
            .containing(.button, identifier: "Insert").containing(.button, identifier: "Clear Range")
        try wait("unique source inspector") { panes.count == 1 }
        let pane = panes.element(boundBy: 0)
        let buttons = pane.buttons.matching(NSPredicate(format: "label == %@", "Insert"))
        try require(buttons.count == 1, "Source Insert is missing or ambiguous")
        let button = buttons.element(boundBy: 0)
        try wait("enabled source Insert") { button.exists && button.isEnabled }
        let viewport = pane.frame
        try require(viewport.minX.isFinite && viewport.minY.isFinite && viewport.width.isFinite
                    && viewport.height.isFinite && !viewport.isEmpty
                    && window.frame.contains(viewport), "The source inspector viewport is not visible")
        var deltaY = -viewport.height * 0.75
        for _ in 0..<4 {
            let before = button.frame
            if button.isHittable && viewport.contains(before) {
                _ = try evidence("source-insert-visible")
                return button
            }
            let action = actions.count
            recordAction(["kind": "scroll", "target": "Source inspector", "deltaX": 0, "deltaY": deltaY,
                            "viewport": NSStringFromRect(viewport), "beforeFrame": NSStringFromRect(before),
                            "targetEnabled": button.isEnabled])
            pane.scroll(byDeltaX: 0, deltaY: deltaY)
            let after = button.frame
            actions[action]["afterFrame"] = NSStringFromRect(after)
            actions[action]["targetHittable"] = button.isHittable
            if abs(after.midY - viewport.midY) >= abs(before.midY - viewport.midY) { deltaY = -deltaY }
        }
        try require(button.isHittable && viewport.contains(button.frame), "Source Insert remains outside its visible inspector")
        _ = try evidence("source-insert-visible")
        return button
    }

    private func click(_ element: XCUIElement, _ name: String) throws {
        try wait(name) { element.exists && element.isEnabled && element.isHittable }
        recordAction(["kind": "click", "target": name, "frame": NSStringFromRect(element.frame)])
        element.click()
    }

    private func key(_ key: String, modifiers: XCUIElement.KeyModifierFlags = [], in element: XCUIElement? = nil) throws {
        recordAction(["kind": "key", "key": key, "modifiers": modifiers.rawValue])
        if let element { element.typeKey(key, modifierFlags: modifiers) }
        else { app.typeKey(key, modifierFlags: modifiers) }
    }

    private func type(_ text: String, in element: XCUIElement) throws {
        recordAction(["kind": "text", "text": text, "identifier": element.identifier, "label": element.label])
        element.typeText(text)
    }

    private func recordAction(_ fields: [String: Any]) {
        var action = fields
        if config["scenario"] as? String == "transport" { action["time"] = Date().timeIntervalSince1970 }
        actions.append(action)
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
        try write(["schema": evidenceSchema, "stages": stages,
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
