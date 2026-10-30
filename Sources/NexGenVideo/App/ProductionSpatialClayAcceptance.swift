import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ProductionSpatialClayAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context, shotID: String, output: URL) async throws -> [[String: Any]] {
        let defaults = UserDefaults.standard, oldScale = defaults.object(forKey: AppTheme.Typography.scaleKey)
        defer { if let oldScale { defaults.set(oldScale, forKey: AppTheme.Typography.scaleKey) } else { defaults.removeObject(forKey: AppTheme.Typography.scaleKey) } }
        let window = try ProductionSceneUIAcceptance.documentWindow(context), root = context.dataRoot
        var results: [[String: Any]] = []
        for scale in [1.0, 1.25, 1.5] {
            defaults.set(scale, forKey: AppTheme.Typography.scaleKey)
            let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "spatial-clay-\(Int(scale * 100))")
            do {
                try await waitForPresentation(window: window, scale: scale, driver: driver)
                try await ProductionV2PlanningAcceptance.selectPhase("shot_planning", context: context, driver: driver)
                let prior = try await derivation(shotID: shotID, root: root)
                let sceneURL = try await Task.detached {
                    let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: PlanningWriterIO.storyboard(dataRoot: root))
                    guard let reference = draft.shots.first(where: { $0.shotID == shotID })?.camera.sceneReference else {
                        throw GateBlocked("The cancellation control has no current location source.")
                    }
                    return try ProjectLocalFile.resolve(reference.path, dataRoot: root)
                }.value
                func inspectReload(_ gate: BpyNativeHashGate, in sheet: NSWindow, label: String, seconds: Double) async throws -> (String, Bool, UUID) {
                    try await driver.wait(label + " hash started", seconds: seconds) { gate.sample != nil }
                    try await driver.wait(label + " loading visible") { driver.state("shot-planning.clay.loading", in: sheet) == true }
                    let close = driver.text("shot-planning.clay.close", in: sheet) ?? "missing"
                    let rendering = driver.state("shot-planning.clay.rendering", in: sheet) != nil
                    guard let sample = gate.sample, !gate.timedOut, close == "done", !rendering else {
                        throw failed("The Clay reload still claims to be a cancellable render.")
                    }
                    gate.release()
                    return (close, rendering, sample.context.id)
                }
                do {
                    let loadingGate = try BpyNativeHashGate(file: sceneURL)
                    defer { loadingGate.release() }
                    try await driver.click("shot-planning.clay.open." + shotID, in: window)
                    let loading = try await driver.sheet("shot-planning.clay.sheet")
                    try await driver.wait("Clay loading hash started", seconds: 30) { loadingGate.sample != nil }
                    guard let sample = loadingGate.sample, !sample.context.isCancelled() else { throw failed("The Clay loading hash was not active.") }
                    try await driver.click("shot-planning.clay.close", in: loading)
                    try await driver.wait("Clay loading sheet closed") { window.attachedSheet == nil }
                    try await driver.wait("Clay closed loading token cancelled") { sample.context.isCancelled() }
                    guard !loadingGate.timedOut else { throw failed("The Clay loading hash gate expired.") }
                    loadingGate.release()
                    try driver.record("Clay close during loading", fields: ["operation": sample.context.id.uuidString,
                        "bytes": sample.progress.bytes, "hashedBytes": sample.progress.hashedBytes, "callerCancelled": sample.context.isCancelled()])
                }
                let afterLoading = try await derivation(shotID: shotID, root: root)
                guard afterLoading?.proof == prior?.proof, afterLoading?.video == prior?.video else { throw failed("Closing Clay preparation changed its output.") }
                try await driver.click("shot-planning.clay.open." + shotID, in: window)
                let sheet = try await driver.sheet("shot-planning.clay.sheet")
                try await driver.wait("confirmed actual state ready to render") { driver.state("shot-planning.clay.render", in: sheet) == true }
                try driver.visible(["shot-planning.clay.close", "shot-planning.clay.render"], in: sheet)
                let gate = try BpyNativeHashGate(file: sceneURL)
                defer { gate.release() }
                try await driver.click("shot-planning.clay.render", in: sheet)
                try await driver.wait("Clay caller hashing started", seconds: 30) { gate.sample != nil }
                guard let sample = gate.sample, !sample.context.isCancelled() else { throw failed("The Clay hash was not active before Cancel.") }
                let cancelledReload = try BpyNativeHashGate(file: sceneURL, excludingOperation: sample.context.id)
                defer { cancelledReload.release() }
                try await driver.click("shot-planning.clay.close", in: sheet)
                try await driver.wait("Clay caller token cancelled") { sample.context.isCancelled() }
                gate.release()
                let cancelledReloadState = try await inspectReload(cancelledReload, in: sheet, label: "Clay cancelled reload", seconds: 30)
                try await driver.wait("Clay render enabled after cancellation", seconds: 30) {
                    driver.state("shot-planning.clay.render", in: sheet) == true || driver.text("shot-planning.clay.failure", in: sheet) != nil
                }
                let cancelled = try await derivation(shotID: shotID, root: root)
                guard !gate.timedOut, driver.text("shot-planning.clay.failure", in: sheet) == nil,
                      driver.text("shot-planning.clay.cancelled", in: sheet) == "Render cancelled. Clay video unchanged.",
                      cancelled?.proof == prior?.proof, cancelled?.video == prior?.video else { throw failed("Cancel did not restore the Clay render control without changing its output.") }
                try driver.capture("cancelled-during-hash", target: sheet)
                try driver.record("Clay cancel during actual caller hash", fields: ["operation": sample.context.id.uuidString,
                    "bytes": sample.progress.bytes, "hashedBytes": sample.progress.hashedBytes, "callerCancelled": sample.context.isCancelled(),
                    "reloadClose": cancelledReloadState.0, "renderingDuringReload": cancelledReloadState.1,
                    "reloadOperation": cancelledReloadState.2.uuidString, "notice": driver.text("shot-planning.clay.cancelled", in: sheet) ?? ""])
                let successfulRender = try BpyNativeHashGate(file: sceneURL)
                defer { successfulRender.release() }
                try await driver.click("shot-planning.clay.render", in: sheet)
                try await driver.wait("Clay successful render caller started", seconds: 30) { successfulRender.sample != nil }
                guard let successfulSample = successfulRender.sample else { throw failed("The Clay render hash was not observed.") }
                let successfulReload = try BpyNativeHashGate(file: sceneURL, excludingOperation: successfulSample.context.id, followReplacements: true)
                defer { successfulReload.release() }
                successfulRender.release()
                let successfulReloadState = try await inspectReload(successfulReload, in: sheet, label: "Clay committed reload", seconds: 180)
                try driver.record("Clay reload after render", fields: ["renderOperation": successfulSample.context.id.uuidString,
                    "reloadOperation": successfulReloadState.2.uuidString, "reloadClose": successfulReloadState.0,
                    "renderingDuringReload": successfulReloadState.1])
                try await driver.wait("full native Clay rendering completed", seconds: 180) {
                    driver.text("shot-planning.clay.failure", in: sheet) != nil
                        || (driver.state("shot-planning.clay.sheet", in: sheet) == true
                            && driver.text("shot-planning.clay.proof", in: sheet) != nil
                            && driver.text("shot-planning.clay.proof", in: sheet) != prior?.proof.sha256)
                }
                if let error = driver.text("shot-planning.clay.failure", in: sheet) { throw failed(error) }
                let current = try await derivation(shotID: shotID, root: root)
                guard let current, current.proof != prior?.proof,
                      driver.text("shot-planning.clay.video", in: sheet) == current.video.sha256 else {
                    throw failed("The native render did not publish a new authenticated complete-shot output.")
                }
                try await driver.click("production.input.video.open." + current.video.id, in: sheet)
                let inspection = try await driver.sheet("production.input.video.player", parent: sheet)
                try driver.visible(["production.input.video.player", "production.input.video.close"], in: inspection)
                guard driver.text("production.input.video.player", in: inspection) == current.video.sha256 else {
                    throw failed("The actual video inspection opened different Clay bytes.")
                }
                let duration = try await AVURLAsset(url: ProjectLocalFile.requireHash(current.video.sha256,
                    at: current.video.path, dataRoot: root)).load(.duration)
                try await ProductionNativePlayerAcceptance.playWholeTake(duration: duration.seconds, driver: driver, sheet: inspection,
                    playerID: "production.input.video.player", recordLabel: "complete native Clay playback")
                try driver.capture("complete-clay-played", target: inspection)
                try await driver.click("production.input.video.close", in: inspection)
                try await driver.wait("Clay video inspector closed") { sheet.attachedSheet == nil && sheet.isKeyWindow }
                try await driver.click("shot-planning.clay.close", in: sheet)
                try await driver.wait("Clay review closed") { window.attachedSheet == nil }
                let persisted = try await derivation(shotID: shotID, root: root)
                guard persisted?.video == current.video, persisted?.proof == current.proof else {
                    throw failed("Closing the actual Clay inspection changed the assigned output.")
                }
                try driver.record("native full shot Clay render and inspect", fields: ["shotID": shotID,
                    "videoSHA256": current.video.sha256, "proofSHA256": current.proof.sha256, "durationSeconds": duration.seconds])
                var result = driver.result()
                result["cancelDuringHash"] = true; result["closeDuringLoading"] = true
                results.append(result.merging(try presentation(window: window, scale: scale)) { _, new in new })
            } catch { driver.failure(error); throw error }
        }
        return results
    }

    static func storyboard(context: ProductionPlanningAcceptanceFixture.Context, scene: SpatialSceneHead,
                           cameraID: String, shotID: String, momentID: String, output: URL) async throws -> [[String: Any]] {
        let defaults = UserDefaults.standard, oldScale = defaults.object(forKey: AppTheme.Typography.scaleKey)
        defer { if let oldScale { defaults.set(oldScale, forKey: AppTheme.Typography.scaleKey) } else { defaults.removeObject(forKey: AppTheme.Typography.scaleKey) } }
        var results: [[String: Any]] = []
        for scale in [1.0, 1.25, 1.5] {
            defaults.set(scale, forKey: AppTheme.Typography.scaleKey)
            results.append(try await storyboardAtScale(context: context, scene: scene, cameraID: cameraID, shotID: shotID, momentID: momentID, output: output, scale: scale))
        }
        return results
    }

    private static func storyboardAtScale(context: ProductionPlanningAcceptanceFixture.Context, scene: SpatialSceneHead,
                                         cameraID: String, shotID: String, momentID: String, output: URL, scale: Double) async throws -> [String: Any] {
        let window = try ProductionSceneUIAcceptance.documentWindow(context), root = context.dataRoot
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "spatial-storyboard-\(Int(scale * 100))")
        do {
            try await waitForPresentation(window: window, scale: scale, driver: driver)
            try await ProductionV2PlanningAcceptance.selectPhase("storyboard", context: context, driver: driver)
            let original = try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root) }.value
            let revision = try await Task.detached { try SpatialSceneStore.load(scene, in: root) }.value
            guard let camera = revision.snapshot.cameras.first(where: { $0.id == cameraID }) else { throw failed("The native sketch camera disappeared.") }
            for cancel in [true, false] {
                try await driver.menu("storyboard.sketch.sources." + momentID, title: "Create from location…", in: window)
                let sheet = try await driver.sheet("storyboard.spatial.sheet")
                try await driver.wait("native spatial sketch locations loaded") { driver.state("storyboard.spatial.scene", in: sheet) == true }
                guard driver.state("storyboard.spatial.assign", in: sheet) == false else { throw failed("A location sketch without a camera is assignable.") }
                try await driver.picker("storyboard.spatial.scene", title: scene.name, expected: scene.id.uuidString, in: sheet)
                try await driver.wait("native sketch cameras loaded") { driver.state("storyboard.spatial.camera", in: sheet) == true }
                try await driver.picker("storyboard.spatial.camera", title: camera.name, expected: camera.id, in: sheet)
                try driver.visible(["storyboard.spatial.cancel", "storyboard.spatial.assign"], in: sheet)
                try driver.capture(cancel ? "camera-selected-cancel" : "camera-selected-assign", target: sheet)
                try await driver.click(cancel ? "storyboard.spatial.cancel" : "storyboard.spatial.assign", in: sheet)
                try await driver.wait("native camera sketch decision completed", seconds: 90) {
                    window.attachedSheet == nil || driver.text("storyboard.spatial.failure", in: sheet) != nil
                }
                if let error = driver.text("storyboard.spatial.failure", in: sheet) { throw failed(error) }
                let written = try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root) }.value
                if cancel { guard written.fingerprint == original.fingerprint else { throw failed("Canceling a native location sketch changed the Storyboard.") } }
                else {
                    guard let asset = written.timing.shots.first(where: { $0.id == shotID })?.moments.first(where: { $0.id == momentID })?.asset,
                          written.fingerprint != original.fingerprint else { throw failed("The real location sketch was not assigned to its chosen moment.") }
                    try await Task.detached {
                        let proof = try PlanningWriterIO.read(StoryboardSketchProofV1.self, at: asset.proof.path, dataRoot: root)
                        try PipelineSpatialDerivationWriter.requireStoryboardSketch(proof, dataRoot: root)
                    }.value
                    try await driver.inspect("storyboard.sketch.inspect." + momentID, in: window)
                    try driver.capture("spatial-sketch-assigned", target: window)
                    try driver.record("native location sketch assigned", fields: ["shotID": shotID, "momentID": momentID,
                        "imageSHA256": asset.image.sha256, "proofSHA256": asset.proof.sha256, "cancelPreservedStoryboard": true])
                }
            }
            return driver.result().merging(try presentation(window: window, scale: scale)) { _, new in new }
        } catch { driver.failure(error); throw error }
    }

    private static func waitForPresentation(window: NSWindow, scale: Double, driver: ProductionVisualSourcesDriver) async throws {
        try await driver.wait("actual minimum document viewport and interface scale") {
            window.contentView?.bounds.size == NSSize(width: 960, height: 640)
                && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
        }
    }

    private static func presentation(window: NSWindow, scale: Double) throws -> [String: Any] {
        let effectiveScale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
        guard let bounds = window.contentView?.bounds, bounds.size == NSSize(width: 960, height: 640),
              effectiveScale == scale, window.backingScaleFactor.isFinite, window.backingScaleFactor > 0 else {
            throw failed("The actual document viewport or interface scale changed during native input.")
        }
        return ["scale": scale, "effectiveScale": effectiveScale, "viewport": [bounds.width, bounds.height],
                "backingScale": window.backingScaleFactor]
    }

    private static func derivation(shotID: String, root: URL) async throws -> (video: CanonicalArtifactReferenceV1, proof: CanonicalArtifactReferenceV1)? {
        try await Task.detached { () throws -> (video: CanonicalArtifactReferenceV1, proof: CanonicalArtifactReferenceV1)? in
            let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: PlanningWriterIO.storyboard(dataRoot: root))
            guard let shot = draft.shots.first(where: { $0.shotID == shotID }), let proof = shot.camera.spatialDerivation else { return nil }
            guard let state = shot.camera.spatialState, let camera = shot.camera.spatialCameraID, let scene = shot.camera.sceneReference,
                  let video = try PipelineSpatialDerivationWriter.planningDerivationReferences(reference: proof,
                    stateReference: state, cameraID: camera, sceneReference: scene, shotID: shotID, dataRoot: root).first(where: { $0.role == "core.shot-clay-video" }) else {
                throw GateBlocked("The assigned Clay video has no complete exact state proof.")
            }
            return (video, proof)
        }.value
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native Clay acceptance: " + message) }
}
