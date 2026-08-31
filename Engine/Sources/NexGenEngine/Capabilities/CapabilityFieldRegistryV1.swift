import Foundation

public enum CapabilityFieldValueTypeV1: String, Codable, Sendable, Equatable {
    case integer
    case decimal
    case boolean
    case stringList = "string_list"
    case integerList = "integer_list"
}

public enum CapabilityEndpointMergePolicyV1: String, Codable, Sendable, Equatable {
    case maximum
    case minimum
    case booleanAnd = "boolean_and"
    case setIntersection = "set_intersection"
    case intrinsicOnly = "intrinsic_only"
}

public struct CapabilityFieldDefinitionV1: Sendable, Equatable {
    public let id: String
    public let modalities: Set<CapabilityModalityV1>
    public let valueType: CapabilityFieldValueTypeV1
    public let endpointMergePolicy: CapabilityEndpointMergePolicyV1
    public let requiresDefensiveDefault: Bool

    public init(
        id: String,
        modalities: Set<CapabilityModalityV1>,
        valueType: CapabilityFieldValueTypeV1,
        endpointMergePolicy: CapabilityEndpointMergePolicyV1,
        requiresDefensiveDefault: Bool = true
    ) {
        self.id = id
        self.modalities = modalities
        self.valueType = valueType
        self.endpointMergePolicy = endpointMergePolicy
        self.requiresDefensiveDefault = requiresDefensiveDefault
    }
}

public enum CapabilityFieldRegistryV1 {
    private static let allModalities = Set(CapabilityModalityV1.allCases)
    private static let audioModalities: Set<CapabilityModalityV1> = [.audio, .music]

    public static let definitions: [CapabilityFieldDefinitionV1] = [
        field(CapabilityFieldIDV1.modes, allModalities, .stringList, .setIntersection),
        field(CapabilityFieldIDV1.inputKinds, allModalities, .stringList, .setIntersection),
        field(CapabilityFieldIDV1.outputKinds, allModalities, .stringList, .setIntersection),
        field(CapabilityFieldIDV1.promptCharacters, allModalities, .integer, .maximum),
        field(CapabilityFieldIDV1.resolutions, allModalities, .stringList, .setIntersection),
        field(CapabilityFieldIDV1.aspectRatios, allModalities, .stringList, .setIntersection),
        field(CapabilityFieldIDV1.knownExclusivities, allModalities, .stringList, .intrinsicOnly),

        field(CapabilityFieldIDV1.visibleCharacters, [.video], .integer, .intrinsicOnly),
        field(CapabilityFieldIDV1.referenceImages, [.video], .integer, .maximum),
        field(CapabilityFieldIDV1.referenceVideos, [.video], .integer, .maximum),
        field(CapabilityFieldIDV1.referenceAudios, [.video], .integer, .maximum),
        field(CapabilityFieldIDV1.totalReferences, [.video], .integer, .maximum),
        field(
            CapabilityFieldIDV1.combinedVideoReferenceSeconds,
            [.video],
            .decimal,
            .maximum
        ),
        field(
            CapabilityFieldIDV1.combinedAudioReferenceSeconds,
            [.video],
            .decimal,
            .maximum
        ),
        field(CapabilityFieldIDV1.firstFrame, [.video], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.lastFrame, [.video], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.sourceVideo, [.video], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.edit, [.video], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.extend, [.video], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.durationMinimum, [.video], .decimal, .minimum),
        field(CapabilityFieldIDV1.durationMaximum, [.video], .decimal, .maximum),
        field(CapabilityFieldIDV1.durationValues, [.video], .integerList, .setIntersection),
        field(CapabilityFieldIDV1.durationAutomatic, [.video], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.fpsValues, [.video], .integerList, .setIntersection),
        field(CapabilityFieldIDV1.nativeAudio, [.video], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.lipSync, [.video], .boolean, .booleanAnd),

        field(CapabilityFieldIDV1.imageVisibleCharacters, [.image], .integer, .intrinsicOnly),
        field(CapabilityFieldIDV1.imageReferences, [.image], .integer, .maximum),
        field(CapabilityFieldIDV1.imageReferenceRoles, [.image], .stringList, .setIntersection),
        field(CapabilityFieldIDV1.imageMask, [.image], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.imageInpaint, [.image], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.imageOutpaint, [.image], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.imageEdit, [.image], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.imageIdentity, [.image], .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.imageOutputsPerRequest, [.image], .integer, .maximum),

        field(CapabilityFieldIDV1.audioDurationMinimum, audioModalities, .decimal, .minimum),
        field(CapabilityFieldIDV1.audioDurationMaximum, audioModalities, .decimal, .maximum),
        field(CapabilityFieldIDV1.audioLyrics, audioModalities, .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.audioVocals, audioModalities, .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.audioLanguages, audioModalities, .stringList, .setIntersection),
        field(CapabilityFieldIDV1.audioReference, audioModalities, .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.audioContinue, audioModalities, .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.audioRemix, audioModalities, .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.audioStems, audioModalities, .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.audioTempoControl, audioModalities, .boolean, .booleanAnd),
        field(CapabilityFieldIDV1.audioKeyControl, audioModalities, .boolean, .booleanAnd),
    ]

    public static let byID: [String: CapabilityFieldDefinitionV1] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.id, $0) }
    )

    public static func requiredDefensiveFields(
        for modality: CapabilityModalityV1
    ) -> [CapabilityFieldDefinitionV1] {
        definitions.filter {
            $0.requiresDefensiveDefault && $0.modalities.contains(modality)
        }
    }

    private static func field(
        _ id: String,
        _ modalities: Set<CapabilityModalityV1>,
        _ valueType: CapabilityFieldValueTypeV1,
        _ mergePolicy: CapabilityEndpointMergePolicyV1
    ) -> CapabilityFieldDefinitionV1 {
        CapabilityFieldDefinitionV1(
            id: id,
            modalities: modalities,
            valueType: valueType,
            endpointMergePolicy: mergePolicy
        )
    }
}
