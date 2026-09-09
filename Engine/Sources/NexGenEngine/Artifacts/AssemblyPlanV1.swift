import Foundation

public enum SelectedShotMediaKindV1: String, Codable, Sendable, Equatable {
    case generatedTake = "generated_take"
    case importedSource = "imported_source"
    case reviewedTakeRange = "reviewed_take_range"
    case timelineAnimatedStill = "timeline_animated_still"
}

public struct SelectedShotMediaV1: Codable, Sendable, Equatable {
    public let shotID: String
    public let sourceKind: SelectedShotMediaKindV1
    public let sourcePath: String
    public let sourceSHA256: String
    public let sourceByteCount: Int64
    public let sourceFPS: Int
    public let sourceStartFrame: Int
    public let sourceEndFrame: Int
    public let takeID: String?
    public let reviewPath: String?
    public let reviewSHA256: String?

    private enum CodingKeys: String, CodingKey {
        case shotID = "shot_id"
        case sourceKind = "source_kind"
        case sourcePath = "source_path"
        case sourceSHA256 = "source_sha256"
        case sourceByteCount = "source_byte_count"
        case sourceFPS = "source_fps"
        case sourceStartFrame = "source_start_frame"
        case sourceEndFrame = "source_end_frame"
        case takeID = "take_id"
        case reviewPath = "review_path"
        case reviewSHA256 = "review_sha256"
    }

    public init(
        shotID: String,
        sourceKind: SelectedShotMediaKindV1,
        sourcePath: String,
        sourceSHA256: String,
        sourceByteCount: Int64,
        sourceFPS: Int,
        sourceStartFrame: Int,
        sourceEndFrame: Int,
        takeID: String? = nil,
        reviewPath: String? = nil,
        reviewSHA256: String? = nil
    ) {
        self.shotID = shotID
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.sourceSHA256 = sourceSHA256
        self.sourceByteCount = sourceByteCount
        self.sourceFPS = sourceFPS
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.takeID = takeID
        self.reviewPath = reviewPath
        self.reviewSHA256 = reviewSHA256
    }
}

public enum AssemblyTransitionKindV1: String, Codable, Sendable, Equatable {
    case cut
    case dissolve
    case fade
}

public struct AssemblyTransitionV1: Codable, Sendable, Equatable {
    public let kind: AssemblyTransitionKindV1
    public let durationFrames: Int

    private enum CodingKeys: String, CodingKey {
        case kind
        case durationFrames = "duration_frames"
    }

    public init(kind: AssemblyTransitionKindV1, durationFrames: Int = 0) {
        self.kind = kind
        self.durationFrames = durationFrames
    }
}

public struct AssemblyPlacementV1: Codable, Sendable, Equatable {
    public let shotID: String
    public let trackID: String
    public let timelineStartFrame: Int
    public let sourceStartFrame: Int
    public let sourceEndFrame: Int
    public let transitionIn: AssemblyTransitionV1

    private enum CodingKeys: String, CodingKey {
        case shotID = "shot_id"
        case trackID = "track_id"
        case timelineStartFrame = "timeline_start_frame"
        case sourceStartFrame = "source_start_frame"
        case sourceEndFrame = "source_end_frame"
        case transitionIn = "transition_in"
    }

    public init(
        shotID: String,
        trackID: String,
        timelineStartFrame: Int,
        sourceStartFrame: Int,
        sourceEndFrame: Int,
        transitionIn: AssemblyTransitionV1 = .init(kind: .cut)
    ) {
        self.shotID = shotID
        self.trackID = trackID
        self.timelineStartFrame = timelineStartFrame
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.transitionIn = transitionIn
    }
}

public enum AssemblyTimingPolicyKindV1: String, Codable, Sendable, Equatable {
    case freeform
    case musicSync = "music_sync"
}

public struct AssemblyPolicyV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "assembly-policy/v1"
    public let schema: String
    public let id: String
    public let version: String
    public let timing: AssemblyTimingPolicyKindV1
    public let timelineFPS: Int
    public let requiredDurationFrames: Int?
    public let anchorAudioAtFrameZero: Bool
    public let snapToleranceFrames: Int

    private enum CodingKeys: String, CodingKey {
        case schema, id, version, timing
        case timelineFPS = "timeline_fps"
        case requiredDurationFrames = "required_duration_frames"
        case anchorAudioAtFrameZero = "anchor_audio_at_frame_zero"
        case snapToleranceFrames = "snap_tolerance_frames"
    }

    public init(
        id: String,
        version: String,
        timing: AssemblyTimingPolicyKindV1,
        timelineFPS: Int,
        requiredDurationFrames: Int? = nil,
        anchorAudioAtFrameZero: Bool = false,
        snapToleranceFrames: Int = 0
    ) {
        schema = Self.schemaVersion
        self.id = id
        self.version = version
        self.timing = timing
        self.timelineFPS = timelineFPS
        self.requiredDurationFrames = requiredDurationFrames
        self.anchorAudioAtFrameZero = anchorAudioAtFrameZero
        self.snapToleranceFrames = snapToleranceFrames
    }
}

public struct AssemblyPlanV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "assembly-plan/v1"
    public static let relativePath = "assembly/plan.v1.json"
    public let schema: String
    public let projectID: String
    public let phase: String
    public let selectedMedia: [SelectedShotMediaV1]
    public let placements: [AssemblyPlacementV1]
    public let existingRegionFingerprint: String?
    public let policyPath: String
    public let policySHA256: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case phase
        case selectedMedia = "selected_media"
        case placements
        case existingRegionFingerprint = "existing_region_fingerprint"
        case policyPath = "policy_path"
        case policySHA256 = "policy_sha256"
    }

    public init(
        projectID: String,
        phase: String,
        selectedMedia: [SelectedShotMediaV1],
        placements: [AssemblyPlacementV1],
        existingRegionFingerprint: String?,
        policyPath: String,
        policySHA256: String
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.phase = phase
        self.selectedMedia = selectedMedia
        self.placements = placements
        self.existingRegionFingerprint = existingRegionFingerprint
        self.policyPath = policyPath
        self.policySHA256 = policySHA256
    }
}

public struct AssemblyAppliedPlacementV1: Codable, Sendable, Equatable {
    public let selected: SelectedShotMediaV1
    public let placement: AssemblyPlacementV1
    public let clipIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case selected, placement
        case clipIDs = "clip_ids"
    }

    public init(selected: SelectedShotMediaV1, placement: AssemblyPlacementV1, clipIDs: [String]) {
        self.selected = selected
        self.placement = placement
        self.clipIDs = clipIDs
    }
}

public struct AssemblyManifestV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "assembly-manifest/v1"
    public static let relativePath = "assembly/manifest.v1.json"
    public let schema: String
    public let projectID: String
    public let phase: String
    public let planSHA256: String
    public let policyID: String
    public let policyVersion: String
    public let policySHA256: String
    public let priorRegionFingerprint: String?
    public let appliedRegionFingerprint: String
    public let timelineFingerprint: String
    public let idempotencyKey: String
    public let placements: [AssemblyAppliedPlacementV1]
    public let deviations: [String]
    public let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case phase
        case planSHA256 = "plan_sha256"
        case policyID = "policy_id"
        case policyVersion = "policy_version"
        case policySHA256 = "policy_sha256"
        case priorRegionFingerprint = "prior_region_fingerprint"
        case appliedRegionFingerprint = "applied_region_fingerprint"
        case timelineFingerprint = "timeline_fingerprint"
        case idempotencyKey = "idempotency_key"
        case placements, deviations, warnings
    }

    public init(
        projectID: String,
        phase: String,
        planSHA256: String,
        policyID: String,
        policyVersion: String,
        policySHA256: String,
        priorRegionFingerprint: String?,
        appliedRegionFingerprint: String,
        timelineFingerprint: String,
        idempotencyKey: String,
        placements: [AssemblyAppliedPlacementV1],
        deviations: [String] = [],
        warnings: [String] = []
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.phase = phase
        self.planSHA256 = planSHA256
        self.policyID = policyID
        self.policyVersion = policyVersion
        self.policySHA256 = policySHA256
        self.priorRegionFingerprint = priorRegionFingerprint
        self.appliedRegionFingerprint = appliedRegionFingerprint
        self.timelineFingerprint = timelineFingerprint
        self.idempotencyKey = idempotencyKey
        self.placements = placements
        self.deviations = deviations
        self.warnings = warnings
    }
}

public enum AssemblyValidationErrorV1: Error, Sendable, Equatable {
    case invalidIdentity
    case invalidPolicy
    case invalidSelection(String)
    case invalidPlacement(String)
    case missingSelection(String)
    case policyMismatch
    case manifestMismatch
}

public enum AssemblyValidatorV1 {
    public static func validate(policy: AssemblyPolicyV1) throws {
        guard policy.schema == AssemblyPolicyV1.schemaVersion,
              text(policy.id), text(policy.version), policy.timelineFPS > 0,
              policy.snapToleranceFrames >= 0,
              policy.requiredDurationFrames.map({ $0 > 0 }) ?? true,
              policy.timing == .musicSync || !policy.anchorAudioAtFrameZero else {
            throw AssemblyValidationErrorV1.invalidPolicy
        }
    }

    public static func validate(plan: AssemblyPlanV1, policy: AssemblyPolicyV1) throws {
        try validate(policy: policy)
        guard plan.schema == AssemblyPlanV1.schemaVersion,
              text(plan.projectID), text(plan.phase), !plan.selectedMedia.isEmpty,
              plan.selectedMedia.map(\.shotID) == plan.placements.map(\.shotID),
              Set(plan.selectedMedia.map(\.shotID)).count == plan.selectedMedia.count,
              digest(plan.policySHA256), text(plan.policyPath) else {
            throw AssemblyValidationErrorV1.invalidIdentity
        }
        for selected in plan.selectedMedia { try validate(selected: selected) }
        let selectedByShot = Dictionary(uniqueKeysWithValues: plan.selectedMedia.map { ($0.shotID, $0) })
        for placement in plan.placements {
            guard let selected = selectedByShot[placement.shotID] else {
                throw AssemblyValidationErrorV1.missingSelection(placement.shotID)
            }
            let duration = placement.sourceEndFrame - placement.sourceStartFrame
            guard text(placement.trackID), placement.timelineStartFrame >= 0,
                  placement.sourceStartFrame == selected.sourceStartFrame,
                  placement.sourceEndFrame == selected.sourceEndFrame,
                  duration > 0,
                  placement.transitionIn.durationFrames >= 0,
                  placement.transitionIn.durationFrames < duration,
                  placement.transitionIn.kind != .cut || placement.transitionIn.durationFrames == 0 else {
                throw AssemblyValidationErrorV1.invalidPlacement(placement.shotID)
            }
        }
        let sorted = plan.placements.sorted { ($0.trackID, $0.timelineStartFrame) < ($1.trackID, $1.timelineStartFrame) }
        for pair in zip(sorted, sorted.dropFirst()) where pair.0.trackID == pair.1.trackID {
            let firstEnd = pair.0.timelineStartFrame + pair.0.sourceEndFrame - pair.0.sourceStartFrame
            guard pair.1.timelineStartFrame + pair.1.transitionIn.durationFrames >= firstEnd else {
                throw AssemblyValidationErrorV1.invalidPlacement(pair.1.shotID)
            }
        }
        if let required = policy.requiredDurationFrames {
            let end = plan.placements.map { $0.timelineStartFrame + $0.sourceEndFrame - $0.sourceStartFrame }.max() ?? 0
            guard end == required else { throw AssemblyValidationErrorV1.policyMismatch }
        }
    }

    public static func validate(
        manifest: AssemblyManifestV1,
        plan: AssemblyPlanV1,
        planSHA256: String,
        policy: AssemblyPolicyV1
    ) throws {
        try validate(plan: plan, policy: policy)
        guard manifest.schema == AssemblyManifestV1.schemaVersion,
              manifest.projectID == plan.projectID, manifest.phase == plan.phase,
              manifest.planSHA256 == planSHA256, digest(manifest.planSHA256),
              manifest.policyID == policy.id, manifest.policyVersion == policy.version,
              manifest.policySHA256 == plan.policySHA256,
              manifest.priorRegionFingerprint == plan.existingRegionFingerprint,
              digest(manifest.appliedRegionFingerprint),
              digest(manifest.timelineFingerprint), digest(manifest.idempotencyKey),
              manifest.placements.map(\.selected) == plan.selectedMedia,
              manifest.placements.map(\.placement) == plan.placements,
              manifest.placements.allSatisfy({ !$0.clipIDs.isEmpty && Set($0.clipIDs).count == $0.clipIDs.count }) else {
            throw AssemblyValidationErrorV1.manifestMismatch
        }
    }

    private static func validate(selected: SelectedShotMediaV1) throws {
        let reviewBinding = selected.reviewPath != nil || selected.reviewSHA256 != nil
        guard text(selected.shotID), text(selected.sourcePath), digest(selected.sourceSHA256),
              selected.sourceByteCount > 0, selected.sourceFPS > 0,
              selected.sourceStartFrame >= 0, selected.sourceEndFrame > selected.sourceStartFrame,
              selected.takeID.map(text) ?? true,
              selected.reviewPath.map(text) ?? true,
              selected.reviewSHA256.map(digest) ?? true else {
            throw AssemblyValidationErrorV1.invalidSelection(selected.shotID)
        }
        switch selected.sourceKind {
        case .generatedTake:
            guard selected.takeID != nil, selected.reviewPath != nil,
                  selected.reviewSHA256 != nil else {
                throw AssemblyValidationErrorV1.invalidSelection(selected.shotID)
            }
        case .reviewedTakeRange:
            guard selected.takeID != nil, selected.reviewPath != nil, selected.reviewSHA256 != nil else {
                throw AssemblyValidationErrorV1.invalidSelection(selected.shotID)
            }
        case .importedSource, .timelineAnimatedStill:
            guard selected.takeID == nil, !reviewBinding else {
                throw AssemblyValidationErrorV1.invalidSelection(selected.shotID)
            }
        }
    }

    private static func text(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func digest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
