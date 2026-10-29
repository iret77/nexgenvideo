import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@MainActor
@Suite("Native spatial file authority")
struct NativeSpatialFileAuthorityTests {
    @Test("Agent file tools cannot forge native spatial receipts or derived sketches")
    func refusesNativePublicationDestinations() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "Authority", mode: .generic)
        _ = try ProjectLocalFile.ensureDirectory("import", dataRoot: root)
        let source = root.appendingPathComponent("import/candidate.png")
        let original = Data("candidate bytes; publication must be refused before copying".utf8)
        try original.write(to: source)
        let harness = ToolHarness()
        let id = UUID().uuidString.lowercased()
        let destinations = ["spatial-adoptions/\(id).v1.json", "pipeline/spatial-adoptions/\(id).v1.json",
            "shot-planning/spatial-states/\(id)/state.v1.json", "shot-planning/spatial-states/\(id)/selection.v1.json",
            "storyboard/sketches/\(id)/spatial-\(id)/proof.v1.json", "storyboard/sketches/\(id)/spatial-\(id)/frame.png"]
        for path in destinations {
            let copied = await harness.runRaw("copy_project_file", args: ["project_dir": root.path,
                "from": "import/candidate.png", "to": path])
            #expect(copied.isError)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
            let imported = await harness.runRaw("import_media", args: ["source": ["path": source.path], "destination": path])
            #expect(imported.isError)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
        let written = await harness.runRaw("write_file", args: ["path": root.appendingPathComponent(destinations[0]).path, "content": "forged"])
        #expect(written.isError)
        #expect(try Data(contentsOf: source) == original)
    }
}
