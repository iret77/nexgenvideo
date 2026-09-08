import Foundation
import Testing
@testable import NexGenEngine
@testable import NexGenVideo

@Suite("Actual repair-request changes")
struct TakeRepairPlanTests {
    private func input() -> GenerationInput {
        var input = GenerationInput(prompt: "Wide view.\nThe mouse turns left.", model: "first-model", duration: 4, aspectRatio: "16:9")
        input.promptShotId = "s001"; input.promptShotFingerprint = "plan"
        input.referenceImageAssetIds = ["reference-one"]
        input.compileRecipe = .init(intent: "Turn left.", setting: "", lighting: "", style: "", preserveComposition: false, styleFingerprint: "style")
        return input
    }

    @Test func aModelDialectChangeIsNotASecondCreativeChangeOrACleanRewrite() throws {
        let parent = input()
        var changed = parent
        changed.model = "second-model"
        changed.prompt = "Camera: wide. Action: mouse turning left."
        try TakeRepairPlan.validateChange(from: parent, to: changed, operation: .changeModel)
        #expect(throws: (any Error).self) { try TakeRepairPlan.validateChange(from: parent, to: changed, operation: .cleanRewriteWithModel) }
        changed.compileRecipe = .init(intent: "One clear left turn, body fully visible.", setting: "", lighting: "", style: "", preserveComposition: false, styleFingerprint: "style")
        try TakeRepairPlan.validateChange(from: parent, to: changed, operation: .cleanRewriteWithModel)
    }

    @Test func aSurgicalChangeCannotHideAnotherVariableOrBypassStop() throws {
        let parent = input()
        var changed = parent
        changed.referenceImageAssetIds = ["reference-two"]
        try TakeRepairPlan.validateChange(from: parent, to: changed, operation: .changeReference)
        changed.duration = 8
        #expect(throws: (any Error).self) { try TakeRepairPlan.validateChange(from: parent, to: changed, operation: .changeReference) }
        try TakeRepairPlan.validateChange(from: parent, to: parent, operation: .reroll)
        for operation in [TakeRepairPlan.Operation.stop, .simplifyShot, .rescueRange] {
            #expect(throws: (any Error).self) { try TakeRepairPlan.validateChange(from: parent, to: parent, operation: operation) }
        }
    }

    @Test func decisionAndCompilerMetadataCannotResetTheRollCounter() throws {
        let parent = input()
        var annotated = parent
        annotated.takeRepairPlanID = String(repeating: "a", count: 64)
        annotated.spendTransactionId = "another-transaction"
        annotated.createdAt = Date()
        annotated.intent = "An explanatory note."
        annotated.compileRecipe = nil
        #expect(try PipelineRenderTakeStore.promptRevision(parent) == PipelineRenderTakeStore.promptRevision(annotated))
        annotated.prompt += " The camera holds."
        #expect(try PipelineRenderTakeStore.promptRevision(parent) != PipelineRenderTakeStore.promptRevision(annotated))
    }

    @Test func aStoppedShotCannotLoseItsDecisionByDeletingThePointer() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let take = try fixture.take(input())
        let decision = try fixture.decision(take: take, operation: .stop)
        #expect(try TakeRepairPlan.current(shotID: "s001", dataRoot: fixture.root)?.id == decision)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(TakeRepairPlan.currentPath(shotID: "s001")))
        #expect(throws: (any Error).self) { try TakeRepairPlan.current(shotID: "s001", dataRoot: fixture.root) }
        #expect(try TakeRepairPlan.current(shotID: "s002", dataRoot: fixture.root) == nil)
    }

    @Test func rerollsKeepCleanRewriteEvidenceButAnUnrelatedPlanCannotClaimIt() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let parent = try fixture.take(input())
        var rewritten = input()
        rewritten.prompt = "A stable wide camera. The mouse makes one visible left turn."
        rewritten.model = "second-model"
        rewritten.compileRecipe = .init(intent: "One visible left turn.", setting: "", lighting: "", style: "", preserveComposition: false, styleFingerprint: "style")
        rewritten.takeRepairPlanID = try fixture.decision(take: parent, operation: .cleanRewriteWithModel)
        let clean = try fixture.take(rewritten)
        var repeated = rewritten
        repeated.takeRepairPlanID = try fixture.decision(take: clean, operation: .reroll)
        let reroll = try fixture.take(repeated)
        let evidence = try TakeRepairPlan.iterationEvidence(take: reroll, dataRoot: fixture.root)
        #expect(evidence.cleanRewrite)
        #expect(evidence.channel == "model")
        repeated.duration = 8
        let mismatched = try fixture.take(repeated)
        #expect(throws: (any Error).self) { try TakeRepairPlan.iterationEvidence(take: mismatched, dataRoot: fixture.root) }
    }

    private struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func write(_ data: Data, at path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        func take(_ input: GenerationInput) throws -> PipelineRenderTakeV1 {
            let event = UUID().uuidString
            var manifest = RenderManifest(project: "demo", phase: "final")
            record(&manifest, shotId: "s001", output: "media/\(event).mp4", costEur: 1, phase: "final")
            let entry = try #require(manifest.entries["s001"])
            let output = RenderPublishedArtifactV1(path: "media/\(event).mp4", sha256: String(repeating: "b", count: 64))
            let proof = RenderShotProvenanceProofV1(project: "demo", phase: "final", shotID: "s001", renderEntry: entry,
                renderProofEntry: .init(shotId: "s001", output: output.path, outputSha256: output.sha256,
                    providerPrompt: input.prompt, generationModel: input.model), routingProofEntry: nil,
                frames: nil, lastFrame: nil, outputs: [output])
            let bytes = try JSONEncoder().encode(proof)
            let artifact = RenderPublishedArtifactV1(path: "proofs/\(event).json", sha256: FileDigest.sha256(of: bytes))
            try write(bytes, at: artifact.path)
            let prepared = try PipelineRenderTakeStore.prepare(completed: .init(eventID: event, generationInput: input),
                provenance: artifact, shotProof: proof, manifest: manifest, shotID: "s001", dataRoot: root)
            for file in prepared.files { try write(file.data, at: file.path) }
            return try PipelineRenderTakeStore.take(id: #require(prepared.takeID), dataRoot: root)
        }
        func decision(take: PipelineRenderTakeV1, operation: TakeRepairPlan.Operation) throws -> String {
            let review = TakeReview(schema: "take-review/v1", takeID: take.id, outputSHA256: take.output.sha256,
                durationValue: 4, durationTimescale: 1, reviewer: "native-user", findings: [
                    .init(pass: .identity, verdict: .rejected, observation: "The face changes.", startSeconds: 0, endSeconds: 4)
                ], reviewedAt: "fixture")
            let reviewBytes = try JSONEncoder().encode(review)
            let reviewHash = FileDigest.sha256(of: reviewBytes)
            try write(reviewBytes, at: "renders/takes/reviews/\(take.id)/\(reviewHash).v1.json")
            let plan = TakeRepairPlan(schema: "take-repair-plan/v1", takeID: take.id, reviewSHA256: reviewHash,
                operation: operation, reason: "Observed identity drift.", policy: .init(), decidedBy: "native-user", decidedAt: "fixture")
            let bytes = try JSONEncoder().encode(plan)
            let id = FileDigest.sha256(of: bytes)
            try write(bytes, at: TakeRepairPlan.archivePath(id: id))
            try write(bytes, at: TakeRepairPlan.currentPath(shotID: "s001"))
            return id
        }
    }
}
