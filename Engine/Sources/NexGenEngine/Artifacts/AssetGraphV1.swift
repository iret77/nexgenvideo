import Foundation

public let assetGraphV1Schema = "asset-graph/v1"
public let referenceDemandSetV1Schema = "reference-demand-set/v1"

public enum CoreReferenceSemanticJobIDV1 {
    public static let firstFrame = "core.first-frame"
    public static let lastFrame = "core.last-frame"
    public static let predecessorLastFrame = "core.predecessor-last-frame"
    public static let sourceVideo = "core.source-video"
    public static let audioTiming = "core.audio-timing"
}

public enum CoreReferenceInputSlotIDV1 {
    public static let referenceImage = "core.input.reference-image"
    public static let referenceVideo = "core.input.reference-video"
    public static let referenceAudio = "core.input.reference-audio"
    public static let referenceGeometry = "core.input.reference-geometry"
    public static let firstFrame = "core.input.first-frame"
    public static let lastFrame = "core.input.last-frame"
    public static let sourceVideo = "core.input.source-video"
    public static let audioTiming = "core.input.audio-timing"
}

public enum CoreAssetProvenanceKindIDV1 {
    public static let approvedFrame = "core.approved-frame"
    public static let renderFrame = "core.render-frame"
}

public enum AssetPhysicalModalityV1: String, Codable, CaseIterable, Sendable, Equatable {
    case image
    case video
    case audio
    case geometry
}

public enum AssetApprovalStateV1: String, Codable, Sendable, Equatable {
    case pending
    case approved
    case rejected
}

public struct AssetProvenanceV1: Codable, Sendable, Equatable {
    public let kindID: String
    public let sourceAssetID: String?
    public let modelID: String?
    public let promptSHA256: String?
    public let sourceShotID: String?
    public let sourceRoleID: String?
    public let sourceProofPath: String?
    public let sourceProofSHA256: String?
    public let recordedAt: String

    private enum CodingKeys: String, CodingKey {
        case kindID = "kind_id"
        case sourceAssetID = "source_asset_id"
        case modelID = "model_id"
        case promptSHA256 = "prompt_sha256"
        case sourceShotID = "source_shot_id"
        case sourceRoleID = "source_role_id"
        case sourceProofPath = "source_proof_path"
        case sourceProofSHA256 = "source_proof_sha256"
        case recordedAt = "recorded_at"
    }

    public init(
        kindID: String,
        sourceAssetID: String? = nil,
        modelID: String? = nil,
        promptSHA256: String? = nil,
        sourceShotID: String? = nil,
        sourceRoleID: String? = nil,
        sourceProofPath: String? = nil,
        sourceProofSHA256: String? = nil,
        recordedAt: String
    ) {
        self.kindID = kindID
        self.sourceAssetID = sourceAssetID
        self.modelID = modelID
        self.promptSHA256 = promptSHA256
        self.sourceShotID = sourceShotID
        self.sourceRoleID = sourceRoleID
        self.sourceProofPath = sourceProofPath
        self.sourceProofSHA256 = sourceProofSHA256
        self.recordedAt = recordedAt
    }
}

public struct AssetGraphNodeV1: Codable, Sendable, Equatable {
    public let id: String
    public let version: Int
    public let path: String
    public let sha256: String
    public let modality: AssetPhysicalModalityV1
    public let entityID: String?
    public let canonIDs: [String]
    public let stateID: String?
    public let viewID: String?
    public let approval: AssetApprovalStateV1
    public let provenance: AssetProvenanceV1
    public let allowedUseIDs: [String]
    public let durationSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case path
        case sha256
        case modality
        case entityID = "entity_id"
        case canonIDs = "canon_ids"
        case stateID = "state_id"
        case viewID = "view_id"
        case approval
        case provenance
        case allowedUseIDs = "allowed_use_ids"
        case durationSeconds = "duration_seconds"
    }

    public init(
        id: String,
        version: Int,
        path: String,
        sha256: String,
        modality: AssetPhysicalModalityV1,
        entityID: String? = nil,
        canonIDs: [String] = [],
        stateID: String? = nil,
        viewID: String? = nil,
        approval: AssetApprovalStateV1,
        provenance: AssetProvenanceV1,
        allowedUseIDs: [String],
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.version = version
        self.path = path
        self.sha256 = sha256
        self.modality = modality
        self.entityID = entityID
        self.canonIDs = canonIDs
        self.stateID = stateID
        self.viewID = viewID
        self.approval = approval
        self.provenance = provenance
        self.allowedUseIDs = allowedUseIDs
        self.durationSeconds = durationSeconds
    }
}

public struct AssetGraphV1: Codable, Sendable, Equatable {
    public static let artifactRole = "core.asset-graph"
    public let schema: String
    public let id: String
    public let projectID: String
    public let assets: [AssetGraphNodeV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case id
        case projectID = "project_id"
        case assets
    }

    public init(
        schema: String = assetGraphV1Schema,
        id: String,
        projectID: String,
        assets: [AssetGraphNodeV1]
    ) {
        self.schema = schema
        self.id = id
        self.projectID = projectID
        self.assets = assets
    }
}

public enum AssetGraphContentAddressV1 {
    private struct AssetIdentity: Encodable {
        let version: Int
        let path: String
        let sha256: String
        let modality: AssetPhysicalModalityV1
        let entityID: String?
        let canonIDs: [String]
        let stateID: String?
        let viewID: String?
        let approval: AssetApprovalStateV1
        let provenance: AssetProvenanceV1
        let allowedUseIDs: [String]
        let durationSeconds: Double?
    }

    private struct GraphIdentity: Encodable {
        let schema: String
        let projectID: String
        let assets: [AssetGraphNodeV1]
    }

    public static func assetID(for asset: AssetGraphNodeV1) throws -> String {
        let identity = AssetIdentity(
            version: asset.version,
            path: asset.path,
            sha256: asset.sha256,
            modality: asset.modality,
            entityID: asset.entityID,
            canonIDs: asset.canonIDs.sorted(),
            stateID: asset.stateID,
            viewID: asset.viewID,
            approval: asset.approval,
            provenance: asset.provenance,
            allowedUseIDs: asset.allowedUseIDs.sorted(),
            durationSeconds: asset.durationSeconds
        )
        return "asset-\(FileDigest.sha256(of: try encode(identity)))"
    }

    public static func reidentified(_ asset: AssetGraphNodeV1) throws -> AssetGraphNodeV1 {
        let id = try assetID(for: asset)
        return AssetGraphNodeV1(
            id: id,
            version: asset.version,
            path: asset.path,
            sha256: asset.sha256,
            modality: asset.modality,
            entityID: asset.entityID,
            canonIDs: asset.canonIDs.sorted(),
            stateID: asset.stateID,
            viewID: asset.viewID,
            approval: asset.approval,
            provenance: asset.provenance,
            allowedUseIDs: asset.allowedUseIDs.sorted(),
            durationSeconds: asset.durationSeconds
        )
    }

    public static func graphID(projectID: String, assets: [AssetGraphNodeV1]) throws -> String {
        let identity = GraphIdentity(
            schema: assetGraphV1Schema,
            projectID: projectID,
            assets: assets.sorted { $0.id < $1.id }
        )
        return "asset-graph-\(FileDigest.sha256(of: try encode(identity)))"
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public struct ReferenceDemandV1: Codable, Sendable, Equatable {
    public let id: String
    public let assetID: String
    public let modality: AssetPhysicalModalityV1
    public let semanticJobID: String
    public let isRequired: Bool
    public let priority: Int
    public let preservationScopeIDs: [String]
    public let exclusionDemandIDs: [String]
    public let inputSlotID: String
    public let modeID: String
    public let durationSeconds: Double?
    public let expectedSourceShotID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case assetID = "asset_id"
        case modality
        case semanticJobID = "semantic_job_id"
        case isRequired = "is_required"
        case priority
        case preservationScopeIDs = "preservation_scope_ids"
        case exclusionDemandIDs = "exclusion_demand_ids"
        case inputSlotID = "input_slot_id"
        case modeID = "mode_id"
        case durationSeconds = "duration_seconds"
        case expectedSourceShotID = "expected_source_shot_id"
    }

    public init(
        id: String,
        assetID: String,
        modality: AssetPhysicalModalityV1,
        semanticJobID: String,
        isRequired: Bool,
        priority: Int,
        preservationScopeIDs: [String] = [],
        exclusionDemandIDs: [String] = [],
        inputSlotID: String,
        modeID: String,
        durationSeconds: Double? = nil,
        expectedSourceShotID: String? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.modality = modality
        self.semanticJobID = semanticJobID
        self.isRequired = isRequired
        self.priority = priority
        self.preservationScopeIDs = preservationScopeIDs
        self.exclusionDemandIDs = exclusionDemandIDs
        self.inputSlotID = inputSlotID
        self.modeID = modeID
        self.durationSeconds = durationSeconds
        self.expectedSourceShotID = expectedSourceShotID
    }
}

public struct ReferenceDemandSetV1: Codable, Sendable, Equatable {
    public static let artifactRole = "core.reference-demand-set"
    public let schema: String
    public let id: String
    public let projectID: String
    public let shotID: String
    public let assetGraph: CanonicalArtifactReferenceV1
    public let demands: [ReferenceDemandV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case id
        case projectID = "project_id"
        case shotID = "shot_id"
        case assetGraph = "asset_graph"
        case demands
    }

    public init(
        schema: String = referenceDemandSetV1Schema,
        id: String,
        projectID: String,
        shotID: String,
        assetGraph: CanonicalArtifactReferenceV1,
        demands: [ReferenceDemandV1]
    ) {
        self.schema = schema
        self.id = id
        self.projectID = projectID
        self.shotID = shotID
        self.assetGraph = assetGraph
        self.demands = demands
    }
}

public enum AssetGraphValidationError: Error, Sendable, Equatable {
    case unsupportedSchema(String)
    case emptyField(String)
    case duplicateID(String)
    case invalidPath(String)
    case invalidHash(String)
    case invalidVersion(String)
    case invalidDuration(String)
    case invalidNamespacedID(String)
    case projectMismatch
    case assetGraphMismatch
    case unknownAsset(String)
    case modalityMismatch(String)
    case useNotAllowed(demandID: String, jobID: String)
    case invalidExclusion(String)
    case unapprovedAsset(String)
    case invalidCoreReference(String)
    case invalidProvenance(String)
    case invalidChainedReferencePlan
}

public enum AssetGraphValidatorV1 {
    public static func validate(_ graph: AssetGraphV1) throws {
        guard graph.schema == assetGraphV1Schema else {
            throw AssetGraphValidationError.unsupportedSchema(graph.schema)
        }
        try require(graph.id, field: "asset_graph.id")
        try require(graph.projectID, field: "asset_graph.project_id")
        try unique(graph.assets.map(\.id))
        try unique(graph.assets.map(\.path))
        for asset in graph.assets {
            try require(asset.id, field: "asset.id")
            guard asset.version > 0 else {
                throw AssetGraphValidationError.invalidVersion(asset.id)
            }
            try validatePath(asset.path)
            try validateHash(asset.sha256)
            try requireOptional(asset.entityID, field: "asset.entity_id")
            try requireOptional(asset.stateID, field: "asset.state_id")
            try requireOptional(asset.viewID, field: "asset.view_id")
            try uniqueNonEmpty(asset.canonIDs)
            try uniqueNonEmpty(asset.allowedUseIDs)
            guard Set(asset.allowedUseIDs.map(
                ProductionIdentifierNormalizerV1.canonical
            )).count == asset.allowedUseIDs.count else {
                throw AssetGraphValidationError.duplicateID(asset.id)
            }
            for useID in asset.allowedUseIDs {
                try validateNamespaced(useID)
            }
            if let duration = asset.durationSeconds,
               !duration.isFinite || duration <= 0
                    || (asset.modality != .video && asset.modality != .audio) {
                throw AssetGraphValidationError.invalidDuration(asset.id)
            }
            try require(asset.provenance.kindID, field: "asset.provenance.kind_id")
            try require(asset.provenance.recordedAt, field: "asset.provenance.recorded_at")
            try requireOptional(
                asset.provenance.sourceAssetID,
                field: "asset.provenance.source_asset_id"
            )
            try requireOptional(asset.provenance.modelID, field: "asset.provenance.model_id")
            if let promptSHA256 = asset.provenance.promptSHA256 {
                try validateHash(promptSHA256)
            }
            let renderProofFields = [
                asset.provenance.sourceShotID,
                asset.provenance.sourceRoleID,
                asset.provenance.sourceProofPath,
                asset.provenance.sourceProofSHA256,
            ]
            if asset.provenance.kindID == CoreAssetProvenanceKindIDV1.approvedFrame
                || asset.provenance.kindID == CoreAssetProvenanceKindIDV1.renderFrame
                || renderProofFields.contains(where: { $0 != nil }) {
                guard renderProofFields.allSatisfy({ $0 != nil }) else {
                    throw AssetGraphValidationError.invalidProvenance(asset.id)
                }
                try requirePathSegment(
                    asset.provenance.sourceShotID!,
                    field: "asset.provenance.source_shot_id"
                )
                try validateNamespaced(asset.provenance.sourceRoleID!)
                try validatePath(asset.provenance.sourceProofPath!)
                try validateHash(asset.provenance.sourceProofSHA256!)
            }
            guard asset.id == (try AssetGraphContentAddressV1.assetID(for: asset)) else {
                throw AssetGraphValidationError.invalidHash(asset.id)
            }
        }
        guard graph.id == (try AssetGraphContentAddressV1.graphID(
            projectID: graph.projectID,
            assets: graph.assets
        )) else {
            throw AssetGraphValidationError.invalidHash(graph.id)
        }
    }

    public static func validate(
        _ demandSet: ReferenceDemandSetV1,
        against graph: AssetGraphV1
    ) throws {
        guard demandSet.schema == referenceDemandSetV1Schema else {
            throw AssetGraphValidationError.unsupportedSchema(demandSet.schema)
        }
        try validate(graph)
        try require(demandSet.id, field: "reference_demand_set.id")
        try require(demandSet.projectID, field: "reference_demand_set.project_id")
        try requirePathSegment(demandSet.shotID, field: "reference_demand_set.shot_id")
        guard demandSet.projectID == graph.projectID else {
            throw AssetGraphValidationError.projectMismatch
        }
        let graphData = try AssetGraphCanonicalCodecV1.encode(graph)
        guard demandSet.assetGraph.id == graph.id,
              demandSet.assetGraph.role == AssetGraphV1.artifactRole,
              demandSet.assetGraph.path == PipelineLayout.assetGraphFile,
              demandSet.assetGraph.sha256 == FileDigest.sha256(of: graphData) else {
            throw AssetGraphValidationError.assetGraphMismatch
        }
        try unique(demandSet.demands.map(\.id))
        let demandIDs = Set(demandSet.demands.map(\.id))
        let assetsByID = Dictionary(uniqueKeysWithValues: graph.assets.map { ($0.id, $0) })
        for demand in demandSet.demands {
            try require(demand.id, field: "reference_demand.id")
            try require(demand.assetID, field: "reference_demand.asset_id")
            try validateNamespaced(demand.semanticJobID)
            try validateNamespaced(demand.inputSlotID)
            try require(demand.modeID, field: "reference_demand.mode_id")
            if let expectedSourceShotID = demand.expectedSourceShotID {
                try requirePathSegment(
                    expectedSourceShotID,
                    field: "reference_demand.expected_source_shot_id"
                )
            }
            guard demand.priority >= 0 else {
                throw AssetGraphValidationError.invalidVersion(demand.id)
            }
            try uniqueNonEmpty(demand.preservationScopeIDs)
            try uniqueNonEmpty(demand.exclusionDemandIDs)
            if let duration = demand.durationSeconds,
               !duration.isFinite || duration <= 0
                    || (demand.modality != .video && demand.modality != .audio) {
                throw AssetGraphValidationError.invalidDuration(demand.id)
            }
            guard let asset = assetsByID[demand.assetID] else {
                throw AssetGraphValidationError.unknownAsset(demand.assetID)
            }
            guard asset.approval == .approved else {
                throw AssetGraphValidationError.unapprovedAsset(asset.id)
            }
            guard asset.modality == demand.modality else {
                throw AssetGraphValidationError.modalityMismatch(demand.id)
            }
            if let declaredDuration = demand.durationSeconds,
               asset.durationSeconds != declaredDuration {
                throw AssetGraphValidationError.invalidDuration(demand.id)
            }
            guard asset.allowedUseIDs.contains(where: {
                ProductionIdentifierNormalizerV1.matches($0, demand.semanticJobID)
            }) else {
                throw AssetGraphValidationError.useNotAllowed(
                    demandID: demand.id,
                    jobID: demand.semanticJobID
                )
            }
            for exclusion in demand.exclusionDemandIDs
            where exclusion == demand.id || !demandIDs.contains(exclusion) {
                throw AssetGraphValidationError.invalidExclusion(demand.id)
            }
        }
        try validateCoreReferences(demandSet.demands, assetsByID: assetsByID)
        let predecessor = demandSet.demands.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame
            )
        }
        if !predecessor.isEmpty {
            let competingDemands = demandSet.demands.filter {
                $0.id != predecessor[0].id
                    && !ProductionIdentifierNormalizerV1.matches(
                        $0.semanticJobID,
                        CoreReferenceSemanticJobIDV1.audioTiming
                    )
            }
            guard predecessor.count == 1,
                  competingDemands.isEmpty,
                  predecessor[0].isRequired,
                  predecessor[0].modality == .image,
                  let expectedSourceShotID = predecessor[0].expectedSourceShotID,
                  let asset = assetsByID[predecessor[0].assetID],
                  asset.provenance.kindID == CoreAssetProvenanceKindIDV1.renderFrame,
                  asset.provenance.sourceShotID == expectedSourceShotID,
                  asset.provenance.sourceRoleID.map({
                      ProductionIdentifierNormalizerV1.matches(
                          $0,
                          CoreReferenceSemanticJobIDV1.lastFrame
                      )
                  }) == true,
                  asset.provenance.sourceProofPath != nil,
                  asset.provenance.sourceProofSHA256 != nil else {
                throw AssetGraphValidationError.invalidChainedReferencePlan
            }
        }
    }

    public static func validate(
        _ demandSet: ReferenceDemandSetV1,
        against graph: AssetGraphV1,
        immediatePredecessorShotID: String?
    ) throws {
        try validate(demandSet, against: graph)
        guard let predecessor = demandSet.demands.first(where: {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame
            )
        }) else { return }
        guard predecessor.expectedSourceShotID == immediatePredecessorShotID else {
            throw AssetGraphValidationError.invalidChainedReferencePlan
        }
    }

    public static func validateProjectFiles(
        _ graph: AssetGraphV1,
        dataRoot: URL
    ) throws {
        try validate(graph)
        for asset in graph.assets {
            _ = try ProjectLocalFile.requireHash(
                asset.sha256,
                at: asset.path,
                dataRoot: dataRoot
            )
            if let proofPath = asset.provenance.sourceProofPath,
               let proofSHA256 = asset.provenance.sourceProofSHA256 {
                let proofURL = try ProjectLocalFile.requireHash(
                    proofSHA256,
                    at: proofPath,
                    dataRoot: dataRoot
                )
                switch asset.provenance.kindID {
                case CoreAssetProvenanceKindIDV1.approvedFrame:
                    try validateFramesPublicationProof(
                        for: asset,
                        projectID: graph.projectID,
                        proofURL: proofURL,
                        proofPath: proofPath
                    )
                case CoreAssetProvenanceKindIDV1.renderFrame:
                    try validateRenderProof(
                        for: asset,
                        projectID: graph.projectID,
                        proofURL: proofURL,
                        proofPath: proofPath,
                        dataRoot: dataRoot
                    )
                default:
                    throw AssetGraphValidationError.invalidProvenance(asset.id)
                }
            }
        }
    }

    private static func validateFramesPublicationProof(
        for asset: AssetGraphNodeV1,
        projectID: String,
        proofURL: URL,
        proofPath: String
    ) throws {
        guard asset.provenance.kindID == CoreAssetProvenanceKindIDV1.approvedFrame,
              let sourceShotID = asset.provenance.sourceShotID,
              let sourceRoleID = asset.provenance.sourceRoleID,
              let role = frameRole(for: sourceRoleID),
              let data = try? Data(contentsOf: proofURL),
              let proof = try? JSONDecoder().decode(
                  RenderShotProvenanceProofV1.self,
                  from: data
              ),
              (try? RenderShotProvenanceValidatorV1.validate(
                  proof,
                  artifactPath: proofPath,
                  artifactSHA256: FileDigest.sha256(of: data)
              )) != nil,
              proof.project == projectID,
              proof.phase == "frames",
              proof.shotID == sourceShotID,
              let frames = proof.frames,
              let frame = frames.frames.first(where: {
                  $0.role == role
              }),
              frame.approved,
              frame.path == asset.path,
              proof.outputs.contains(RenderPublishedArtifactV1(
                  path: asset.path,
                  sha256: asset.sha256
              )),
              frames.frames.contains(where: {
                  $0.path == proof.renderEntry.output
              }) == true else {
            throw AssetGraphValidationError.invalidProvenance(asset.id)
        }
    }

    private static func validateRenderProof(
        for asset: AssetGraphNodeV1,
        projectID: String,
        proofURL: URL,
        proofPath: String,
        dataRoot: URL
    ) throws {
        guard asset.provenance.kindID == CoreAssetProvenanceKindIDV1.renderFrame,
              let sourceShotID = asset.provenance.sourceShotID,
              let sourceRoleID = asset.provenance.sourceRoleID,
              let data = try? Data(contentsOf: proofURL),
              let proof = try? JSONDecoder().decode(
                  RenderShotProvenanceProofV1.self,
                  from: data
              ),
              (try? RenderShotProvenanceValidatorV1.validate(
                  proof,
                  artifactPath: proofPath,
                  artifactSHA256: FileDigest.sha256(of: data)
              )) != nil,
              proof.project == projectID,
              proof.shotID == sourceShotID,
              !proof.phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let proofEntry = proof.renderProofEntry,
              proofEntry.shotId == sourceShotID,
              !proofEntry.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !proofEntry.providerPrompt.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              !proofEntry.generationModel.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              proof.outputs.contains(RenderPublishedArtifactV1(
                  path: asset.path,
                  sha256: asset.sha256
              )),
              let outputURL = try? ProjectLocalFile.requireHash(
                  proofEntry.outputSha256,
                  at: proofEntry.output,
                  dataRoot: dataRoot
              ) else {
            throw AssetGraphValidationError.invalidProvenance(asset.id)
        }
        for dependency in proof.dependencies {
            _ = try ProjectLocalFile.requireHash(
                dependency.sha256,
                at: dependency.path,
                dataRoot: dataRoot
            )
        }
        guard ProductionIdentifierNormalizerV1.matches(
            sourceRoleID,
            CoreReferenceSemanticJobIDV1.lastFrame
        ) else {
            return
        }
        guard asset.modality == .image,
              ProjectMediaExtensions.videos.contains(
                  outputURL.pathExtension.lowercased()
              ),
              proof.renderEntry.shotId == sourceShotID,
              proof.renderEntry.phase == proof.phase,
              proof.renderEntry.status == .rendered,
              proof.renderEntry.output == proofEntry.output,
              proof.renderEntry.lastFramePath == asset.path,
              let frameProof = proof.lastFrame,
              frameProof.shotID == sourceShotID,
              frameProof.phase == proof.phase,
              frameProof.path == asset.path,
              frameProof.sha256 == asset.sha256,
              frameProof.sourceOutput == proofEntry.output,
              frameProof.sourceOutputSHA256 == proofEntry.outputSha256,
              frameProof.extractor == RenderLastFrameProofV1.extractorID else {
            throw AssetGraphValidationError.invalidProvenance(asset.id)
        }
    }

    private static func frameRole(for semanticJobID: String) -> String? {
        if ProductionIdentifierNormalizerV1.matches(
            semanticJobID,
            CoreReferenceSemanticJobIDV1.firstFrame
        ) {
            return "start"
        }
        if ProductionIdentifierNormalizerV1.matches(
            semanticJobID,
            CoreReferenceSemanticJobIDV1.lastFrame
        ) {
            return "end"
        }
        return nil
    }

    private static func validateCoreReferences(
        _ demands: [ReferenceDemandV1],
        assetsByID: [String: AssetGraphNodeV1]
    ) throws {
        let definitions: [(jobID: String, modality: AssetPhysicalModalityV1, slotID: String)] = [
            (
                CoreReferenceSemanticJobIDV1.firstFrame,
                .image,
                CoreReferenceInputSlotIDV1.firstFrame
            ),
            (
                CoreReferenceSemanticJobIDV1.lastFrame,
                .image,
                CoreReferenceInputSlotIDV1.lastFrame
            ),
            (
                CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                .image,
                CoreReferenceInputSlotIDV1.firstFrame
            ),
            (
                CoreReferenceSemanticJobIDV1.sourceVideo,
                .video,
                CoreReferenceInputSlotIDV1.sourceVideo
            ),
            (
                CoreReferenceSemanticJobIDV1.audioTiming,
                .audio,
                CoreReferenceInputSlotIDV1.audioTiming
            ),
        ]
        let jobsByDedicatedSlot = Dictionary(
            grouping: definitions,
            by: { ProductionIdentifierNormalizerV1.canonical($0.slotID) }
        ).mapValues {
            Set($0.map { ProductionIdentifierNormalizerV1.canonical($0.jobID) })
        }
        for demand in demands {
            let slotID = ProductionIdentifierNormalizerV1.canonical(demand.inputSlotID)
            guard let allowedJobs = jobsByDedicatedSlot[slotID] else { continue }
            guard allowedJobs.contains(
                ProductionIdentifierNormalizerV1.canonical(demand.semanticJobID)
            ) else {
                throw AssetGraphValidationError.invalidCoreReference(demand.id)
            }
        }
        for definition in definitions {
            let matches = demands.filter {
                ProductionIdentifierNormalizerV1.matches(
                    $0.semanticJobID,
                    definition.jobID
                )
            }
            guard matches.count <= 1 else {
                throw AssetGraphValidationError.invalidCoreReference(definition.jobID)
            }
            guard let demand = matches.first else { continue }
            guard demand.modality == definition.modality,
                  ProductionIdentifierNormalizerV1.matches(
                      demand.inputSlotID,
                      definition.slotID
                  ),
                  assetsByID[demand.assetID]?.modality == definition.modality else {
                throw AssetGraphValidationError.invalidCoreReference(demand.id)
            }
            if definition.jobID != CoreReferenceSemanticJobIDV1.predecessorLastFrame,
               demand.expectedSourceShotID != nil {
                throw AssetGraphValidationError.invalidCoreReference(demand.id)
            }
        }
        let firstFrameJobs = demands.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.firstFrame
            ) || ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame
            )
        }
        guard firstFrameJobs.count <= 1 else {
            throw AssetGraphValidationError.invalidCoreReference(
                CoreReferenceInputSlotIDV1.firstFrame
            )
        }
    }

    private static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              !NSString(string: path).isAbsolutePath,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AssetGraphValidationError.invalidPath(path)
        }
    }

    private static func validateHash(_ value: String) throws {
        guard value.count == 64,
              value.allSatisfy({ $0.isHexDigit }),
              value == value.lowercased() else {
            throw AssetGraphValidationError.invalidHash(value)
        }
    }

    private static func validateNamespaced(_ value: String) throws {
        let pattern = #"^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)+$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw AssetGraphValidationError.invalidNamespacedID(value)
        }
    }

    private static func unique(_ values: [String]) throws {
        var seen = Set<String>()
        for value in values {
            try require(value, field: "id")
            guard seen.insert(value).inserted else {
                throw AssetGraphValidationError.duplicateID(value)
            }
        }
    }

    private static func uniqueNonEmpty(_ values: [String]) throws {
        try unique(values)
    }

    private static func require(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssetGraphValidationError.emptyField(field)
        }
    }

    private static func requireOptional(_ value: String?, field: String) throws {
        if let value { try require(value, field: field) }
    }

    private static func requirePathSegment(_ value: String, field: String) throws {
        try require(value, field: field)
        guard !value.contains("/"), value != ".", value != ".." else {
            throw AssetGraphValidationError.invalidPath(value)
        }
    }
}

public enum AssetGraphCanonicalCodecV1 {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decodeGraph(_ data: Data) throws -> AssetGraphV1 {
        let graph = try JSONDecoder().decode(AssetGraphV1.self, from: data)
        try AssetGraphValidatorV1.validate(graph)
        return graph
    }

    public static func decodeDemandSet(
        _ data: Data,
        graph: AssetGraphV1
    ) throws -> ReferenceDemandSetV1 {
        let demandSet = try JSONDecoder().decode(ReferenceDemandSetV1.self, from: data)
        try AssetGraphValidatorV1.validate(demandSet, against: graph)
        return demandSet
    }
}
