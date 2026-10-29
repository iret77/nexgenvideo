import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import NexGenEngine
import UniformTypeIdentifiers

@MainActor
enum ProductionRetainedSpatialAcceptance {
    static func blockout(context: ProductionPlanningAcceptanceFixture.Context, shotID: String,
                         imported: Bool, output: URL) async throws -> [[String: Any]] {
        let window = try ProductionSceneUIAcceptance.documentWindow(context), root = context.dataRoot
        let defaults = UserDefaults.standard, oldScale = defaults.object(forKey: AppTheme.Typography.scaleKey)
        defer { if let oldScale { defaults.set(oldScale, forKey: AppTheme.Typography.scaleKey) } else { defaults.removeObject(forKey: AppTheme.Typography.scaleKey) } }
        var results: [[String: Any]] = []
        for scale in [1.0, 1.25, 1.5] {
            defaults.set(scale, forKey: AppTheme.Typography.scaleKey)
            let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "native-blockout-\(imported ? "import" : "plan")-\(Int(scale * 100))")
            do {
                try await ProductionV2PlanningAcceptance.selectPhase("shot_planning", context: context, driver: driver)
                if WorkspaceUIAcceptance.probeFrame(identifier: "shot-planning.reload." + shotID, in: window) != nil {
                    try await driver.click("shot-planning.reload." + shotID, in: window)
                }
                let before = try await draft(root)
                guard let shot = before.shots.first(where: { $0.shotID == shotID }), shot.camera.spatialState != nil else { throw failed("The real shot has no confirmed native camera state.") }
                let source: URL?
                if imported {
                    source = try await Task.detached {
                        guard let ref = shot.camera.spatialDerivation, let state = shot.camera.spatialState,
                              let camera = shot.camera.spatialCameraID, let scene = shot.camera.sceneReference,
                              let clip = try PipelineSpatialDerivationWriter.planningDerivationReferences(reference: ref,
                                stateReference: state, cameraID: camera, sceneReference: scene, shotID: shotID, dataRoot: root)
                                .first(where: { $0.role == "core.shot-clay-video" }) else { throw failed("Import acceptance requires the actual previously rendered Clay MOV, not a fabricated blockout fixture.") }
                        return try ProjectLocalFile.requireHash(clip.sha256, at: clip.path, dataRoot: root)
                    }.value
                } else { source = nil }
                try await driver.click("shot-planning.blockout.open." + shotID, in: window)
                let sheet = try await driver.sheet("shot.blockout.sheet")
                try await driver.wait("native blockout ready") { driver.state("shot.blockout.plan", in: sheet) == true }
                if let source {
                    try await driver.chooseFile(source, in: sheet, trigger: "shot.blockout.choose")
                    try await driver.wait("blockout source decoded") { driver.text("shot.blockout.source", in: sheet) != nil }
                    guard driver.state("shot.blockout.confirm", in: sheet) == false else { throw failed("An unreviewed imported blockout can be confirmed.") }
                    try await driver.fill("shot.blockout.start", value: "0", in: sheet)
                    try await driver.click("shot.blockout.preview", in: sheet)
                    let duration = try await AVURLAsset(url: source).load(.duration)
                    try await driver.wait("actual blockout playback") {
                        guard let player = ProductionNativePlaybackAcceptance.player("shot.blockout.player", in: sheet) else { return false }
                        return player.rate > 0 && player.currentTime().seconds > 0
                    }
                    try driver.capture("blockout-playing", target: sheet)
                    try await driver.wait("actual blockout reached interval end", seconds: duration.seconds + 5) {
                        guard let player = ProductionNativePlaybackAcceptance.player("shot.blockout.player", in: sheet), let end = player.currentItem?.forwardPlaybackEndTime else { return false }
                        return player.rate == 0 && CMTimeCompare(player.currentTime(), end) >= 0
                    }
                    try await driver.click("shot.blockout.reviewed", in: sheet)
                    try await driver.fill("shot.blockout.observation", value: "The selected clip is the actual saved camera and complete object-pose animation from this shot.", in: sheet)
                    try await driver.click("shot.blockout.confirm", in: sheet)
                } else {
                    try driver.visible(["shot.blockout.plan", "shot.blockout.done"], in: sheet)
                    try driver.capture("plan-ready", target: sheet)
                    try await driver.click("shot.blockout.plan", in: sheet)
                }
                try await driver.wait("native blockout published", seconds: 120) { window.attachedSheet == nil }
                let after = try await draft(root)
                guard let selected = after.shots.first(where: { $0.shotID == shotID }), let reference = selected.camera.blockingReference else { throw failed("The native action did not publish its assignment.") }
                let result = try await Task.detached { () async throws -> (PipelineNativeBlockoutStore.Receipt, CMTime, String) in
                    let references = try PipelineNativeBlockoutStore.references(reference, shot: selected, dataRoot: root)
                    guard references.allSatisfy({ ref in after.header.inputs.contains { $0.path == ref.path && $0.sha256 == ref.sha256 } }) else { throw failed("Shot Planning does not bind every native blockout byte.") }
                    let value = try PipelineNativeBlockoutStore.read(reference, dataRoot: root)
                    let url = try ProjectLocalFile.requireHash(value.output.sha256, at: value.output.path, dataRoot: root)
                    let duration = try await AVURLAsset(url: url).load(.duration)
                    let board = try PlanningWriterIO.storyboard(dataRoot: root)
                    guard let timing = board.timing.shots.first(where: { $0.id == shotID }) else { throw failed("The actual shot timing disappeared.") }
                    let planned = CMTime(value: timing.durationTicks, timescale: Int32(board.timing.timebase.ticksPerSecond))
                    guard duration.isNumeric, duration.value > 0, CMTimeCompare(duration, planned) == 0 else { throw failed("The actual blockout MOV does not cover the exact planned shot interval.") }
                    if let source {
                        guard value.original?.sha256 == (try FileDigest.sha256(of: source)), value.originalName == source.lastPathComponent,
                              value.sourceStartValue == 0, let sourceDuration = value.sourceDurationValue,
                              let clock = value.sourceDurationTimescale,
                              CMTimeCompare(CMTime(value: sourceDuration, timescale: clock), planned) == 0 else { throw failed("The imported blockout lost its real original bytes or selected source clock.") }
                    }
                    _ = try await AVAssetImageGenerator(asset: AVURLAsset(url: url)).image(at: .zero)
                    var purposeRejected = false
                    do { try PipelineProductionAssetEvidence.requireReferencePurpose(path: value.output.path, sha256: value.output.sha256,
                        semanticJobID: CoreReferenceSemanticJobIDV1.styleReference, dataRoot: root) }
                    catch let error as GateBlocked {
                        purposeRejected = error.message == "A blockout carries geometry only. Plan/elevation diagrams are planning evidence, not appearance or generation inputs."
                    }
                    guard purposeRejected else { throw failed("Blockout bytes can be used as appearance.") }
                    let name = "native-blockout-\(imported ? "import" : "plan")-\(Int(scale * 100)).mov"
                    try FileManager.default.copyItem(at: url, to: output.appendingPathComponent(name))
                    let closure = output.appendingPathComponent(name + ".evidence")
                    for ref in references {
                        let target = closure.appendingPathComponent(ref.path)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if !FileManager.default.fileExists(atPath: target.path) {
                            try FileManager.default.copyItem(at: ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: root), to: target)
                        }
                    }
                    try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root))
                        .write(to: output.appendingPathComponent(name + ".receipt.json"), options: .atomic)
                    return (value, duration, name)
                }.value
                guard result.0.kind == (imported ? .importedGeometry : .planElevation),
                      selected.camera.spatialState == shot.camera.spatialState,
                      !imported || (selected.camera.spatialDerivation == nil && result.0.original != nil) else { throw failed("The native blockout has incorrect source or state semantics.") }
                if WorkspaceUIAcceptance.probeFrame(identifier: "shot-planning.reload." + shotID, in: window) != nil {
                    try await driver.click("shot-planning.reload." + shotID, in: window)
                }
                try await driver.click("shot-planning.blockout.open." + shotID, in: window)
                let exportSheet = try await driver.sheet("shot.blockout.sheet")
                try await driver.wait("actual blockout export available") { driver.text("shot.blockout.current", in: exportSheet) == result.0.output.sha256 }
                let exportName = "native-blockout-\(imported ? "import" : "plan")-\(Int(scale * 100))-export.mov"
                let destination = output.appendingPathComponent(exportName)
                try await driver.click("shot.blockout.export", in: exportSheet)
                try await driver.saveFile(destination, in: exportSheet)
                try await driver.wait("native MOV export completed") {
                    (try? FileDigest.sha256(of: destination)) == result.0.output.sha256 && driver.state("shot.blockout.done", in: exportSheet) == true
                }
                try driver.capture("actual-export-saved", target: exportSheet)
                try await driver.click("shot.blockout.done", in: exportSheet)
                try await driver.wait("blockout export inspector closed") { window.attachedSheet == nil }
                let previousRevision = context.editor.engineStateRevision
                try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
                try await driver.wait("blockout Undo") { context.editor.engineStateRevision > previousRevision }
                guard try await draft(root).shots == before.shots else { throw failed("Native blockout Undo did not restore the prior complete shot.") }
                let undoRevision = context.editor.engineStateRevision
                try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
                try await driver.wait("blockout Redo") { context.editor.engineStateRevision > undoRevision }
                guard try await draft(root).shots == after.shots else { throw failed("Native blockout Redo lost its exact assignment.") }
                try driver.record("native retained blockout", fields: ["shotID": shotID, "kind": result.0.kind.rawValue,
                    "outputSHA256": result.0.output.sha256, "receiptSHA256": reference.sha256, "durationValue": result.1.value,
                    "durationTimescale": result.1.timescale, "media": result.2, "export": exportName, "nativeFileExport": true, "appearanceRejected": true, "nativeUndoRedo": true])
                results.append(driver.result().merging(try presentation(window, scale: scale)) { _, new in new })
                if imported {
                    let revision = context.editor.engineStateRevision
                    try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
                    try await driver.wait("restore genuine Clay input for next scale") { context.editor.engineStateRevision > revision }
                    guard try await draft(root).shots == before.shots else { throw failed("The next scale would not start with the actual native Clay source.") }
                }
            } catch { driver.failure(error); throw error }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-blockout-\(imported ? "import" : "plan")-result.json"), options: .atomic)
        return results
    }

    static func prepareAppearanceFixture(context: ProductionPlanningAcceptanceFixture.Context,
                                         locationID: String, locationName: String) async throws -> String {
        let root = context.dataRoot
        let source = "import/locations/" + locationID + "/fixture-appearance.png"
        let target = try await Task.detached {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve("production_design/refs/lighting.png", dataRoot: root))
            _ = try ProjectLocalFile.ensureDirectory((source as NSString).deletingLastPathComponent, dataRoot: root)
            try bytes.write(to: root.appendingPathComponent(source), options: .atomic)
            try ConfirmedIdentityAssetStoreV1.recordIntake(role: .location, identityName: locationName,
                identitySlug: locationID, paths: [source], dataRoot: root)
            return try ProductionWorkflowRecoveryMigration.outputPath(area: "bible",
                leaf: "fixture-appearance-" + UUID().uuidString.lowercased() + ".png", dataRoot: root)
        }.value
        try await ProductionPlanningAcceptanceFixture.run("copy_project_file", args: ["from": source, "to": target], in: context)
        return target
    }

    static func panorama(context: ProductionPlanningAcceptanceFixture.Context, locationID: String, output: URL) async throws -> [[String: Any]] {
        let window = try ProductionSceneUIAcceptance.documentWindow(context), root = context.dataRoot
        let source = output.appendingPathComponent("native-owner-panorama.png")
        let invalid = output.appendingPathComponent("native-owner-non-panorama.png")
        try writeImage(source, width: 512, height: 256)
        try writeImage(invalid, width: 256, height: 256)
        let defaults = UserDefaults.standard, oldScale = defaults.object(forKey: AppTheme.Typography.scaleKey)
        defer { if let oldScale { defaults.set(oldScale, forKey: AppTheme.Typography.scaleKey) } else { defaults.removeObject(forKey: AppTheme.Typography.scaleKey) } }
        let sourceHash = try FileDigest.sha256(of: source)
        var results: [[String: Any]] = []
        for scale in [1.0, 1.25, 1.5] {
            defaults.set(scale, forKey: AppTheme.Typography.scaleKey)
            let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "native-panorama-\(Int(scale * 100))")
            do {
                try await ProductionV2PlanningAcceptance.selectPhase("bible", context: context, driver: driver)
                try await driver.segment("bible.section", title: "Locations", titles: ["Characters", "Ensembles", "Props", "Locations", "Look", "Shot references"], in: window)
                let before = try await readBible(root)
                try JSONEncoder().encode(before).write(to: output.appendingPathComponent("native-panorama-\(Int(scale * 100))-bible-before.json"), options: .atomic)
                let appearance = try await Task.detached {
                    guard let location = before.locations.first(where: { $0.id == locationID }), !location.sheets.isEmpty else {
                        throw failed("Panorama preservation needs a real nonempty, independently confirmed appearance-sheet fixture.")
                    }
                    try PipelineProductionAssetEvidence.requireBible(before, dataRoot: root)
                    return try location.sheets.keys.sorted().map { view in
                        let path = location.sheets[view]!
                        let hash = try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: root))
                        try PipelineProductionAssetEvidence.requireReferencePurpose(path: path, sha256: hash,
                            semanticJobID: CoreReferenceSemanticJobIDV1.styleReference, dataRoot: root)
                        return PlanningWriterIO.reference(path, id: view, role: "fixture.confirmed-appearance", bytes: try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root)))
                    }
                }.value
                func open() async throws -> NSWindow {
                    try await driver.click("bible.panorama.open." + locationID, in: window)
                    return try await driver.sheet("bible.panorama.sheet")
                }
                func undo(_ expected: Bible, label: String) async throws {
                    let revision = context.editor.engineStateRevision
                    try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
                    try await driver.wait(label) { context.editor.engineStateRevision > revision }
                    guard try await readBible(root) == expected else { throw failed(label + " did not restore the exact Bible.") }
                }
                let sheet = try await open()
                try await driver.chooseFile(invalid, in: sheet, trigger: "bible.panorama.choose")
                try await driver.click("bible.panorama.extract", in: sheet)
                try await driver.wait("invalid panorama explicitly rejected") { driver.text("bible.panorama.error", in: sheet)?.contains("2:1") == true }
                guard try await readBible(root) == before else { throw failed("An invalid panorama changed the Bible.") }
                try await driver.chooseFile(source, in: sheet, trigger: "bible.panorama.choose")
                try await driver.click("bible.panorama.custom", in: sheet)
                try await driver.fill("bible.panorama.name", value: "owner_reverse", in: sheet)
                try await driver.fill("bible.panorama.yaw", value: "180", in: sheet)
                try await driver.fill("bible.panorama.pitch", value: "0", in: sheet)
                try await driver.fill("bible.panorama.fov", value: "60", in: sheet)
                try await driver.click("bible.panorama.extract", in: sheet)
                try await driver.wait("new extracted candidate available") {
                    driver.text("bible.panorama.candidate", in: sheet) != nil
                        && driver.state("bible.panorama.reviewed", in: sheet) == false
                        && driver.text("bible.panorama.image.owner_reverse", in: sheet) != nil
                }
                guard driver.state("bible.panorama.confirm", in: sheet) == false else { throw failed("An unreviewed panorama can be confirmed.") }
                for name in defaultFourWallPovs.map(\.name) + ["owner_reverse"] {
                    try await driver.reveal("bible.panorama.image." + name, in: sheet)
                    try driver.capture("view-" + name, target: sheet)
                    try await driver.inspect("bible.panorama.inspect." + name, in: sheet)
                }
                try await driver.click("bible.panorama.reviewed", in: sheet)
                try await driver.click("bible.panorama.confirm", in: sheet)
                try await driver.wait("native panorama assignment") { window.attachedSheet == nil }
                let after = try await readBible(root)
                try JSONEncoder().encode(after).write(to: output.appendingPathComponent("native-panorama-\(Int(scale * 100))-bible-after.json"), options: .atomic)
                let evidence = try await Task.detached { () throws -> (String, String, Data, [[String: String]]) in
                    guard let location = after.locations.first(where: { $0.id == locationID }),
                          let receipt = try PipelinePanoramaStore.current(location: location, dataRoot: root),
                          receipt.views.count == 5, receipt.panorama.sha256 == sourceHash,
                          receipt.views.map(\.geometry) == (defaultFourWallPovs + [.init(name: "owner_reverse", yawDegrees: 180, pitchDegrees: 0, fovHorizontalDegrees: 60)]).map(Scene3D.PovRecord.init),
                          location.sheets == before.locations.first(where: { $0.id == locationID })?.sheets else { throw failed("The actual panorama bytes, camera geometry or separate appearance sheets changed.") }
                    try PipelineProductionAssetEvidence.requireBible(after, dataRoot: root)
                    let references = try PipelinePanoramaStore.references(location: location, dataRoot: root)
                    guard let selected = references.first, let pov = receipt.views.first else { throw failed("The selected panorama closure is empty.") }
                    var rejected = false
                    do { try PipelineProductionAssetEvidence.requireReferencePurpose(path: pov.image.path, sha256: pov.image.sha256,
                        semanticJobID: CoreReferenceSemanticJobIDV1.styleReference, dataRoot: root) }
                    catch let error as GateBlocked {
                        rejected = error.message == "A panorama geometry anchor cannot supply appearance, style or identity. Create a separate approved appearance sheet from this view."
                    }
                    guard rejected else { throw failed("The actual panorama POV did not reject its use as appearance.") }
                    for reference in references {
                        let name = "native-panorama-\(Int(scale * 100))-" + URL(fileURLWithPath: reference.path).lastPathComponent
                        try FileManager.default.copyItem(at: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root), to: output.appendingPathComponent(name))
                    }
                    let sheets = try appearance.map { ref -> [String: String] in
                        let copy = "native-panorama-\(Int(scale * 100))-appearance-" + ref.id + ".png"
                        try FileManager.default.copyItem(at: ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: root), to: output.appendingPathComponent(copy))
                        return ["view": ref.id, "path": ref.path, "sha256": ref.sha256, "copy": copy]
                    }
                    return (selected.path, selected.sha256, try Data(contentsOf: ProjectLocalFile.requireHash(selected.sha256, at: selected.path, dataRoot: root)), sheets)
                }.value
                try await undo(before, label: "panorama native Undo")
                let undoRevision = context.editor.engineStateRevision
                try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
                try await driver.wait("panorama native Redo") { context.editor.engineStateRevision > undoRevision }
                guard try await readBible(root) == after else { throw failed("Panorama Redo lost the exact selection.") }
                let removal = try await open()
                try await driver.click("bible.panorama.remove", in: removal)
                try await driver.wait("native panorama removal") { window.attachedSheet == nil }
                let removed = try await readBible(root)
                try JSONEncoder().encode(removed).write(to: output.appendingPathComponent("native-panorama-\(Int(scale * 100))-bible-removed.json"), options: .atomic)
                try await requireRemoved(removed, locationID: locationID, appearance: appearance, root: root)
                try await undo(after, label: "native panorama removal Undo")
                for damage in ["missing", "tampered"] {
                    let receiptURL = root.appendingPathComponent(evidence.0)
                    let quarantine = output.appendingPathComponent("native-panorama-\(Int(scale * 100))-\(damage).quarantine")
                    if damage == "missing" { try FileManager.default.moveItem(at: receiptURL, to: quarantine) }
                    else { try Data("changed native receipt".utf8).write(to: receiptURL, options: .atomic) }
                    var restoredBytes = false
                    defer { if !restoredBytes { try? evidence.2.write(to: receiptURL, options: .atomic) } }
                    let recovery = try await open()
                    try await driver.wait("invalid panorama has native recovery") {
                        driver.text("bible.panorama.error", in: recovery)?.contains("missing or changed") == true
                            && driver.state("bible.panorama.remove-invalid", in: recovery) == true
                    }
                    try await driver.reveal("bible.panorama.error", in: recovery)
                    try driver.capture("recovery-" + damage, target: recovery)
                    try await driver.click("bible.panorama.remove-invalid", in: recovery)
                    try await driver.wait("invalid panorama removed natively") { window.attachedSheet == nil }
                    try await requireRemoved(try await readBible(root), locationID: locationID, appearance: appearance, root: root)
                    try evidence.2.write(to: receiptURL, options: .atomic); restoredBytes = true
                    try await undo(after, label: damage + " panorama recovery Undo after restoring original receipt bytes")
                }
                guard let field = driver.interactions.compactMap({ $0["field"] as? [String: Any] }).last(where: { $0["id"] as? String == "bible.panorama.fov" }),
                      let pointSize = field["fontPointSize"] as? CGFloat,
                      abs(pointSize - AppTheme.Typography.ui * scale) < 0.5 else { throw failed("The actual rendered panorama field did not use the requested interface scale.") }
                try driver.record("native panorama selection", fields: ["locationID": locationID, "viewCount": 5,
                    "panoramaSHA256": sourceHash, "receiptSHA256": evidence.1, "receiptPath": evidence.0,
                    "appearanceSheets": evidence.3, "renderedFontPointSize": Double(pointSize),
                    "customYaw": 180, "customPitch": 0, "customFOV": 60, "appearanceRejected": true,
                    "invalidAspectRejected": true, "appearanceSheetsPreserved": true, "nativeUndoRedo": true,
                    "nativeRemoval": true, "removalUndo": true, "missingReceiptRecovery": true,
                    "tamperedReceiptRecovery": true, "recoveryUndoAfterRestoringOriginalBytes": true, "bibleChanged": before != after])
                results.append(driver.result().merging(try presentation(window, scale: scale)) { _, new in new })
            } catch { driver.failure(error); throw error }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-panorama-result.json"), options: .atomic)
        return results
    }

    private static func readBible(_ root: URL) async throws -> Bible {
        try await Task.detached { try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile) }.value
    }

    private static func requireRemoved(_ bible: Bible, locationID: String, appearance: [CanonicalArtifactReferenceV1], root: URL) async throws {
        try await Task.detached {
            guard let location = bible.locations.first(where: { $0.id == locationID }), location.scene3d == Scene3D(),
                  location.attributes[PipelinePanoramaStore.receiptPathKey] == nil,
                  location.attributes[PipelinePanoramaStore.receiptHashKey] == nil,
                  location.sheets.count == appearance.count else { throw failed("Native panorama removal did not clear exactly its selection.") }
            for ref in appearance {
                guard location.sheets[ref.id] == ref.path else { throw failed("Native panorama removal changed an appearance sheet path.") }
                _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: root)
            }
            try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: root)
        }.value
    }

    private static func draft(_ root: URL) async throws -> ShotPlanningDraftV1 {
        try await Task.detached { try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: PlanningWriterIO.storyboard(dataRoot: root)) }.value
    }
    private static func presentation(_ window: NSWindow, scale: Double) throws -> [String: Any] {
        let actual = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
        guard let bounds = window.contentView?.bounds, bounds.size == NSSize(width: 960, height: 640), actual == scale else { throw failed("The actual minimum document window or interface scale changed.") }
        return ["scale": actual, "viewport": [bounds.width, bounds.height], "backingScale": window.backingScaleFactor]
    }
    private static func writeImage(_ url: URL, width: Int, height: Int) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failed("The panorama fixture could not allocate pixels.") }
        for x in 0..<width {
            context.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 1 - CGFloat(x) / CGFloat(width), alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw failed("The panorama fixture could not be encoded.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failed("The panorama fixture could not be saved.") }
    }
    nonisolated private static func failed(_ message: String) -> GateBlocked { GateBlocked("Retained spatial native acceptance: " + message) }
}
