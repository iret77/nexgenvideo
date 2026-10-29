import AppKit
import NexGenEngine

@MainActor
enum ProductionSpatialPoseAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context, scene: SpatialSceneHead,
                    cameraID: String, shotID: String, output: URL) async throws -> [[String: Any]] {
        let defaults = UserDefaults.standard, oldScale = defaults.object(forKey: AppTheme.Typography.scaleKey)
        defer { if let oldScale { defaults.set(oldScale, forKey: AppTheme.Typography.scaleKey) } else { defaults.removeObject(forKey: AppTheme.Typography.scaleKey) } }
        let window = try ProductionSceneUIAcceptance.documentWindow(context), root = context.dataRoot
        let initial = try await Task.detached { try PipelineSpatialDerivationWriter.planningContext(shotID: shotID, scene: scene, dataRoot: root) }.value
        guard let camera = initial.scene.snapshot.cameras.first(where: { $0.id == cameraID }),
              let cube = initial.scene.snapshot.objects.first(where: { $0.id != cameraID }), initial.frameCount > 2 else {
            throw failed("The real shot needs a camera, cube and distinct intermediate frame.")
        }
        let prefix = "shot-planning.spatial.", end = initial.frameCount - 1, middle = initial.frameCount / 2
        var results: [[String: Any]] = []
        for scale in [1.0, 1.25, 1.5] {
            defaults.set(scale, forKey: AppTheme.Typography.scaleKey)
            let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "spatial-pose-\(Int(scale * 100))")
            do {
                try await ProductionV2PlanningAcceptance.selectPhase("shot_planning", context: context, driver: driver)
                let before = try await draft(root)
                try await driver.click(prefix + "open." + shotID, in: window)
                var sheet = try await driver.sheet(prefix + "sheet")
                try driver.visible([prefix + "cancel", prefix + "confirm"], in: sheet)
                try await driver.click(prefix + "cancel", in: sheet)
                try await driver.wait("native pose cancellation") { window.attachedSheet == nil && window.isKeyWindow }
                guard try await draft(root) == before else { throw failed("Canceling spatial state changed the canonical draft.") }
                try await driver.click(prefix + "open." + shotID, in: window)
                sheet = try await driver.sheet(prefix + "sheet")
                if before.shots.first(where: { $0.shotID == shotID })?.camera.spatialState == nil {
                    try await driver.wait("verified native locations loaded") { driver.state(prefix + "location", in: sheet) == true }
                    guard driver.state(prefix + "confirm", in: sheet) == false else { throw failed("An uninitialized state is confirmable.") }
                    try await driver.picker(prefix + "location", title: scene.name, expected: scene.id.uuidString, in: sheet)
                    try await driver.wait("actual scene cameras loaded") { driver.state(prefix + "camera", in: sheet) == true }
                    try await driver.picker(prefix + "camera", title: camera.name, expected: cameraID, in: sheet)
                    try await driver.click(prefix + "initialize", in: sheet)
                }
                try await driver.wait("actual full shot pose timeline loaded") { driver.state(prefix + "object", in: sheet) == true }
                try await driver.picker(prefix + "object", title: cube.name, expected: cube.id, in: sheet)
                let originalX = driver.text(prefix + "position.0", in: sheet)
                try await driver.fill(prefix + "position.0", value: "999.0", in: sheet)
                guard driver.state(prefix + "confirm", in: sheet) == false,
                      driver.state(prefix + "scrubber", in: sheet) == false,
                      driver.state(prefix + "object", in: sheet) == false else {
                    throw failed("Unapplied transform fields can be silently lost or confirmed.")
                }
                try await driver.click(prefix + "discard", in: sheet)
                try await driver.wait("native transform fields restored") { driver.text(prefix + "position.0", in: sheet) == originalX }
                try await move(to: middle, frameCount: initial.frameCount, driver: driver, sheet: sheet)
                try await driver.fill(prefix + "position.0", value: "0.75", in: sheet)
                try await driver.click(prefix + "set", in: sheet)
                try await driver.wait("native intermediate keyframe inserted") { frames(driver, sheet).contains(middle) }
                try await driver.click(prefix + "remove", in: sheet)
                try await driver.wait("native intermediate keyframe removed") { !frames(driver, sheet).contains(middle) }
                try await driver.fill(prefix + "position.0", value: "0.75", in: sheet)
                try await driver.click(prefix + "set", in: sheet)
                try await driver.wait("native intermediate keyframe restored") { frames(driver, sheet).contains(middle) }
                try await move(to: end, frameCount: initial.frameCount, driver: driver, sheet: sheet)
                let x = 2 + scale / 10
                try await driver.fill(prefix + "position.0", value: String(x), in: sheet)
                try await driver.click(prefix + "set", in: sheet)
                try await driver.wait("native end pose applied") {
                    driver.state(prefix + "confirm", in: sheet) == true && driver.text(prefix + "position.0", in: sheet) == String(x)
                }
                try await driver.reveal(prefix + "preview", in: sheet)
                try driver.visible([prefix + "preview", prefix + "cancel", prefix + "confirm"], in: sheet)
                try driver.capture("confirmed-motion-preview", target: sheet)
                try await driver.click(prefix + "confirm", in: sheet)
                try await driver.wait("actual shot state committed", seconds: 60) { window.attachedSheet == nil }
                let written = try await draft(root)
                guard let shot = written.shots.first(where: { $0.shotID == shotID }), let state = shot.camera.spatialState,
                      let source = shot.camera.sceneReference, shot.camera.spatialCameraID == cameraID else { throw failed("The native state has no exact scene and camera binding.") }
                let saved = try await Task.detached {
                    (try PipelineSpatialDerivationWriter.requirePlanningState(reference: state, cameraID: cameraID,
                        sceneReference: source, shotID: shotID, dataRoot: root),
                     try PipelineSpatialDerivationWriter.planningPoseTimeline(reference: state, cameraID: cameraID,
                        sceneReference: source, shotID: shotID, dataRoot: root))
                }.value
                guard saved.0.frames.map(\.frame) == Array(0..<initial.frameCount),
                      saved.1.keyframes.keys.sorted() == [0, middle, end],
                      let last = saved.0.frames.last?.objects.first(where: { $0.objectID == cube.id }),
                      abs(last.matrixWorld[3] - x) < 0.000001,
                      saved.0.frames.first?.objects != saved.0.frames.last?.objects else { throw failed("Native keyframes did not persist the full motion and sparse authoring frames.") }
                try await driver.click(prefix + "open." + shotID, in: window)
                sheet = try await driver.sheet(prefix + "sheet")
                try await driver.wait("reopened native sparse keyframes") { frames(driver, sheet) == [0, middle, end] }
                try driver.capture("pose-reopened", target: sheet)
                try await driver.click(prefix + "cancel", in: sheet)
                try await driver.wait("reopened pose closed") { window.attachedSheet == nil }
                guard try await draft(root) == written else { throw failed("Read-only pose reopen changed the saved draft.") }
                try driver.record("native complete shot poses", fields: ["shotID": shotID, "stateSHA256": state.sha256,
                    "frameCount": initial.frameCount, "authoringFrames": [0, middle, end], "endX": x,
                    "cancelPreservedDraft": true, "pendingTransformBlocked": true, "sparseReopenPreserved": true])
                guard let viewport = window.contentView?.bounds.size else { throw failed("The native document viewport is unavailable.") }
                results.append(driver.result().merging(["scale": scale, "viewport": [viewport.width, viewport.height]]) { _, new in new })
            } catch { driver.failure(error); throw error }
        }
        return results
    }

    private static func draft(_ root: URL) async throws -> ShotPlanningDraftV1 {
        try await Task.detached { try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root,
            storyboard: PlanningWriterIO.storyboard(dataRoot: root)) }.value
    }

    private static func frames(_ driver: ProductionVisualSourcesDriver, _ sheet: NSWindow) -> [Int] {
        (driver.text("shot-planning.spatial.keyframes", in: sheet) ?? "").split(separator: ",").compactMap { Int($0) }
    }

    private static func move(to target: Int, frameCount: Int, driver: ProductionVisualSourcesDriver, sheet: NSWindow) async throws {
        let id = "shot-planning.spatial.scrubber"
        try await driver.click(id, in: sheet, fraction: .init(x: max(0.01, min(0.99, CGFloat(target) / CGFloat(frameCount - 1))), y: 0.5))
        for _ in 0..<frameCount {
            guard let current = driver.text(id, in: sheet).flatMap(Int.init) else { throw failed("The native frame control lost its actual value.") }
            if current == target { return }
            guard let slider = sheet.firstResponder as? NSSlider, slider.window === sheet,
                  let root = sheet.contentView, let frame = WorkspaceUIAcceptance.probeFrame(identifier: id, in: sheet),
                  frame.insetBy(dx: -1, dy: -1).contains(slider.convert(slider.bounds, to: root)) else {
                throw failed("The actual pose slider does not own keyboard input.")
            }
            try driver.pressKey(current < target ? 124 : 123,
                characters: current < target ? "\u{f703}" : "\u{f702}", modifiers: [.function, .numericPad], in: sheet)
            try await driver.wait("native pose frame keyboard step") { driver.text(id, in: sheet) != String(current) }
        }
        throw failed("Native frame input did not reach the requested pose.")
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native spatial pose acceptance: " + message) }
}
