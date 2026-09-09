import Foundation

public enum FinishOperationKindV1: String, Codable, Sendable, Equatable {
    case grade, mix, caption, upscale, title, composite
}

public struct FinishOperationProofV1: Codable, Sendable, Equatable {
    public let id: String
    public let kind: FinishOperationKindV1
    public let inputSHA256: String
    public let outputPath: String
    public let outputSHA256: String
    public let settingsPath: String
    public let settingsSHA256: String

    private enum CodingKeys: String, CodingKey {
        case id, kind
        case inputSHA256 = "input_sha256"
        case outputPath = "output_path"
        case outputSHA256 = "output_sha256"
        case settingsPath = "settings_path"
        case settingsSHA256 = "settings_sha256"
    }

    public init(
        id: String,
        kind: FinishOperationKindV1,
        inputSHA256: String,
        outputPath: String,
        outputSHA256: String,
        settingsPath: String,
        settingsSHA256: String
    ) {
        self.id = id
        self.kind = kind
        self.inputSHA256 = inputSHA256
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.settingsPath = settingsPath
        self.settingsSHA256 = settingsSHA256
    }
}

public struct FinishPlanV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "finish-plan/v1"
    public static let relativePath = "delivery/finish-plan.v1.json"
    public let schema: String
    public let projectID: String
    public let sourceTimelineSHA256: String
    public let assemblyManifestSHA256: String?
    public let sequenceReviewSHA256: String?
    public let operations: [FinishOperationProofV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case sourceTimelineSHA256 = "source_timeline_sha256"
        case assemblyManifestSHA256 = "assembly_manifest_sha256"
        case sequenceReviewSHA256 = "sequence_review_sha256"
        case operations
    }

    public init(
        projectID: String,
        sourceTimelineSHA256: String,
        assemblyManifestSHA256: String? = nil,
        sequenceReviewSHA256: String? = nil,
        operations: [FinishOperationProofV1] = []
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.sourceTimelineSHA256 = sourceTimelineSHA256
        self.assemblyManifestSHA256 = assemblyManifestSHA256
        self.sequenceReviewSHA256 = sequenceReviewSHA256
        self.operations = operations
    }
}

public struct FinishedTimelineManifestV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "finished-timeline-manifest/v1"
    public static let relativePath = "delivery/finished-timeline.v1.json"
    public let schema: String
    public let projectID: String
    public let finishPlanSHA256: String
    public let timelinePath: String
    public let timelineSHA256: String
    public let media: [RenderPublishedArtifactV1]
    public let operationProofs: [FinishOperationProofV1]
    public let adoptedManualTimeline: Bool

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case finishPlanSHA256 = "finish_plan_sha256"
        case timelinePath = "timeline_path"
        case timelineSHA256 = "timeline_sha256"
        case media
        case operationProofs = "operation_proofs"
        case adoptedManualTimeline = "adopted_manual_timeline"
    }

    public init(
        projectID: String,
        finishPlanSHA256: String,
        timelinePath: String,
        timelineSHA256: String,
        media: [RenderPublishedArtifactV1],
        operationProofs: [FinishOperationProofV1],
        adoptedManualTimeline: Bool
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.finishPlanSHA256 = finishPlanSHA256
        self.timelinePath = timelinePath
        self.timelineSHA256 = timelineSHA256
        self.media = media
        self.operationProofs = operationProofs
        self.adoptedManualTimeline = adoptedManualTimeline
    }
}

public enum DeliveryRequirementStateV1: String, Codable, Sendable, Equatable {
    case supported, enforced, unsupported
}

public struct DeliveryRequirementV1: Codable, Sendable, Equatable {
    public let id: String
    public let state: DeliveryRequirementStateV1
    public let required: Bool
    public let value: String

    public init(id: String, state: DeliveryRequirementStateV1, required: Bool, value: String) {
        self.id = id
        self.state = state
        self.required = required
        self.value = value
    }
}

public enum DeliveryTargetKindV1: String, Codable, Sendable, Equatable {
    case master, derivative
}

public struct DeliverySpecV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "delivery-spec/v1"
    public let schema: String
    public let id: String
    public let targetKind: DeliveryTargetKindV1
    public let container: String
    public let videoCodec: String
    public let width: Int
    public let height: Int
    public let fpsNumerator: Int
    public let fpsDenominator: Int
    public let colorSpace: String
    public let hdr: Bool
    public let audioLayout: String
    public let loudnessTarget: String?
    public let captionMode: String
    public let disclosureMode: String
    public let requirements: [DeliveryRequirementV1]
    public let extensionRefs: [String]

    private enum CodingKeys: String, CodingKey {
        case schema, id
        case targetKind = "target_kind"
        case container
        case videoCodec = "video_codec"
        case width, height
        case fpsNumerator = "fps_numerator"
        case fpsDenominator = "fps_denominator"
        case colorSpace = "color_space"
        case hdr
        case audioLayout = "audio_layout"
        case loudnessTarget = "loudness_target"
        case captionMode = "caption_mode"
        case disclosureMode = "disclosure_mode"
        case requirements
        case extensionRefs = "extension_refs"
    }

    public init(
        id: String,
        targetKind: DeliveryTargetKindV1,
        container: String,
        videoCodec: String,
        width: Int,
        height: Int,
        fpsNumerator: Int,
        fpsDenominator: Int = 1,
        colorSpace: String,
        hdr: Bool,
        audioLayout: String,
        loudnessTarget: String? = nil,
        captionMode: String,
        disclosureMode: String,
        requirements: [DeliveryRequirementV1] = [],
        extensionRefs: [String] = []
    ) {
        schema = Self.schemaVersion
        self.id = id
        self.targetKind = targetKind
        self.container = container
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.fpsNumerator = fpsNumerator
        self.fpsDenominator = fpsDenominator
        self.colorSpace = colorSpace
        self.hdr = hdr
        self.audioLayout = audioLayout
        self.loudnessTarget = loudnessTarget
        self.captionMode = captionMode
        self.disclosureMode = disclosureMode
        self.requirements = requirements
        self.extensionRefs = extensionRefs
    }
}

public enum DeliveryJobStatusV1: String, Codable, Sendable, Equatable {
    case queued, running, succeeded, failed, cancelled, interrupted
}

public struct DeliveryProbeQCV1: Codable, Sendable, Equatable {
    public let durationValue: Int64
    public let durationTimescale: Int32
    public let width: Int
    public let height: Int
    public let fpsNumerator: Int
    public let fpsDenominator: Int
    public let videoCodec: String
    public let audioCodec: String?
    public let audioChannels: Int
    public let passed: Bool

    private enum CodingKeys: String, CodingKey {
        case durationValue = "duration_value"
        case durationTimescale = "duration_timescale"
        case width, height
        case fpsNumerator = "fps_numerator"
        case fpsDenominator = "fps_denominator"
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case audioChannels = "audio_channels"
        case passed
    }

    public init(
        durationValue: Int64,
        durationTimescale: Int32,
        width: Int,
        height: Int,
        fpsNumerator: Int,
        fpsDenominator: Int,
        videoCodec: String,
        audioCodec: String?,
        audioChannels: Int,
        passed: Bool
    ) {
        self.durationValue = durationValue
        self.durationTimescale = durationTimescale
        self.width = width
        self.height = height
        self.fpsNumerator = fpsNumerator
        self.fpsDenominator = fpsDenominator
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.passed = passed
    }
}

public struct DeliveryAttemptV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "delivery-attempt/v1"
    public let schema: String
    public let id: String
    public let spec: DeliverySpecV1
    public let finishedTimelineSHA256: String
    public let sequenceReviewSHA256: String?
    public let status: DeliveryJobStatusV1
    public let outputPath: String?
    public let outputSHA256: String?
    public let outputByteCount: Int64?
    public let probeQC: DeliveryProbeQCV1?
    public let warnings: [String]
    public let failures: [String]
    public let createdAt: String
    public let completedAt: String?

    private enum CodingKeys: String, CodingKey {
        case schema, id, spec
        case finishedTimelineSHA256 = "finished_timeline_sha256"
        case sequenceReviewSHA256 = "sequence_review_sha256"
        case status
        case outputPath = "output_path"
        case outputSHA256 = "output_sha256"
        case outputByteCount = "output_byte_count"
        case probeQC = "probe_qc"
        case warnings, failures
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }

    public init(
        id: String,
        spec: DeliverySpecV1,
        finishedTimelineSHA256: String,
        sequenceReviewSHA256: String? = nil,
        status: DeliveryJobStatusV1,
        outputPath: String? = nil,
        outputSHA256: String? = nil,
        outputByteCount: Int64? = nil,
        probeQC: DeliveryProbeQCV1? = nil,
        warnings: [String] = [],
        failures: [String] = [],
        createdAt: String,
        completedAt: String? = nil
    ) {
        schema = Self.schemaVersion
        self.id = id
        self.spec = spec
        self.finishedTimelineSHA256 = finishedTimelineSHA256
        self.sequenceReviewSHA256 = sequenceReviewSHA256
        self.status = status
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.outputByteCount = outputByteCount
        self.probeQC = probeQC
        self.warnings = warnings
        self.failures = failures
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

public struct DeliverySelectionV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "delivery-selection/v1"
    public let schema: String
    public let masterAttemptID: String?
    public let derivativeAttemptIDs: [String: String]
    public let selectedAt: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case masterAttemptID = "master_attempt_id"
        case derivativeAttemptIDs = "derivative_attempt_ids"
        case selectedAt = "selected_at"
    }

    public init(masterAttemptID: String?, derivativeAttemptIDs: [String: String], selectedAt: String) {
        schema = Self.schemaVersion
        self.masterAttemptID = masterAttemptID
        self.derivativeAttemptIDs = derivativeAttemptIDs
        self.selectedAt = selectedAt
    }
}

public enum DeliveryValidationErrorV1: Error, Sendable, Equatable {
    case invalidIdentity
    case unsupportedSpecRequirement(String)
    case staleFinish
    case invalidOperation(String)
    case invalidAttempt
    case unsuccessfulOutput
}

public enum DeliveryValidatorV1 {
    public static func validate(spec: DeliverySpecV1) throws {
        guard spec.schema == DeliverySpecV1.schemaVersion,
              text(spec.id), text(spec.container), text(spec.videoCodec),
              spec.width > 0, spec.height > 0,
              spec.fpsNumerator > 0, spec.fpsDenominator > 0,
              text(spec.colorSpace), text(spec.audioLayout),
              text(spec.captionMode), text(spec.disclosureMode),
              Set(spec.requirements.map(\.id)).count == spec.requirements.count,
              Set(spec.extensionRefs).count == spec.extensionRefs.count else {
            throw DeliveryValidationErrorV1.invalidIdentity
        }
        if let unsupported = spec.requirements.first(where: { $0.required && $0.state == .unsupported }) {
            throw DeliveryValidationErrorV1.unsupportedSpecRequirement(unsupported.id)
        }
    }

    public static func validate(plan: FinishPlanV1) throws {
        guard plan.schema == FinishPlanV1.schemaVersion, text(plan.projectID),
              digest(plan.sourceTimelineSHA256),
              plan.assemblyManifestSHA256.map(digest) ?? true,
              plan.sequenceReviewSHA256.map(digest) ?? true,
              Set(plan.operations.map(\.id)).count == plan.operations.count else {
            throw DeliveryValidationErrorV1.invalidIdentity
        }
        var expected = plan.sourceTimelineSHA256
        for operation in plan.operations {
            guard text(operation.id), operation.inputSHA256 == expected,
                  text(operation.outputPath), digest(operation.outputSHA256),
                  text(operation.settingsPath), digest(operation.settingsSHA256) else {
                throw DeliveryValidationErrorV1.invalidOperation(operation.id)
            }
            expected = operation.outputSHA256
        }
    }

    public static func validate(
        manifest: FinishedTimelineManifestV1,
        plan: FinishPlanV1,
        planSHA256: String,
        currentTimelineSHA256: String
    ) throws {
        try validate(plan: plan)
        guard manifest.schema == FinishedTimelineManifestV1.schemaVersion,
              manifest.projectID == plan.projectID,
              manifest.finishPlanSHA256 == planSHA256, digest(planSHA256),
              text(manifest.timelinePath), digest(manifest.timelineSHA256),
              manifest.timelineSHA256 == currentTimelineSHA256,
              manifest.operationProofs == plan.operations,
              Set(manifest.media.map(\.path)).count == manifest.media.count,
              manifest.media.allSatisfy({ text($0.path) && digest($0.sha256) }) else {
            throw DeliveryValidationErrorV1.staleFinish
        }
    }

    public static func validateSuccessfulAttempt(
        _ attempt: DeliveryAttemptV1,
        finishedTimelineSHA256: String,
        requiredSequenceReviewSHA256: String?
    ) throws {
        try validate(spec: attempt.spec)
        guard attempt.schema == DeliveryAttemptV1.schemaVersion,
              text(attempt.id), digest(attempt.finishedTimelineSHA256),
              attempt.finishedTimelineSHA256 == finishedTimelineSHA256,
              attempt.sequenceReviewSHA256 == requiredSequenceReviewSHA256,
              !attempt.createdAt.isEmpty else {
            throw DeliveryValidationErrorV1.invalidAttempt
        }
        guard attempt.status == .succeeded,
              attempt.outputPath.map(text) == true,
              attempt.outputSHA256.map(digest) == true,
              attempt.outputByteCount.map({ $0 > 0 }) == true,
              attempt.probeQC?.passed == true,
              attempt.failures.isEmpty,
              attempt.completedAt?.isEmpty == false else {
            throw DeliveryValidationErrorV1.unsuccessfulOutput
        }
        guard let qc = attempt.probeQC,
              qc.durationTimescale > 0, qc.durationValue > 0,
              qc.width == attempt.spec.width, qc.height == attempt.spec.height,
              qc.fpsNumerator == attempt.spec.fpsNumerator,
              qc.fpsDenominator == attempt.spec.fpsDenominator,
              qc.videoCodec == attempt.spec.videoCodec else {
            throw DeliveryValidationErrorV1.unsuccessfulOutput
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
