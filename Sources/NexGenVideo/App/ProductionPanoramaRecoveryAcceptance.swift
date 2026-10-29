import AppKit
import NexGenEngine

@MainActor
enum ProductionPanoramaRecoveryAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context, locationID: String, source: URL,
                    scale: Double, driver: ProductionVisualSourcesDriver, output: URL) async throws {
        let root = context.dataRoot, window = driver.window
        let directory = output.appendingPathComponent("panorama-batch-\(Int(scale * 100))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = try await bible(root)
        try PlanningWriterIO.json(first).write(to: directory.appendingPathComponent("bible-initial.json"))
        let initialBytes = try await bibleBytes(root)
        try initialBytes.write(to: directory.appendingPathComponent("bible-negative-before.yaml"))
        guard let location = first.locations.first(where: { $0.id == locationID }),
              let receipt = try await Task.detached(operation: { try PipelinePanoramaStore.current(location: location, dataRoot: root) }).value,
              let pov = receipt.views.first else { throw failed("The actual first panorama selection is missing.") }
        let copy = try await Task.detached {
            let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "bible", leaf: "negative-pov-" + UUID().uuidString.lowercased() + ".png", dataRoot: root)
            _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: root)
            try FileManager.default.copyItem(at: ProjectLocalFile.requireHash(pov.image.sha256, at: pov.image.path, dataRoot: root), to: root.appendingPathComponent(path))
            return path
        }.value
        for (name, path) in [("panorama-alias", receipt.panorama.path), ("copied-pov", copy), ("character-sheet", copy)] {
            var candidate = first
            if name == "character-sheet" {
                candidate.characters.append(try Character(id: "panorama_negative_person", name: "Negative fixture person",
                    visualPrompt: "A person.", sheets: ["front": path]))
            } else {
                guard let index = candidate.locations.firstIndex(where: { $0.id == locationID }) else { throw failed("The selected location disappeared.") }
                candidate.locations[index].sheets["negative_alias"] = path
            }
            let arguments = try ProductionBibleToolFixture.arguments(candidate)
            let beforeSHA = try await bibleSHA(root)
            guard beforeSHA == FileDigest.sha256(of: initialBytes) else { throw failed("The negative baseline changed.") }
            let input = try await Task.detached { try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root)) }.value
            let inputCopy = "negative-input-" + name + ".bin"
            try input.write(to: directory.appendingPathComponent(inputCopy))
            let result = await context.executor.execute(name: "write_bible", args: arguments)
            let message = result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
            guard result.isError, message.contains("A panorama geometry anchor cannot supply appearance, style or identity."),
                  try await bible(root) == first, try await bibleSHA(root) == beforeSHA else { throw failed("The actual write_bible path accepted raw panorama geometry as an appearance sheet.") }
            let afterBytes = try await bibleBytes(root)
            let afterCopy = "bible-negative-after-" + name + ".yaml"
            try afterBytes.write(to: directory.appendingPathComponent(afterCopy))
            let artifact: [String: Any] = ["case": name, "arguments": arguments, "isError": result.isError, "error": message,
                "bibleSHA256Before": beforeSHA, "bibleSHA256After": try await bibleSHA(root),
                "path": path, "sha256": FileDigest.sha256(of: input), "inputCopy": inputCopy,
                "beforeCopy": "bible-negative-before.yaml", "afterCopy": afterCopy]
            try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(name + ".json"))
            try driver.record("actual panorama sheet refusal " + name, fields: ["error": message, "canonicalUnchanged": true])
        }
        let secondID = "panorama_recovery_room"
        let createdSecondLocation = !first.locations.contains(where: { $0.id == secondID })
        if createdSecondLocation {
            let appearance = try await ProductionRetainedSpatialAcceptance.prepareAppearanceFixture(context: context,
                locationID: secondID, locationName: "Second recovery room")
            var fixture = first
            fixture.locations.append(try Location(id: secondID, name: "Second recovery room", visualPrompt: "A second room.", referenceImages: ["production_design/refs/lighting.png"], sheets: ["owner_appearance": appearance]))
            try await ProductionPlanningAcceptanceFixture.run("write_bible", args: ProductionBibleToolFixture.arguments(fixture), in: context)
        }
        let selectedSourceSHA256 = try await Task.detached { try FileDigest.sha256(of: source) }.value
        try await driver.click("bible.panorama.open." + secondID, in: window)
        let sheet = try await driver.sheet("bible.panorama.sheet")
        try await driver.chooseFile(source, in: sheet, trigger: "bible.panorama.choose")
        try await driver.click("bible.panorama.custom", in: sheet)
        try await driver.fill("bible.panorama.name", value: "panorama", in: sheet)
        try await driver.fill("bible.panorama.yaw", value: "0", in: sheet)
        try await driver.fill("bible.panorama.pitch", value: "0", in: sheet)
        try await driver.fill("bible.panorama.fov", value: "60", in: sheet)
        try await driver.click("bible.panorama.extract", in: sheet)
        try await driver.wait("noncolliding panorama-named view") {
            driver.text("bible.panorama.candidate", in: sheet) != nil && driver.text("bible.panorama.image.panorama", in: sheet) != nil
        }
        for name in defaultFourWallPovs.map(\.name) + ["panorama"] { try await driver.inspect("bible.panorama.inspect." + name, in: sheet) }
        try await driver.click("bible.panorama.reviewed", in: sheet)
        try await driver.click("bible.panorama.confirm", in: sheet)
        try await driver.wait("second genuine panorama selection") { window.attachedSheet == nil }
        let selected = try await bible(root)
        try await Task.detached {
            guard let location = selected.locations.first(where: { $0.id == secondID }),
                  let receipt = try PipelinePanoramaStore.current(location: location, dataRoot: root),
                  receipt.views.map(\.geometry) == (defaultFourWallPovs + [.init(name: "panorama", yawDegrees: 0, pitchDegrees: 0, fovHorizontalDegrees: 60)]).map(Scene3D.PovRecord.init),
                  receipt.panorama.sha256 == selectedSourceSHA256, try FileDigest.sha256(of: source) == selectedSourceSHA256,
                  receipt.panorama.path.hasSuffix("/source.panorama"),
                  receipt.views.allSatisfy({ $0.image.path != receipt.panorama.path }) else {
                throw failed("The actual selected source collided with its panorama-named view.")
            }
            let references = [(receipt.panorama, "second-source.panorama")]
                + receipt.views.map { ($0.image, "second-view-" + $0.geometry.name + ".png") }
            for (reference, name) in references {
                try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root))
                    .write(to: directory.appendingPathComponent(name))
            }
        }.value
        let ids = [locationID, secondID]
        let receipts = try await Task.detached {
            try ids.map { id -> (String, Data) in
                guard let location = selected.locations.first(where: { $0.id == id }),
                      let reference = try PipelinePanoramaStore.references(location: location, dataRoot: root).first else { throw failed("Both selections need actual native receipt bytes.") }
                return (reference.path, try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)))
            }
        }.value
        try PlanningWriterIO.json(selected).write(to: directory.appendingPathComponent("bible-selected.json"))
        try await bibleBytes(root).write(to: directory.appendingPathComponent("bible-selected.yaml"))
        for (index, receipt) in receipts.enumerated() { try receipt.1.write(to: directory.appendingPathComponent("receipt-\(index).json")) }
        var restored = false
        defer { if !restored { for receipt in receipts { try? receipt.1.write(to: root.appendingPathComponent(receipt.0), options: .atomic) } } }
        var pass = 0
        func damage() throws {
            pass += 1
            let original = root.appendingPathComponent(receipts[0].0)
            let quarantine = directory.appendingPathComponent("missing-" + UUID().uuidString)
            try FileManager.default.moveItem(at: original, to: quarantine)
            try Data("changed second native receipt".utf8).write(to: root.appendingPathComponent(receipts[1].0), options: .atomic)
            let observed: [[String: Any]] = try receipts.enumerated().map { index, receipt in
                let url = root.appendingPathComponent(receipt.0), exists = FileManager.default.fileExists(atPath: url.path)
                let actualHash: Any
                if exists { actualHash = try FileDigest.sha256(of: url) } else { actualHash = NSNull() }
                return ["path": receipt.0, "expectedSHA256": FileDigest.sha256(of: receipt.1),
                    "exists": exists, "actualSHA256": actualHash,
                    "state": index == 0 ? "missing" : "tampered"]
            }
            try JSONSerialization.data(withJSONObject: observed, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("damage-\(pass).json"))
        }
        func restore() throws { for receipt in receipts { try receipt.1.write(to: root.appendingPathComponent(receipt.0), options: .atomic) } }
        func removeBoth() async throws -> Bible {
            guard let manager = context.editor.undoManager else { throw failed("The native document has no Undo manager.") }
            manager.removeAllActions()
            guard !manager.canUndo else { throw failed("The recovery fixture did not start with empty Undo history.") }
            try await driver.click("bible.panorama.open." + locationID, in: window)
            let recovery = try await driver.sheet("bible.panorama.sheet")
            try await driver.wait("both invalid assignments listed before removal") {
                driver.text("bible.panorama.invalid-locations", in: recovery) == ids.joined(separator: ",")
                    && driver.state("bible.panorama.remove-invalid", in: recovery) == true
            }
            try driver.record("actual invalid panorama list \(pass)", fields: ["visibleLocationIDs": driver.text("bible.panorama.invalid-locations", in: recovery) ?? ""])
            try driver.capture("two-invalid-panorama-assignments", target: recovery)
            try await driver.click("bible.panorama.remove-invalid", in: recovery)
            try await driver.wait("one native transaction removed both invalid selections") { window.attachedSheet == nil }
            let after = try await bible(root)
            for id in ids {
                guard let old = selected.locations.first(where: { $0.id == id }), let new = after.locations.first(where: { $0.id == id }),
                      new.scene3d == Scene3D(), new.attributes[PipelinePanoramaStore.receiptPathKey] == nil,
                      new.attributes[PipelinePanoramaStore.receiptHashKey] == nil,
                      new.sheets == old.sheets, new.referenceImages == old.referenceImages else { throw failed("Batch recovery did not clear exactly the shown selections.") }
            }
            try await Task.detached { try PipelineProductionAssetEvidence.requireBible(after, dataRoot: root) }.value
            if pass == 1 { try await requireUndo(context: context, driver: driver, pass: pass) }
            return after
        }
        try damage()
        let hash = try await bibleSHA(root)
        guard let one = selected.locations.first(where: { $0.id == locationID }) else { throw failed("The selected first location disappeared.") }
        var subsetRefused = false
        do { try await PipelinePanoramaStore.clearInvalid(locations: [one], bibleSHA256: hash, editor: context.editor) }
        catch is CancellationError { throw CancellationError() }
        catch let error as GateBlocked {
            subsetRefused = error.message == "The panorama, Bible or project changed. Create and inspect the current views before confirming them."
        }
        guard subsetRefused, try await bibleSHA(root) == hash else { throw failed("A partial invalid list was allowed to mutate the Bible.") }
        let removed = try await removeBoth()
        try PlanningWriterIO.json(removed).write(to: directory.appendingPathComponent("bible-removed.json"))
        try await bibleBytes(root).write(to: directory.appendingPathComponent("bible-removed.yaml"))
        try restore()
        if driver.text("production.feedback", in: window) != nil { try await driver.click("production.feedback.dismiss", in: window) }
        try await driver.wait("empty feedback before successful native Undo") { context.editor.mediaPanelToast == nil }
        try driver.record("panorama successful undo feedback baseline", fields: ["empty": true])
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await waitForBible(selected, root: root)
        try await driver.wait("native Bible Undo released its production lease") {
            context.editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
        }
        try await driver.wait("successful native Bible Undo retains inverse history without an error") {
            guard let manager = context.editor.undoManager else { return false }
            return manager.canRedo && manager.redoActionName == "Remove Invalid Panorama Assignments"
                && window.undoManager === manager && context.editor.mediaPanelToast == nil
                && driver.text("production.feedback", in: window) == nil
        }
        guard try await bible(root) == selected else { throw failed("Batch removal was not one complete semantic Undo step.") }
        try driver.record("panorama semantic undo restored", fields: ["semanticBibleRestored": true,
            "canRedo": context.editor.undoManager?.canRedo == true, "redoActionName": context.editor.undoManager?.redoActionName ?? "",
            "managerOwned": window.undoManager === context.editor.undoManager, "feedbackEmpty": context.editor.mediaPanelToast == nil,
            "phaseIdle": context.editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil])
        try PlanningWriterIO.json(try await bible(root)).write(to: directory.appendingPathComponent("bible-after-undo.json"))
        try await bibleBytes(root).write(to: directory.appendingPathComponent("bible-after-undo.yaml"))
        try damage()
        guard try await removeBoth() == removed else { throw failed("Repeated batch removal changed unrelated Bible fields.") }
        guard context.editor.workspaceFocus == .production else { throw failed("The native Undo refusal must remain in Production.") }
        try await requireUndo(context: context, driver: driver, pass: pass)
        if driver.text("production.feedback", in: window) != nil { try await driver.click("production.feedback.dismiss", in: window) }
        try await driver.wait("previous production message dismissed before native Undo") {
            context.editor.mediaPanelToast == nil && driver.text("production.feedback", in: window) == nil
        }
        try driver.record("panorama undo toast baseline", fields: ["empty": true])
        try await bibleBytes(root).write(to: directory.appendingPathComponent("bible-before-blocked-undo.yaml"))
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("broken receipts refuse native Undo visibly") {
            guard let message = driver.text("production.feedback", in: window) else { return false }
            return !message.hasPrefix("Bible updated; Undo is unavailable.")
                && message.contains("panorama assignment") && message.contains("missing or changed")
                && context.editor.undoManager?.canUndo == false
        }
        guard try await bible(root) == removed else { throw failed("Undo trusted broken original receipts.") }
        try PlanningWriterIO.json(try await bible(root)).write(to: directory.appendingPathComponent("bible-after-blocked-undo.json"))
        try await bibleBytes(root).write(to: directory.appendingPathComponent("bible-after-blocked-undo.yaml"))
        let undoError = driver.text("production.feedback", in: window) ?? ""
        try driver.record("panorama undo surface", fields: ["workspace": context.editor.workspaceFocus.rawValue,
            "feedback": "production.feedback", "message": undoError])
        try driver.capture("broken-panorama-undo-refused", target: window)
        try await ProductionFeedbackBannerAcceptance.run(editor: context.editor, driver: driver)
        try driver.visible(["production.feedback.viewport", "production.feedback.dismiss"], in: window)
        try await driver.click("production.feedback.dismiss", in: window)
        try await driver.wait("Production Undo error explicitly dismissed") { context.editor.mediaPanelToast == nil }
        try restore(); restored = true
        let snapshots = try await Task.detached {
            try Dictionary(uniqueKeysWithValues: ["selected", "removed", "after-undo", "before-blocked-undo", "after-blocked-undo"].map { state in
                let name = "bible-" + state + ".yaml"
                return (state, ["file": name, "sha256": try FileDigest.sha256(of: directory.appendingPathComponent(name))])
            })
        }.value
        try driver.record("native panorama batch recovery", fields: ["locationIDs": ids, "invalidCount": 2,
            "missingAndTampered": true, "subsetRefused": true, "oneUndoRestoredBoth": true,
            "brokenUndoRefusedVisibly": true, "noncollidingPanoramaView": true,
            "initialSecondLocationFixture": createdSecondLocation, "selectedSourceSHA256": selectedSourceSHA256, "canonicalSnapshots": snapshots, "undoError": undoError, "directory": directory.lastPathComponent])
    }

    private static func requireUndo(context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver, pass: Int) async throws {
        let editor = context.editor, window = driver.window
        if window.firstResponder is NSTextView { try driver.pressKey(48, characters: "\t", in: window) }
        var menuTitle = ""
        try await driver.wait("actual batch removal registered in the native Undo menu") {
            guard !(window.firstResponder is NSTextView), window.undoManager === editor.undoManager,
                  let manager = editor.undoManager, manager.canUndo,
                  manager.undoActionName == "Remove Invalid Panorama Assignments",
                  let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" })?.submenu else { return false }
            menu.update()
            guard let item = menu.items.first(where: { $0.action == NSSelectorFromString("undo:") }),
                  item.isEnabled, item.title == manager.undoMenuItemTitle else { return false }
            menuTitle = item.title
            return editor.mediaPanelToast?.message.hasPrefix("Bible updated; Undo is unavailable.") != true
        }
        try driver.record("panorama removal undo ready \(pass)", fields: ["historyInitiallyEmpty": true,
            "canUndo": true, "managerOwned": window.undoManager === editor.undoManager, "firstResponderIsTextEditor": window.firstResponder is NSTextView,
            "actionName": editor.undoManager?.undoActionName ?? "", "menuTitle": menuTitle, "menuEnabled": true])
    }

    private static func waitForBible(_ expected: Bible, root: URL) async throws {
        for _ in 0..<200 {
            if try await bible(root) == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw failed("Native Undo did not restore the complete expected Bible.")
    }

    private static func bibleBytes(_ root: URL) async throws -> Data {
        try await Task.detached { try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root)) }.value
    }

    private static func bible(_ root: URL) async throws -> Bible {
        try await Task.detached { try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile) }.value
    }
    private static func bibleSHA(_ root: URL) async throws -> String {
        try await Task.detached { try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root)) }.value
    }
    nonisolated private static func failed(_ message: String) -> GateBlocked { GateBlocked("Panorama recovery native acceptance: " + message) }
}
