import Foundation
import NexGenEngine

@MainActor
enum PipelineStoryboardUploadedImageWriter {
    static func assign(from url: URL, shotID: String, momentID: String, expectedFingerprint: String,
                       editor: EditorViewModel, filmFlow: FilmFlowAdoption? = nil,
                       validatePublication: (@MainActor () throws -> Void)? = nil,
                       didCommit: @escaping @MainActor (StoryboardBundleSnapshot) -> Void = { _ in }) async throws -> StoryboardBundleSnapshot {
        if let validatePublication { try validatePublication() }
        else { try PipelineStoryboardEditor.requireAvailable(editor: editor) }
        let access = try PipelineNativeEditAccess(editor: editor, label: "Assign Storyboard sketch")
        defer { access.end(editor: editor) }
        let task = Task.detached(priority: .userInitiated) {
            _ = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "storyboard")
            let before = try PlanningWriterIO.storyboard(dataRoot: access.root, requireVisuals: false)
            guard before.fingerprint == expectedFingerprint,
                  let shot = before.timing.shots.first(where: { $0.id == shotID }),
                  let moment = shot.moments.first(where: { $0.id == momentID }) else { throw changed() }
            let file = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard file.isRegularFile == true, file.isSymbolicLink != true,
                  ProjectMediaExtensions.images.contains(url.pathExtension.lowercased()) else {
                throw GateBlocked("Choose a regular image file for this sketch.")
            }
            let bytes = try Data(contentsOf: url)
            let sha = FileDigest.sha256(of: bytes)
            guard try FileDigest.sha256(of: url) == sha else { throw changed() }
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                additionalCanonicalPaths: before.references.map(\.path))
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "storyboard")
                guard try PlanningWriterIO.storyboard(dataRoot: staging, requireVisuals: false).fingerprint == expectedFingerprint else { throw changed() }
                let id = UUID().uuidString.lowercased()
                let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "storyboard/sketches",
                    leaf: id + "." + url.pathExtension.lowercased(), dataRoot: staging)
                try ProductionWorkflowRecoveryMigration.requireNewOutput(path, dataRoot: staging)
                _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: staging)
                try bytes.write(to: staging.appendingPathComponent(path), options: .atomic)
                _ = try FrameRasterizer.loadImage(at: ProjectLocalFile.requireHash(sha, at: path, dataRoot: staging))
                let image = CanonicalArtifactReferenceV1(id: "sketch." + sha, role: "core.storyboard-sketch", path: path, sha256: sha)
                let proof = StoryboardSketchProofV1(projectID: before.storyboard.header.projectID, shotID: shotID,
                    momentID: momentID, intentSHA256: FileDigest.sha256(of: Data(moment.intent.utf8)),
                    framingSHA256: try shot.framing.fingerprint(), image: image, source: .uploaded(original: image, selectionReceiptID: id))
                try PipelineStoryboardSketchEvidence.recordSelection(proof: proof, receiptID: id, originalName: url.lastPathComponent,
                    expectedFingerprint: expectedFingerprint, dataRoot: staging)
                let proofPath = "storyboard/sketch-proofs/" + id + ".v1.json"
                let proofBytes = try PlanningWriterIO.json(proof)
                _ = try ProjectLocalFile.ensureDirectory("storyboard/sketch-proofs", dataRoot: staging)
                try proofBytes.write(to: staging.appendingPathComponent(proofPath), options: .atomic)
                let asset = StoryboardTimingV1.SketchAsset(image: image,
                    proof: PlanningWriterIO.reference(proofPath, id: "sketch-proof." + id, role: "core.storyboard-sketch-proof", bytes: proofBytes))
                let after = try PipelineStoryboardBundleWriter.write(PipelineStoryboardBundleWriter.proposal(from: before,
                    replacing: momentID, in: shotID, with: asset), origin: .userRevision, access: writer)
                guard after.sketchProofs[proofPath] == proof, after.sketchProblems[momentID] == nil else { throw changed() }
                if let filmFlow { try filmFlow.record(phase: "storyboard", outputs: FilmFlowAdoption.storyboardOutputs(after), dataRoot: staging) }
                return after
            }
            do { try fence.requireUnchanged(); return (transaction, fence) }
            catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        let after = try result.0.commit { _ in
            try validatePublication?()
            try access.requireCurrent(editor: editor)
            try result.1.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        didCommit(after)
        return after
    }

    nonisolated private static func changed() -> GateBlocked { GateBlocked("The Storyboard or selected image changed. Choose the current sketch again.") }
}
