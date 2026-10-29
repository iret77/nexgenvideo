import AppKit
import NexGenEngine

@MainActor
enum ProductionVisualSourcesAcceptance {
    private static let scales = [1.0, 1.25, 1.5]

    static func storyboard(context: ProductionPlanningAcceptanceFixture.Context, output: URL, sourceVideo: URL) async throws -> [[String: Any]] {
        let defaults = UserDefaults.standard
        let oldScale = defaults.object(forKey: AppTheme.Typography.scaleKey)
        defer { if let oldScale { defaults.set(oldScale, forKey: AppTheme.Typography.scaleKey) } else { defaults.removeObject(forKey: AppTheme.Typography.scaleKey) } }
        let sourceSHA = try await Task.detached { try FileDigest.sha256(of: sourceVideo) }.value
        let external = context.dataRoot.appendingPathComponent("production_design/refs/lighting.png")
        let externalSHA = try FileDigest.sha256(of: external)
        let window = try documentWindow(context)
        var results: [[String: Any]] = []
        for scale in scales {
            defaults.set(scale, forKey: AppTheme.Typography.scaleKey)
            let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "visual-source-\(Int(scale * 100))")
            do {
                try await requireViewport(window, driver: driver)
                context.editor.setWorkspaceFocus(.production); context.editor.revealCockpit(.storyboard)
                let board = try await readBoard(context)
                guard let shot = board.timing.shots.first, let moment = shot.moments.first else { throw failed("Storyboard fixture has no moments.") }
                let prefix = "storyboard.native-sketch."
                func open(_ mode: String, _ title: String) async throws -> NSWindow {
                    try await driver.menu("storyboard.sketch.sources." + moment.id, title: title, in: window)
                    let sheet = try await driver.sheet(prefix + "sheet")
                    try await driver.wait("native sketch mode " + mode) { driver.text(prefix + "sheet", in: sheet) == mode }
                    try driver.visible([prefix + "choose", prefix + "cancel", prefix + "confirm"], in: sheet)
                    guard driver.state(prefix + "confirm", in: sheet) == false else { throw failed("An empty sketch sheet permits assignment.") }
                    return sheet
                }
                func close(_ sheet: NSWindow) async throws {
                    try await driver.click(prefix + "cancel", in: sheet)
                    try await driver.wait("cancel native sketch sheet") { window.attachedSheet == nil && window.isKeyWindow }
                }
                var sheet = try await open("sourceFrame", "Capture source video frame…")
                try await driver.chooseFile(nil, in: sheet)
                try await close(sheet)
                guard try await readBoard(context).fingerprint == board.fingerprint else { throw failed("File-panel cancellation changed the Storyboard.") }

                sheet = try await open("sourceFrame", "Capture source video frame…")
                try await driver.chooseFile(sourceVideo, in: sheet)
                try await driver.fill(prefix + "source-seconds", value: "1.001", in: sheet)
                try await driver.click(prefix + "preview-frame", in: sheet)
                try await driver.wait("decoded source frame preview", seconds: 30) { driver.state(prefix + "confirm", in: sheet) == true && driver.text(prefix + "image", in: sheet)?.count == 64 }
                try await driver.reveal(prefix + "image", in: sheet)
                try driver.visible([prefix + "image", prefix + "cancel", prefix + "confirm"], in: sheet)
                let sourcePreviewSHA = driver.text(prefix + "image", in: sheet)
                try driver.capture("source-preview", target: sheet)
                try await driver.inspect(prefix + "inspect", in: sheet)
                try await driver.fill(prefix + "source-seconds", value: "0", in: sheet)
                try await driver.wait("source time edit revokes preview") { driver.state(prefix + "confirm", in: sheet) == false && driver.text(prefix + "image", in: sheet) == nil }
                try await driver.fill(prefix + "source-seconds", value: "1.001", in: sheet)
                try await driver.click(prefix + "preview-frame", in: sheet)
                try await driver.wait("new exact source preview", seconds: 30) { driver.state(prefix + "confirm", in: sheet) == true && driver.text(prefix + "image", in: sheet) == sourcePreviewSHA }
                try await driver.click(prefix + "confirm", in: sheet)
                try await driver.wait("source assignment closes sheet") { window.attachedSheet == nil }
                let sourceProof = try await assignedProof(context, shotID: shot.id, momentID: moment.id)
                guard case .sourceFrame(let video, let clock, let tick, _, _) = sourceProof.source,
                      video.sha256 == sourceSHA, sourceProof.image.sha256 == sourcePreviewSHA,
                      abs(clock.seconds(for: tick) - 1.001) < 0.000001 else { throw failed("Assigned source proof differs from the native preview or selected time.") }
                try await driver.wait("source image in Storyboard") { WorkspaceUIAcceptance.probeText(identifier: "storyboard.moment." + moment.id, in: window) == sourceProof.image.sha256 }
                try driver.capture("source-assigned", target: window)
                try await driver.inspect("storyboard.sketch.inspect." + moment.id, in: window)

                for stale in [false, true] {
                    sheet = try await open("sourceFrame", "Capture source video frame…")
                    try await driver.chooseFile(sourceVideo, in: sheet)
                    try await driver.fill(prefix + "source-seconds", value: "1.001", in: sheet)
                    try await driver.click(prefix + "preview-frame", in: sheet)
                    try await driver.wait("source candidate for cancellation or stale edit", seconds: 30) {
                        driver.state(prefix + "confirm", in: sheet) == true && driver.text(prefix + "image", in: sheet) == sourcePreviewSHA
                    }
                    let current = try await readBoard(context)
                    if stale {
                        _ = try await PipelineStoryboardEditor.apply(.setMomentIntent(shotID: shot.id, momentID: moment.id,
                            intent: moment.intent + " Source revision \(Int(scale * 100))."), expectedFingerprint: current.fingerprint, editor: context.editor)
                        await context.editor.refreshEngineState()
                        let changed = try await readBoard(context).fingerprint
                        guard changed != current.fingerprint else { throw failed("The stale source-frame fixture did not change its target.") }
                        try await driver.click(prefix + "confirm", in: sheet)
                        try await driver.wait("stale source-frame assignment reported") { !(driver.text(prefix + "failure", in: sheet) ?? "").isEmpty }
                        guard window.attachedSheet === sheet, try await readBoard(context).fingerprint == changed else { throw failed("A stale source frame changed the new Storyboard revision.") }
                        try await driver.reveal(prefix + "failure", in: sheet)
                        try driver.capture("source-stale", target: sheet)
                    } else { try driver.capture("source-preview-cancel", target: sheet) }
                    let beforeDismiss = try await readBoard(context).fingerprint
                    try await close(sheet)
                    guard try await readBoard(context).fingerprint == beforeDismiss else { throw failed("Cancelling the source-frame candidate changed its Storyboard assignment.") }
                }

                let beforeCancel = try await readBoard(context).fingerprint
                sheet = try await open("external", "Import external sketch…")
                try await driver.chooseFile(external, in: sheet)
                try await driver.wait("external image without author") { driver.text(prefix + "image", in: sheet) == externalSHA && driver.state(prefix + "confirm", in: sheet) == false }
                try await driver.fill(prefix + "source-description", value: "Native acceptance external artwork", in: sheet)
                try await driver.wait("external author enables confirmation") { driver.state(prefix + "confirm", in: sheet) == true }
                try await driver.inspect(prefix + "inspect", in: sheet)
                try driver.capture("external-preview-cancel", target: sheet)
                try await close(sheet)
                guard try await readBoard(context).fingerprint == beforeCancel else { throw failed("Cancelling a prepared external sketch changed the Storyboard.") }

                sheet = try await open("external", "Import external sketch…")
                try await driver.chooseFile(external, in: sheet)
                let author = "Independent external artwork at scale \(Int(scale * 100))"
                try await driver.fill(prefix + "source-description", value: author, in: sheet)
                try await driver.wait("external candidate ready") { driver.state(prefix + "confirm", in: sheet) == true }
                try await driver.click(prefix + "confirm", in: sheet)
                try await driver.wait("external assignment closes sheet") { window.attachedSheet == nil }
                let externalProof = try await assignedProof(context, shotID: shot.id, momentID: moment.id)
                guard case .externalConfirmed(let original, _) = externalProof.source,
                      original.sha256 == externalSHA, externalProof.image.sha256 == externalSHA else { throw failed("External confirmation did not publish the exact preview bytes.") }
                let root = context.dataRoot
                let confirmedAuthor = try await Task.detached {
                    let references = try PipelineStoryboardNativeMedia.references(externalProof, dataRoot: root)
                    guard let receipt = references.first(where: { $0.role == "host.storyboard-external-confirmation" }),
                          let value = try JSONSerialization.jsonObject(with: Data(contentsOf: ProjectLocalFile.requireHash(receipt.sha256, at: receipt.path, dataRoot: root))) as? [String: Any],
                          let description = value["sourceDescription"] as? String else { throw GateBlocked("The native external confirmation receipt is missing.") }
                    return description
                }.value
                guard confirmedAuthor == author else { throw failed("The external confirmation did not persist the text typed into its exact native field.") }
                try driver.capture("external-assigned", target: window)

                sheet = try await open("external", "Import external sketch…")
                try await driver.chooseFile(external, in: sheet)
                try await driver.fill(prefix + "source-description", value: "Prepared before another canonical edit", in: sheet)
                try await driver.wait("external candidate before stale edit") { driver.state(prefix + "confirm", in: sheet) == true }
                let current = try await readBoard(context)
                _ = try await PipelineStoryboardEditor.apply(.setMomentIntent(shotID: shot.id, momentID: moment.id,
                    intent: moment.intent + " Framing revision \(Int(scale * 100))."), expectedFingerprint: current.fingerprint, editor: context.editor)
                await context.editor.refreshEngineState()
                let changed = try await readBoard(context).fingerprint
                guard changed != current.fingerprint else { throw failed("The stale candidate fixture did not create a new canonical revision.") }
                try await driver.click(prefix + "confirm", in: sheet)
                try await driver.wait("stale external candidate reported") { !(driver.text(prefix + "failure", in: sheet) ?? "").isEmpty }
                guard window.attachedSheet === sheet, try await readBoard(context).fingerprint == changed else { throw failed("Stale external assignment changed the newer Storyboard.") }
                try await driver.reveal(prefix + "failure", in: sheet)
                try driver.capture("external-stale", target: sheet)
                try await close(sheet)
                var result = driver.result()
                result.merge(["scale": scale, "viewport": [960, 640], "sourceFilePanel": true, "sourcePreviewAndAssignment": true,
                    "changedTimeRevokesPreview": true, "externalPreviewAndAssignment": true, "nativeImageInspection": true,
                    "filePanelCancel": true, "preparedCancelUnchanged": true, "staleAssignmentUnchanged": true,
                    "sourcePreparedCancelUnchanged": true, "sourceStaleAssignmentUnchanged": true,
                    "sourceSHA256": sourceSHA, "sourceImageSHA256": sourceProof.image.sha256, "externalSHA256": externalSHA]) { _, new in new }
                results.append(result)
            } catch { driver.failure(error); throw error }
        }
        return results
    }

    static func bible(context: ProductionPlanningAcceptanceFixture.Context, output: URL,
                      scene: SpatialSceneHead, cameraID: String, locationID: String) async throws -> [[String: Any]] {
        let defaults = UserDefaults.standard
        let oldScale = defaults.object(forKey: AppTheme.Typography.scaleKey)
        defer { if let oldScale { defaults.set(oldScale, forKey: AppTheme.Typography.scaleKey) } else { defaults.removeObject(forKey: AppTheme.Typography.scaleKey) } }
        let window = try documentWindow(context)
        let root = context.dataRoot
        let revision = try await Task.detached { try SpatialSceneStore.load(scene, in: root) }.value
        guard let camera = revision.snapshot.cameras.first(where: { $0.id == cameraID }) else { throw failed("The saved native camera is missing.") }
        var results: [[String: Any]] = []
        for scale in scales {
            defaults.set(scale, forKey: AppTheme.Typography.scaleKey)
            let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "visual-bible-\(Int(scale * 100))")
            let prefix = "bible.spatial."
            do {
                try await requireViewport(window, driver: driver)
                context.editor.setWorkspaceFocus(.production); context.editor.revealCockpit(.bible)
                try await driver.segment("bible.section", title: "Locations",
                    titles: ["Characters", "Ensembles", "Props", "Locations", "Look", "Shot references"], in: window)
                try await driver.wait("Bible locations section") { driver.text("bible.section", in: window) == "Locations" }
                func open() async throws -> NSWindow {
                    try await driver.click(prefix + "open." + locationID, in: window)
                    let sheet = try await driver.sheet(prefix + "sheet")
                    try await driver.wait("Bible fields loaded") { driver.state(prefix + "scene", in: sheet) == true }
                    try driver.visible([prefix + "cancel", prefix + "assign"], in: sheet)
                    guard driver.state(prefix + "assign", in: sheet) == false else { throw failed("The unrendered Bible sheet allows assignment.") }
                    return sheet
                }
                func close(_ sheet: NSWindow) async throws {
                    try await driver.click(prefix + "cancel", in: sheet)
                    try await driver.wait("cancel Bible sheet") { window.attachedSheet == nil && window.isKeyWindow }
                }
                func prepare(_ sheet: NSWindow, view: String) async throws -> String {
                    try await driver.picker(prefix + "scene", title: scene.name, expected: scene.id.uuidString, in: sheet)
                    try await driver.wait("saved camera loaded") { driver.state(prefix + "camera", in: sheet) == true }
                    try await driver.picker(prefix + "camera", title: camera.name, expected: camera.id, in: sheet)
                    try await driver.fill(prefix + "view-id", value: view, in: sheet)
                    if driver.text(prefix + "purpose", in: sheet) != "" { try await driver.fill(prefix + "purpose", value: "", in: sheet) }
                    guard driver.state(prefix + "render", in: sheet) == false else { throw failed("A Bible view without a purpose can render.") }
                    try await driver.fill(prefix + "purpose", value: "Show the complete room and its cube at \(Int(scale * 100)) percent.", in: sheet)
                    try await driver.wait("Bible render enabled") { driver.state(prefix + "render", in: sheet) == true }
                    try await driver.reveal(prefix + "render", in: sheet)
                    try driver.visible([prefix + "render", prefix + "cancel", prefix + "assign"], in: sheet)
                    try driver.capture("before-render", target: sheet)
                    try await driver.click(prefix + "render", in: sheet)
                    try await driver.wait("actual Bible render preview", seconds: 130) { driver.state(prefix + "assign", in: sheet) == true && driver.text(prefix + "image", in: sheet)?.count == 64 }
                    try await driver.reveal(prefix + "image", in: sheet)
                    try driver.visible([prefix + "image", prefix + "cancel", prefix + "assign"], in: sheet)
                    guard let digest = driver.text(prefix + "image", in: sheet) else { throw failed("The actual Bible preview has no image identity.") }
                    try driver.capture("rendered-preview", target: sheet)
                    try await driver.inspect(prefix + "inspect", in: sheet)
                    return digest
                }
                var sheet = try await open()
                let beforeCancel = try await bibleDigest(context)
                _ = try await prepare(sheet, view: "cancel_\(Int(scale * 100))")
                try await close(sheet)
                guard try await bibleDigest(context) == beforeCancel else { throw failed("Cancelling the actual rendered Bible preview changed its assignment.") }

                sheet = try await open()
                let viewID = "native_\(Int(scale * 100))"
                let preview = try await prepare(sheet, view: viewID)
                try await driver.click(prefix + "assign", in: sheet)
                try await driver.wait("Bible assignment closes sheet") { window.attachedSheet == nil }
                let assigned = try await Task.detached {
                    let bible = try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile)
                    try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: root)
                    guard let location = bible.locations.first(where: { $0.id == locationID }), let path = location.sheets[viewID],
                          let references = try PipelineSpatialDerivationWriter.bibleViewReferences(location: location, viewID: viewID, dataRoot: root),
                          references.contains(where: { $0.role == "core.spatial-derivation" }) else { throw GateBlocked("The native Bible assignment lost its actual render proof.") }
                    return try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: root))
                }.value
                guard assigned == preview else { throw failed("Bible assignment differs from the inspected preview.") }
                try driver.capture("assigned", target: window)

                sheet = try await open()
                _ = try await prepare(sheet, view: "stale_\(Int(scale * 100))")
                let old = try await bibleDigest(context)
                let bible = try YAMLArtifactStore(dataRoot: context.dataRoot).load(Bible.self, at: PipelineLayout.bibleFile)
                guard var look = try ProductionPlanningAcceptanceFixture.object(bible.look) as? [String: Any] else { throw failed("The canonical Look could not be staged.") }
                look["style"] = bible.look.style + " Revision \(Int(scale * 100))."
                try await ProductionPlanningAcceptanceFixture.run("write_bible", args: ["look": look,
                    "characters": try ProductionPlanningAcceptanceFixture.object(bible.characters),
                    "ensembles": try ProductionPlanningAcceptanceFixture.object(bible.ensembles),
                    "props": try ProductionPlanningAcceptanceFixture.object(bible.props),
                    "locations": try ProductionPlanningAcceptanceFixture.object(bible.locations)], in: context)
                let changed = try await bibleDigest(context)
                guard changed != old else { throw failed("The stale Bible fixture did not publish another canonical revision.") }
                try await driver.click(prefix + "assign", in: sheet)
                try await driver.wait("stale Bible assignment reported") { !(driver.text(prefix + "failure", in: sheet) ?? "").isEmpty }
                guard window.attachedSheet === sheet, try await bibleDigest(context) == changed else { throw failed("A stale native Bible assignment changed the newer revision.") }
                try await driver.reveal(prefix + "failure", in: sheet)
                try driver.capture("stale", target: sheet)
                try await driver.click(prefix + "reload", in: sheet)
                try await driver.wait("stale Bible reloaded") {
                    driver.state(prefix + "scene", in: sheet) == true && driver.text(prefix + "scene", in: sheet) == ""
                        && driver.state(prefix + "assign", in: sheet) == false && driver.text(prefix + "failure", in: sheet) == nil
                }
                let recoveredID = "recovered_\(Int(scale * 100))"
                let recoveredSHA = try await prepare(sheet, view: recoveredID)
                try await driver.click(prefix + "assign", in: sheet)
                try await driver.wait("reloaded Bible assignment closes sheet") { window.attachedSheet == nil }
                try await Task.detached {
                    let bible = try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile)
                    try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: root)
                    guard let path = bible.locations.first(where: { $0.id == locationID })?.sheets[recoveredID],
                          try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: root)) == recoveredSHA else {
                        throw GateBlocked("The reloaded Bible preview was not assigned exactly.")
                    }
                }.value
                try driver.capture("reloaded-assigned", target: window)
                var result = driver.result()
                result.merge(["scale": scale, "viewport": [960, 640], "nativeSceneAndCameraSelection": true,
                    "requiredPurpose": true, "realRenderedPreview": true, "nativeImageInspection": true,
                    "exactPreviewAssigned": true, "preparedCancelUnchanged": true, "staleAssignmentUnchanged": true,
                    "reloadAndAssign": true,
                    "imageSHA256": assigned, "viewID": viewID]) { _, new in new }
                results.append(result)
            } catch { driver.failure(error); throw error }
        }
        return results
    }

    private static func documentWindow(_ context: ProductionPlanningAcceptanceFixture.Context) throws -> NSWindow {
        if context.document.windowControllers.isEmpty { context.document.makeWindowControllers() }
        guard let window = context.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window else {
            throw failed("The real document window is unavailable.")
        }
        window.setContentSize(NSSize(width: 960, height: 640)); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
    private static func requireViewport(_ window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try await driver.wait("minimum document viewport") {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentView?.bounds.size == NSSize(width: 960, height: 640)
        }
    }
    private static func readBoard(_ context: ProductionPlanningAcceptanceFixture.Context) async throws -> StoryboardBundleSnapshot {
        let root = context.dataRoot
        return try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false) }.value
    }
    private static func assignedProof(_ context: ProductionPlanningAcceptanceFixture.Context, shotID: String, momentID: String) async throws -> StoryboardSketchProofV1 {
        let root = context.dataRoot
        return try await Task.detached {
            let board = try PlanningWriterIO.storyboard(dataRoot: root)
            guard let proof = board.timing.shots.first(where: { $0.id == shotID })?.moments.first(where: { $0.id == momentID })?.asset?.proof else {
                throw GateBlocked("The native Storyboard assignment has no proof.")
            }
            let value = try PlanningWriterIO.read(StoryboardSketchProofV1.self, at: proof.path, dataRoot: root)
            try PipelineStoryboardNativeMedia.requireCurrent(value, dataRoot: root)
            return value
        }.value
    }
    private static func bibleDigest(_ context: ProductionPlanningAcceptanceFixture.Context) async throws -> String {
        let root = context.dataRoot
        return try await Task.detached { try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root)) }.value
    }
    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native visual sources: " + message) }
}
