import Foundation

public struct ReviewReelEDLEntryV1: Codable, Sendable, Equatable {
    public let shotID: String
    public let sourcePath: String
    public let sourceSHA256: String
    public let sourceStartFrame: Int
    public let sourceEndFrame: Int
    public let reelStartFrame: Int
    public let reelEndFrame: Int
    public let transitionIn: AssemblyTransitionV1

    private enum CodingKeys: String, CodingKey {
        case shotID = "shot_id"
        case sourcePath = "source_path"
        case sourceSHA256 = "source_sha256"
        case sourceStartFrame = "source_start_frame"
        case sourceEndFrame = "source_end_frame"
        case reelStartFrame = "reel_start_frame"
        case reelEndFrame = "reel_end_frame"
        case transitionIn = "transition_in"
    }

    public init(
        shotID: String,
        sourcePath: String,
        sourceSHA256: String,
        sourceStartFrame: Int,
        sourceEndFrame: Int,
        reelStartFrame: Int,
        reelEndFrame: Int,
        transitionIn: AssemblyTransitionV1
    ) {
        self.shotID = shotID
        self.sourcePath = sourcePath
        self.sourceSHA256 = sourceSHA256
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.reelStartFrame = reelStartFrame
        self.reelEndFrame = reelEndFrame
        self.transitionIn = transitionIn
    }
}

public struct ReviewReelV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "review-reel/v1"
    public let schema: String
    public let path: String
    public let sha256: String
    public let byteCount: Int64
    public let fps: Int
    public let durationFrames: Int
    public let edlPath: String
    public let edlSHA256: String
    public let entries: [ReviewReelEDLEntryV1]

    private enum CodingKeys: String, CodingKey {
        case schema, path, sha256
        case byteCount = "byte_count"
        case fps
        case durationFrames = "duration_frames"
        case edlPath = "edl_path"
        case edlSHA256 = "edl_sha256"
        case entries
    }

    public init(
        path: String,
        sha256: String,
        byteCount: Int64,
        fps: Int,
        durationFrames: Int,
        edlPath: String,
        edlSHA256: String,
        entries: [ReviewReelEDLEntryV1]
    ) {
        schema = Self.schemaVersion
        self.path = path
        self.sha256 = sha256
        self.byteCount = byteCount
        self.fps = fps
        self.durationFrames = durationFrames
        self.edlPath = edlPath
        self.edlSHA256 = edlSHA256
        self.entries = entries
    }
}

public enum SequenceReviewScopeV1: String, Codable, Sendable, Equatable {
    case adjacentPair = "adjacent_pair"
    case wholePlayback = "whole_playback"
}

public enum SequenceReviewCategoryV1: String, Codable, Sendable, Equatable, CaseIterable {
    case identity
    case stateAndProps = "state_and_props"
    case geographyAndScreenDirection = "geography_and_screen_direction"
    case actionAndTransition = "action_and_transition"
    case timingAndPacing = "timing_and_pacing"
    case camera
    case visualArtifact = "visual_artifact"
    case audio
}

public enum SequenceReviewSeverityV1: String, Codable, Sendable, Equatable {
    case info, warning, blocking
}

public enum SequenceReviewActionV1: String, Codable, Sendable, Equatable {
    case accept
    case localRepair = "local_repair"
    case reroll
    case rescue
    case rewind
}

public enum SequenceReviewerKindV1: String, Codable, Sendable, Equatable {
    case deterministicEngine = "deterministic_engine"
    case nativeUser = "native_user"
    case model
}

public struct SequenceReviewerProvenanceV1: Codable, Sendable, Equatable {
    public let kind: SequenceReviewerKindV1
    public let reviewerID: String
    public let modelID: String?
    public let promptPath: String?
    public let promptSHA256: String?
    public let responsePath: String?
    public let responseSHA256: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case reviewerID = "reviewer_id"
        case modelID = "model_id"
        case promptPath = "prompt_path"
        case promptSHA256 = "prompt_sha256"
        case responsePath = "response_path"
        case responseSHA256 = "response_sha256"
    }

    public init(
        kind: SequenceReviewerKindV1,
        reviewerID: String,
        modelID: String? = nil,
        promptPath: String? = nil,
        promptSHA256: String? = nil,
        responsePath: String? = nil,
        responseSHA256: String? = nil
    ) {
        self.kind = kind
        self.reviewerID = reviewerID
        self.modelID = modelID
        self.promptPath = promptPath
        self.promptSHA256 = promptSHA256
        self.responsePath = responsePath
        self.responseSHA256 = responseSHA256
    }
}

public struct SequenceReviewFindingV1: Codable, Sendable, Equatable {
    public let id: String
    public let scope: SequenceReviewScopeV1
    public let category: SequenceReviewCategoryV1
    public let severity: SequenceReviewSeverityV1
    public let shotIDs: [String]
    public let startFrame: Int
    public let endFrame: Int
    public let evidence: String
    public let recommendedAction: SequenceReviewActionV1
    public let provenance: SequenceReviewerProvenanceV1

    private enum CodingKeys: String, CodingKey {
        case id, scope, category, severity
        case shotIDs = "shot_ids"
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case evidence
        case recommendedAction = "recommended_action"
        case provenance
    }

    public init(
        id: String,
        scope: SequenceReviewScopeV1,
        category: SequenceReviewCategoryV1,
        severity: SequenceReviewSeverityV1,
        shotIDs: [String],
        startFrame: Int,
        endFrame: Int,
        evidence: String,
        recommendedAction: SequenceReviewActionV1,
        provenance: SequenceReviewerProvenanceV1
    ) {
        self.id = id
        self.scope = scope
        self.category = category
        self.severity = severity
        self.shotIDs = shotIDs
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.evidence = evidence
        self.recommendedAction = recommendedAction
        self.provenance = provenance
    }
}

public struct SequenceReviewV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "sequence-review/v1"
    public static let relativePath = "reviews/sequence/current.v1.json"
    public let schema: String
    public let projectID: String
    public let selectedMedia: [SelectedShotMediaV1]
    public let reviewReel: ReviewReelV1
    public let executionPlanSHA256: String
    public let canonSHA256: String
    public let referencePlanSHA256: String
    public let adjacentPairCompleted: Bool
    public let wholePlaybackCompleted: Bool
    public let findings: [SequenceReviewFindingV1]
    public let reviewedAt: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case selectedMedia = "selected_media"
        case reviewReel = "review_reel"
        case executionPlanSHA256 = "execution_plan_sha256"
        case canonSHA256 = "canon_sha256"
        case referencePlanSHA256 = "reference_plan_sha256"
        case adjacentPairCompleted = "adjacent_pair_completed"
        case wholePlaybackCompleted = "whole_playback_completed"
        case findings
        case reviewedAt = "reviewed_at"
    }

    public init(
        projectID: String,
        selectedMedia: [SelectedShotMediaV1],
        reviewReel: ReviewReelV1,
        executionPlanSHA256: String,
        canonSHA256: String,
        referencePlanSHA256: String,
        adjacentPairCompleted: Bool,
        wholePlaybackCompleted: Bool,
        findings: [SequenceReviewFindingV1],
        reviewedAt: String
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.selectedMedia = selectedMedia
        self.reviewReel = reviewReel
        self.executionPlanSHA256 = executionPlanSHA256
        self.canonSHA256 = canonSHA256
        self.referencePlanSHA256 = referencePlanSHA256
        self.adjacentPairCompleted = adjacentPairCompleted
        self.wholePlaybackCompleted = wholePlaybackCompleted
        self.findings = findings
        self.reviewedAt = reviewedAt
    }
}

public enum SequenceReviewValidationErrorV1: Error, Sendable, Equatable {
    case invalidIdentity
    case staleSelection
    case invalidReel
    case incompleteReview
    case fabricatedDeterministicFinding(String)
    case invalidFinding(String)
}

public enum SequenceReviewValidatorV1 {
    public static func validate(
        _ review: SequenceReviewV1,
        selectedMedia: [SelectedShotMediaV1],
        executionPlanSHA256: String,
        canonSHA256: String,
        referencePlanSHA256: String
    ) throws {
        guard review.schema == SequenceReviewV1.schemaVersion,
              !review.projectID.isEmpty,
              digest(review.executionPlanSHA256), digest(review.canonSHA256),
              digest(review.referencePlanSHA256), !review.reviewedAt.isEmpty else {
            throw SequenceReviewValidationErrorV1.invalidIdentity
        }
        guard review.selectedMedia == selectedMedia,
              review.executionPlanSHA256 == executionPlanSHA256,
              review.canonSHA256 == canonSHA256,
              review.referencePlanSHA256 == referencePlanSHA256 else {
            throw SequenceReviewValidationErrorV1.staleSelection
        }
        try validate(reel: review.reviewReel, selectedMedia: selectedMedia)
        guard review.adjacentPairCompleted, review.wholePlaybackCompleted else {
            throw SequenceReviewValidationErrorV1.incompleteReview
        }
        let selectedIDs = Set(selectedMedia.map(\.shotID))
        guard Set(review.findings.map(\.id)).count == review.findings.count else {
            throw SequenceReviewValidationErrorV1.invalidIdentity
        }
        for finding in review.findings {
            guard !finding.id.isEmpty, !finding.shotIDs.isEmpty,
                  Set(finding.shotIDs).isSubset(of: selectedIDs),
                  finding.startFrame >= 0, finding.endFrame > finding.startFrame,
                  finding.endFrame <= review.reviewReel.durationFrames,
                  !finding.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !finding.provenance.reviewerID.isEmpty else {
                throw SequenceReviewValidationErrorV1.invalidFinding(finding.id)
            }
            try validate(provenance: finding.provenance)
            if finding.provenance.kind == .deterministicEngine,
               ![.timingAndPacing, .audio].contains(finding.category) {
                throw SequenceReviewValidationErrorV1.fabricatedDeterministicFinding(finding.id)
            }
        }
    }

    public static func validate(reel: ReviewReelV1, selectedMedia: [SelectedShotMediaV1]) throws {
        guard reel.schema == ReviewReelV1.schemaVersion,
              !reel.path.isEmpty, digest(reel.sha256), reel.byteCount > 0,
              reel.fps > 0, reel.durationFrames > 0,
              !reel.edlPath.isEmpty, digest(reel.edlSHA256),
              reel.entries.map(\.shotID) == selectedMedia.map(\.shotID) else {
            throw SequenceReviewValidationErrorV1.invalidReel
        }
        var expectedStart = 0
        for (entry, selected) in zip(reel.entries, selectedMedia) {
            guard entry.shotID == selected.shotID,
                  entry.sourcePath == selected.sourcePath,
                  entry.sourceSHA256 == selected.sourceSHA256,
                  entry.sourceStartFrame == selected.sourceStartFrame,
                  entry.sourceEndFrame == selected.sourceEndFrame,
                  entry.reelStartFrame == expectedStart,
                  entry.reelEndFrame > entry.reelStartFrame,
                  entry.reelEndFrame - entry.reelStartFrame == entry.sourceEndFrame - entry.sourceStartFrame else {
                throw SequenceReviewValidationErrorV1.invalidReel
            }
            expectedStart = entry.reelEndFrame
        }
        guard expectedStart == reel.durationFrames else {
            throw SequenceReviewValidationErrorV1.invalidReel
        }
    }

    private static func validate(provenance: SequenceReviewerProvenanceV1) throws {
        let hasPrompt = provenance.promptPath != nil || provenance.promptSHA256 != nil
        let hasResponse = provenance.responsePath != nil || provenance.responseSHA256 != nil
        let validBindings = (provenance.promptPath.map({ !$0.isEmpty }) ?? true)
            && (provenance.promptSHA256.map(digest) ?? true)
            && (provenance.responsePath.map({ !$0.isEmpty }) ?? true)
            && (provenance.responseSHA256.map(digest) ?? true)
        guard validBindings else { throw SequenceReviewValidationErrorV1.invalidIdentity }
        switch provenance.kind {
        case .model:
            guard provenance.modelID?.isEmpty == false,
                  provenance.promptPath != nil, provenance.promptSHA256 != nil,
                  provenance.responsePath != nil, provenance.responseSHA256 != nil else {
                throw SequenceReviewValidationErrorV1.invalidIdentity
            }
        case .deterministicEngine, .nativeUser:
            guard provenance.modelID == nil, !hasPrompt, !hasResponse else {
                throw SequenceReviewValidationErrorV1.invalidIdentity
            }
        }
    }

    private static func digest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
