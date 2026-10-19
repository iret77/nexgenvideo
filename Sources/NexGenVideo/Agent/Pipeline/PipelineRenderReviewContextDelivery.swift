import Foundation
import NexGenEngine

@MainActor
enum PipelineRenderReviewContextDelivery {
    struct ImageInput: Codable, Sendable, Equatable {
        let source: CanonicalArtifactReferenceV1
        let deliveredImage: CanonicalArtifactReferenceV1
        let mediaType: String
    }

    private struct Delivery: Codable, Sendable, Equatable {
        let schema: String
        let snapshot: PipelineRenderReviewWriter.Snapshot
        let readEvidence: HostAgentReviewEvidence
        let deliveredText: String
        let images: [ImageInput]
    }

    static func deliver(snapshot: PipelineRenderReviewWriter.Snapshot, evidence: HostAgentReviewEvidence,
                        editor: EditorViewModel) async throws -> ToolResult {
        try editor.agentService.requireCurrentReviewEvidence(evidence)
        guard evidence.response.matchesHostTool("get_render_review_inputs"),
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else {
            throw GateBlocked("Render input delivery requires its actual originating model tool call.")
        }
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: .init(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract), phase: "render_review")
        try PipelineRenderReviewWriter.requireSnapshot(snapshot, root: root)
        let text = String(decoding: try PlanningWriterIO.json(snapshot), as: UTF8.self)
        var images: [ImageInput] = []
        var files: [(path: String, bytes: Data)] = []
        var blocks: [ToolResult.Block] = [.text(text)]
        var seen = Set<String>()
        for source in snapshot.shots.flatMap({ $0.review.evidence }) {
            guard ProjectMediaExtensions.images.contains((source.path as NSString).pathExtension.lowercased()),
                  seen.insert(source.path).inserted else { continue }
            let url = try ProjectLocalFile.requireHash(source.sha256, at: source.path, dataRoot: root)
            let encoding = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let bytes = try Data(contentsOf: url)
                guard FileDigest.sha256(of: bytes) == source.sha256 else { throw GateBlocked("The exact review image changed before decoding.") }
                let encoded = ImageEncoder.encode(data: bytes)
                try Task.checkCancellation()
                return encoded
            }
            guard let image = try await withTaskCancellationHandler(operation: { try await encoding.value }, onCancel: { encoding.cancel() }) else {
                throw GateBlocked("A current review image could not be decoded for model inspection.")
            }
            try access.revalidate()
            try Task.checkCancellation()
            try editor.agentService.requireCurrentReviewEvidence(evidence)
            let hash = FileDigest.sha256(of: image.data)
            let fileExtension: String
            switch image.mime {
            case "image/png": fileExtension = "png"
            case "image/jpeg": fileExtension = "jpg"
            case "image/gif": fileExtension = "gif"
            case "image/webp": fileExtension = "webp"
            default: throw GateBlocked("The review image has an unsupported media type.")
            }
            let imagePath = "render-review/input-images/\(hash)." + fileExtension
            let reference = PlanningWriterIO.reference(imagePath, id: "model-image." + hash,
                role: "host.render-review-delivered-image", bytes: image.data)
            let candidate = root.appendingPathComponent(imagePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                _ = try ProjectLocalFile.requireHash(hash, at: imagePath, dataRoot: root)
            } else if !files.contains(where: { $0.path == imagePath }) { files.append((imagePath, image.data)) }
            images.append(.init(source: source, deliveredImage: reference, mediaType: image.mime))
            blocks.append(.text("Review image: \(source.path) · SHA256 \(source.sha256)"))
            blocks.append(.image(base64: image.data.base64EncodedString(), mediaType: image.mime))
        }
        let delivery = Delivery(schema: "render-review-context-delivery/v1", snapshot: snapshot,
            readEvidence: evidence, deliveredText: text, images: images)
        let path = deliveryPath(snapshot: snapshot, evidence: evidence)
        let bytes: Data
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let existingBytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root))
            let existing = try JSONDecoder().decode(Delivery.self, from: existingBytes)
            guard existing.snapshot == snapshot, existing.deliveredText == text, existing.images == images,
                  sameTurn(existing.readEvidence, evidence) else { throw GateBlocked("The review input delivery changed during this model turn.") }
            bytes = existingBytes
        } else {
            bytes = try PlanningWriterIO.json(delivery)
            files.append((path, bytes))
        }
        try access.publish(files, captureLineage: false) {
            try Task.checkCancellation()
            try editor.agentService.requireCurrentReviewEvidence(evidence)
            try PipelineRenderReviewWriter.requireSnapshot(snapshot, root: root)
        }
        let reference = PlanningWriterIO.reference(path, id: snapshot.fingerprint,
            role: "host.render-review-input-delivery", bytes: bytes)
        blocks.append(.text("Review input receipt: \(reference.path) · SHA256 \(reference.sha256). Evaluate the exact captured shots and inputs, then call write_render_review with expected_fingerprint=\(snapshot.fingerprint). A deferred predecessor recipe describes future materialization; no final predecessor video has been observed here. Still images cannot establish unobserved motion or sound."))
        return ToolResult(content: blocks, isError: false)
    }

    nonisolated static func reference(snapshot: PipelineRenderReviewWriter.Snapshot, evidence: HostAgentReviewEvidence,
                                      dataRoot: URL) throws -> CanonicalArtifactReferenceV1 {
        let path = deliveryPath(snapshot: snapshot, evidence: evidence)
        let reference = try PlanningWriterIO.reference(path, id: snapshot.fingerprint,
            role: "host.render-review-input-delivery", dataRoot: dataRoot)
        _ = try verify(reference, snapshot: snapshot, evidence: evidence, dataRoot: dataRoot)
        return reference
    }

    nonisolated static func verify(_ reference: CanonicalArtifactReferenceV1, snapshot: PipelineRenderReviewWriter.Snapshot,
                                   evidence: HostAgentReviewEvidence, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot))
        let value = try JSONDecoder().decode(Delivery.self, from: bytes)
        guard value.schema == "render-review-context-delivery/v1", value.snapshot == snapshot,
              value.readEvidence.response.matchesHostTool("get_render_review_inputs"),
              evidence.response.matchesHostTool("write_render_review"), sameTurn(value.readEvidence, evidence),
              reference.path == deliveryPath(snapshot: snapshot, evidence: evidence),
              value.deliveredText == String(decoding: try PlanningWriterIO.json(snapshot), as: UTF8.self) else {
            throw GateBlocked("The model review has no exact input delivery in its originating host turn.")
        }
        try PipelineRenderReviewWriter.requireSnapshot(snapshot, root: dataRoot)
        var expectedPaths = Set<String>()
        let expectedImages = snapshot.shots.flatMap { $0.review.evidence }.filter {
            ProjectMediaExtensions.images.contains(($0.path as NSString).pathExtension.lowercased()) && expectedPaths.insert($0.path).inserted
        }
        guard value.images.map(\.source) == expectedImages else {
            throw GateBlocked("The model review did not receive every captured review image.")
        }
        for image in value.images {
            guard snapshot.references.contains(where: { $0.path == image.source.path && $0.sha256 == image.source.sha256 }) else {
                throw GateBlocked("The delivered image was not captured in this review.")
            }
            for reference in [image.source, image.deliveredImage] {
                _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
            }
            _ = try FrameRasterizer.loadImage(at: ProjectLocalFile.resolve(image.deliveredImage.path, dataRoot: dataRoot))
        }
        return [reference] + value.images.flatMap { [$0.source, $0.deliveredImage] }
    }

    nonisolated private static func deliveryPath(snapshot: PipelineRenderReviewWriter.Snapshot,
                                                evidence: HostAgentReviewEvidence) -> String {
        "render-review/context-deliveries/\(evidence.runtimeGenerationID.uuidString)-\(evidence.logicalTurnID.uuidString)-\(snapshot.fingerprint).v1.json"
    }

    nonisolated private static func sameTurn(_ lhs: HostAgentReviewEvidence, _ rhs: HostAgentReviewEvidence) -> Bool {
        lhs.projectGenerationID == rhs.projectGenerationID && lhs.chatSessionID == rhs.chatSessionID
            && lhs.runtimeGenerationID == rhs.runtimeGenerationID && lhs.logicalTurnID == rhs.logicalTurnID
            && lhs.inputMessageID == rhs.inputMessageID
    }
}
