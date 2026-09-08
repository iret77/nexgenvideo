import Foundation
import Testing
@testable import NexGenEngine

@Suite("Production style currency")
struct ProductionStyleStoreTests {
    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("style-store-\(UUID().uuidString)")
        let root = try ProjectScaffold.initProject(home: home, name: "style-test")
        try Data("brief version one".utf8).write(to: root.appendingPathComponent(PipelineLayout.briefFile))
        return root
    }

    private func design() throws -> ProductionDesign {
        try ProductionDesign(project: "style-test", generated: "2026-09-08", generator: "test",
                             visualMedium: .liveActionRealistic, colorScript: ["opening": "warm amber"])
    }

    private var selection: ProductionStyleSelectionV1 {
        .init(directorID: "director-wes-anderson-symmetry-deadpan")
    }

    @Test("changed upstream bytes and deleted style cannot silently reuse an approval")
    func tampering() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try ProductionStyleStoreV1.write(design: design(), selection: selection, clearStyle: false, dataRoot: root)
        #expect(try ProductionStyleStoreV1.load(dataRoot: root)?.selection == selection)
        let briefURL = root.appendingPathComponent(PipelineLayout.briefFile)
        let original = try Data(contentsOf: briefURL)
        try Data("changed brief".utf8).write(to: briefURL)
        #expect(throws: (any Error).self) { try ProductionStyleStoreV1.load(dataRoot: root) }
        try original.write(to: briefURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent(ResolvedProductionStyleV1.relativePath))
        #expect(throws: (any Error).self) { try ProductionStyleStoreV1.load(dataRoot: root) }
        try ProductionStyleStoreV1.write(design: design(), selection: nil, clearStyle: true, dataRoot: root)
        #expect(try ProductionStyleStoreV1.load(dataRoot: root) == nil)
    }

    @Test("failed currency publication restores the design and leaves no partial style")
    func rollback() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let path = root.appendingPathComponent("production_design/production_design.yaml")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = Data("existing design bytes".utf8)
        try old.write(to: path)
        try FileManager.default.removeItem(at: root.appendingPathComponent(PipelineLayout.briefFile))
        #expect(throws: (any Error).self) {
            try ProductionStyleStoreV1.write(design: design(), selection: selection, clearStyle: false, dataRoot: root)
        }
        #expect(try Data(contentsOf: path) == old)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(ResolvedProductionStyleV1.relativePath).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(PipelineLayout.lineageFile).path))
    }
}
