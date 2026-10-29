import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@MainActor
@Suite("Production render record authority")
struct ProductionRenderRecordAuthorityTests {
    @Test("Core render-record preparation requires the independently trusted production contract")
    func coreBindingCannotBeInferred() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "Authority", mode: .generic)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let manifest = RenderManifest(project: "Authority", phase: "frames")
        let frames = FramesManifest(project: "Authority", generated: "2026-10-18T00:00:00Z")
        #expect(throws: (any Error).self) {
            try PipelineRenderRecordWriter.publish(manifest: manifest, proof: nil, routingProof: nil,
                framesManifest: frames, replacingShotID: nil, preparedLastFrame: nil, reconciledLastFrames: [:],
                expectedPublicationTransactionID: nil, dataRoot: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(PipelineLayout.renderManifestFile(phase: "frames")).path))
        let publication = try PipelineRenderRecordWriter.publish(manifest: manifest, proof: nil, routingProof: nil,
            framesManifest: frames, replacingShotID: nil, preparedLastFrame: nil, reconciledLastFrames: [:],
            expectedPublicationTransactionID: nil, dataRoot: root, declaredProductionContract: .current)
        let snapshot = try PipelineRenderRecordWriter.loadMutationSnapshot(dataRoot: root, phase: "frames",
            declaredProductionContract: .current)
        #expect(snapshot.publication == publication)
        #expect(snapshot.framesManifest == frames)
    }
}
