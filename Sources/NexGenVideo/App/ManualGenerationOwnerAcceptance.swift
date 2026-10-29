import AppKit
import NexGenEngine

@MainActor
enum ManualGenerationOwnerAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "manual-generation-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        let package = directory.appendingPathComponent("Generation.ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        var timeline = Timeline()
        timeline.width = 320; timeline.height = 180; timeline.fps = 30; timeline.settingsConfigured = true
        try JSONEncoder().encode(timeline).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let document = try await VideoProject.load(from: package)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        defer { document.close() }
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The native generation project did not open.") }
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await ManualGenerationAcceptance.run(editor: document.editorViewModel, directory: directory)
        let progressURL = directory.appendingPathComponent("manual-generation.json")
        guard let progress = try JSONSerialization.jsonObject(with: Data(contentsOf: progressURL)) as? [String: Any],
              progress["failure"] is NSNull,
              let interactions = progress["interactions"] as? [[String: Any]],
              let images = progress["screenshots"] as? [String], !images.isEmpty else {
            throw GateBlocked("Native generation did not produce complete interaction evidence.")
        }
        return ["viewport": [960, 640], "interactions": interactions,
                "screenshots": images.map { name + "/" + $0 }, "nativeScenario": true,
                "liveProvider": false, "progress": name + "/manual-generation.json"]
    }
}
