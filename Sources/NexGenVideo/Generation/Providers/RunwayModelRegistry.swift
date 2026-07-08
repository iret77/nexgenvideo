import Foundation

// Runway catalog. Ids are namespaced under `runway/` so GenerationService routes them through
// RunwayClient (the user's Runway key — never fal). Runway's video models are image-to-video:
// promptImage is required, so the entries advertise a required image reference like the Kling/
// Seedance i2v models. Model names, ratio enums, and duration ranges verified against the
// official SDK (runwayml/sdk-node).

struct RunwayModel: Sendable {
    let entry: CatalogEntry
    let apiModel: String   // Runway `model` field, e.g. "gen4.5"
}

enum RunwayModelRegistry {
    static let idPrefix = "runway/"

    static func isRunwayModel(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    static let models: [RunwayModel] = [
        video("runway/gen4.5", "Runway Gen-4.5 (image)", apiModel: "gen4.5", durations: [4, 6, 8, 10]),
        video("runway/gen4_turbo", "Runway Gen-4 Turbo (image)", apiModel: "gen4_turbo", durations: [5, 10]),
        image("runway/gen4_image", "Runway Gen-4 Image", apiModel: "gen4_image"),
    ]

    static let entries: [CatalogEntry] = models.map { model in
        var e = model.entry
        e.offers = [ProviderOffer(provider: .runway, providerRef: e.id)]
        return e
    }

    private static let byId: [String: RunwayModel] =
        Dictionary(models.map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func model(for id: String) -> RunwayModel? { byId[id] }

    // MARK: - Ratio mapping (NGV aspect label → Runway ratio string)

    /// gen4.5 / gen4_turbo share the video ratio enum.
    static func videoRatio(for aspect: String) -> String {
        switch aspect {
        case "9:16": "720:1280"
        case "1:1": "960:960"
        default: "1280:720" // 16:9
        }
    }

    static func imageRatio(for aspect: String) -> String {
        switch aspect {
        case "9:16": "1080:1920"
        case "1:1": "1024:1024"
        case "4:3": "1440:1080"
        case "3:4": "1080:1440"
        default: "1920:1080" // 16:9
        }
    }

    // MARK: - Entry builders

    private static func video(
        _ id: String, _ name: String, apiModel: String, durations: [Int]
    ) -> RunwayModel {
        RunwayModel(
            entry: CatalogEntry(
                id: id, kind: .video, displayName: name,
                allowedEndpoints: [id], responseShape: .video,
                uiCapabilities: .video(VideoCaps(
                    durations: durations, resolutions: nil,
                    aspectRatios: ["16:9", "9:16", "1:1"],
                    supportsFirstFrame: false, supportsLastFrame: false,
                    maxReferenceImages: 1, maxReferenceVideos: 0, maxReferenceAudios: 0,
                    maxTotalReferences: 1,
                    maxCombinedVideoRefSeconds: nil, maxCombinedAudioRefSeconds: nil,
                    framesAndReferencesExclusive: false, referenceTagNoun: "image",
                    requiresSourceVideo: false, requiresReferenceImage: true
                ))
            ),
            apiModel: apiModel
        )
    }

    private static func image(_ id: String, _ name: String, apiModel: String) -> RunwayModel {
        RunwayModel(
            entry: CatalogEntry(
                id: id, kind: .image, displayName: name,
                allowedEndpoints: [id], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil,
                    aspectRatios: ["16:9", "9:16", "1:1", "4:3", "3:4"],
                    qualities: nil,
                    supportsImageReference: false, maxImages: 1
                ))
            ),
            apiModel: apiModel
        )
    }
}
