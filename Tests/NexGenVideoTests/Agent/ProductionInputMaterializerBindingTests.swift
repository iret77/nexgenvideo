import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Production materialized source and frame ownership")
struct ProductionInputMaterializerBindingTests {
    @Test("AI-enhanced uses exactly its verified prepared range, not another approved video")
    func preparedSourceMustMatchTheReferencedAsset() throws {
        let prepared = reference("prepared-range.mov", "a")
        let selected = video("selected", output: prepared)
        let other = video("other-approved", output: reference("other-approved.mov", "b"))
        try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: selected.id,
            assets: [selected, other], preparedOutputs: [prepared], predecessor: nil)
        for outputs in [[], [prepared, prepared]] {
            #expect(throws: (any Error).self) {
                try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: selected.id,
                    assets: [selected], preparedOutputs: outputs, predecessor: nil)
            }
        }
        #expect(throws: (any Error).self) {
            try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: other.id,
                assets: [selected, other], preparedOutputs: [prepared], predecessor: nil)
        }
        for changed in [reference(prepared.path, "b"), reference("copied-range.mov", "a")] {
            #expect(throws: (any Error).self) {
                try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: selected.id,
                    assets: [video(selected.id, output: changed)], preparedOutputs: [prepared], predecessor: nil)
            }
        }
        for invalid in [video(selected.id, output: prepared, approval: .rejected),
                        video(selected.id, output: prepared, modality: .image)] {
            #expect(throws: (any Error).self) {
                try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: selected.id,
                    assets: [invalid], preparedOutputs: [prepared], predecessor: nil)
            }
        }
        let missingIDs: [String?] = [nil, "missing"]
        for missingID in missingIDs {
            #expect(throws: (any Error).self) {
                try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: missingID,
                    assets: [selected], preparedOutputs: [prepared], predecessor: nil)
            }
        }
    }

    @Test("An alternate asset ID with the exact prepared path and bytes remains valid")
    func exactPreparedBytesPermitAReferencedAlias() throws {
        let prepared = reference("prepared-range.mov", "a")
        let alias = video("independently-approved-alias", output: prepared)
        try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: alias.id,
            assets: [alias], preparedOutputs: [prepared], predecessor: nil)
        let renamedReference = CanonicalArtifactReferenceV1(id: "other-reference-id", role: "verified-range",
            path: prepared.path, sha256: prepared.sha256)
        try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: alias.id,
            assets: [alias], preparedOutputs: [renamedReference], predecessor: nil)
    }

    @Test("Untrimmed native extension uses the actual selected predecessor without extra preparation")
    func untrimmedNativePredecessor() throws {
        let output = reference("selected-predecessor.mov", "a")
        let predecessor = makePredecessor(output: output, start: 0)
        let asset = video("native-source", output: output)
        try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: asset.id,
            assets: [asset], preparedOutputs: [], predecessor: predecessor)
        #expect(throws: (any Error).self) {
            try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: asset.id,
                assets: [asset], preparedOutputs: [output], predecessor: predecessor)
        }
        #expect(throws: (any Error).self) {
            try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: asset.id,
                assets: [video(asset.id, output: reference("another-selected.mov", "a"))], preparedOutputs: [], predecessor: predecessor)
        }
    }

    @Test("Trimmed native extension requires its single exact prepared predecessor output")
    func trimmedNativePredecessor() throws {
        let output = reference("trimmed-predecessor.mov", "a")
        let predecessor = makePredecessor(output: output, start: 600)
        let asset = video("native-source", output: output)
        try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: asset.id,
            assets: [asset], preparedOutputs: [output], predecessor: predecessor)
        for outputs in [[], [output, output], [reference("untrimmed-predecessor.mov", "a")], [reference(output.path, "b")]] {
            #expect(throws: (any Error).self) {
                try PipelineProductionInputMaterializer.requireSourceVideoBinding(assetID: asset.id,
                    assets: [asset], preparedOutputs: outputs, predecessor: predecessor)
            }
        }
    }

    @Test("Two cross-shot Frames bind their own published proofs, not the target shot's proof")
    func crossShotFramesUseSourceShotPublication() throws {
        let firstProof = reference("proofs/first.json", "a")
        let secondProof = reference("proofs/second.json", "b")
        let first = frame("first-frame", sourceShotID: "first-shot", proof: firstProof)
        let second = frame("second-frame", sourceShotID: "second-shot", proof: secondProof)
        let publication = RenderShotProvenancePublicationV1(transactionID: "publication", project: "project", phase: "frames",
            proofs: ["first-shot": .init(path: firstProof.path, sha256: firstProof.sha256),
                     "second-shot": .init(path: secondProof.path, sha256: secondProof.sha256)])
        try PipelineProductionInputMaterializer.requireFrameBindings(assets: [first, second], publication: publication)
        let withoutSecond = RenderShotProvenancePublicationV1(transactionID: "publication", project: "project", phase: "frames",
            proofs: ["first-shot": .init(path: firstProof.path, sha256: firstProof.sha256)])
        #expect(throws: (any Error).self) {
            try PipelineProductionInputMaterializer.requireFrameBindings(assets: [first, second], publication: withoutSecond)
        }
        for invalid in [frame(second.id, sourceShotID: "second-shot", proof: firstProof),
                        frame(second.id, sourceShotID: "second-shot", proof: reference(secondProof.path, "a")),
                        frame(second.id, sourceShotID: "unpublished-shot", proof: secondProof),
                        frame(second.id, sourceShotID: nil, proof: secondProof),
                        frame(second.id, sourceShotID: "second-shot", proof: nil)] {
            #expect(throws: (any Error).self) {
                try PipelineProductionInputMaterializer.requireFrameBindings(assets: [first, invalid], publication: publication)
            }
        }
    }

    private func reference(_ path: String, _ character: Swift.Character) -> CanonicalArtifactReferenceV1 {
        .init(id: "fixture-reference", role: "verified-output", path: path, sha256: String(repeating: String(character), count: 64))
    }

    private func video(_ id: String, output: CanonicalArtifactReferenceV1,
                       approval: AssetApprovalStateV1 = .approved, modality: AssetPhysicalModalityV1 = .video) -> AssetGraphNodeV1 {
        .init(id: id, version: 1, path: output.path, sha256: output.sha256, modality: modality, approval: approval,
            provenance: .init(kindID: "core.selected-source-range", recordedAt: "2026-10-19T10:00:00Z"), allowedUseIDs: [])
    }

    private func makePredecessor(output: CanonicalArtifactReferenceV1, start: Int64) -> RenderSubmissionBindingV1.SelectedPredecessor {
        .init(shotID: "predecessor-shot", takeID: "selected-take", selectionReceipt: reference("selection.json", "c"),
            outputVideo: output, fullDurationTicks: 2400, selectedStartTicks: start, selectedEndTicks: 2400,
            sourceTimebase: .init(ticksPerSecond: 600))
    }

    private func frame(_ id: String, sourceShotID: String?, proof: CanonicalArtifactReferenceV1?) -> AssetGraphNodeV1 {
        .init(id: id, version: 1, path: id + ".png", sha256: String(repeating: "d", count: 64), modality: .image, approval: .approved,
            provenance: .init(kindID: CoreAssetProvenanceKindIDV1.approvedFrame, sourceShotID: sourceShotID, sourceRoleID: CoreReferenceSemanticJobIDV1.firstFrame,
                sourceProofPath: proof?.path, sourceProofSHA256: proof?.sha256, recordedAt: "2026-10-19T10:00:00Z"), allowedUseIDs: [])
    }
}
