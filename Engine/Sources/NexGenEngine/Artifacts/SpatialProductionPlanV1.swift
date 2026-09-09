import Foundation

public struct SpatialVector3V1: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct SpatialPlanActivationV1: Codable, Sendable, Equatable {
    public let verticalGeography: Bool
    public let axisIDs: [String]
    public let documentedSpatialDrift: Bool
    public let rationale: String

    private enum CodingKeys: String, CodingKey {
        case verticalGeography = "vertical_geography"
        case axisIDs = "axis_ids"
        case documentedSpatialDrift = "documented_spatial_drift"
        case rationale
    }

    public init(
        verticalGeography: Bool,
        axisIDs: [String],
        documentedSpatialDrift: Bool,
        rationale: String
    ) {
        self.verticalGeography = verticalGeography
        self.axisIDs = axisIDs
        self.documentedSpatialDrift = documentedSpatialDrift
        self.rationale = rationale
    }

    public var requiresBlockout: Bool {
        verticalGeography || Set(axisIDs).count > 1 || documentedSpatialDrift
    }
}

public enum CameraAxisSideV1: String, Codable, Sendable, Equatable, CaseIterable {
    case negative
    case onAxis = "on_axis"
    case positive
    case intentionalCross = "intentional_cross"
}

public struct CameraPathKeyframeV1: Codable, Sendable, Equatable {
    public let timeSeconds: Double
    public let position: SpatialVector3V1
    public let lookAt: SpatialVector3V1

    private enum CodingKeys: String, CodingKey {
        case timeSeconds = "time_seconds"
        case position
        case lookAt = "look_at"
    }

    public init(timeSeconds: Double, position: SpatialVector3V1, lookAt: SpatialVector3V1) {
        self.timeSeconds = timeSeconds
        self.position = position
        self.lookAt = lookAt
    }
}

public struct CameraSetupV1: Codable, Sendable, Equatable {
    public let id: String
    public let locationID: String
    public let position: SpatialVector3V1
    public let orientationDegrees: SpatialVector3V1
    public let axisID: String
    public let axisSide: CameraAxisSideV1
    public let heightMeters: Double
    public let focalLengthMM: Double
    public let horizontalFOVDegrees: Double
    public let lookTarget: String
    public let path: [CameraPathKeyframeV1]
    public let deviationReason: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case locationID = "location_id"
        case position
        case orientationDegrees = "orientation_degrees"
        case axisID = "axis_id"
        case axisSide = "axis_side"
        case heightMeters = "height_meters"
        case focalLengthMM = "focal_length_mm"
        case horizontalFOVDegrees = "horizontal_fov_degrees"
        case lookTarget = "look_target"
        case path
        case deviationReason = "deviation_reason"
    }

    public init(
        id: String,
        locationID: String,
        position: SpatialVector3V1,
        orientationDegrees: SpatialVector3V1,
        axisID: String,
        axisSide: CameraAxisSideV1,
        heightMeters: Double,
        focalLengthMM: Double,
        horizontalFOVDegrees: Double,
        lookTarget: String,
        path: [CameraPathKeyframeV1],
        deviationReason: String? = nil
    ) {
        self.id = id
        self.locationID = locationID
        self.position = position
        self.orientationDegrees = orientationDegrees
        self.axisID = axisID
        self.axisSide = axisSide
        self.heightMeters = heightMeters
        self.focalLengthMM = focalLengthMM
        self.horizontalFOVDegrees = horizontalFOVDegrees
        self.lookTarget = lookTarget
        self.path = path
        self.deviationReason = deviationReason
    }
}

public struct CameraSetupPlanV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "camera-setup-plan/v1"
    public static let relativePath = PipelineLayout.cameraSetupPlanFile
    public let schema: String
    public let projectID: String
    public let shotlistSHA256: String
    public let activation: SpatialPlanActivationV1
    public let setups: [CameraSetupV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case shotlistSHA256 = "shotlist_sha256"
        case activation
        case setups
    }

    public init(
        projectID: String,
        shotlistSHA256: String,
        activation: SpatialPlanActivationV1,
        setups: [CameraSetupV1]
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.shotlistSHA256 = shotlistSHA256
        self.activation = activation
        self.setups = setups
    }
}

public enum PlannedCutKindV1: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case manual
    case modelInternal = "model_internal"
}

public struct TimedReferenceAnchorV1: Codable, Sendable, Equatable {
    public let roleID: String
    public let demandID: String
    public let timeSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case roleID = "role_id"
        case demandID = "demand_id"
        case timeSeconds = "time_seconds"
    }

    public init(roleID: String, demandID: String, timeSeconds: Double) {
        self.roleID = roleID
        self.demandID = demandID
        self.timeSeconds = timeSeconds
    }
}

public struct PlannedGenerationShotV1: Codable, Sendable, Equatable {
    public let shotID: String
    public let generationID: String
    public let setupID: String
    public let internalStartSeconds: Double
    public let internalEndSeconds: Double
    public let cutAfter: PlannedCutKindV1
    public let startStateID: String
    public let endStateID: String
    public let continuityIn: [String]
    public let continuityOut: [String]
    public let timedReferences: [TimedReferenceAnchorV1]

    private enum CodingKeys: String, CodingKey {
        case shotID = "shot_id"
        case generationID = "generation_id"
        case setupID = "setup_id"
        case internalStartSeconds = "internal_start_seconds"
        case internalEndSeconds = "internal_end_seconds"
        case cutAfter = "cut_after"
        case startStateID = "start_state_id"
        case endStateID = "end_state_id"
        case continuityIn = "continuity_in"
        case continuityOut = "continuity_out"
        case timedReferences = "timed_references"
    }

    public init(
        shotID: String,
        generationID: String,
        setupID: String,
        internalStartSeconds: Double,
        internalEndSeconds: Double,
        cutAfter: PlannedCutKindV1,
        startStateID: String,
        endStateID: String,
        continuityIn: [String],
        continuityOut: [String],
        timedReferences: [TimedReferenceAnchorV1]
    ) {
        self.shotID = shotID
        self.generationID = generationID
        self.setupID = setupID
        self.internalStartSeconds = internalStartSeconds
        self.internalEndSeconds = internalEndSeconds
        self.cutAfter = cutAfter
        self.startStateID = startStateID
        self.endStateID = endStateID
        self.continuityIn = continuityIn
        self.continuityOut = continuityOut
        self.timedReferences = timedReferences
    }
}

public struct ShotGenerationCutPlanV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "shot-generation-cut-plan/v1"
    public static let relativePath = PipelineLayout.shotGenerationCutPlanFile
    public let schema: String
    public let projectID: String
    public let shotlistSHA256: String
    public let shots: [PlannedGenerationShotV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case shotlistSHA256 = "shotlist_sha256"
        case shots
    }

    public init(projectID: String, shotlistSHA256: String, shots: [PlannedGenerationShotV1]) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.shotlistSHA256 = shotlistSHA256
        self.shots = shots
    }
}

public struct ProductionStateV1: Codable, Sendable, Equatable {
    public let id: String
    public let entityID: String
    public let version: Int
    public let description: String
    public let causeBeatID: String
    public let stateSheetPath: String?
    public let stateSheetSHA256: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case entityID = "entity_id"
        case version
        case description
        case causeBeatID = "cause_beat_id"
        case stateSheetPath = "state_sheet_path"
        case stateSheetSHA256 = "state_sheet_sha256"
    }

    public init(
        id: String,
        entityID: String,
        version: Int,
        description: String,
        causeBeatID: String,
        stateSheetPath: String? = nil,
        stateSheetSHA256: String? = nil
    ) {
        self.id = id
        self.entityID = entityID
        self.version = version
        self.description = description
        self.causeBeatID = causeBeatID
        self.stateSheetPath = stateSheetPath
        self.stateSheetSHA256 = stateSheetSHA256
    }
}

public struct StateLadderV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "state-ladder/v1"
    public static let relativePath = PipelineLayout.stateLadderFile
    public let schema: String
    public let projectID: String
    public let shotlistSHA256: String
    public let states: [ProductionStateV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case shotlistSHA256 = "shotlist_sha256"
        case states
    }

    public init(projectID: String, shotlistSHA256: String, states: [ProductionStateV1]) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.shotlistSHA256 = shotlistSHA256
        self.states = states
    }
}

public struct SpatialLayoutV1: Codable, Sendable, Equatable {
    public let locationID: String
    public let widthMeters: Double
    public let depthMeters: Double
    public let heightMeters: Double
    public let setupIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case locationID = "location_id"
        case widthMeters = "width_meters"
        case depthMeters = "depth_meters"
        case heightMeters = "height_meters"
        case setupIDs = "setup_ids"
    }

    public init(
        locationID: String,
        widthMeters: Double,
        depthMeters: Double,
        heightMeters: Double,
        setupIDs: [String]
    ) {
        self.locationID = locationID
        self.widthMeters = widthMeters
        self.depthMeters = depthMeters
        self.heightMeters = heightMeters
        self.setupIDs = setupIDs
    }
}

public struct LookFreePanelV1: Codable, Sendable, Equatable {
    public let id: String
    public let setupID: String
    public let path: String
    public let sha256: String
    public let lookFree: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case setupID = "setup_id"
        case path
        case sha256
        case lookFree = "look_free"
    }

    public init(id: String, setupID: String, path: String, sha256: String, lookFree: Bool) {
        self.id = id
        self.setupID = setupID
        self.path = path
        self.sha256 = sha256
        self.lookFree = lookFree
    }
}

public struct LayoutPanelsV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "layout-panels/v1"
    public static let relativePath = PipelineLayout.layoutPanelsFile
    public let schema: String
    public let projectID: String
    public let shotlistSHA256: String
    public let layouts: [SpatialLayoutV1]
    public let panels: [LookFreePanelV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case shotlistSHA256 = "shotlist_sha256"
        case layouts
        case panels
    }

    public init(
        projectID: String,
        shotlistSHA256: String,
        layouts: [SpatialLayoutV1],
        panels: [LookFreePanelV1]
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.shotlistSHA256 = shotlistSHA256
        self.layouts = layouts
        self.panels = panels
    }
}

public enum BlockoutSourceModeV1: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case native
    case imported
}

public struct BlockoutRequestV1: Codable, Sendable, Equatable {
    public let mode: BlockoutSourceModeV1
    public let importedClipPath: String?
    public let width: Int
    public let height: Int
    public let fps: Int
    public let durationSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case mode
        case importedClipPath = "imported_clip_path"
        case width
        case height
        case fps
        case durationSeconds = "duration_seconds"
    }

    public init(
        mode: BlockoutSourceModeV1,
        importedClipPath: String? = nil,
        width: Int,
        height: Int,
        fps: Int,
        durationSeconds: Double
    ) {
        self.mode = mode
        self.importedClipPath = importedClipPath
        self.width = width
        self.height = height
        self.fps = fps
        self.durationSeconds = durationSeconds
    }
}

public struct SpatialProductionPlanDraftV1: Codable, Sendable, Equatable {
    public let activation: SpatialPlanActivationV1
    public let setups: [CameraSetupV1]
    public let shots: [PlannedGenerationShotV1]
    public let states: [ProductionStateV1]
    public let layouts: [SpatialLayoutV1]
    public let panels: [LookFreePanelV1]
    public let blockout: BlockoutRequestV1

    public init(
        activation: SpatialPlanActivationV1,
        setups: [CameraSetupV1],
        shots: [PlannedGenerationShotV1],
        states: [ProductionStateV1],
        layouts: [SpatialLayoutV1],
        panels: [LookFreePanelV1],
        blockout: BlockoutRequestV1
    ) {
        self.activation = activation
        self.setups = setups
        self.shots = shots
        self.states = states
        self.layouts = layouts
        self.panels = panels
        self.blockout = blockout
    }
}

public struct BlockoutProofV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "blockout-proof/v1"
    public static let relativePath = PipelineLayout.blockoutProofFile
    public let schema: String
    public let projectID: String
    public let sourceMode: BlockoutSourceModeV1
    public let cameraSetupPlanSHA256: String
    public let shotGenerationCutPlanSHA256: String
    public let stateLadderSHA256: String
    public let layoutPanelsSHA256: String
    public let clipPath: String
    public let clipSHA256: String
    public let container: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let durationSeconds: Double
    public let setupIDs: [String]
    public let entityStateIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case sourceMode = "source_mode"
        case cameraSetupPlanSHA256 = "camera_setup_plan_sha256"
        case shotGenerationCutPlanSHA256 = "shot_generation_cut_plan_sha256"
        case stateLadderSHA256 = "state_ladder_sha256"
        case layoutPanelsSHA256 = "layout_panels_sha256"
        case clipPath = "clip_path"
        case clipSHA256 = "clip_sha256"
        case container
        case width
        case height
        case fps
        case durationSeconds = "duration_seconds"
        case setupIDs = "setup_ids"
        case entityStateIDs = "entity_state_ids"
    }

    public init(
        projectID: String,
        sourceMode: BlockoutSourceModeV1,
        cameraSetupPlanSHA256: String,
        shotGenerationCutPlanSHA256: String,
        stateLadderSHA256: String,
        layoutPanelsSHA256: String,
        clipPath: String,
        clipSHA256: String,
        container: String,
        width: Int,
        height: Int,
        fps: Int,
        durationSeconds: Double,
        setupIDs: [String],
        entityStateIDs: [String]
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.sourceMode = sourceMode
        self.cameraSetupPlanSHA256 = cameraSetupPlanSHA256
        self.shotGenerationCutPlanSHA256 = shotGenerationCutPlanSHA256
        self.stateLadderSHA256 = stateLadderSHA256
        self.layoutPanelsSHA256 = layoutPanelsSHA256
        self.clipPath = clipPath
        self.clipSHA256 = clipSHA256
        self.container = container
        self.width = width
        self.height = height
        self.fps = fps
        self.durationSeconds = durationSeconds
        self.setupIDs = setupIDs
        self.entityStateIDs = entityStateIDs
    }
}

public enum SpatialProductionValidationErrorV1: Error, Sendable, Equatable {
    case invalidField(String)
    case duplicateID(String)
    case unknownSetup(String)
    case unknownState(String)
    case overlappingIntervals(String)
    case blockoutRequired
    case staleProof(String)
}

public enum SpatialProductionValidatorV1 {
    public static func validate(_ draft: SpatialProductionPlanDraftV1) throws {
        try require(draft.activation.rationale, "activation.rationale")
        try unique(draft.activation.axisIDs, "activation.axis_ids")
        guard !draft.activation.axisIDs.isEmpty else {
            throw SpatialProductionValidationErrorV1.invalidField("activation.axis_ids")
        }
        let setupIDs = try unique(draft.setups.map(\.id), "setups.id")
        let stateIDs = try unique(draft.states.map(\.id), "states.id")
        _ = try unique(draft.shots.map(\.shotID), "shots.shot_id")
        _ = try unique(draft.layouts.map(\.locationID), "layouts.location_id")
        _ = try unique(draft.panels.map(\.id), "panels.id")
        for setup in draft.setups {
            try require(setup.id, "setup.id")
            try require(setup.locationID, "setup.location_id")
            try require(setup.axisID, "setup.axis_id")
            try require(setup.lookTarget, "setup.look_target")
            guard Set(draft.activation.axisIDs).contains(setup.axisID) else {
                throw SpatialProductionValidationErrorV1.invalidField("setup.axis_id")
            }
            try finite(setup.position, "setup.position")
            try finite(setup.orientationDegrees, "setup.orientation_degrees")
            guard setup.heightMeters.isFinite, setup.heightMeters >= 0,
                  setup.focalLengthMM.isFinite, setup.focalLengthMM > 0,
                  setup.horizontalFOVDegrees.isFinite,
                  setup.horizontalFOVDegrees > 0, setup.horizontalFOVDegrees < 180 else {
                throw SpatialProductionValidationErrorV1.invalidField("setup.optics")
            }
            var prior = -Double.infinity
            for keyframe in setup.path {
                guard keyframe.timeSeconds.isFinite, keyframe.timeSeconds >= 0,
                      keyframe.timeSeconds > prior else {
                    throw SpatialProductionValidationErrorV1.invalidField("setup.path")
                }
                try finite(keyframe.position, "setup.path.position")
                try finite(keyframe.lookAt, "setup.path.look_at")
                prior = keyframe.timeSeconds
            }
            if setup.axisSide == .intentionalCross {
                try requireOptional(setup.deviationReason, "setup.deviation_reason")
                guard setup.deviationReason != nil else {
                    throw SpatialProductionValidationErrorV1.invalidField("setup.deviation_reason")
                }
            }
        }
        for state in draft.states {
            try require(state.id, "state.id")
            try require(state.entityID, "state.entity_id")
            try require(state.description, "state.description")
            try require(state.causeBeatID, "state.cause_beat_id")
            guard state.version > 0, (state.stateSheetPath == nil) == (state.stateSheetSHA256 == nil) else {
                throw SpatialProductionValidationErrorV1.invalidField("state")
            }
            if let hash = state.stateSheetSHA256 { try validHash(hash, "state.state_sheet_sha256") }
        }
        let grouped = Dictionary(grouping: draft.shots, by: \.generationID)
        for shot in draft.shots {
            try require(shot.shotID, "shot.shot_id")
            try require(shot.generationID, "shot.generation_id")
            guard setupIDs.contains(shot.setupID) else {
                throw SpatialProductionValidationErrorV1.unknownSetup(shot.setupID)
            }
            guard stateIDs.contains(shot.startStateID) else {
                throw SpatialProductionValidationErrorV1.unknownState(shot.startStateID)
            }
            guard stateIDs.contains(shot.endStateID) else {
                throw SpatialProductionValidationErrorV1.unknownState(shot.endStateID)
            }
            guard shot.internalStartSeconds.isFinite,
                  shot.internalEndSeconds.isFinite,
                  shot.internalStartSeconds >= 0,
                  shot.internalEndSeconds > shot.internalStartSeconds else {
                throw SpatialProductionValidationErrorV1.invalidField("shot.internal_interval")
            }
            _ = try unique(shot.continuityIn, "shot.continuity_in")
            _ = try unique(shot.continuityOut, "shot.continuity_out")
            _ = try unique(
                shot.timedReferences.map(\.demandID),
                "shot.timed_references.demand_id"
            )
            var prior = -Double.infinity
            for reference in shot.timedReferences {
                try require(reference.roleID, "shot.timed_reference.role_id")
                try require(reference.demandID, "shot.timed_reference.demand_id")
                guard reference.timeSeconds >= shot.internalStartSeconds,
                      reference.timeSeconds <= shot.internalEndSeconds,
                      reference.timeSeconds > prior else {
                    throw SpatialProductionValidationErrorV1.invalidField("shot.timed_references")
                }
                prior = reference.timeSeconds
            }
        }
        for (generationID, shots) in grouped {
            let ordered = shots.sorted { $0.internalStartSeconds < $1.internalStartSeconds }
            for pair in zip(ordered, ordered.dropFirst()) where
                pair.0.internalEndSeconds > pair.1.internalStartSeconds {
                throw SpatialProductionValidationErrorV1.overlappingIntervals(generationID)
            }
        }
        for layout in draft.layouts {
            try require(layout.locationID, "layout.location_id")
            guard layout.widthMeters > 0, layout.depthMeters > 0, layout.heightMeters > 0,
                  layout.widthMeters.isFinite, layout.depthMeters.isFinite,
                  layout.heightMeters.isFinite else {
                throw SpatialProductionValidationErrorV1.invalidField("layout.dimensions")
            }
            let declared = try unique(layout.setupIDs, "layout.setup_ids")
            guard declared.isSubset(of: setupIDs),
                  draft.setups.filter({ $0.locationID == layout.locationID })
                    .allSatisfy({ declared.contains($0.id) }) else {
                throw SpatialProductionValidationErrorV1.unknownSetup(layout.locationID)
            }
        }
        for panel in draft.panels {
            try require(panel.id, "panel.id")
            guard setupIDs.contains(panel.setupID), panel.lookFree else {
                throw SpatialProductionValidationErrorV1.invalidField("panel")
            }
            try path(panel.path, "panel.path")
            try validHash(panel.sha256, "panel.sha256")
        }
        let blockout = draft.blockout
        guard blockout.width >= 64, blockout.height >= 64, blockout.fps > 0,
              blockout.durationSeconds.isFinite, blockout.durationSeconds > 0 else {
            throw SpatialProductionValidationErrorV1.invalidField("blockout")
        }
        if draft.activation.requiresBlockout, blockout.mode == .none {
            throw SpatialProductionValidationErrorV1.blockoutRequired
        }
        if blockout.mode == .imported {
            guard let imported = blockout.importedClipPath else {
                throw SpatialProductionValidationErrorV1.invalidField("blockout.imported_clip_path")
            }
            try path(imported, "blockout.imported_clip_path")
        } else if blockout.importedClipPath != nil {
            throw SpatialProductionValidationErrorV1.invalidField("blockout.imported_clip_path")
        }
    }

    public static func validate(
        proof: BlockoutProofV1,
        cameraSetupPlanData: Data,
        shotGenerationCutPlanData: Data,
        stateLadderData: Data,
        layoutPanelsData: Data,
        dataRoot: URL
    ) throws {
        guard proof.schema == BlockoutProofV1.schemaVersion,
              proof.sourceMode != .none,
              proof.cameraSetupPlanSHA256 == FileDigest.sha256(of: cameraSetupPlanData),
              proof.shotGenerationCutPlanSHA256 == FileDigest.sha256(of: shotGenerationCutPlanData),
              proof.stateLadderSHA256 == FileDigest.sha256(of: stateLadderData),
              proof.layoutPanelsSHA256 == FileDigest.sha256(of: layoutPanelsData),
              proof.width >= 64, proof.height >= 64, proof.fps > 0,
              proof.durationSeconds > 0, proof.container == "quicktime" else {
            throw SpatialProductionValidationErrorV1.staleProof("plan")
        }
        try path(proof.clipPath, "proof.clip_path")
        _ = try ProjectLocalFile.requireHash(
            proof.clipSHA256,
            at: proof.clipPath,
            dataRoot: dataRoot
        )
    }

    private static func unique(_ values: [String], _ field: String) throws -> Set<String> {
        for value in values { try require(value, field) }
        let result = Set(values)
        guard result.count == values.count else {
            throw SpatialProductionValidationErrorV1.duplicateID(field)
        }
        return result
    }

    private static func finite(_ value: SpatialVector3V1, _ field: String) throws {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
            throw SpatialProductionValidationErrorV1.invalidField(field)
        }
    }

    private static func require(_ value: String, _ field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpatialProductionValidationErrorV1.invalidField(field)
        }
    }

    private static func requireOptional(_ value: String?, _ field: String) throws {
        if let value { try require(value, field) }
    }

    private static func path(_ value: String, _ field: String) throws {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("..") else {
            throw SpatialProductionValidationErrorV1.invalidField(field)
        }
    }

    private static func validHash(_ value: String, _ field: String) throws {
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else {
            throw SpatialProductionValidationErrorV1.invalidField(field)
        }
    }
}
