import Foundation

public struct ShotPlanningDraftV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "shot-planning-draft/v1"
    public static let currentPath = "shot-planning/current.v1.json"

    public struct Obligation: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case characterIdentity, locationAppearance, prop, look, geometry, sourceFootage, stateVariant
        }

        public let id: String
        public let kind: Kind
        public let subject: String
        public let requirement: String
        public let required: Bool
        public let allowedSkipReason: String?

        public init(id: String, kind: Kind, subject: String, requirement: String, required: Bool, allowedSkipReason: String? = nil) {
            self.id = id
            self.kind = kind
            self.subject = subject
            self.requirement = requirement
            self.required = required
            self.allowedSkipReason = allowedSkipReason
        }
    }

    public struct CameraIntent: Codable, Sendable, Equatable {
        public let framing: StoryboardTimingV1.FramingIntent
        public let movement: CameraMovement
        public let movementDetail: String?
        public let blocking: [String]
        public let sceneReference: CanonicalArtifactReferenceV1?
        public let spatialState: CanonicalArtifactReferenceV1?
        public let spatialCameraID: String?
        public let spatialDerivation: CanonicalArtifactReferenceV1?
        public let blockingReference: CanonicalArtifactReferenceV1?

        public init(framing: StoryboardTimingV1.FramingIntent, movement: CameraMovement,
                    movementDetail: String? = nil, blocking: [String] = [], sceneReference: CanonicalArtifactReferenceV1? = nil,
                    spatialState: CanonicalArtifactReferenceV1? = nil, spatialCameraID: String? = nil,
                    spatialDerivation: CanonicalArtifactReferenceV1? = nil, blockingReference: CanonicalArtifactReferenceV1? = nil) {
            self.framing = framing
            self.movement = movement
            self.movementDetail = movementDetail
            self.blocking = blocking
            self.sceneReference = sceneReference
            self.spatialState = spatialState
            self.spatialCameraID = spatialCameraID
            self.spatialDerivation = spatialDerivation
            self.blockingReference = blockingReference
        }
    }

    public struct ShotIntent: Codable, Sendable, Equatable {
        public enum ChainKind: String, Codable, Sendable { case none, frameContinuation, nativeExtension }

        public let shotID: String
        public let sourceMode: SourceMode
        public let source: CanonicalArtifactReferenceV1?
        public let sourceObligationID: String?
        public let camera: CameraIntent
        public let obligations: [Obligation]
        public let chainKind: ChainKind
        public let predecessorShotID: String?
        public let narrativeBeat: NarrativeBeat?
        public let sourceInputRange: SourceFootageRangeV1?

        public init(shotID: String, sourceMode: SourceMode, source: CanonicalArtifactReferenceV1? = nil,
                    sourceObligationID: String? = nil, camera: CameraIntent, obligations: [Obligation],
                    chainKind: ChainKind = .none, predecessorShotID: String? = nil, narrativeBeat: NarrativeBeat? = nil,
                    sourceInputRange: SourceFootageRangeV1? = nil) {
            self.shotID = shotID
            self.sourceMode = sourceMode
            self.source = source
            self.sourceObligationID = sourceObligationID
            self.camera = camera
            self.obligations = obligations
            self.chainKind = chainKind
            self.predecessorShotID = predecessorShotID
            self.narrativeBeat = narrativeBeat
            self.sourceInputRange = sourceInputRange
        }
    }

    public let schema: String
    public let header: PlanningArtifactHeaderV1
    public let storyboardRevision: Int
    public let shots: [ShotIntent]

    public init(schema: String = schemaVersion, header: PlanningArtifactHeaderV1, storyboardRevision: Int, shots: [ShotIntent]) {
        self.schema = schema
        self.header = header
        self.storyboardRevision = storyboardRevision
        self.shots = shots
    }

    public static func versionPath(_ revision: Int) -> String { "shot-planning/v\(revision).v1.json" }
}

public enum ShotPlanningValidatorV1 {
    public static func validate(_ value: ShotPlanningDraftV1, timing: StoryboardTimingV1) throws {
        try validate(value, timing: timing, approval: false)
    }

    public static func validate(_ value: ShotPlanningDraftV1, timing: StoryboardTimingV1, approval: Bool) throws {
        try PlanningValidation.require(value.schema == ShotPlanningDraftV1.schemaVersion, "shotPlanning.schema")
        try value.header.validate()
        try PlanningValidation.require(value.header.projectID == timing.header.projectID
            && value.storyboardRevision == timing.header.revision, "shotPlanning.storyboardBinding")
        try PlanningValidation.unique(value.shots.map(\.shotID), "shotPlanning.shotIDs")
        try PlanningValidation.unique(timing.shots.map(\.id), "storyboard.shotIDs")
        try PlanningValidation.require(value.shots.map(\.shotID) == timing.shots.map(\.id), "shotPlanning.shotCoverage")
        let known = Dictionary(uniqueKeysWithValues: timing.shots.map { ($0.id, $0) })
        let intents = Dictionary(uniqueKeysWithValues: value.shots.map { ($0.shotID, $0) })
        for shot in value.shots {
            try PlanningValidation.shotID(shot.shotID)
            try PlanningValidation.require(shot.camera.framing == known[shot.shotID]?.framing, "shotPlanning.sketchFraming")
            if shot.camera.movement == .other {
                try PlanningValidation.text(shot.camera.movementDetail ?? "", "shotPlanning.camera.movementDetail")
            }
            for blocking in shot.camera.blocking { try PlanningValidation.text(blocking, "shotPlanning.camera.blocking") }
            if let scene = shot.camera.sceneReference { try PlanningValidation.reference(scene) }
            try PlanningValidation.require((shot.camera.spatialState == nil) == (shot.camera.spatialCameraID == nil), "shotPlanning.spatialStatePair")
            if let state = shot.camera.spatialState, let cameraID = shot.camera.spatialCameraID {
                try PlanningValidation.reference(state)
                try PlanningValidation.identifier(cameraID, "shotPlanning.spatialCameraID")
                try PlanningValidation.require(shot.camera.sceneReference != nil && value.header.inputs.contains { $0.path == state.path && $0.sha256 == state.sha256 }, "shotPlanning.spatialStateBinding")
                if let scene = shot.camera.sceneReference {
                    try PlanningValidation.require(value.header.inputs.contains { $0.path == scene.path && $0.sha256 == scene.sha256 }, "shotPlanning.spatialSceneBinding")
                }
            }
            if let derivation = shot.camera.spatialDerivation {
                try PlanningValidation.reference(derivation)
                try PlanningValidation.require(shot.camera.spatialState != nil && shot.camera.spatialCameraID != nil
                    && shot.camera.sceneReference != nil
                    && value.header.inputs.contains { $0.path == derivation.path && $0.sha256 == derivation.sha256 },
                                               "shotPlanning.spatialDerivationBinding")
            }
            if let blockout = shot.camera.blockingReference {
                try PlanningValidation.reference(blockout)
                try PlanningValidation.require(shot.camera.spatialState != nil && shot.camera.sceneReference != nil && shot.camera.spatialCameraID != nil
                    && value.header.inputs.contains { $0.path == blockout.path && $0.sha256 == blockout.sha256 }, "shotPlanning.blockingReferenceBinding")
            }
            try PlanningValidation.unique(shot.obligations.map(\.id), "shotPlanning.obligationIDs")
            for obligation in shot.obligations {
                try PlanningValidation.identifier(obligation.id, "shotPlanning.obligation.id")
                try PlanningValidation.text(obligation.subject, "shotPlanning.obligation.subject")
                try PlanningValidation.text(obligation.requirement, "shotPlanning.obligation.requirement")
                if obligation.required {
                    try PlanningValidation.require(obligation.allowedSkipReason == nil, "shotPlanning.obligation.requiredSkip")
                } else {
                    try PlanningValidation.text(obligation.allowedSkipReason ?? "", "shotPlanning.obligation.skipAlternative")
                }
            }
            if let source = shot.source {
                try PlanningValidation.reference(source)
                try PlanningValidation.require(value.header.inputs.contains { $0.path == source.path && $0.sha256 == source.sha256 }, "shotPlanning.sourceBinding")
            }
            if let range = shot.sourceInputRange {
                try range.validate()
                try PlanningValidation.require(shot.sourceMode != .generated && range.source == shot.source,
                                               "shotPlanning.sourceInputRange")
            }
            if approval, shot.source != nil {
                guard let range = shot.sourceInputRange else { throw ProductionPlanningError.invalid("shotPlanning.nativeSourceRangeRequired") }
                if shot.sourceMode == .imported {
                    try PlanningValidation.require(range.timebase.representsSameTime(range.durationTicks,
                        as: known[shot.shotID]?.durationTicks ?? 0, timebase: timing.timebase), "shotPlanning.importedRangeMustMatchShotDuration")
                }
            }
            if shot.sourceMode == .generated {
                try PlanningValidation.require(shot.source == nil && shot.sourceObligationID == nil, "shotPlanning.generatedSource")
            } else {
                try PlanningValidation.require(shot.chainKind == .none && shot.predecessorShotID == nil, "shotPlanning.sourceChain")
                try PlanningValidation.require((shot.source == nil) != (shot.sourceObligationID == nil), "shotPlanning.sourceChoice")
                if let requirement = shot.sourceObligationID {
                    try PlanningValidation.require(shot.obligations.contains {
                        $0.id == requirement && $0.kind == .sourceFootage && $0.required
                    }, "shotPlanning.sourceObligation")
                }
            }
            if shot.chainKind == .none {
                try PlanningValidation.require(shot.predecessorShotID == nil, "shotPlanning.noChain")
            } else {
                guard let predecessor = shot.predecessorShotID, predecessor != shot.shotID,
                      intents[predecessor] != nil else {
                    throw ProductionPlanningError.invalid("shotPlanning.predecessor")
                }
                try PlanningValidation.require(shot.sourceMode == .generated
                    && intents[predecessor]?.sourceMode == .generated, "shotPlanning.chainSourceMode")
            }
        }
        for shot in value.shots {
            var visited = Set<String>()
            var cursor: String? = shot.shotID
            while let id = cursor {
                try PlanningValidation.require(visited.insert(id).inserted, "shotPlanning.chainCycle")
                cursor = intents[id]?.predecessorShotID
            }
        }
    }
}
