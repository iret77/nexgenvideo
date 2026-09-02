import Foundation

public let executionPlanV1Schema = "execution-plan/v1"

public struct CanonicalArtifactReferenceV1: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let role: String
    public let path: String
    public let sha256: String

    public init(id: String, role: String, path: String, sha256: String) {
        self.id = id
        self.role = role
        self.path = path
        self.sha256 = sha256
    }
}

public struct PackArtifactExtensionReferenceV1: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let schema: String
    public let path: String
    public let sha256: String

    public init(id: String, schema: String, path: String, sha256: String) {
        self.id = id
        self.schema = schema
        self.path = path
        self.sha256 = sha256
    }
}

public struct ProjectMediaReferenceV1: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let role: String
    public let path: String
    public let sha256: String

    public init(id: String, role: String, path: String, sha256: String) {
        self.id = id
        self.role = role
        self.path = path
        self.sha256 = sha256
    }
}

public struct ProjectCreativeContextV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "project-creative-context/v1"

    public let schema: String
    public let projectID: String
    public let artifacts: [CanonicalArtifactReferenceV1]
    public let media: [ProjectMediaReferenceV1]
    public let extensions: [PackArtifactExtensionReferenceV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case artifacts
        case media
        case extensions
    }

    public init(
        schema: String = schemaVersion,
        projectID: String,
        artifacts: [CanonicalArtifactReferenceV1],
        media: [ProjectMediaReferenceV1] = [],
        extensions: [PackArtifactExtensionReferenceV1] = []
    ) {
        self.schema = schema
        self.projectID = projectID
        self.artifacts = artifacts
        self.media = media
        self.extensions = extensions
    }
}

public enum ExecutionPlanCompletenessV1: String, Codable, Sendable, Equatable {
    case complete
    case legacyIncomplete = "legacy_incomplete"
}

public enum ExecutionSourceModeV1: String, Codable, Sendable, Equatable, CaseIterable {
    case generated
    case imported
    case aiEnhanced = "ai_enhanced"
}

public struct ExecutionStateV1: Codable, Sendable, Equatable {
    public let summary: String
    public let entityStateIDs: [String]
    public let spatialState: String?

    private enum CodingKeys: String, CodingKey {
        case summary
        case entityStateIDs = "entity_state_ids"
        case spatialState = "spatial_state"
    }

    public init(summary: String, entityStateIDs: [String] = [], spatialState: String? = nil) {
        self.summary = summary
        self.entityStateIDs = entityStateIDs
        self.spatialState = spatialState
    }
}

public struct ExecutionCameraPlanV1: Codable, Sendable, Equatable {
    public let movementID: String
    public let movementDetail: String?
    public let framingID: String?
    public let placement: String?
    public let endpoint: String?

    private enum CodingKeys: String, CodingKey {
        case movementID = "movement_id"
        case movementDetail = "movement_detail"
        case framingID = "framing_id"
        case placement
        case endpoint
    }

    public init(
        movementID: String,
        movementDetail: String? = nil,
        framingID: String? = nil,
        placement: String? = nil,
        endpoint: String? = nil
    ) {
        self.movementID = movementID
        self.movementDetail = movementDetail
        self.framingID = framingID
        self.placement = placement
        self.endpoint = endpoint
    }
}

public struct ExecutionBlockingV1: Codable, Sendable, Equatable {
    public let entityID: String
    public let anchorAssetID: String?
    public let relation: String
    public let performance: String?

    private enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case anchorAssetID = "anchor_asset_id"
        case relation
        case performance
    }

    public init(
        entityID: String,
        anchorAssetID: String? = nil,
        relation: String,
        performance: String? = nil
    ) {
        self.entityID = entityID
        self.anchorAssetID = anchorAssetID
        self.relation = relation
        self.performance = performance
    }
}

public struct TimedActionBeatV1: Codable, Sendable, Equatable {
    public let timeSeconds: Double
    public let action: String

    private enum CodingKeys: String, CodingKey {
        case timeSeconds = "time_seconds"
        case action
    }

    public init(timeSeconds: Double, action: String) {
        self.timeSeconds = timeSeconds
        self.action = action
    }
}

public enum ExecutionRenderabilityV1: String, Codable, Sendable, Equatable {
    case green
    case yellow
    case red
}

public struct ExecutionAcceptanceCriterionV1: Codable, Sendable, Equatable {
    public let id: String
    public let requirement: String
    public let severity: String

    public init(id: String, requirement: String, severity: String) {
        self.id = id
        self.requirement = requirement
        self.severity = severity
    }
}

public struct RequestedDurationV1: Codable, Sendable, Equatable {
    public let preferredSeconds: Double?
    public let minimumSeconds: Double?
    public let maximumSeconds: Double?
    public let allowsAutomatic: Bool

    private enum CodingKeys: String, CodingKey {
        case preferredSeconds = "preferred_seconds"
        case minimumSeconds = "minimum_seconds"
        case maximumSeconds = "maximum_seconds"
        case allowsAutomatic = "allows_automatic"
    }

    public init(
        preferredSeconds: Double? = nil,
        minimumSeconds: Double? = nil,
        maximumSeconds: Double? = nil,
        allowsAutomatic: Bool = false
    ) {
        self.preferredSeconds = preferredSeconds
        self.minimumSeconds = minimumSeconds
        self.maximumSeconds = maximumSeconds
        self.allowsAutomatic = allowsAutomatic
    }
}

public struct GenerationRequirementV1: Codable, Sendable, Equatable {
    public let modalityID: String
    public let modeIDs: [String]
    public let visibleEntityCount: Int
    public let identityLockAssetIDs: [String]
    public let referenceDemandIDs: [String]
    public let requiresFirstFrame: Bool
    public let requiresLastFrame: Bool
    public let sourceVideoAssetID: String?
    public let duration: RequestedDurationV1?
    public let resolution: String?
    public let aspectRatio: String?
    public let requiresOutputAudio: Bool
    public let productionProfileRequirementIDs: [String]
    public let qualityTarget: String?
    public let maximumCost: Double?
    public let maximumLatencySeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case modalityID = "modality_id"
        case modeIDs = "mode_ids"
        case visibleEntityCount = "visible_entity_count"
        case identityLockAssetIDs = "identity_lock_asset_ids"
        case referenceDemandIDs = "reference_demand_ids"
        case requiresFirstFrame = "requires_first_frame"
        case requiresLastFrame = "requires_last_frame"
        case sourceVideoAssetID = "source_video_asset_id"
        case duration
        case resolution
        case aspectRatio = "aspect_ratio"
        case requiresOutputAudio = "requires_output_audio"
        case productionProfileRequirementIDs = "production_profile_requirement_ids"
        case qualityTarget = "quality_target"
        case maximumCost = "maximum_cost"
        case maximumLatencySeconds = "maximum_latency_seconds"
    }

    public init(
        modalityID: String,
        modeIDs: [String],
        visibleEntityCount: Int,
        identityLockAssetIDs: [String] = [],
        referenceDemandIDs: [String] = [],
        requiresFirstFrame: Bool = false,
        requiresLastFrame: Bool = false,
        sourceVideoAssetID: String? = nil,
        duration: RequestedDurationV1? = nil,
        resolution: String? = nil,
        aspectRatio: String? = nil,
        requiresOutputAudio: Bool = false,
        productionProfileRequirementIDs: [String] = [],
        qualityTarget: String? = nil,
        maximumCost: Double? = nil,
        maximumLatencySeconds: Double? = nil
    ) {
        self.modalityID = modalityID
        self.modeIDs = modeIDs
        self.visibleEntityCount = visibleEntityCount
        self.identityLockAssetIDs = identityLockAssetIDs
        self.referenceDemandIDs = referenceDemandIDs
        self.requiresFirstFrame = requiresFirstFrame
        self.requiresLastFrame = requiresLastFrame
        self.sourceVideoAssetID = sourceVideoAssetID
        self.duration = duration
        self.resolution = resolution
        self.aspectRatio = aspectRatio
        self.requiresOutputAudio = requiresOutputAudio
        self.productionProfileRequirementIDs = productionProfileRequirementIDs
        self.qualityTarget = qualityTarget
        self.maximumCost = maximumCost
        self.maximumLatencySeconds = maximumLatencySeconds
    }
}

public typealias ProductionRequirementV1 = GenerationRequirementV1

public struct ExecutionShotV1: Codable, Sendable, Equatable {
    public let id: String
    public let sourceMode: ExecutionSourceModeV1
    public let sourceAssetID: String?
    public let startState: ExecutionStateV1
    public let endState: ExecutionStateV1
    public let primaryAction: String
    public let camera: ExecutionCameraPlanV1
    public let blocking: [ExecutionBlockingV1]
    public let timedActionBeats: [TimedActionBeatV1]
    public let continuityLocks: [String]
    public let transitionIntent: String?
    public let renderability: ExecutionRenderabilityV1
    public let risks: [String]
    public let rescue: String?
    public let acceptance: [ExecutionAcceptanceCriterionV1]
    public let generationRequirement: GenerationRequirementV1?

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceMode = "source_mode"
        case sourceAssetID = "source_asset_id"
        case startState = "start_state"
        case endState = "end_state"
        case primaryAction = "primary_action"
        case camera
        case blocking
        case timedActionBeats = "timed_action_beats"
        case continuityLocks = "continuity_locks"
        case transitionIntent = "transition_intent"
        case renderability
        case risks
        case rescue
        case acceptance
        case generationRequirement = "generation_requirement"
    }

    public init(
        id: String,
        sourceMode: ExecutionSourceModeV1,
        sourceAssetID: String? = nil,
        startState: ExecutionStateV1,
        endState: ExecutionStateV1,
        primaryAction: String,
        camera: ExecutionCameraPlanV1,
        blocking: [ExecutionBlockingV1] = [],
        timedActionBeats: [TimedActionBeatV1] = [],
        continuityLocks: [String] = [],
        transitionIntent: String? = nil,
        renderability: ExecutionRenderabilityV1,
        risks: [String] = [],
        rescue: String? = nil,
        acceptance: [ExecutionAcceptanceCriterionV1] = [],
        generationRequirement: GenerationRequirementV1? = nil
    ) {
        self.id = id
        self.sourceMode = sourceMode
        self.sourceAssetID = sourceAssetID
        self.startState = startState
        self.endState = endState
        self.primaryAction = primaryAction
        self.camera = camera
        self.blocking = blocking
        self.timedActionBeats = timedActionBeats
        self.continuityLocks = continuityLocks
        self.transitionIntent = transitionIntent
        self.renderability = renderability
        self.risks = risks
        self.rescue = rescue
        self.acceptance = acceptance
        self.generationRequirement = generationRequirement
    }
}

public struct ExecutionPlanV1: Codable, Sendable, Equatable {
    public static let creativeContextArtifactID = "core.creative-context"
    public static let creativeContextArtifactRole = "core.creative-context"
    public static let publicationArtifactPath = "execution/publication.v1.json"

    public let schema: String
    public let id: String
    public let projectID: String
    public let creativeContext: CanonicalArtifactReferenceV1
    public let extensionReferences: [PackArtifactExtensionReferenceV1]
    public let completeness: ExecutionPlanCompletenessV1
    public let incompleteReasons: [String]
    public let shots: [ExecutionShotV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case id
        case projectID = "project_id"
        case creativeContext = "creative_context"
        case extensionReferences = "extension_references"
        case completeness
        case incompleteReasons = "incomplete_reasons"
        case shots
    }

    public init(
        schema: String = executionPlanV1Schema,
        id: String,
        projectID: String,
        creativeContext: CanonicalArtifactReferenceV1,
        extensionReferences: [PackArtifactExtensionReferenceV1] = [],
        completeness: ExecutionPlanCompletenessV1 = .complete,
        incompleteReasons: [String] = [],
        shots: [ExecutionShotV1]
    ) {
        self.schema = schema
        self.id = id
        self.projectID = projectID
        self.creativeContext = creativeContext
        self.extensionReferences = extensionReferences
        self.completeness = completeness
        self.incompleteReasons = incompleteReasons
        self.shots = shots
    }
}

public enum ExecutionPlanCanonicalCodec {
    public static func encode(_ plan: ExecutionPlanV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(plan)
    }

    public static func encode(_ context: ProjectCreativeContextV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(context)
    }

    public static func decodePlan(_ data: Data) throws -> ExecutionPlanV1 {
        let plan = try JSONDecoder().decode(ExecutionPlanV1.self, from: data)
        try ExecutionPlanValidator.validate(plan)
        return plan
    }

    public static func decodeContext(_ data: Data) throws -> ProjectCreativeContextV1 {
        let context = try JSONDecoder().decode(ProjectCreativeContextV1.self, from: data)
        try ExecutionPlanValidator.validate(context)
        return context
    }
}

public enum ShotlistV4ExecutionPlanAdapterError: Error, Sendable, Equatable {
    case unsupportedSchema(String)
    case projectMismatch(shotlist: String, context: String)
}

public enum ShotlistV4ExecutionPlanAdapter {
    public static func project(
        _ shotlist: Shotlist,
        planID: String,
        context: ProjectCreativeContextV1
    ) throws -> ExecutionPlanV1 {
        guard shotlist.schema_ == shotlistSchemaVersion else {
            throw ShotlistV4ExecutionPlanAdapterError.unsupportedSchema(shotlist.schema_)
        }
        guard shotlist.project == context.projectID else {
            throw ShotlistV4ExecutionPlanAdapterError.projectMismatch(
                shotlist: shotlist.project,
                context: context.projectID
            )
        }
        try ExecutionPlanValidator.validate(context)

        let contextData = try ExecutionPlanCanonicalCodec.encode(context)
        let contextReference = CanonicalArtifactReferenceV1(
            id: ExecutionPlanV1.creativeContextArtifactID,
            role: ExecutionPlanV1.creativeContextArtifactRole,
            path: PipelineLayout.creativeContextFile,
            sha256: FileDigest.sha256(of: contextData)
        )
        let projectedShots = shotlist.shots.map { shot in
            project(shot, media: context.media)
        }
        let plan = ExecutionPlanV1(
            id: planID,
            projectID: shotlist.project,
            creativeContext: contextReference,
            extensionReferences: context.extensions,
            completeness: .legacyIncomplete,
            incompleteReasons: [
                "shotlist/v4 has no exact start and end execution states",
                "shotlist/v4 has no execution acceptance criteria",
                "shotlist/v4 has no format-neutral generation requirements",
            ],
            shots: projectedShots
        )
        try ExecutionPlanValidator.validateLegacyProjection(plan)
        return plan
    }

    private static func project(
        _ shot: Shot,
        media: [ProjectMediaReferenceV1]
    ) -> ExecutionShotV1 {
        let productionPlan = shot.productionPlan
        let sourceAssetID = shot.sourcePath.flatMap { sourcePath in
            let matches = media.filter { $0.path == sourcePath }
            return matches.count == 1 ? matches[0].id : nil
        }
        let sourceMode: ExecutionSourceModeV1
        switch shot.sourceMode {
        case .generated:
            sourceMode = .generated
        case .imported:
            sourceMode = .imported
        case .aiEnhanced:
            sourceMode = .aiEnhanced
        }
        let renderability: ExecutionRenderabilityV1
        switch productionPlan?.renderability {
        case .green:
            renderability = .green
        case .yellow:
            renderability = .yellow
        case .red, nil:
            renderability = .red
        }

        return ExecutionShotV1(
            id: shot.id,
            sourceMode: sourceMode,
            sourceAssetID: sourceAssetID,
            startState: ExecutionStateV1(summary: ""),
            endState: ExecutionStateV1(summary: ""),
            primaryAction: productionPlan?.primaryAction ?? "",
            camera: ExecutionCameraPlanV1(
                movementID: productionPlan?.cameraMovement.rawValue ?? "",
                movementDetail: productionPlan?.cameraMovementDetail
            ),
            blocking: productionPlan?.blockingAnchors.map {
                ExecutionBlockingV1(
                    entityID: $0.characterRef,
                    relation: $0.setAnchor
                )
            } ?? [],
            continuityLocks: productionPlan?.continuityLocks ?? [],
            transitionIntent: productionPlan?.matchActionCue,
            renderability: renderability,
            risks: productionPlan?.risks.map(\.rawValue) ?? [],
            rescue: productionPlan?.rescueCut,
            acceptance: [],
            generationRequirement: nil
        )
    }
}
