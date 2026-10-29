import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
struct ExportDataRootTests {
    @Test func plainExportResolutionDoesNotEnrollAProductionWorkflow() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let before = try Data(contentsOf: home.appendingPathComponent(ProjectPluginSettings.filename))
        let root = try ExportDataRoot.resolve(in: home)
        let metadata = try ExportDataRoot.metadata(in: root)
        #expect(metadata.project == ProjectIdentity.existingUUID(for: home))
        #expect(metadata.mode == .generic)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try Data(contentsOf: home.appendingPathComponent(ProjectPluginSettings.filename)) == before)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("delivery"), withIntermediateDirectories: true)
        #expect(try ExportDataRoot.resolve(in: home) == root)
        #expect(try ExportDataRoot.metadata(in: root) == metadata)
    }

    @Test(arguments: ["project.yaml", "gates.yaml", "brief.yaml", "script/current.v1.json"])
    func incompleteProductionCannotBecomePlainEditing(_ path: String) throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("pipeline").appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("incomplete".utf8).write(to: file)
        #expect(throws: (any Error).self) { try ExportDataRoot.resolve(in: home) }
    }

    @Test func missingBoundProductionAndSymlinkedDeliveryRootAreRejected() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        #expect(throws: (any Error).self) { try ExportDataRoot.resolve(in: home) }
        try ProjectPluginSettings.setProductionContract(nil, projectURL: home)
        let external = home.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("pipeline"), withDestinationURL: external)
        #expect(throws: (any Error).self) { try ExportDataRoot.resolve(in: home) }
    }

    @Test func packageSnapshotKeepsPlainDeliveryAsItsOwnConsistentSnapshot() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let delivery = home.appendingPathComponent("pipeline/delivery")
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let record = delivery.appendingPathComponent("job.json")
        try Data("queued".utf8).write(to: record)
        let source = try ExportQueue.SourceBinding.projectPackage(timeline: .init(), manifest: .init(), sourceRoot: home)
        try Data("completed".utf8).write(to: record)
        let frozen = try source.freeze(jobID: UUID().uuidString, isCancelled: { false })
        defer { frozen.remove() }
        let snapshot = try #require(frozen.projectRoot)
        #expect(try Data(contentsOf: snapshot.appendingPathComponent("pipeline/delivery/job.json")) == Data("completed".utf8))
        #expect(!FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("pipeline/project.yaml").path))
    }

    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ngv")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try ProjectIdentity.uuid(for: home)
        return home
    }
}
