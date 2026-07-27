import Foundation

public let renderProofSchemaVersion = "render_proof/v1"

public struct RenderInputProof: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

public struct RenderProofEntry: Codable, Sendable, Equatable {
    public let shotId: String
    public let output: String
    public let outputSha256: String
    public let providerPrompt: String
    public let generationModel: String
    public let sourceVideo: RenderInputProof?
    public let startFrame: RenderInputProof?
    public let endFrame: RenderInputProof?
    public let referenceImages: [RenderInputProof]
    public let referenceVideos: [RenderInputProof]
    public let referenceAudio: [RenderInputProof]

    private enum CodingKeys: String, CodingKey {
        case shotId = "shot_id"
        case output
        case outputSha256 = "output_sha256"
        case providerPrompt = "provider_prompt"
        case generationModel = "generation_model"
        case sourceVideo = "source_video"
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case referenceImages = "reference_images"
        case referenceVideos = "reference_videos"
        case referenceAudio = "reference_audio"
    }

    public init(
        shotId: String,
        output: String,
        outputSha256: String,
        providerPrompt: String,
        generationModel: String,
        sourceVideo: RenderInputProof? = nil,
        startFrame: RenderInputProof? = nil,
        endFrame: RenderInputProof? = nil,
        referenceImages: [RenderInputProof] = [],
        referenceVideos: [RenderInputProof] = [],
        referenceAudio: [RenderInputProof] = []
    ) {
        self.shotId = shotId
        self.output = output
        self.outputSha256 = outputSha256
        self.providerPrompt = providerPrompt
        self.generationModel = generationModel
        self.sourceVideo = sourceVideo
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.referenceImages = referenceImages
        self.referenceVideos = referenceVideos
        self.referenceAudio = referenceAudio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shotId = try container.decode(String.self, forKey: .shotId)
        output = try container.decode(String.self, forKey: .output)
        outputSha256 = try container.decode(String.self, forKey: .outputSha256)
        providerPrompt = try container.decode(String.self, forKey: .providerPrompt)
        generationModel = try container.decode(String.self, forKey: .generationModel)
        sourceVideo = try container.decodeIfPresent(
            RenderInputProof.self,
            forKey: .sourceVideo
        )
        startFrame = try container.decodeIfPresent(
            RenderInputProof.self,
            forKey: .startFrame
        )
        endFrame = try container.decodeIfPresent(
            RenderInputProof.self,
            forKey: .endFrame
        )
        referenceImages = try container.decodeIfPresent(
            [RenderInputProof].self,
            forKey: .referenceImages
        ) ?? []
        referenceVideos = try container.decodeIfPresent(
            [RenderInputProof].self,
            forKey: .referenceVideos
        ) ?? []
        referenceAudio = try container.decodeIfPresent(
            [RenderInputProof].self,
            forKey: .referenceAudio
        ) ?? []
    }
}

public struct RenderProofManifest: Codable, Sendable, Equatable {
    public let schema: String
    public let project: String
    public let phase: String
    public var entries: [String: RenderProofEntry]

    public init(
        schema: String = renderProofSchemaVersion,
        project: String,
        phase: String,
        entries: [String: RenderProofEntry] = [:]
    ) {
        self.schema = schema
        self.project = project
        self.phase = phase
        self.entries = entries
    }
}

public func loadRenderProofManifest(
    dataRoot: URL,
    phase: String
) throws -> RenderProofManifest {
    let relative = PipelineLayout.renderProofFile(phase: phase)
    let url = PipelineLayout.url(relative, in: dataRoot)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return RenderProofManifest(
            project: FrameInventory.projectName(of: dataRoot)
                ?? dataRoot.lastPathComponent,
            phase: phase
        )
    }
    return try JSONArtifactStore(dataRoot: dataRoot).load(
        RenderProofManifest.self,
        at: relative
    )
}

public func saveRenderProofManifest(
    _ manifest: RenderProofManifest,
    dataRoot: URL
) throws {
    try JSONArtifactStore(dataRoot: dataRoot).save(
        manifest,
        to: PipelineLayout.renderProofFile(phase: manifest.phase)
    )
}
