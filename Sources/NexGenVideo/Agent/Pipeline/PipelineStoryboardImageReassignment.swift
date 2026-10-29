import Foundation
import NexGenEngine

enum PipelineStoryboardImageReassignment {
    struct Prepared: Sendable {
        let targetShotID: String
        let targetMomentID: String
        let asset: StoryboardTimingV1.SketchAsset
        let files: [(path: String, bytes: Data)]

        fileprivate init(targetShotID: String, targetMomentID: String, asset: StoryboardTimingV1.SketchAsset,
                         files: [(path: String, bytes: Data)]) {
            self.targetShotID = targetShotID
            self.targetMomentID = targetMomentID
            self.asset = asset
            self.files = files
        }
    }

    static func prepare(originalAsset: StoryboardTimingV1.SketchAsset, targetShotID: String,
                        targetMoment: StoryboardTimingV1.Moment, framing: StoryboardTimingV1.FramingIntent,
                        projectID: String, expectedFingerprint: String, dataRoot: URL) throws -> Prepared {
        guard expectedFingerprint.count == 64 else { throw GateBlocked("The current Storyboard snapshot is missing.") }
        var originalReference = originalAsset.proof
        var original = try readOriginal(originalReference, dataRoot: dataRoot)
        guard original.image == originalAsset.image, original.projectID == projectID else {
            throw GateBlocked("The selected sketch does not match its original image proof.")
        }
        try PipelineStoryboardSketchEvidence.requireCurrent(original, dataRoot)
        var visited = Set<String>()
        while case .reassigned(_, let reference, _) = original.source {
            guard visited.insert(reference.path).inserted, visited.count < 64 else {
                throw GateBlocked("The sketch reassignment history is invalid.")
            }
            originalReference = reference
            original = try readOriginal(reference, dataRoot: dataRoot)
            guard original.image == originalAsset.image, original.projectID == projectID else {
                throw GateBlocked("The sketch reassignment no longer preserves its original image.")
            }
        }
        let receiptID = UUID().uuidString.lowercased()
        let proof = StoryboardSketchProofV1(projectID: projectID, shotID: targetShotID, momentID: targetMoment.id,
            intentSHA256: FileDigest.sha256(of: Data(targetMoment.intent.utf8)), framingSHA256: try framing.fingerprint(),
            image: originalAsset.image, source: .reassigned(originalImage: original.image,
                originalProof: originalReference, selectionReceiptID: receiptID))
        try proof.validate()
        let selection = try PipelineStoryboardSketchEvidence.selectionFile(proof: proof, receiptID: receiptID,
            originalName: "Reassigned sketch",
            expectedFingerprint: expectedFingerprint)
        let proofPath = "storyboard/sketch-proofs/\(receiptID).v1.json"
        let bytes = try PlanningWriterIO.json(proof)
        let asset = StoryboardTimingV1.SketchAsset(image: originalAsset.image,
            proof: PlanningWriterIO.reference(proofPath, id: "sketch-proof.\(receiptID)", role: "core.storyboard-sketch-proof", bytes: bytes))
        let files = [selection, (path: proofPath, bytes: bytes)]
        for file in files {
            let target = dataRoot.appendingPathComponent(file.path).standardizedFileURL
            guard target.resolvingSymlinksInPath() == target, !FileManager.default.fileExists(atPath: target.path),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil else {
                throw GateBlocked("Sketch reassignment proof paths must be new immutable project files.")
            }
        }
        return Prepared(targetShotID: targetShotID, targetMomentID: targetMoment.id, asset: asset, files: files)
    }

    private static func readOriginal(_ reference: CanonicalArtifactReferenceV1, dataRoot: URL) throws -> StoryboardSketchProofV1 {
        try JSONDecoder().decode(StoryboardSketchProofV1.self,
            from: Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)))
    }
}
