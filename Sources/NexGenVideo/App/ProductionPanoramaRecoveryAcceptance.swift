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
        guard let location = first.locations.first(where: { $0.id == locationID }),
              let receipt = try await Task.detached(operation: { try PipelinePanoramaStore.current(location: location, dataRoot: root) }).value,
              let pov = receipt.views.first else { throw failed("The actual first panorama selection is missing.") }
        let copy = try await Task.detached {
            let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "bible", leaf: "negative-pov-" + UUID().uuidString.lowercased() + ".png", dataRoot: root)
            _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: root)
            try FileManager.default.copyItem(at: ProjectLocalFile.requireHash(pov.image.sha256, at: pov.image.path, dataRoot: root), to: root.appendingPathComponent(path))
            return path
        }.value
        for (name, path) in [("panorama-alias", receipt.panorama.path), ("copied-pov", copy), ("character-sheet", receipt.panorama.path)] {
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
            let result = await context.executor.execute(name: "write_bible", args: arguments)
            let message = result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
            guard result.isError, message.contains("A panorama geometry anchor cannot supply appearance, style or identity."),
                  try await bible(root) == first, try await bibleSHA(root) == beforeSHA else { throw failed("The actual write_bible path accepted raw panorama geometry as an appearance sheet.") }
            let artifact: [String: Any] = ["case": name, "arguments": arguments, "isError": result.isError, "error": message,
                "bibleSHA256Before": beforeSHA, "bibleSHA256After": try await bibleSHA(root),
                "path": path, "sha256": try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: root))]
            try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(name + ".json"))
            try driver.record("actual panorama sheet refusal " + name, fields: ["error": message, "canonicalUnchanged": true])
        }
        let secondID = "panorama_recovery_room"
        if !first.locations.contains(where: { $0.id == secondID }) {
            guard let appearance = location.sheets.values.sorted().first else { throw failed("The genuine appearance fixture is missing.") }
            var fixture = first
            fixture.locations.append(try Location(id: secondID, name: "Second recovery room", visualPrompt: "A second room.", referenceImages: [appearance]))
            try await ProductionPlanningAcceptanceFixture.run("write_bible", args: ProductionBibleToolFixture.arguments(fixture), in: context)
        }
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
        let ids = [locationID, secondID]
        let receipts = try await Task.detached {
            try ids.map { id -> (String, Data) in
                guard let location = selected.locations.first(where: { $0.id == id }),
                      let reference = try PipelinePanoramaStore.references(location: location, dataRoot: root).first else { throw failed("Both selections need actual native receipt bytes.") }
                return (reference.path, try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)))
            }
        }.value
        try PlanningWriterIO.json(selected).write(to: directory.appendingPathComponent("bible-selected.json"))
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
            return after
        }
        try damage()
        let hash = try await bibleSHA(root)
        guard let one = selected.locations.first(where: { $0.id == locationID }) else { throw failed("The selected first location disappeared.") }
        var subsetRefused = false
        do { try await PipelinePanoramaStore.clearInvalid(locations: [one], bibleSHA256: hash, editor: context.editor) }
        catch is CancellationError { throw CancellationError() }
        catch { subsetRefused = true }
        guard subsetRefused, try await bibleSHA(root) == hash else { throw failed("A partial or stale invalid list was allowed to mutate the Bible.") }
        let removed = try await removeBoth()
        try PlanningWriterIO.json(removed).write(to: directory.appendingPathComponent("bible-removed.json"))
        try restore()
        let revision = context.editor.engineStateRevision
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("one Undo restores both original native assignments") { context.editor.engineStateRevision > revision }
        guard try await bible(root) == selected else { throw failed("Batch removal was not one complete Undo step.") }
        try PlanningWriterIO.json(try await bible(root)).write(to: directory.appendingPathComponent("bible-after-undo.json"))
        try damage()
        guard try await removeBoth() == removed else { throw failed("Repeated exact batch removal changed unrelated Bible fields.") }
        if !context.editor.mediaPanelVisible { try await AppNativeMenuAcceptance.choose(["View", "Sidebar"], in: window, driver: driver) }
        let oldToast = driver.text("media.toast", in: window)
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("broken receipts refuse native Undo visibly") {
            guard let message = driver.text("media.toast", in: window), message != oldToast else { return false }
            return message.contains("panorama assignment") && message.contains("missing or changed")
        }
        guard try await bible(root) == removed else { throw failed("Undo trusted broken original receipts.") }
        try PlanningWriterIO.json(try await bible(root)).write(to: directory.appendingPathComponent("bible-after-blocked-undo.json"))
        let undoError = driver.text("media.toast", in: window) ?? ""
        try driver.capture("broken-panorama-undo-refused", target: window)
        try restore(); restored = true
        try driver.record("native panorama batch recovery", fields: ["locationIDs": ids, "invalidCount": 2,
            "missingAndTampered": true, "subsetRefused": true, "oneUndoRestoredBoth": true,
            "brokenUndoRefusedVisibly": true, "noncollidingPanoramaView": true,
            "initialSecondLocationFixture": true, "undoError": undoError, "directory": directory.lastPathComponent])
    }

    private static func bible(_ root: URL) async throws -> Bible {
        try await Task.detached { try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile) }.value
    }
    private static func bibleSHA(_ root: URL) async throws -> String {
        try await Task.detached { try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root)) }.value
    }
    nonisolated private static func failed(_ message: String) -> GateBlocked { GateBlocked("Panorama recovery native acceptance: " + message) }
}
