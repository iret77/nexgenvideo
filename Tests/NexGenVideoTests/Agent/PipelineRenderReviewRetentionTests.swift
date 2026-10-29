import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Native review decisions survive unchanged inputs")
struct PipelineRenderReviewRetentionTests {
    @Test func repeatedCaptureAndReviewPreserveAnAcceptedConcern() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly { context in
            let snapshot = try await PipelineRenderReviewWriter.capture(editor: context.editor)
            let shot = try #require(snapshot.shots.first)
            let finding = RenderReviewV1.Finding(id: "camera-choice", kind: .semanticConcern, category: .camera,
                shotIDs: [shot.shotID], message: "The deliberately static camera needs an editorial decision.",
                evidence: [try #require(shot.review.evidence.first)])
            let first = try await PipelineRenderReviewWriter.recordNativeReview(snapshot: snapshot, findings: [finding], editor: context.editor)
            let accepted = try await PipelineRenderReviewWriter.acceptFinding(id: finding.id,
                reason: "Keep the fixed camera to preserve the abstract composition.",
                expectedFingerprint: PipelineRenderReviewWriter.fingerprint(first), editor: context.editor)
            let receipt = try #require(accepted.findings.first?.acceptance)
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(receipt.path, dataRoot: context.dataRoot))
            let repeated = try await PipelineRenderReviewWriter.capture(editor: context.editor)
            #expect(repeated.fingerprint == snapshot.fingerprint)
            let rereview = try await PipelineRenderReviewWriter.recordNativeReview(snapshot: repeated, findings: [], editor: context.editor)
            #expect(rereview.findings == accepted.findings)
            #expect(rereview.header.revision > accepted.header.revision)
            #expect(try Data(contentsOf: ProjectLocalFile.resolve(receipt.path, dataRoot: context.dataRoot)) == bytes)
            try PipelineRenderReviewWriter.requireCurrent(rereview, context.dataRoot)
        }
        defer { context.document.close() }
        let final = try #require(try PipelineRenderReviewWriter.loadIfPresent(dataRoot: context.dataRoot))
        #expect(final.findings.count == 1)
        #expect(final.findings.first?.acceptance != nil)
        try PipelineRenderReviewWriter.requireCurrent(final, context.dataRoot)
    }

    @Test func agentCopyCannotAliasNativeBibleAssetsByChangingCase() throws {
        for path in ["bible/location/Native-Panorama-view.png", "bible/location/SPATIAL-view.png",
                     "bible/Native-Panorama-Selections/receipt.png", "Render-Review/current.v1.json"] {
            #expect(throws: ToolError.self) { try ToolExecutor.requirePipelineAssetCopyPath(path, source: false) }
        }
        try ToolExecutor.requirePipelineAssetCopyPath("bible/location/model-sheet.png", source: false)
        try ToolExecutor.requirePipelineAssetCopyPath("production_design/refs/Style.png", source: false)
    }
}
