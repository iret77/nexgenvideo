import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Historical takes after production migration")
@MainActor
struct PipelineHistoricalTakeStoreTests {
    @Test func archivedTakesRemainInspectableWithoutRestoringTheirApproval() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let history = try migrate(fixture.home)
        let snapshot = try PipelineHistoricalTakeStore.load(home: fixture.home)
        let items = snapshot.items
        #expect(snapshot.unavailableCount == 0)
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.historyID == history.fingerprint)
        #expect(item.take.id == fixture.takeID)
        #expect(item.previouslySelected)
        #expect(item.media.path == "pipeline/renders/old-result.mp4")
        #expect(item.media.sha256 == FileDigest.sha256(of: fixture.output))
        let root = try #require(DataRootResolver.dataRoot(of: fixture.home))
        #expect(try PipelineRenderTakeStore.load(dataRoot: root, project: "Fixture", phase: "final").selected.isEmpty)
        let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
        #expect(gates.gates.values.allSatisfy { !$0.approved })
    }

    @Test func missingOrChangedHistoricalOutputCannotBePresentedAsTheOriginalTake() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        _ = try migrate(fixture.home)
        let url = fixture.home.appendingPathComponent("pipeline/renders/old-result.mp4")
        try Data("different result".utf8).write(to: url)
        #expect(try PipelineHistoricalTakeStore.load(home: fixture.home).items.isEmpty)
        #expect(try PipelineHistoricalTakeStore.load(home: fixture.home).unavailableCount == 1)
        try FileManager.default.removeItem(at: url)
        #expect(try PipelineHistoricalTakeStore.load(home: fixture.home).items.isEmpty)
        #expect(try PipelineHistoricalTakeStore.load(home: fixture.home).unavailableCount == 1)
        try fixture.output.write(to: url)
        #expect(try PipelineHistoricalTakeStore.load(home: fixture.home).items.count == 1)
    }

    @Test func unavailableVideoDoesNotHideOtherVerifiedHistoricalTakes() throws {
        let fixture = try makeFixture(includeSecondTake: true)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        _ = try migrate(fixture.home)
        #expect(try PipelineHistoricalTakeStore.load(home: fixture.home).items.count == 2)
        try Data("changed video".utf8).write(to: fixture.home.appendingPathComponent("pipeline/renders/old-result.mp4"))
        let snapshot = try PipelineHistoricalTakeStore.load(home: fixture.home)
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items.first?.take.shotID == "s002")
        #expect(snapshot.unavailableCount == 1)
    }

    @Test func changedArchivedTakeMetadataFailsBeforeItReachesTheWorkspace() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let history = try migrate(fixture.home)
        let relative = "pipeline/migration-history/" + history.fingerprint + "/pipeline/"
            + PipelineRenderTakeStore.takePath(id: fixture.takeID, phase: "final")
        let url = fixture.home.appendingPathComponent(relative)
        let bytes = try Data(contentsOf: url)
        var record = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        record["shotID"] = "a-different-shot"
        try JSONSerialization.data(withJSONObject: record).write(to: url)
        #expect(throws: (any Error).self) { try PipelineHistoricalTakeStore.load(home: fixture.home) }
    }

    private struct Fixture {
        let home: URL
        let takeID: String
        let output: Data
    }

    private func makeFixture(includeSecondTake: Bool = false) throws -> Fixture {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString + ".ngv")
        let root = try ProjectScaffold.initProject(home: home, name: "Fixture", mode: .generic)
        try JSONEncoder().encode(Timeline()).write(to: home.appendingPathComponent(Project.timelineFilename))
        _ = try ProjectIdentity.key(for: home)
        var firstID: String?
        var firstOutput = Data()
        for number in 1...(includeSecondTake ? 2 : 1) {
            let shotID = "s00\(number)"
            let outputBytes = Data("historical output bytes for metadata verification".utf8)
            let output = RenderPublishedArtifactV1(path: "renders/\(number == 1 ? "old-result" : "second-result").mp4", sha256: FileDigest.sha256(of: outputBytes))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("renders"), withIntermediateDirectories: true)
            try outputBytes.write(to: root.appendingPathComponent(output.path))
            var manifest = RenderManifest(project: "Fixture", phase: "final")
            record(&manifest, shotId: shotID, output: output.path, costEur: 1, phase: "final")
            let entry = try #require(manifest.entries[shotID])
            let proof = RenderShotProvenanceProofV1(project: "Fixture", phase: "final", shotID: shotID, renderEntry: entry,
                renderProofEntry: .init(shotId: shotID, output: output.path, outputSha256: output.sha256,
                    providerPrompt: "A fixed wide view of the empty courtyard.", generationModel: "fixture-model"),
                routingProofEntry: nil, frames: nil, lastFrame: nil, outputs: [output])
            let proofBytes = try JSONEncoder().encode(proof)
            let provenance = RenderPublishedArtifactV1(path: "renders/old-proof-\(number).json", sha256: FileDigest.sha256(of: proofBytes))
            try proofBytes.write(to: root.appendingPathComponent(provenance.path))
            var input = GenerationInput(prompt: "A fixed wide view of the empty courtyard.", model: "fixture-model", duration: 4, aspectRatio: "16:9")
            input.promptShotId = shotID
            input.promptShotFingerprint = String(repeating: "a", count: 64)
            input.createdAt = Date(timeIntervalSince1970: 100)
            input.spendTransactionId = "fixture-transaction-\(number)"
            let prepared = try PipelineRenderTakeStore.prepare(
                completed: .init(eventID: "fixture-event-\(number)", generationInput: input, reviewedSelection: true),
                provenance: provenance, shotProof: proof, manifest: manifest, shotID: shotID, dataRoot: root)
            for file in prepared.files {
                let url = root.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: url)
            }
            if number == 1 { firstID = prepared.takeID; firstOutput = outputBytes }
        }
        var gates = Gates(project: "Fixture")
        GatesOperations.approve(&gates, phase: "render")
        try YAMLArtifactStore(dataRoot: root).save(gates, to: PipelineLayout.gatesFile)
        return Fixture(home: home, takeID: try #require(firstID), output: firstOutput)
    }

    private func migrate(_ home: URL) throws -> ProductionWorkflowRecoveryMigration.Intent {
        let intent = try ProductionWorkflowRecoveryMigration.preview(projectURL: home, source: .core, target: .core)
        try ProductionWorkflowRecoveryMigration.archiveAndReset(intent, staging: home)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        try ProductionWorkflowRecoveryMigration.finish(intent, staging: home)
        return intent
    }
}
