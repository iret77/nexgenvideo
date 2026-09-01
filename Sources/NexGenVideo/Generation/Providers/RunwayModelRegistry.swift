import Foundation

struct RunwayImageRequestSpec: Sendable {
    let ratios: [String: String]
    let sendsOutputCount: Bool
    let sendsQuality: Bool
    let productionQualityTargetIDs: [String]
}

struct RunwayModel: Sendable {
    let entry: CatalogEntry
    let apiModel: String
    let imageRequest: RunwayImageRequestSpec?
}

enum RunwayModelRegistry {
    static let idPrefix = "runway/"

    static func isRunwayModel(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    private static let standardImageAspects = ["16:9", "9:16", "1:1", "4:3", "3:4"]

    static let models: [RunwayModel] = [
        video("runway/gen4.5", "Runway Gen-4.5 (image)", apiModel: "gen4.5", durations: [4, 6, 8, 10]),
        video("runway/gen4_turbo", "Runway Gen-4 Turbo (image)", apiModel: "gen4_turbo", durations: [5, 10]),
        image(
            "runway/gen4_image_turbo", "Runway Gen-4 Image Turbo",
            apiModel: "gen4_image_turbo",
            ratios: standardRatios(
                landscape: "1920:1080", portrait: "1080:1920", square: "1080:1080",
                wide: "1440:1080", tall: "1080:1440"
            ),
            minReferences: 1, maxReferences: 3, maxImages: 1
        ),
        image(
            "runway/gen4_image", "Runway Gen-4 Image",
            apiModel: "gen4_image",
            ratios: standardRatios(
                landscape: "1920:1080", portrait: "1080:1920", square: "1080:1080",
                wide: "1440:1080", tall: "1080:1440"
            ),
            maxReferences: 3, maxImages: 1
        ),
        image(
            "runway/gpt_image_2", "GPT Image 2",
            apiModel: "gpt_image_2",
            ratios: standardRatios(
                landscape: "1920:1088", portrait: "1088:1920", square: "1920:1920",
                wide: "1920:1440", tall: "1440:1920"
            ),
            qualities: ["low", "medium", "high"], maxReferences: 16, maxImages: 4
        ),
        image(
            "runway/gemini_image3_pro", "Nano Banana Pro (Gemini 3 Pro Image)",
            apiModel: "gemini_image3_pro",
            ratios: standardRatios(
                landscape: "1344:768", portrait: "768:1344", square: "1024:1024",
                wide: "1184:864", tall: "864:1184"
            ),
            maxReferences: 14, maxImages: 1
        ),
        image(
            "runway/gemini_image3.1_flash", "Nano Banana 2 (Gemini 3.1 Flash Image)",
            apiModel: "gemini_image3.1_flash",
            ratios: standardRatios(
                landscape: "1344:768", portrait: "768:1344", square: "1024:1024",
                wide: "1184:864", tall: "864:1184"
            ),
            maxReferences: 14, maxImages: 1
        ),
        image(
            "runway/seedream5_pro", "Seedream 5 Pro",
            apiModel: "seedream5_pro",
            ratios: standardRatios(
                landscape: "1376:768", portrait: "768:1376", square: "1024:1024",
                wide: "1184:896", tall: "896:1184"
            ),
            maxReferences: 10, maxImages: 4
        ),
        image(
            "runway/seedream5_lite", "Seedream 5 Lite",
            apiModel: "seedream5_lite",
            ratios: standardRatios(
                landscape: "2848:1600", portrait: "1600:2848", square: "2048:2048",
                wide: "2304:1728", tall: "1728:2304"
            ),
            maxReferences: 14, maxImages: 4
        ),
        image(
            "runway/grok_imagine_image_2", "Grok Imagine Image 2",
            apiModel: "grok_imagine_image_2",
            ratios: standardRatios(
                landscape: "1280:720", portrait: "720:1280", square: "1024:1024",
                wide: "1152:864", tall: "864:1152"
            ),
            qualities: ["low", "medium"], maxReferences: 3, maxImages: 4
        ),
        image(
            "runway/gemini_2.5_flash", "Nano Banana (Gemini 2.5 Flash)",
            apiModel: "gemini_2.5_flash",
            ratios: standardRatios(
                landscape: "1344:768", portrait: "768:1344", square: "1024:1024",
                wide: "1184:864", tall: "864:1184"
            ),
            maxReferences: 3, maxImages: 1
        ),
        videoEdit("runway/aleph2", "Runway Aleph 2 (restyle)", apiModel: "aleph2"),
    ]

    static let entries: [CatalogEntry] = models.map(entryWithOffer)

    static func discoveredEntries(availableModelIds: Set<String>) -> [CatalogEntry] {
        models
            .filter { availableModelIds.contains($0.apiModel) }
            .map(entryWithOffer)
    }

    private static let byId: [String: RunwayModel] = Dictionary(
        uniqueKeysWithValues: models.map { ($0.entry.id, $0) }
    )

    static func model(for id: String) -> RunwayModel? { byId[id] }

    static func requiresSourceVideo(_ model: RunwayModel) -> Bool {
        guard case .video(let caps) = model.entry.uiCapabilities else { return false }
        return caps.requiresSourceVideo
    }

    static func videoRatio(for aspect: String) -> String {
        switch aspect {
        case "9:16": "720:1280"
        case "1:1": "960:960"
        default: "1280:720"
        }
    }

    static func imageRatio(for model: RunwayModel, aspect: String) -> String? {
        model.imageRequest?.ratios[aspect]
            ?? model.imageRequest?.ratios["1:1"]
    }

    private static func entryWithOffer(_ model: RunwayModel) -> CatalogEntry {
        var entry = model.entry
        let qualityTargetIDs = model.imageRequest?.productionQualityTargetIDs
        entry.offers = [ProviderOffer(
            provider: .runway,
            providerRef: entry.id,
            productionQualityTargetIDs: qualityTargetIDs?.isEmpty == false ? qualityTargetIDs : nil,
            productionInputPolicy: {
                guard case .video(let capabilities) = entry.uiCapabilities else { return nil }
                return ProviderProductionInputPolicyV1(
                    videoCapabilities: capabilities
                )
            }(),
            resolvedVideoCapabilities: {
                guard case .video(let capabilities) = entry.uiCapabilities else { return nil }
                return ResolvedVideoOfferingCapabilitiesV1(
                    videoCapabilities: capabilities,
                    supportsNativeAudio: false
                )
            }()
        )]
        return entry
    }

    private static func standardRatios(
        landscape: String,
        portrait: String,
        square: String,
        wide: String,
        tall: String
    ) -> [String: String] {
        [
            "16:9": landscape,
            "9:16": portrait,
            "1:1": square,
            "4:3": wide,
            "3:4": tall,
        ]
    }

    private static func video(
        _ id: String,
        _ name: String,
        apiModel: String,
        durations: [Int]
    ) -> RunwayModel {
        RunwayModel(
            entry: CatalogEntry(
                id: id,
                kind: .video,
                displayName: name,
                allowedEndpoints: [id],
                responseShape: .video,
                uiCapabilities: .video(VideoCaps(
                    durations: durations,
                    resolutions: nil,
                    aspectRatios: ["16:9", "9:16", "1:1"],
                    supportsFirstFrame: false,
                    supportsLastFrame: false,
                    maxReferenceImages: 1,
                    maxReferenceVideos: 0,
                    maxReferenceAudios: 0,
                    maxTotalReferences: 1,
                    maxCombinedVideoRefSeconds: nil,
                    maxCombinedAudioRefSeconds: nil,
                    framesAndReferencesExclusive: false,
                    referenceTagNoun: "image",
                    requiresSourceVideo: false,
                    requiresReferenceImage: true
                ))
            ),
            apiModel: apiModel,
            imageRequest: nil
        )
    }

    private static func videoEdit(_ id: String, _ name: String, apiModel: String) -> RunwayModel {
        RunwayModel(
            entry: CatalogEntry(
                id: id,
                kind: .video,
                displayName: name,
                allowedEndpoints: [id],
                responseShape: .video,
                uiCapabilities: .video(VideoCaps(
                    durations: [],
                    resolutions: nil,
                    aspectRatios: ["16:9", "9:16", "1:1"],
                    supportsFirstFrame: false,
                    supportsLastFrame: false,
                    maxReferenceImages: 0,
                    maxReferenceVideos: 0,
                    maxReferenceAudios: 0,
                    maxTotalReferences: 0,
                    maxCombinedVideoRefSeconds: nil,
                    maxCombinedAudioRefSeconds: nil,
                    framesAndReferencesExclusive: false,
                    referenceTagNoun: "image",
                    requiresSourceVideo: true,
                    requiresReferenceImage: false
                ))
            ),
            apiModel: apiModel,
            imageRequest: nil
        )
    }

    private static func image(
        _ id: String,
        _ name: String,
        apiModel: String,
        ratios: [String: String],
        qualities: [String]? = nil,
        minReferences: Int = 0,
        maxReferences: Int,
        maxImages: Int
    ) -> RunwayModel {
        RunwayModel(
            entry: CatalogEntry(
                id: id,
                kind: .image,
                displayName: name,
                allowedEndpoints: [id],
                responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil,
                    aspectRatios: standardImageAspects,
                    qualities: qualities,
                    supportsImageReference: maxReferences > 0,
                    requiresImageReference: minReferences > 0,
                    minReferenceImages: minReferences,
                    maxReferenceImages: maxReferences,
                    maxImages: maxImages
                ))
            ),
            apiModel: apiModel,
            imageRequest: RunwayImageRequestSpec(
                ratios: ratios,
                sendsOutputCount: maxImages > 1,
                sendsQuality: qualities != nil,
                productionQualityTargetIDs: qualities ?? []
            )
        )
    }
}
