import Foundation

public let pipelineAssetProofSchemaVersion = "pipeline_asset_proof/v1"

public struct PipelineAssetProofEntry: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let providerPrompt: String
    public let generationModel: String
    public let sourceMediaId: String
    public let recordedAt: String

    private enum CodingKeys: String, CodingKey {
        case path
        case sha256
        case providerPrompt = "provider_prompt"
        case generationModel = "generation_model"
        case sourceMediaId = "source_media_id"
        case recordedAt = "recorded_at"
    }

    public init(
        path: String,
        sha256: String,
        providerPrompt: String,
        generationModel: String,
        sourceMediaId: String,
        recordedAt: String = currentTimestamp()
    ) {
        self.path = path
        self.sha256 = sha256
        self.providerPrompt = providerPrompt
        self.generationModel = generationModel
        self.sourceMediaId = sourceMediaId
        self.recordedAt = recordedAt
    }
}

public struct PipelineAssetProof: Codable, Sendable, Equatable {
    public let schema: String
    public let project: String
    public let scope: String
    public var entries: [String: PipelineAssetProofEntry]

    public init(
        schema: String = pipelineAssetProofSchemaVersion,
        project: String,
        scope: String,
        entries: [String: PipelineAssetProofEntry] = [:]
    ) {
        self.schema = schema
        self.project = project
        self.scope = scope
        self.entries = entries
    }
}

public func loadPipelineAssetProof(
    dataRoot: URL,
    scope: String
) throws -> PipelineAssetProof {
    let relative = PipelineLayout.assetProofFile(scope: scope)
    let url = PipelineLayout.url(relative, in: dataRoot)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return PipelineAssetProof(
            project: FrameInventory.projectName(of: dataRoot)
                ?? dataRoot.lastPathComponent,
            scope: scope
        )
    }
    return try JSONArtifactStore(dataRoot: dataRoot).load(
        PipelineAssetProof.self,
        at: relative
    )
}

public func savePipelineAssetProof(
    _ proof: PipelineAssetProof,
    dataRoot: URL
) throws {
    try JSONArtifactStore(dataRoot: dataRoot).save(
        proof,
        to: PipelineLayout.assetProofFile(scope: proof.scope)
    )
}
