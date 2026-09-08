import Foundation
import Testing
@testable import NexGenEngine
@testable import NexGenVideo

@Suite("Immutable render takes and attributed review")
struct PipelineRenderTakeTests {
    private func input(date: Date, transaction: String) -> GenerationInput {
        var value = GenerationInput(prompt: "A fixed wide view of the empty courtyard.", model: "fixture-model", duration: 4, aspectRatio: "16:9")
        value.promptShotId = "s001"
        value.promptShotFingerprint = String(repeating: "a", count: 64)
        value.createdAt = date
        value.spendTransactionId = transaction
        return value
    }

    @Test("equal output bytes from different generation events remain separate takes of one prompt revision")
    func distinctEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(&manifest, shotId: "s001", output: "media/result.mp4", costEur: 1, phase: "final")
        let entry = try #require(manifest.entries["s001"])
        let output = RenderPublishedArtifactV1(path: "media/result.mp4", sha256: String(repeating: "b", count: 64))
        let proof = RenderShotProvenanceProofV1(project: "demo", phase: "final", shotID: "s001", renderEntry: entry,
            renderProofEntry: .init(shotId: "s001", output: output.path, outputSha256: output.sha256,
                providerPrompt: "A fixed wide view of the empty courtyard.", generationModel: "fixture-model"),
            routingProofEntry: nil, frames: nil, lastFrame: nil, outputs: [output])
        let bytes = try JSONEncoder().encode(proof)
        let artifact = RenderPublishedArtifactV1(path: "proof.json", sha256: FileDigest.sha256(of: bytes))
        try bytes.write(to: root.appendingPathComponent(artifact.path))
        func prepare(_ event: String, _ value: GenerationInput) throws -> PipelineRenderTakeStore.Prepared {
            try PipelineRenderTakeStore.prepare(completed: .init(eventID: event, generationInput: value), provenance: artifact,
                shotProof: proof, manifest: manifest, shotID: "s001", dataRoot: root)
        }
        func persist(_ value: PipelineRenderTakeStore.Prepared) throws {
            for file in value.files {
                let url = root.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: url)
            }
        }
        let firstInput = input(date: Date(timeIntervalSince1970: 100), transaction: "spend-1")
        let first = try prepare("event-1", firstInput)
        try persist(first)
        let repeated = try prepare("event-1", firstInput)
        #expect(repeated.takeID == first.takeID)
        #expect(repeated.files.count == 1)
        let second = try prepare("event-2", input(date: Date(timeIntervalSince1970: 200), transaction: "spend-2"))
        try persist(second)
        let firstRecord = try PipelineRenderTakeStore.take(id: #require(first.takeID), dataRoot: root)
        let secondRecord = try PipelineRenderTakeStore.take(id: #require(second.takeID), dataRoot: root)
        #expect(firstRecord.id != secondRecord.id)
        #expect(firstRecord.promptRevisionID == secondRecord.promptRevisionID)
        #expect(firstRecord.plannedGenerationID == secondRecord.plannedGenerationID)
        #expect(try PipelineRenderTakeStore.load(dataRoot: root, project: "demo", phase: "final").takeIDs.count == 2)
        #expect(throws: (any Error).self) { try prepare("event-1", input(date: Date(timeIntervalSince1970: 300), transaction: "different")) }
        var preview = RenderManifest(project: "demo", phase: "preview")
        record(&preview, shotId: "s001", output: output.path, costEur: 1, phase: "preview")
        let previewProof = RenderShotProvenanceProofV1(project: "demo", phase: "preview", shotID: "s001",
            renderEntry: try #require(preview.entries["s001"]), renderProofEntry: proof.renderProofEntry,
            routingProofEntry: nil, frames: nil, lastFrame: nil, outputs: [output])
        do {
            _ = try PipelineRenderTakeStore.prepare(completed: .init(eventID: "event-1", generationInput: firstInput),
                provenance: artifact, shotProof: previewProof, manifest: preview, shotID: "s001", dataRoot: root)
            Issue.record("One paid generation must not become a new take by changing phase.")
        } catch let error as ToolError {
            #expect(error.message.contains("already recorded in final"))
        }
        let corruptPreview = root.appendingPathComponent(PipelineRenderTakeStore.takePath(id: String(repeating: "c", count: 64), phase: "preview"))
        try FileManager.default.createDirectory(at: corruptPreview.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: corruptPreview)
        #expect(try PipelineRenderTakeStore.load(dataRoot: root, project: "demo", phase: "final").takeIDs.count == 2)
        #expect(try PipelineRenderTakeStore.load(dataRoot: root, project: "demo", phase: "frames").takeIDs.isEmpty)
        #expect(throws: (any Error).self) { try PipelineRenderTakeStore.load(dataRoot: root, project: "demo", phase: "preview") }
        try FileManager.default.removeItem(at: root.appendingPathComponent(PipelineRenderTakeStore.indexPath(phase: "final")))
        #expect(throws: (any Error).self) { try PipelineRenderTakeStore.load(dataRoot: root, project: "demo", phase: "final") }
    }

    @Test("identity rejection stops review while an incomplete positive review cannot pass")
    func orderedReview() throws {
        let rejected = TakeReview.Finding(pass: .identity, verdict: .rejected, observation: "The face changes at the cut.", startSeconds: 1, endSeconds: 2)
        try TakeReview.validate([rejected], duration: 4)
        let premature = TakeReview.Finding(pass: .identity, verdict: .conforms, observation: "Same face throughout.", startSeconds: 0, endSeconds: 4)
        #expect(throws: (any Error).self) { try TakeReview.validate([premature], duration: 4) }
        let findings = TakeReview.Pass.allCases.map {
            TakeReview.Finding(pass: $0, verdict: .conforms, observation: "Observed the approved \($0.rawValue) over the complete take.", startSeconds: 0, endSeconds: 4)
        }
        try TakeReview.validate(findings, duration: 4)
        var bypass = findings
        bypass[0] = .init(pass: .identity, verdict: .notApplicable, observation: "Identity drift is not relevant.", startSeconds: 0, endSeconds: 4)
        #expect(throws: (any Error).self) { try TakeReview.validate(bypass, duration: 4) }
        #expect(throws: (any Error).self) { try TakeReview.validate(Array(findings.reversed()), duration: 4) }
        #expect(throws: (any Error).self) { try TakeReview.validate(findings, duration: 3) }
    }

    @Test("recovery accepts only the take index and immutable take records")
    func recoveryPaths() {
        #expect(PipelineRenderTakeStore.isRecoveryPath("renders/takes/index-final.v1.json", phase: "final"))
        #expect(PipelineRenderTakeStore.isRecoveryPath("renders/takes/final/" + String(repeating: "a", count: 64) + ".v1.json", phase: "final"))
        #expect(!PipelineRenderTakeStore.isRecoveryPath("renders/takes/index-preview.v1.json", phase: "final"))
        #expect(!PipelineRenderTakeStore.isRecoveryPath("renders/takes/../../brief.yaml", phase: "final"))
        #expect(!PipelineRenderTakeStore.isRecoveryPath("renders/takes/index-frames.v1.json", phase: "frames"))
        #expect(!PipelineRenderTakeStore.isRecoveryPath("renders/takes/preview/" + String(repeating: "a", count: 64) + ".v1.json", phase: "final"))
    }
}
