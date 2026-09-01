import Foundation

public let modelCapabilityKnowledgeBaseV1Schema = "model-capability-kb/v1"

public struct ModelFamilyID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ModelVariantID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ModelVersionID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum CapabilityModalityV1: String, Codable, CaseIterable, Hashable, Sendable {
    case video
    case image
    case audio
    case music
}

public enum CapabilityEvidenceKindV1: String, Codable, Hashable, Sendable {
    case documentedAPI = "documented_api"
    case providerSchema = "provider_schema"
    case empirical
    case inferred
    case defensive
}

public enum CapabilityValueSemanticsV1: String, Codable, Hashable, Sendable {
    case hardAPILimit = "hard_api_limit"
    case reliableCapacity = "reliable_capacity"
    case supportedValue = "supported_value"
    case supportedSet = "supported_set"
    case observedRange = "observed_range"
    case defensiveDefault = "defensive_default"
}

public struct CapabilityEvidenceV1: Codable, Sendable, Equatable {
    public let sourceURL: String?
    public let sourceTitle: String
    public let observedAt: String
    public let kind: CapabilityEvidenceKindV1
    public let confidence: Double
    public let conflict: String?

    private enum CodingKeys: String, CodingKey {
        case sourceURL = "source_url"
        case sourceTitle = "source_title"
        case observedAt = "observed_at"
        case kind
        case confidence
        case conflict
    }

    public init(
        sourceURL: String? = nil,
        sourceTitle: String,
        observedAt: String,
        kind: CapabilityEvidenceKindV1,
        confidence: Double,
        conflict: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.observedAt = observedAt
        self.kind = kind
        self.confidence = confidence
        self.conflict = conflict
    }
}

public struct EvidencedCapabilityFieldV1<Value>: Codable, Sendable, Equatable
where Value: Codable & Sendable & Equatable {
    public let value: Value?
    public let semantics: CapabilityValueSemanticsV1
    public let evidence: [CapabilityEvidenceV1]

    public init(
        value: Value?,
        semantics: CapabilityValueSemanticsV1,
        evidence: [CapabilityEvidenceV1]
    ) {
        self.value = value
        self.semantics = semantics
        self.evidence = evidence
    }
}

public struct CapabilityFieldsV1: Codable, Sendable, Equatable {
    public var integers: [String: EvidencedCapabilityFieldV1<Int>]
    public var decimals: [String: EvidencedCapabilityFieldV1<Double>]
    public var booleans: [String: EvidencedCapabilityFieldV1<Bool>]
    public var strings: [String: EvidencedCapabilityFieldV1<[String]>]
    public var integerLists: [String: EvidencedCapabilityFieldV1<[Int]>]

    private enum CodingKeys: String, CodingKey {
        case integers
        case decimals
        case booleans
        case strings
        case integerLists = "integer_lists"
    }

    public init(
        integers: [String: EvidencedCapabilityFieldV1<Int>] = [:],
        decimals: [String: EvidencedCapabilityFieldV1<Double>] = [:],
        booleans: [String: EvidencedCapabilityFieldV1<Bool>] = [:],
        strings: [String: EvidencedCapabilityFieldV1<[String]>] = [:],
        integerLists: [String: EvidencedCapabilityFieldV1<[Int]>] = [:]
    ) {
        self.integers = integers
        self.decimals = decimals
        self.booleans = booleans
        self.strings = strings
        self.integerLists = integerLists
    }
}

public enum CapabilityFieldIDV1 {
    public static let modes = "common.modes"
    public static let inputKinds = "common.input_kinds"
    public static let outputKinds = "common.output_kinds"
    public static let promptCharacters = "common.prompt_characters"
    public static let resolutions = "common.resolutions"
    public static let aspectRatios = "common.aspect_ratios"
    public static let knownExclusivities = "common.known_exclusivities"

    public static let visibleCharacters = "video.visible_characters"
    public static let referenceImages = "video.reference_images"
    public static let referenceVideos = "video.reference_videos"
    public static let referenceAudios = "video.reference_audios"
    public static let totalReferences = "video.total_references"
    public static let combinedVideoReferenceSeconds = "video.combined_video_reference_seconds"
    public static let combinedAudioReferenceSeconds = "video.combined_audio_reference_seconds"
    public static let firstFrame = "video.first_frame"
    public static let lastFrame = "video.last_frame"
    public static let sourceVideo = "video.source_video"
    public static let sourceVideoRequired = "video.source_video_required"
    public static let framesCountTowardImageReferenceLimit =
        "video.frames_count_toward_image_reference_limit"
    public static let framesCountTowardTotalReferenceLimit =
        "video.frames_count_toward_total_reference_limit"
    public static let edit = "video.edit"
    public static let extend = "video.extend"
    public static let durationMinimum = "video.duration_minimum_seconds"
    public static let durationMaximum = "video.duration_maximum_seconds"
    public static let durationValues = "video.duration_values_seconds"
    public static let durationAutomatic = "video.duration_automatic"
    public static let fpsValues = "video.fps_values"
    public static let nativeAudio = "video.native_audio"
    public static let lipSync = "video.lip_sync"

    public static let imageVisibleCharacters = "image.visible_characters"
    public static let imageReferences = "image.references"
    public static let imageReferenceRoles = "image.reference_roles"
    public static let imageMask = "image.mask"
    public static let imageInpaint = "image.inpaint"
    public static let imageOutpaint = "image.outpaint"
    public static let imageEdit = "image.edit"
    public static let imageIdentity = "image.identity"
    public static let imageOutputsPerRequest = "image.outputs_per_request"

    public static let audioDurationMinimum = "audio.duration_minimum_seconds"
    public static let audioDurationMaximum = "audio.duration_maximum_seconds"
    public static let audioLyrics = "audio.lyrics"
    public static let audioVocals = "audio.vocals"
    public static let audioLanguages = "audio.languages"
    public static let audioReference = "audio.reference_audio"
    public static let audioContinue = "audio.continue"
    public static let audioRemix = "audio.remix"
    public static let audioStems = "audio.stems"
    public static let audioTempoControl = "audio.tempo_control"
    public static let audioKeyControl = "audio.key_control"
}

public struct ModelCapabilityIdentityV1: Codable, Sendable, Equatable, Hashable {
    public let familyID: ModelFamilyID
    public let variantID: ModelVariantID
    public let versionID: ModelVersionID
    public let modality: CapabilityModalityV1

    private enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case variantID = "variant_id"
        case versionID = "version_id"
        case modality
    }

    public init(
        familyID: ModelFamilyID,
        variantID: ModelVariantID,
        versionID: ModelVersionID,
        modality: CapabilityModalityV1
    ) {
        self.familyID = familyID
        self.variantID = variantID
        self.versionID = versionID
        self.modality = modality
    }
}

public struct ModelCapabilityProfileV1: Codable, Sendable, Equatable {
    public let identity: ModelCapabilityIdentityV1
    public let predecessorVersionID: ModelVersionID?
    public let fields: CapabilityFieldsV1

    private enum CodingKeys: String, CodingKey {
        case identity
        case predecessorVersionID = "predecessor_version_id"
        case fields
    }

    public init(
        identity: ModelCapabilityIdentityV1,
        predecessorVersionID: ModelVersionID? = nil,
        fields: CapabilityFieldsV1
    ) {
        self.identity = identity
        self.predecessorVersionID = predecessorVersionID
        self.fields = fields
    }
}

public struct ModelCapabilityAliasV1: Codable, Sendable, Equatable, Hashable {
    public let catalogModelID: String
    public let identity: ModelCapabilityIdentityV1

    private enum CodingKeys: String, CodingKey {
        case catalogModelID = "catalog_model_id"
        case identity
    }

    public init(catalogModelID: String, identity: ModelCapabilityIdentityV1) {
        self.catalogModelID = catalogModelID
        self.identity = identity
    }
}

public struct DefensiveCapabilityProfileV1: Codable, Sendable, Equatable {
    public let id: String
    public let modality: CapabilityModalityV1
    public let fields: CapabilityFieldsV1

    public init(id: String, modality: CapabilityModalityV1, fields: CapabilityFieldsV1) {
        self.id = id
        self.modality = modality
        self.fields = fields
    }
}

public struct ModelCapabilityKnowledgeBaseV1: Codable, Sendable, Equatable {
    public let schema: String
    public let profiles: [ModelCapabilityProfileV1]
    public let aliases: [ModelCapabilityAliasV1]
    public let defensiveProfiles: [DefensiveCapabilityProfileV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case profiles
        case aliases
        case defensiveProfiles = "defensive_profiles"
    }

    public init(
        schema: String = modelCapabilityKnowledgeBaseV1Schema,
        profiles: [ModelCapabilityProfileV1],
        aliases: [ModelCapabilityAliasV1],
        defensiveProfiles: [DefensiveCapabilityProfileV1]
    ) {
        self.schema = schema
        self.profiles = profiles
        self.aliases = aliases
        self.defensiveProfiles = defensiveProfiles
    }
}

public struct CapabilityLookupV1: Sendable, Equatable {
    public let familyID: ModelFamilyID?
    public let variantID: ModelVariantID?
    public let versionID: ModelVersionID?
    public let modality: CapabilityModalityV1
    public let catalogModelID: String?

    public init(
        familyID: ModelFamilyID? = nil,
        variantID: ModelVariantID? = nil,
        versionID: ModelVersionID? = nil,
        modality: CapabilityModalityV1,
        catalogModelID: String? = nil
    ) {
        self.familyID = familyID
        self.variantID = variantID
        self.versionID = versionID
        self.modality = modality
        self.catalogModelID = catalogModelID
    }
}
