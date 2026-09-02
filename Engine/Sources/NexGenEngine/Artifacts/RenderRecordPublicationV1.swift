import Foundation

public struct RenderPublishedArtifactV1: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

public struct RenderLastFrameProofV1: Codable, Sendable, Equatable {
    public static let extractorID = "nexgenvideo.avfoundation.last-frame/v1"

    public let shotID: String
    public let phase: String
    public let path: String
    public let sha256: String
    public let sourceOutput: String
    public let sourceOutputSHA256: String
    public let extractor: String
    public let extractedAt: String

    private enum CodingKeys: String, CodingKey {
        case shotID = "shot_id"
        case phase
        case path
        case sha256
        case sourceOutput = "source_output"
        case sourceOutputSHA256 = "source_output_sha256"
        case extractor
        case extractedAt = "extracted_at"
    }

    public init(
        shotID: String,
        phase: String,
        path: String,
        sha256: String,
        sourceOutput: String,
        sourceOutputSHA256: String,
        extractor: String = Self.extractorID,
        extractedAt: String
    ) {
        self.shotID = shotID
        self.phase = phase
        self.path = path
        self.sha256 = sha256
        self.sourceOutput = sourceOutput
        self.sourceOutputSHA256 = sourceOutputSHA256
        self.extractor = extractor
        self.extractedAt = extractedAt
    }
}

public struct RenderRecordPublicationV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "render-record-publication/v1"

    public let schema: String
    public let transactionID: String
    public let project: String
    public let phase: String
    public let renderManifest: RenderPublishedArtifactV1
    public let renderProof: RenderPublishedArtifactV1?
    public let renderRoutingProof: RenderPublishedArtifactV1?
    public let framesManifest: RenderPublishedArtifactV1?
    public let lastFrames: [String: RenderLastFrameProofV1]
    public let committedAt: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case transactionID = "transaction_id"
        case project
        case phase
        case renderManifest = "render_manifest"
        case renderProof = "render_proof"
        case renderRoutingProof = "render_routing_proof"
        case framesManifest = "frames_manifest"
        case lastFrames = "last_frames"
        case committedAt = "committed_at"
    }

    public init(
        transactionID: String,
        project: String,
        phase: String,
        renderManifest: RenderPublishedArtifactV1,
        renderProof: RenderPublishedArtifactV1?,
        renderRoutingProof: RenderPublishedArtifactV1?,
        framesManifest: RenderPublishedArtifactV1?,
        lastFrames: [String: RenderLastFrameProofV1],
        committedAt: String
    ) {
        schema = Self.schemaVersion
        self.transactionID = transactionID
        self.project = project
        self.phase = phase
        self.renderManifest = renderManifest
        self.renderProof = renderProof
        self.renderRoutingProof = renderRoutingProof
        self.framesManifest = framesManifest
        self.lastFrames = lastFrames
        self.committedAt = committedAt
    }

    public static func artifactPath(phase: String) -> String {
        "renders/record-publication-\(phase).v1.json"
    }
}
