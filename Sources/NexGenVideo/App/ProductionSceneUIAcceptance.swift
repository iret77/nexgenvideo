import AppKit
import NexGenEngine

@MainActor
enum ProductionSceneUIAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context, output: URL) async throws -> (SpatialSceneHead, [[String: Any]]) {
        let defaults = UserDefaults.standard, oldScale = defaults.object(forKey: AppTheme.Typography.scaleKey)
        defer { if let oldScale { defaults.set(oldScale, forKey: AppTheme.Typography.scaleKey) } else { defaults.removeObject(forKey: AppTheme.Typography.scaleKey) } }
        let window = try documentWindow(context), root = context.dataRoot
        var results: [[String: Any]] = [], lastHead: SpatialSceneHead?
        for scale in [1.0, 1.25, 1.5] {
            defaults.set(scale, forKey: AppTheme.Typography.scaleKey)
            let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "spatial-scene-\(Int(scale * 100))")
            do {
                await context.editor.refreshEngineState()
                try await driver.wait("minimum scene viewport") { window.contentView?.bounds.size == NSSize(width: 960, height: 640) }
                try await ProductionV2PlanningAcceptance.selectPhase("production_design", context: context, driver: driver)
                try await driver.segment("production-design.view", title: "Locations · 3D", titles: ["Design", "Locations · 3D"], in: window)
                try await driver.wait("real location runtime ready", seconds: 90) {
                    driver.state("spatial.location.create", in: window) == true || driver.text("spatial.workspace.error", in: window) != nil
                }
                if let error = driver.text("spatial.workspace.error", in: window) { throw failed(error) }
                let name = "Pale room \(Int(scale * 100))"
                try await driver.fill("spatial.location.name", value: name, in: window)
                var previous = driver.text("spatial.scene", in: window)
                try await driver.click("spatial.location.create", in: window)
                try await revision(after: previous, driver: driver)
                let empty = try await read(name: name, root: root)
                guard empty.1.snapshot.objects.isEmpty else { throw failed("The new native location did not start empty.") }
                previous = driver.text("spatial.scene", in: window)
                try await driver.menu("spatial.object.add", title: "Cube", in: window)
                try await revision(after: previous, driver: driver)
                let created = try await read(name: name, root: root)
                guard created.1.snapshot.objects.count == 1, let cube = created.1.snapshot.objects.first else {
                    throw failed("The Add object menu did not create exactly one real cube.")
                }
                try await driver.click("spatial.object." + cube.id, in: window)
                try await driver.fill("spatial.position.0", value: "0.5", in: window)
                previous = driver.text("spatial.scene", in: window)
                try await driver.click("spatial.transform.apply", in: window)
                try await revision(after: previous, driver: driver)
                let moved = try await read(name: name, root: root)
                guard let movedCube = moved.1.snapshot.objects.first(where: { $0.id == cube.id }),
                      abs(movedCube.matrixWorld[3] - 0.5) < 0.000001 else { throw failed("The typed transform did not change the actual Blender object.") }
                previous = driver.text("spatial.scene", in: window)
                try await driver.click("spatial.undo", in: window)
                try await revision(after: previous, driver: driver)
                let undone = try await read(name: name, root: root)
                guard undone.1.snapshot.objects.first(where: { $0.id == cube.id })?.matrixWorld == cube.matrixWorld else {
                    throw failed("Native scene Undo did not restore the preceding object matrix.")
                }
                previous = driver.text("spatial.scene", in: window)
                try await driver.click("spatial.redo", in: window)
                try await revision(after: previous, driver: driver)
                let restored = try await read(name: name, root: root)
                guard restored.1.snapshot.objects.first(where: { $0.id == cube.id })?.matrixWorld == movedCube.matrixWorld else {
                    throw failed("Native scene Redo did not restore the actual transform.")
                }
                try await driver.fill("spatial.camera.name", value: "Wide camera", in: window)
                try await driver.fill("spatial.camera.fov", value: "60.0", in: window)
                try await driver.fill("spatial.camera.width", value: "641", in: window)
                try await driver.fill("spatial.camera.height", value: "360", in: window)
                guard driver.state("spatial.camera.apply", in: window) == false,
                      !(driver.text("spatial.camera.dimensions-error", in: window) ?? "").isEmpty else {
                    throw failed("The non-renderable camera ratio was silently accepted before Save.")
                }
                try driver.capture("camera-invalid-ratio", target: window)
                guard try await read(name: name, root: root).0 == restored.0 else { throw failed("Unsaved camera fields mutated the canonical location.") }
                try await driver.fill("spatial.camera.width", value: "128", in: window)
                try await driver.fill("spatial.camera.height", value: "128", in: window)
                if driver.state("spatial.camera.keyframe", in: window) == false {
                    try await driver.click("spatial.camera.keyframe", in: window, enabled: false)
                }
                try await driver.wait("native camera keyframe checked") { driver.state("spatial.camera.keyframe", in: window) == true }
                previous = driver.text("spatial.scene", in: window)
                try await driver.click("spatial.camera.apply", in: window)
                try await revision(after: previous, driver: driver)
                let cameraRevision = try await read(name: name, root: root)
                guard cameraRevision.1.snapshot.cameras.count == 1, let camera = cameraRevision.1.snapshot.cameras.first,
                      camera.name == "Wide camera", camera.width == 128, camera.height == 128,
                      abs(camera.verticalFieldOfView - .pi / 3) < 0.000001 else { throw failed("The native camera differs from its entered fields.") }
                try await driver.picker("spatial.camera.select", title: camera.name, expected: camera.id, in: window)
                try await driver.click("spatial.camera.render", in: window)
                try await driver.wait("actual camera frame visible", seconds: 90) {
                    driver.state("spatial.scene", in: window) == true && driver.text("spatial.camera.rendered", in: window) != nil
                }
                try await driver.reveal("spatial.camera.rendered", in: window)
                try driver.visible(["spatial.camera.rendered", "spatial.camera.return"], in: window)
                try driver.capture("camera-rendered", target: window)
                try await driver.click("spatial.camera.return", in: window)
                try await driver.wait("native viewport restored") { driver.state("spatial.viewport", in: window) == true }
                try driver.capture("scene-edited", target: window)
                let final = try await read(name: name, root: root)
                guard final.0 == cameraRevision.0 else { throw failed("Read-only camera rendering changed the saved scene.") }
                lastHead = final.0
                try driver.record("native scene camera transform undo redo", fields: ["sceneID": final.0.id.uuidString,
                    "manifestSHA256": final.0.manifestSHA256, "cubeID": cube.id, "cameraID": camera.id,
                    "invalidRatioBlocked": true, "undoRestoredMatrix": true, "redoRestoredMatrix": true,
                    "cameraRenderPreservedScene": true])
                results.append(driver.result().merging(["scale": scale, "viewport": [960, 640]]) { _, new in new })
            } catch { driver.failure(error); throw error }
        }
        guard let lastHead else { throw failed("No actual native location was created.") }
        return (lastHead, results)
    }

    static func documentWindow(_ context: ProductionPlanningAcceptanceFixture.Context) throws -> NSWindow {
        if context.document.windowControllers.isEmpty { context.document.makeWindowControllers() }
        guard let window = context.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window else {
            throw failed("The real production document has no window.")
        }
        window.setContentSize(NSSize(width: 960, height: 640)); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private static func read(name: String, root: URL) async throws -> (SpatialSceneHead, SpatialSceneRevision) {
        try await Task.detached {
            try PipelineSpatialSceneAuthority.requireCurrent(dataRoot: root)
            guard let head = try SpatialSceneStore.index(in: root).scenes.first(where: { $0.name == name }) else {
                throw GateBlocked("The native scene has no canonical head.")
            }
            return (head, try SpatialSceneStore.load(head, in: root))
        }.value
    }

    private static func revision(after previous: String?, driver: ProductionVisualSourcesDriver) async throws {
        try await driver.wait("native Blender revision committed", seconds: 90) {
            driver.text("spatial.error", in: driver.window) != nil || (driver.state("spatial.scene", in: driver.window) == true
                && driver.text("spatial.scene", in: driver.window) != previous)
        }
        if let error = driver.text("spatial.error", in: driver.window) { throw failed(error) }
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native scene acceptance: " + message) }
}
