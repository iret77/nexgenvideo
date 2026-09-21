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

public enum DeliveryTargetKindV1: String, Codable, Sendable, Equatable, Hashable {
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
              spec.requirements.allSatisfy({ text($0.id) && text($0.value) }),
              Set(spec.requirements.map(\.id)).count == spec.requirements.count,
              spec.extensionRefs.allSatisfy(text),
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
        try validate(attempt: attempt)
        guard attempt.schema == DeliveryAttemptV1.schemaVersion,
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

    public static func validate(attempt: DeliveryAttemptV1) throws {
        try validate(spec: attempt.spec)
        guard attempt.schema == DeliveryAttemptV1.schemaVersion,
              text(attempt.id), digest(attempt.finishedTimelineSHA256),
              attempt.sequenceReviewSHA256.map(digest) ?? true,
              text(attempt.createdAt),
              attempt.warnings.allSatisfy(text),
              attempt.failures.allSatisfy(text) else {
            throw DeliveryValidationErrorV1.invalidAttempt
        }
        switch attempt.status {
        case .queued, .running:
            guard attempt.outputPath == nil,
                  attempt.outputSHA256 == nil,
                  attempt.outputByteCount == nil,
                  attempt.probeQC == nil,
                  attempt.failures.isEmpty,
                  attempt.completedAt == nil else {
                throw DeliveryValidationErrorV1.invalidAttempt
            }
        case .succeeded:
            guard attempt.outputPath.map(text) == true,
                  attempt.outputSHA256.map(digest) == true,
                  attempt.outputByteCount.map({ $0 > 0 }) == true,
                  attempt.probeQC?.passed == true,
                  attempt.failures.isEmpty,
                  attempt.completedAt.map(text) == true else {
                throw DeliveryValidationErrorV1.invalidAttempt
            }
        case .failed, .cancelled, .interrupted:
            guard attempt.outputSHA256 == nil,
                  attempt.outputByteCount == nil,
                  attempt.probeQC == nil,
                  !attempt.failures.isEmpty,
                  attempt.completedAt.map(text) == true else {
                throw DeliveryValidationErrorV1.invalidAttempt
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

public struct DeliveryHDRTrackQCV1: Codable, Sendable, Equatable {
    public let codec: String
    public let bitsPerComponent: Int
    public let colorPrimaries: String
    public let transferFunction: String
    public let yCbCrMatrix: String
    public let fullRange: Bool

    private enum CodingKeys: String, CodingKey {
        case codec
        case bitsPerComponent = "bits_per_component"
        case colorPrimaries = "color_primaries"
        case transferFunction = "transfer_function"
        case yCbCrMatrix = "ycbcr_matrix"
        case fullRange = "full_range"
    }

    public init(
        codec: String,
        bitsPerComponent: Int,
        colorPrimaries: String,
        transferFunction: String,
        yCbCrMatrix: String,
        fullRange: Bool
    ) {
        self.codec = codec
        self.bitsPerComponent = bitsPerComponent
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.fullRange = fullRange
    }
}

public struct DeliveryHDRContainerQCV1: Codable, Sendable, Equatable {
    public let fileType: String
    public let sampleEntry: String
    public let hasHEVCConfiguration: Bool
    public let profileIDC: Int
    public let lumaBitDepth: Int
    public let chromaBitDepth: Int
    public let colorPrimariesIndex: Int
    public let transferFunctionIndex: Int
    public let matrixIndex: Int
    public let fullRangeFlag: Bool?

    private enum CodingKeys: String, CodingKey {
        case fileType = "file_type"
        case sampleEntry = "sample_entry"
        case hasHEVCConfiguration = "has_hevc_configuration"
        case profileIDC = "profile_idc"
        case lumaBitDepth = "luma_bit_depth"
        case chromaBitDepth = "chroma_bit_depth"
        case colorPrimariesIndex = "color_primaries_index"
        case transferFunctionIndex = "transfer_function_index"
        case matrixIndex = "matrix_index"
        case fullRangeFlag = "full_range_flag"
    }

    public init(
        fileType: String,
        sampleEntry: String,
        hasHEVCConfiguration: Bool,
        profileIDC: Int,
        lumaBitDepth: Int,
        chromaBitDepth: Int,
        colorPrimariesIndex: Int,
        transferFunctionIndex: Int,
        matrixIndex: Int,
        fullRangeFlag: Bool?
    ) {
        self.fileType = fileType
        self.sampleEntry = sampleEntry
        self.hasHEVCConfiguration = hasHEVCConfiguration
        self.profileIDC = profileIDC
        self.lumaBitDepth = lumaBitDepth
        self.chromaBitDepth = chromaBitDepth
        self.colorPrimariesIndex = colorPrimariesIndex
        self.transferFunctionIndex = transferFunctionIndex
        self.matrixIndex = matrixIndex
        self.fullRangeFlag = fullRangeFlag
    }
}

public struct DeliveryHDRReferenceFrameQCV1: Codable, Sendable, Equatable {
    public let index: Int
    public let presentationTimeValue: Int64
    public let presentationTimeTimescale: Int32
    public let pixelFormat: String
    public let lumaMinimumCode: Int
    public let lumaMaximumCode: Int
    public let outOfRangePixelCount: Int
    public let pixelCount: Int
    public let chromaCbMeanCode: Double
    public let chromaCrMeanCode: Double
    public let pixelSHA256: String

    private enum CodingKeys: String, CodingKey {
        case index
        case presentationTimeValue = "presentation_time_value"
        case presentationTimeTimescale = "presentation_time_timescale"
        case pixelFormat = "pixel_format"
        case lumaMinimumCode = "luma_minimum_code"
        case lumaMaximumCode = "luma_maximum_code"
        case outOfRangePixelCount = "out_of_range_pixel_count"
        case pixelCount = "pixel_count"
        case chromaCbMeanCode = "chroma_cb_mean_code"
        case chromaCrMeanCode = "chroma_cr_mean_code"
        case pixelSHA256 = "pixel_sha256"
    }

    public init(
        index: Int,
        presentationTimeValue: Int64,
        presentationTimeTimescale: Int32,
        pixelFormat: String,
        lumaMinimumCode: Int,
        lumaMaximumCode: Int,
        outOfRangePixelCount: Int,
        pixelCount: Int,
        chromaCbMeanCode: Double,
        chromaCrMeanCode: Double,
        pixelSHA256: String
    ) {
        self.index = index
        self.presentationTimeValue = presentationTimeValue
        self.presentationTimeTimescale = presentationTimeTimescale
        self.pixelFormat = pixelFormat
        self.lumaMinimumCode = lumaMinimumCode
        self.lumaMaximumCode = lumaMaximumCode
        self.outOfRangePixelCount = outOfRangePixelCount
        self.pixelCount = pixelCount
        self.chromaCbMeanCode = chromaCbMeanCode
        self.chromaCrMeanCode = chromaCrMeanCode
        self.pixelSHA256 = pixelSHA256
    }
}

public struct DeliveryHDRQCV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "delivery-hdr-qc/v1"
    public static let sdrReferenceWhiteMaximumCode = 768
    public static let decodedLumaMinimumCode = 60
    public static let decodedLumaMaximumCode = 944
    public let schema: String
    public let outputSHA256: String
    public let conversion: String
    public let track: DeliveryHDRTrackQCV1
    public let container: DeliveryHDRContainerQCV1
    public let referenceFrames: [DeliveryHDRReferenceFrameQCV1]
    public let passed: Bool

    private enum CodingKeys: String, CodingKey {
        case schema
        case outputSHA256 = "output_sha256"
        case conversion, track, container
        case referenceFrames = "reference_frames"
        case passed
    }

    public init(
        outputSHA256: String,
        conversion: String,
        track: DeliveryHDRTrackQCV1,
        container: DeliveryHDRContainerQCV1,
        referenceFrames: [DeliveryHDRReferenceFrameQCV1],
        passed: Bool
    ) {
        schema = Self.schemaVersion
        self.outputSHA256 = outputSHA256
        self.conversion = conversion
        self.track = track
        self.container = container
        self.referenceFrames = referenceFrames
        self.passed = passed
    }
}

public extension DeliveryValidatorV1 {
    static func validate(
        hdrQC: DeliveryHDRQCV1,
        outputSHA256: String
    ) throws {
        guard hdrValidationFailures(hdrQC: hdrQC, outputSHA256: outputSHA256).isEmpty else {
            throw DeliveryValidationErrorV1.unsuccessfulOutput
        }
    }

    static func hdrValidationFailures(
        hdrQC: DeliveryHDRQCV1,
        outputSHA256: String
    ) -> [String] {
        var failures: [String] = []
        check(
            hdrQC.schema == DeliveryHDRQCV1.schemaVersion,
            "schema",
            DeliveryHDRQCV1.schemaVersion,
            hdrQC.schema,
            into: &failures
        )
        check(
            hdrQC.outputSHA256 == outputSHA256,
            "output_sha256",
            outputSHA256,
            hdrQC.outputSHA256,
            into: &failures
        )
        check(
            digest(outputSHA256),
            "output_sha256_format",
            "64 lowercase hexadecimal characters",
            outputSHA256,
            into: &failures
        )
        check(
            hdrQC.conversion == "rec709-sdr-reference-white-75-to-bt2020-hlg",
            "conversion",
            "rec709-sdr-reference-white-75-to-bt2020-hlg",
            hdrQC.conversion,
            into: &failures
        )
        check(hdrQC.track.codec == "hvc1", "track.codec", "hvc1", hdrQC.track.codec, into: &failures)
        check(hdrQC.track.bitsPerComponent == 10, "track.bits_per_component", 10, hdrQC.track.bitsPerComponent, into: &failures)
        check(hdrQC.track.colorPrimaries == "bt2020", "track.color_primaries", "bt2020", hdrQC.track.colorPrimaries, into: &failures)
        check(hdrQC.track.transferFunction == "hlg", "track.transfer_function", "hlg", hdrQC.track.transferFunction, into: &failures)
        check(hdrQC.track.yCbCrMatrix == "bt2020-ncl", "track.ycbcr_matrix", "bt2020-ncl", hdrQC.track.yCbCrMatrix, into: &failures)
        check(!hdrQC.track.fullRange, "track.full_range", false, hdrQC.track.fullRange, into: &failures)
        check(hdrQC.container.fileType == "mov", "container.file_type", "mov", hdrQC.container.fileType, into: &failures)
        check(hdrQC.container.sampleEntry == "hvc1", "container.sample_entry", "hvc1", hdrQC.container.sampleEntry, into: &failures)
        check(hdrQC.container.hasHEVCConfiguration, "container.has_hevc_configuration", true, hdrQC.container.hasHEVCConfiguration, into: &failures)
        check(hdrQC.container.profileIDC == 2, "container.profile_idc", 2, hdrQC.container.profileIDC, into: &failures)
        check(hdrQC.container.lumaBitDepth == 10, "container.luma_bit_depth", 10, hdrQC.container.lumaBitDepth, into: &failures)
        check(hdrQC.container.chromaBitDepth == 10, "container.chroma_bit_depth", 10, hdrQC.container.chromaBitDepth, into: &failures)
        check(hdrQC.container.colorPrimariesIndex == 9, "container.color_primaries_index", 9, hdrQC.container.colorPrimariesIndex, into: &failures)
        check(hdrQC.container.transferFunctionIndex == 18, "container.transfer_function_index", 18, hdrQC.container.transferFunctionIndex, into: &failures)
        check(hdrQC.container.matrixIndex == 9, "container.matrix_index", 9, hdrQC.container.matrixIndex, into: &failures)
        check(hdrQC.container.fullRangeFlag != true, "container.full_range_flag", "false or absent", String(describing: hdrQC.container.fullRangeFlag), into: &failures)
        check(hdrQC.referenceFrames.count == 4, "reference_frames.count", 4, hdrQC.referenceFrames.count, into: &failures)
        check(hdrQC.referenceFrames.map(\.index) == [0, 1, 2, 3], "reference_frames.indices", [0, 1, 2, 3], hdrQC.referenceFrames.map(\.index), into: &failures)

        for frame in hdrQC.referenceFrames {
            let prefix = "reference_frames[\(frame.index)]"
            check(frame.presentationTimeTimescale > 0, "\(prefix).presentation_time_timescale", "> 0", frame.presentationTimeTimescale, into: &failures)
            check(frame.pixelFormat == "x420", "\(prefix).pixel_format", "x420", frame.pixelFormat, into: &failures)
            check(frame.lumaMinimumCode >= DeliveryHDRQCV1.decodedLumaMinimumCode, "\(prefix).luma_minimum_code", ">= \(DeliveryHDRQCV1.decodedLumaMinimumCode)", frame.lumaMinimumCode, into: &failures)
            check(frame.lumaMaximumCode <= DeliveryHDRQCV1.decodedLumaMaximumCode, "\(prefix).luma_maximum_code", "<= \(DeliveryHDRQCV1.decodedLumaMaximumCode)", frame.lumaMaximumCode, into: &failures)
            check(frame.lumaMaximumCode <= DeliveryHDRQCV1.sdrReferenceWhiteMaximumCode, "\(prefix).sdr_reference_white_maximum_code", "<= \(DeliveryHDRQCV1.sdrReferenceWhiteMaximumCode)", frame.lumaMaximumCode, into: &failures)
            check(frame.lumaMinimumCode <= frame.lumaMaximumCode, "\(prefix).luma_code_order", "minimum <= maximum", "\(frame.lumaMinimumCode)...\(frame.lumaMaximumCode)", into: &failures)
            check(frame.outOfRangePixelCount >= 0, "\(prefix).out_of_range_pixel_count", ">= 0", frame.outOfRangePixelCount, into: &failures)
            check(frame.outOfRangePixelCount <= frame.pixelCount, "\(prefix).out_of_range_pixel_count", "<= pixel_count (\(frame.pixelCount))", frame.outOfRangePixelCount, into: &failures)
            check(frame.pixelCount > 0, "\(prefix).pixel_count", "> 0", frame.pixelCount, into: &failures)
            check(frame.chromaCbMeanCode.isFinite, "\(prefix).chroma_cb_mean_code", "finite", frame.chromaCbMeanCode, into: &failures)
            check((60.0...964.0).contains(frame.chromaCbMeanCode), "\(prefix).chroma_cb_mean_code", "60...964", frame.chromaCbMeanCode, into: &failures)
            check(frame.chromaCrMeanCode.isFinite, "\(prefix).chroma_cr_mean_code", "finite", frame.chromaCrMeanCode, into: &failures)
            check((60.0...964.0).contains(frame.chromaCrMeanCode), "\(prefix).chroma_cr_mean_code", "60...964", frame.chromaCrMeanCode, into: &failures)
            check(digest(frame.pixelSHA256), "\(prefix).pixel_sha256", "64 lowercase hexadecimal characters", frame.pixelSHA256, into: &failures)
        }
        check(hdrQC.passed, "passed", true, hdrQC.passed, into: &failures)
        return failures
    }

    private static func check<Expected, Measured>(
        _ condition: Bool,
        _ predicate: String,
        _ expected: Expected,
        _ measured: Measured,
        into failures: inout [String]
    ) {
        guard !condition else { return }
        failures.append("\(predicate) expected \(expected) measured \(measured)")
    }
}
