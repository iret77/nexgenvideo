import Foundation
import NexGenEngine

enum PipelineExecutionShotInputValidationError: Error, Sendable, Equatable,
    LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let field):
            return "Invalid execution shot input at \(field)."
        }
    }
}

struct PipelineExecutionStateInput: Codable, Sendable, Equatable {
    let summary: String
    let entityStateIDs: [String]
    let spatialState: String?

    private enum CodingKeys: String, CodingKey {
        case summary
        case entityStateIDs = "entity_state_ids"
        case spatialState = "spatial_state"
    }

    func validate(path: String) throws {
        try PipelineExecutionInputValidation.require(summary, field: "\(path).summary")
        try PipelineExecutionInputValidation.uniqueNonEmpty(
            entityStateIDs,
            field: "\(path).entity_state_ids"
        )
        try PipelineExecutionInputValidation.requireOptional(
            spatialState,
            field: "\(path).spatial_state"
        )
    }
}

struct PipelineExecutionBlockingInput: Codable, Sendable, Equatable {
    let entityID: String
    let anchorDemandID: String?
    let performance: String

    private enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case anchorDemandID = "anchor_demand_id"
        case performance
    }

    func validate(path: String) throws {
        try PipelineExecutionInputValidation.require(entityID, field: "\(path).entity_id")
        try PipelineExecutionInputValidation.requireOptional(
            anchorDemandID,
            field: "\(path).anchor_demand_id"
        )
        try PipelineExecutionInputValidation.require(
            performance,
            field: "\(path).performance"
        )
    }
}

struct PipelineTimedActionBeatInput: Codable, Sendable, Equatable {
    let timeSeconds: Double
    let action: String

    private enum CodingKeys: String, CodingKey {
        case timeSeconds = "time_seconds"
        case action
    }

    func validate(path: String) throws {
        guard timeSeconds.isFinite, timeSeconds >= 0 else {
            throw PipelineExecutionShotInputValidationError.invalid(
                "\(path).time_seconds"
            )
        }
        try PipelineExecutionInputValidation.require(action, field: "\(path).action")
    }
}

struct PipelineExecutionAcceptanceInput: Codable, Sendable, Equatable {
    let id: String
    let requirement: String
    let severity: String

    func validate(path: String) throws {
        try PipelineExecutionInputValidation.require(id, field: "\(path).id")
        try PipelineExecutionInputValidation.require(
            requirement,
            field: "\(path).requirement"
        )
        try PipelineExecutionInputValidation.require(
            severity,
            field: "\(path).severity"
        )
    }
}

struct PipelineExecutionCameraInput: Codable, Sendable, Equatable {
    let movementID: String
    let movementDetail: String?
    let framingID: String?
    let placement: String?
    let endpoint: String?

    private enum CodingKeys: String, CodingKey {
        case movementID = "movement_id"
        case movementDetail = "movement_detail"
        case framingID = "framing_id"
        case placement
        case endpoint
    }

    func validate(path: String) throws {
        try PipelineExecutionInputValidation.require(
            movementID,
            field: "\(path).movement_id"
        )
        try PipelineExecutionInputValidation.requireOptional(
            movementDetail,
            field: "\(path).movement_detail"
        )
        try PipelineExecutionInputValidation.requireOptional(
            framingID,
            field: "\(path).framing_id"
        )
        try PipelineExecutionInputValidation.requireOptional(
            placement,
            field: "\(path).placement"
        )
        try PipelineExecutionInputValidation.requireOptional(
            endpoint,
            field: "\(path).endpoint"
        )
    }
}

struct PipelineExecutionDurationInput: Codable, Sendable, Equatable {
    let minimumSeconds: Double?
    let maximumSeconds: Double?
    let allowsAutomatic: Bool

    private enum CodingKeys: String, CodingKey {
        case minimumSeconds = "minimum_seconds"
        case maximumSeconds = "maximum_seconds"
        case allowsAutomatic = "allows_automatic"
    }

    func validate(path: String) throws {
        let values = [minimumSeconds, maximumSeconds].compactMap { $0 }
        guard !values.isEmpty || allowsAutomatic,
              values.allSatisfy({ $0.isFinite && $0 > 0 }),
              minimumSeconds == nil || maximumSeconds == nil
                || minimumSeconds! <= maximumSeconds! else {
            throw PipelineExecutionShotInputValidationError.invalid(path)
        }
    }

}

struct PipelineGenerationRequirementInput: Codable, Sendable, Equatable {
    let modalityID: CapabilityModalityV1
    let modeIDs: [String]
    let duration: PipelineExecutionDurationInput
    let requiresOutputAudio: Bool
    let qualityTarget: String?
    let maximumCost: Double?
    let maximumLatencySeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case modalityID = "modality_id"
        case modeIDs = "mode_ids"
        case duration
        case requiresOutputAudio = "requires_output_audio"
        case qualityTarget = "quality_target"
        case maximumCost = "maximum_cost"
        case maximumLatencySeconds = "maximum_latency_seconds"
    }

    func validate(path: String) throws {
        guard !modeIDs.isEmpty else {
            throw PipelineExecutionShotInputValidationError.invalid(
                "\(path).mode_ids"
            )
        }
        try PipelineExecutionInputValidation.uniqueCanonical(
            modeIDs,
            by: \.self,
            field: "\(path).mode_ids"
        )
        try duration.validate(path: "\(path).duration")
        try PipelineExecutionInputValidation.requireOptional(
            qualityTarget,
            field: "\(path).quality_target"
        )
        if let maximumCost, !maximumCost.isFinite || maximumCost < 0 {
            throw PipelineExecutionShotInputValidationError.invalid(
                "\(path).maximum_cost"
            )
        }
        if let maximumLatencySeconds,
           !maximumLatencySeconds.isFinite || maximumLatencySeconds <= 0 {
            throw PipelineExecutionShotInputValidationError.invalid(
                "\(path).maximum_latency_seconds"
            )
        }
    }
}

struct PipelineExecutionCoreInputsInput: Codable, Sendable, Equatable {
    let firstFrameModeID: String?
    let lastFrameModeID: String?
    let predecessorLastFrameModeID: String?
    let sourceVideoModeID: String?
    let audioTimingModeID: String?

    private enum CodingKeys: String, CodingKey {
        case firstFrameModeID = "first_frame_mode_id"
        case lastFrameModeID = "last_frame_mode_id"
        case predecessorLastFrameModeID = "predecessor_last_frame_mode_id"
        case sourceVideoModeID = "source_video_mode_id"
        case audioTimingModeID = "audio_timing_mode_id"
    }

    func validate(path: String) throws {
        try PipelineExecutionInputValidation.requireOptional(
            firstFrameModeID,
            field: "\(path).first_frame_mode_id"
        )
        try PipelineExecutionInputValidation.requireOptional(
            lastFrameModeID,
            field: "\(path).last_frame_mode_id"
        )
        try PipelineExecutionInputValidation.requireOptional(
            predecessorLastFrameModeID,
            field: "\(path).predecessor_last_frame_mode_id"
        )
        try PipelineExecutionInputValidation.requireOptional(
            sourceVideoModeID,
            field: "\(path).source_video_mode_id"
        )
        try PipelineExecutionInputValidation.requireOptional(
            audioTimingModeID,
            field: "\(path).audio_timing_mode_id"
        )
        if predecessorLastFrameModeID != nil,
           firstFrameModeID != nil || lastFrameModeID != nil || sourceVideoModeID != nil {
            throw PipelineExecutionShotInputValidationError.invalid(path)
        }
    }

    var modeIDs: [String] {
        [
            firstFrameModeID,
            lastFrameModeID,
            predecessorLastFrameModeID,
            sourceVideoModeID,
            audioTimingModeID,
        ].compactMap { $0 }
    }
}

struct PipelineReferenceDemandInput: Codable, Sendable, Equatable {
    let id: String
    let assetPath: String
    let modality: AssetPhysicalModalityV1
    let semanticJobID: String
    let isRequired: Bool
    let priority: Int
    let preservationScopeIDs: [String]
    let exclusionDemandIDs: [String]
    let inputSlotID: String
    let modeID: String
    let identityLock: Bool
    let entityID: String?
    let canonIDs: [String]
    let stateID: String?
    let viewID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case assetPath = "asset_path"
        case modality
        case semanticJobID = "semantic_job_id"
        case isRequired = "is_required"
        case priority
        case preservationScopeIDs = "preservation_scope_ids"
        case exclusionDemandIDs = "exclusion_demand_ids"
        case inputSlotID = "input_slot_id"
        case modeID = "mode_id"
        case identityLock = "identity_lock"
        case entityID = "entity_id"
        case canonIDs = "canon_ids"
        case stateID = "state_id"
        case viewID = "view_id"
    }

    func validate(path: String) throws {
        try PipelineExecutionInputValidation.require(id, field: "\(path).id")
        try PipelineExecutionInputValidation.projectPath(
            assetPath,
            field: "\(path).asset_path"
        )
        try PipelineExecutionInputValidation.namespaced(
            semanticJobID,
            field: "\(path).semantic_job_id"
        )
        guard priority >= 0 else {
            throw PipelineExecutionShotInputValidationError.invalid("\(path).priority")
        }
        try PipelineExecutionInputValidation.uniqueNonEmpty(
            preservationScopeIDs,
            field: "\(path).preservation_scope_ids"
        )
        try PipelineExecutionInputValidation.uniqueNonEmpty(
            exclusionDemandIDs,
            field: "\(path).exclusion_demand_ids"
        )
        try PipelineExecutionInputValidation.namespaced(
            inputSlotID,
            field: "\(path).input_slot_id"
        )
        try PipelineExecutionInputValidation.require(modeID, field: "\(path).mode_id")
        try PipelineExecutionInputValidation.requireOptional(
            entityID,
            field: "\(path).entity_id"
        )
        try PipelineExecutionInputValidation.uniqueNonEmpty(
            canonIDs,
            field: "\(path).canon_ids"
        )
        try PipelineExecutionInputValidation.requireOptional(
            stateID,
            field: "\(path).state_id"
        )
        try PipelineExecutionInputValidation.requireOptional(
            viewID,
            field: "\(path).view_id"
        )
        guard !identityLock || isRequired,
              !exclusionDemandIDs.contains(id),
              !ProductionReferenceDemandSemanticsV1.isDedicated(
                  semanticJobID: semanticJobID
              ) else {
            throw PipelineExecutionShotInputValidationError.invalid(path)
        }
    }
}

struct PipelineExecutionShotInput: Codable, Sendable, Equatable {
    let id: String
    let sourceMode: ExecutionSourceModeV1
    let startState: PipelineExecutionStateInput
    let endState: PipelineExecutionStateInput
    let blocking: [PipelineExecutionBlockingInput]
    let timedActionBeats: [PipelineTimedActionBeatInput]
    let acceptance: [PipelineExecutionAcceptanceInput]

    let cameraPlacement: String?
    let cameraEndpoint: String?
    let generationRequirement: PipelineGenerationRequirementInput?
    let coreInputs: PipelineExecutionCoreInputsInput?
    let referenceDemands: [PipelineReferenceDemandInput]

    let primaryAction: String?
    let camera: PipelineExecutionCameraInput?
    let continuityLocks: [String]
    let transitionIntent: String?
    let renderability: ExecutionRenderabilityV1?
    let risks: [String]
    let rescue: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case sourceMode = "source_mode"
        case startState = "start_state"
        case endState = "end_state"
        case blocking
        case timedActionBeats = "timed_action_beats"
        case acceptance
        case cameraPlacement = "camera_placement"
        case cameraEndpoint = "camera_endpoint"
        case generationRequirement = "generation_requirement"
        case coreInputs = "core_inputs"
        case referenceDemands = "reference_demands"
        case primaryAction = "primary_action"
        case camera
        case continuityLocks = "continuity_locks"
        case transitionIntent = "transition_intent"
        case renderability
        case risks
        case rescue
    }

    private init(
        id: String,
        sourceMode: ExecutionSourceModeV1,
        startState: PipelineExecutionStateInput,
        endState: PipelineExecutionStateInput,
        blocking: [PipelineExecutionBlockingInput],
        timedActionBeats: [PipelineTimedActionBeatInput],
        acceptance: [PipelineExecutionAcceptanceInput],
        cameraPlacement: String?,
        cameraEndpoint: String?,
        generationRequirement: PipelineGenerationRequirementInput?,
        coreInputs: PipelineExecutionCoreInputsInput?,
        referenceDemands: [PipelineReferenceDemandInput],
        primaryAction: String?,
        camera: PipelineExecutionCameraInput?,
        continuityLocks: [String],
        transitionIntent: String?,
        renderability: ExecutionRenderabilityV1?,
        risks: [String],
        rescue: String?
    ) {
        self.id = id
        self.sourceMode = sourceMode
        self.startState = startState
        self.endState = endState
        self.blocking = blocking
        self.timedActionBeats = timedActionBeats
        self.acceptance = acceptance
        self.cameraPlacement = cameraPlacement
        self.cameraEndpoint = cameraEndpoint
        self.generationRequirement = generationRequirement
        self.coreInputs = coreInputs
        self.referenceDemands = referenceDemands
        self.primaryAction = primaryAction
        self.camera = camera
        self.continuityLocks = continuityLocks
        self.transitionIntent = transitionIntent
        self.renderability = renderability
        self.risks = risks
        self.rescue = rescue
    }

    static func imported(from shot: ExecutionShotV1) throws -> Self {
        guard shot.sourceMode == .generated || shot.sourceMode == .aiEnhanced else {
            throw PipelineExecutionShotInputValidationError.invalid(
                "execution_shot[\(shot.id)].source_mode"
            )
        }
        let blocking = try shot.blocking.map { item in
            guard let performance = item.performance else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "execution_shot[\(shot.id)].blocking.performance"
                )
            }
            return PipelineExecutionBlockingInput(
                entityID: item.entityID,
                anchorDemandID: nil,
                performance: performance
            )
        }
        let result = Self(
            id: shot.id,
            sourceMode: .imported,
            startState: PipelineExecutionStateInput(
                summary: shot.startState.summary,
                entityStateIDs: shot.startState.entityStateIDs,
                spatialState: shot.startState.spatialState
            ),
            endState: PipelineExecutionStateInput(
                summary: shot.endState.summary,
                entityStateIDs: shot.endState.entityStateIDs,
                spatialState: shot.endState.spatialState
            ),
            blocking: blocking,
            timedActionBeats: shot.timedActionBeats.map {
                PipelineTimedActionBeatInput(
                    timeSeconds: $0.timeSeconds,
                    action: $0.action
                )
            },
            acceptance: shot.acceptance.map {
                PipelineExecutionAcceptanceInput(
                    id: $0.id,
                    requirement: $0.requirement,
                    severity: $0.severity
                )
            },
            cameraPlacement: nil,
            cameraEndpoint: nil,
            generationRequirement: nil,
            coreInputs: nil,
            referenceDemands: [],
            primaryAction: shot.primaryAction,
            camera: PipelineExecutionCameraInput(
                movementID: shot.camera.movementID,
                movementDetail: shot.camera.movementDetail,
                framingID: shot.camera.framingID,
                placement: shot.camera.placement,
                endpoint: shot.camera.endpoint
            ),
            continuityLocks: shot.continuityLocks,
            transitionIntent: shot.transitionIntent,
            renderability: shot.renderability,
            risks: shot.risks,
            rescue: shot.rescue
        )
        try result.validate()
        return result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceMode = try container.decode(ExecutionSourceModeV1.self, forKey: .sourceMode)
        try Self.rejectUnexpectedKeys(from: decoder, for: sourceMode)

        id = try container.decode(String.self, forKey: .id)
        startState = try container.decode(PipelineExecutionStateInput.self, forKey: .startState)
        endState = try container.decode(PipelineExecutionStateInput.self, forKey: .endState)
        blocking = try container.decode([PipelineExecutionBlockingInput].self, forKey: .blocking)
        timedActionBeats = try container.decode(
            [PipelineTimedActionBeatInput].self,
            forKey: .timedActionBeats
        )
        acceptance = try container.decode(
            [PipelineExecutionAcceptanceInput].self,
            forKey: .acceptance
        )

        switch sourceMode {
        case .generated:
            cameraPlacement = try container.decodeIfPresent(String.self, forKey: .cameraPlacement)
            cameraEndpoint = try container.decodeIfPresent(String.self, forKey: .cameraEndpoint)
            generationRequirement = try container.decode(
                PipelineGenerationRequirementInput.self,
                forKey: .generationRequirement
            )
            coreInputs = try container.decode(
                PipelineExecutionCoreInputsInput.self,
                forKey: .coreInputs
            )
            referenceDemands = try container.decode(
                [PipelineReferenceDemandInput].self,
                forKey: .referenceDemands
            )
            primaryAction = nil
            camera = nil
            continuityLocks = []
            transitionIntent = nil
            renderability = nil
            risks = []
            rescue = nil
        case .aiEnhanced:
            cameraPlacement = try container.decodeIfPresent(String.self, forKey: .cameraPlacement)
            cameraEndpoint = try container.decodeIfPresent(String.self, forKey: .cameraEndpoint)
            generationRequirement = try container.decode(
                PipelineGenerationRequirementInput.self,
                forKey: .generationRequirement
            )
            coreInputs = try container.decode(
                PipelineExecutionCoreInputsInput.self,
                forKey: .coreInputs
            )
            referenceDemands = try container.decodeIfPresent(
                [PipelineReferenceDemandInput].self,
                forKey: .referenceDemands
            ) ?? []
            primaryAction = nil
            camera = nil
            continuityLocks = []
            transitionIntent = nil
            renderability = nil
            risks = []
            rescue = nil
        case .imported:
            cameraPlacement = nil
            cameraEndpoint = nil
            generationRequirement = nil
            coreInputs = nil
            referenceDemands = []
            primaryAction = try container.decode(String.self, forKey: .primaryAction)
            camera = try container.decode(PipelineExecutionCameraInput.self, forKey: .camera)
            continuityLocks = try container.decode([String].self, forKey: .continuityLocks)
            transitionIntent = try container.decodeIfPresent(String.self, forKey: .transitionIntent)
            renderability = try container.decode(
                ExecutionRenderabilityV1.self,
                forKey: .renderability
            )
            risks = try container.decode([String].self, forKey: .risks)
            rescue = try container.decodeIfPresent(String.self, forKey: .rescue)
        }
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceMode, forKey: .sourceMode)
        try container.encode(startState, forKey: .startState)
        try container.encode(endState, forKey: .endState)
        try container.encode(blocking, forKey: .blocking)
        try container.encode(timedActionBeats, forKey: .timedActionBeats)
        try container.encode(acceptance, forKey: .acceptance)

        switch sourceMode {
        case .generated:
            try container.encodeIfPresent(cameraPlacement, forKey: .cameraPlacement)
            try container.encodeIfPresent(cameraEndpoint, forKey: .cameraEndpoint)
            try container.encode(generationRequirement, forKey: .generationRequirement)
            try container.encode(coreInputs, forKey: .coreInputs)
            try container.encode(referenceDemands, forKey: .referenceDemands)
        case .aiEnhanced:
            try container.encodeIfPresent(cameraPlacement, forKey: .cameraPlacement)
            try container.encodeIfPresent(cameraEndpoint, forKey: .cameraEndpoint)
            try container.encode(generationRequirement, forKey: .generationRequirement)
            try container.encode(coreInputs, forKey: .coreInputs)
            if !referenceDemands.isEmpty {
                try container.encode(referenceDemands, forKey: .referenceDemands)
            }
        case .imported:
            try container.encode(primaryAction, forKey: .primaryAction)
            try container.encode(camera, forKey: .camera)
            try container.encode(continuityLocks, forKey: .continuityLocks)
            try container.encodeIfPresent(transitionIntent, forKey: .transitionIntent)
            try container.encode(renderability, forKey: .renderability)
            try container.encode(risks, forKey: .risks)
            try container.encodeIfPresent(rescue, forKey: .rescue)
        }
    }

    func validate(timedBeatMaximumSeconds: Double? = nil) throws {
        let path = "execution_shot[\(id)]"
        try PipelineExecutionInputValidation.require(id, field: "\(path).id")
        try startState.validate(path: "\(path).start_state")
        try endState.validate(path: "\(path).end_state")
        try PipelineExecutionInputValidation.uniqueCanonical(
            blocking,
            by: \PipelineExecutionBlockingInput.entityID,
            field: "\(path).blocking"
        )
        for (index, item) in blocking.enumerated() {
            try item.validate(path: "\(path).blocking[\(index)]")
        }
        try PipelineExecutionInputValidation.unique(
            acceptance,
            by: \PipelineExecutionAcceptanceInput.id,
            field: "\(path).acceptance"
        )
        guard !acceptance.isEmpty else {
            throw PipelineExecutionShotInputValidationError.invalid("\(path).acceptance")
        }
        for (index, item) in acceptance.enumerated() {
            try item.validate(path: "\(path).acceptance[\(index)]")
        }
        try validateTimedBeats(
            path: path,
            maximumSeconds: timedBeatMaximumSeconds
        )

        switch sourceMode {
        case .generated, .aiEnhanced:
            try validateGenerated(path: path)
        case .imported:
            try validateImported(path: path)
        }
    }

    private func validateGenerated(path: String) throws {
        try PipelineExecutionInputValidation.requireOptional(
            cameraPlacement,
            field: "\(path).camera_placement"
        )
        try PipelineExecutionInputValidation.requireOptional(
            cameraEndpoint,
            field: "\(path).camera_endpoint"
        )
        guard let generationRequirement, let coreInputs else {
            throw PipelineExecutionShotInputValidationError.invalid(path)
        }
        try generationRequirement.validate(path: "\(path).generation_requirement")
        try coreInputs.validate(path: "\(path).core_inputs")

        if sourceMode == .generated {
            guard coreInputs.sourceVideoModeID == nil else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "\(path).core_inputs.source_video_mode_id"
                )
            }
        } else {
            guard coreInputs.sourceVideoModeID != nil,
                  coreInputs.firstFrameModeID == nil,
                  coreInputs.lastFrameModeID == nil,
                  coreInputs.predecessorLastFrameModeID == nil,
                  referenceDemands.isEmpty else {
                throw PipelineExecutionShotInputValidationError.invalid(path)
            }
        }

        try PipelineExecutionInputValidation.unique(
            referenceDemands,
            by: \PipelineReferenceDemandInput.id,
            field: "\(path).reference_demands"
        )
        let demandIDs = Set(referenceDemands.map(\.id))
        for (index, demand) in referenceDemands.enumerated() {
            try demand.validate(path: "\(path).reference_demands[\(index)]")
            guard Set(demand.exclusionDemandIDs).isSubset(of: demandIDs) else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "\(path).reference_demands[\(index)].exclusion_demand_ids"
                )
            }
        }
        for (index, item) in blocking.enumerated() {
            if let anchorDemandID = item.anchorDemandID,
               !demandIDs.contains(anchorDemandID) {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "\(path).blocking[\(index)].anchor_demand_id"
                )
            }
        }

        let declaredModes = Set(generationRequirement.modeIDs.map(
            ProductionIdentifierNormalizerV1.canonical
        ))
        let inputModes = coreInputs.modeIDs + referenceDemands.map(\.modeID)
        guard inputModes.allSatisfy({
            declaredModes.contains(ProductionIdentifierNormalizerV1.canonical($0))
        }) else {
            throw PipelineExecutionShotInputValidationError.invalid(
                "\(path).generation_requirement.mode_ids"
            )
        }
        if coreInputs.predecessorLastFrameModeID != nil,
           !referenceDemands.isEmpty {
            throw PipelineExecutionShotInputValidationError.invalid(
                "\(path).reference_demands"
            )
        }
    }

    private func validateImported(path: String) throws {
        guard let primaryAction, let camera, let renderability else {
            throw PipelineExecutionShotInputValidationError.invalid(path)
        }
        try PipelineExecutionInputValidation.require(
            primaryAction,
            field: "\(path).primary_action"
        )
        try camera.validate(path: "\(path).camera")
        try PipelineExecutionInputValidation.uniqueNonEmpty(
            continuityLocks,
            field: "\(path).continuity_locks"
        )
        try PipelineExecutionInputValidation.requireOptional(
            transitionIntent,
            field: "\(path).transition_intent"
        )
        try PipelineExecutionInputValidation.uniqueNonEmpty(
            risks,
            field: "\(path).risks"
        )
        try PipelineExecutionInputValidation.requireOptional(rescue, field: "\(path).rescue")
        if renderability == .green {
            guard risks.isEmpty, rescue == nil else {
                throw PipelineExecutionShotInputValidationError.invalid(path)
            }
        } else {
            guard !risks.isEmpty,
                  rescue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw PipelineExecutionShotInputValidationError.invalid(path)
            }
        }
        guard blocking.allSatisfy({ $0.anchorDemandID == nil }) else {
            throw PipelineExecutionShotInputValidationError.invalid("\(path).blocking")
        }
    }

    private func validateTimedBeats(
        path: String,
        maximumSeconds: Double?
    ) throws {
        if let maximumSeconds,
           !maximumSeconds.isFinite || maximumSeconds <= 0 {
            throw PipelineExecutionShotInputValidationError.invalid(
                "\(path).timed_action_beats"
            )
        }
        let effectiveMaximum = [
            maximumSeconds,
            generationRequirement?.duration.maximumSeconds,
        ].compactMap { $0 }.min()
        var previous = -Double.infinity
        for (index, beat) in timedActionBeats.enumerated() {
            try beat.validate(path: "\(path).timed_action_beats[\(index)]")
            guard index == 0 || beat.timeSeconds > previous,
                  effectiveMaximum.map({ beat.timeSeconds <= $0 }) ?? true else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "\(path).timed_action_beats[\(index)]"
                )
            }
            previous = beat.timeSeconds
        }
    }

    private static func rejectUnexpectedKeys(
        from decoder: Decoder,
        for sourceMode: ExecutionSourceModeV1
    ) throws {
        let dynamic = try decoder.container(keyedBy: PipelineDynamicCodingKey.self)
        let common: Set<String> = [
            CodingKeys.id.rawValue,
            CodingKeys.sourceMode.rawValue,
            CodingKeys.startState.rawValue,
            CodingKeys.endState.rawValue,
            CodingKeys.blocking.rawValue,
            CodingKeys.timedActionBeats.rawValue,
            CodingKeys.acceptance.rawValue,
        ]
        let variant: Set<String>
        switch sourceMode {
        case .generated:
            variant = [
                CodingKeys.cameraPlacement.rawValue,
                CodingKeys.cameraEndpoint.rawValue,
                CodingKeys.generationRequirement.rawValue,
                CodingKeys.coreInputs.rawValue,
                CodingKeys.referenceDemands.rawValue,
            ]
        case .aiEnhanced:
            variant = [
                CodingKeys.cameraPlacement.rawValue,
                CodingKeys.cameraEndpoint.rawValue,
                CodingKeys.generationRequirement.rawValue,
                CodingKeys.coreInputs.rawValue,
                CodingKeys.referenceDemands.rawValue,
            ]
        case .imported:
            variant = [
                CodingKeys.primaryAction.rawValue,
                CodingKeys.camera.rawValue,
                CodingKeys.continuityLocks.rawValue,
                CodingKeys.transitionIntent.rawValue,
                CodingKeys.renderability.rawValue,
                CodingKeys.risks.rawValue,
                CodingKeys.rescue.rawValue,
            ]
        }
        let unknown = Set(dynamic.allKeys.map(\.stringValue)).subtracting(common.union(variant))
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unexpected fields for \(sourceMode.rawValue): "
                    + unknown.sorted().joined(separator: ", ")
            ))
        }
    }
}

private struct PipelineDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum PipelineExecutionInputValidation {
    static func require(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineExecutionShotInputValidationError.invalid(field)
        }
    }

    static func requireOptional(_ value: String?, field: String) throws {
        if let value {
            try require(value, field: field)
        }
    }

    static func uniqueNonEmpty(_ values: [String], field: String) throws {
        var seen = Set<String>()
        for value in values {
            try require(value, field: field)
            guard seen.insert(value).inserted else {
                throw PipelineExecutionShotInputValidationError.invalid(field)
            }
        }
    }

    static func unique<T>(
        _ values: [T],
        by keyPath: KeyPath<T, String>,
        field: String
    ) throws {
        var seen = Set<String>()
        for value in values {
            let id = value[keyPath: keyPath]
            try require(id, field: field)
            guard seen.insert(id).inserted else {
                throw PipelineExecutionShotInputValidationError.invalid(field)
            }
        }
    }

    static func uniqueCanonical<T>(
        _ values: [T],
        by keyPath: KeyPath<T, String>,
        field: String
    ) throws {
        var seen = Set<String>()
        for value in values {
            let id = value[keyPath: keyPath]
            try require(id, field: field)
            let canonical = ProductionIdentifierNormalizerV1.canonical(id)
            guard seen.insert(canonical).inserted else {
                throw PipelineExecutionShotInputValidationError.invalid(field)
            }
        }
    }

    static func namespaced(_ value: String, field: String) throws {
        let pattern = #"^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)+$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw PipelineExecutionShotInputValidationError.invalid(field)
        }
    }

    static func projectPath(_ value: String, field: String) throws {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !NSString(string: value).isAbsolutePath,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PipelineExecutionShotInputValidationError.invalid(field)
        }
    }
}
