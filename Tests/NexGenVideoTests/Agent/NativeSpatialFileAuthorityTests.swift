import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@MainActor
@Suite("Native spatial file authority")
struct NativeSpatialFileAuthorityTests {
    @Test("Native Bible views are excluded from agent asset staging before filesystem mutation")
    func reservesNativeBibleViews() throws {
        let id = UUID().uuidString.lowercased()
        for path in ["bible/\(id)/spatial-\(id)/clay-00000000.png", "pipeline/bible/\(id)/spatial-\(id)/clay-00000000.png"] {
            #expect(throws: (any Error).self) { try ToolExecutor.requirePipelineAssetCopyPath(path, source: false) }
        }
        try ToolExecutor.requirePipelineAssetCopyPath("bible/\(id)/location.png", source: false)
    }

    @Test("The actual asset-copy tool refuses native publication before copying")
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
        let allowed = "bible/authority/candidate.png"
        let positive = await harness.runRaw("copy_project_file", args: ["project_dir": root.path,
            "from": "import/candidate.png", "to": allowed])
        #expect(!positive.isError, "\(ToolHarness.textOf(positive))")
        #expect(try Data(contentsOf: root.appendingPathComponent(allowed)) == original)
        let destinations = ["spatial-adoptions/\(id).v1.json", "pipeline/spatial-adoptions/\(id).v1.json",
            "shot-planning/spatial-states/\(id)/state.v1.json", "shot-planning/spatial-states/\(id)/selection.v1.json",
            "storyboard/sketches/\(id)/spatial-\(id)/proof.v1.json", "storyboard/sketches/\(id)/spatial-\(id)/frame.png",
            "execution/blockout/\(id)/native-\(id)/blockout.mov", "bible/\(id)/native-panorama-\(id)/view.png"]
        for path in destinations {
            let copied = await harness.runRaw("copy_project_file", args: ["project_dir": root.path,
                "from": "import/candidate.png", "to": path])
            #expect(copied.isError)
            #expect(ToolHarness.textOf(copied).contains("Native production receipts, camera states and derived media can only be published by their verified host operation."))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
        #expect(try Data(contentsOf: source) == original)
    }
}
