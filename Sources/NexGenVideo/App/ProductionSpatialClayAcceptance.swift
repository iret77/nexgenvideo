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
                try await ProductionV2PlanningAcceptance.selectPhase("shot_planning", context: context, driver: driver)
                try await driver.click("shot-planning.clay.open." + shotID, in: window)
                let sheet = try await driver.sheet("shot-planning.clay.sheet")
                try await driver.wait("confirmed actual state ready to render") { driver.state("shot-planning.clay.render", in: sheet) == true }
                try driver.visible(["shot-planning.clay.close", "shot-planning.clay.render"], in: sheet)
                let prior = try await derivation(shotID: shotID, root: root)
                try await driver.click("shot-planning.clay.render", in: sheet)
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
                results.append(driver.result().merging(["scale": scale, "viewport": [960, 640]]) { _, new in new })
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
            return driver.result().merging(["scale": scale, "viewport": [960, 640]]) { _, new in new }
        } catch { driver.failure(error); throw error }
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
