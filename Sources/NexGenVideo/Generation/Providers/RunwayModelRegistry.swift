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
        // #223 — the restyle pass. The FIRST model on the source-video edit path: `generateVideoEdit`
        // and the submission's edit branch already existed but nothing routed to them until now.
        videoEdit("runway/aleph2", "Runway Aleph 2 (restyle)", apiModel: "aleph2"),
    ]

    /// Models that only appear once the user's ACCOUNT is known to carry them (`discoveredEntries`).
    /// Aleph is here because its predecessor, `gen4_aleph`, is being sunset (2026-07-30) — a hardcoded
    /// seed entry is exactly how a dead model reaches a user. The account's own list decides instead.
    private static let discoveryGated: Set<String> = ["runway/aleph2"]

    /// The launch seed — the models whose ids are pinned against the published SDK and which every
    /// Runway key can reach. Discovery-gated models are excluded; they arrive via `discoveredEntries`.
    static let entries: [CatalogEntry] = models
        .filter { !discoveryGated.contains($0.entry.id) }
        .map { model in
            var e = model.entry
            e.offers = [ProviderOffer(provider: .runway, providerRef: e.id)]
            return e
        }

    /// The discovery-gated models this ACCOUNT actually carries — resolved against
    /// `GET /v1/organization`'s `tier.models` (#159: offer only what is really runnable).
    ///
    /// This is what the owner asked for in #223 and what I wrongly reported as impossible: Runway has
    /// no `GET /v1/models`, but the organization endpoint returns the account's entitled model ids,
    /// which is *better* than a global list — it is scoped to this key. Hardcoding `gen4_aleph`
    /// instead is precisely how a model 14 days from sunset got shipped.
    static func discoveredEntries(availableModelIds: Set<String>) -> [CatalogEntry] {
        models
            .filter { discoveryGated.contains($0.entry.id) && availableModelIds.contains($0.apiModel) }
            .map { model in
                var e = model.entry
                e.offers = [ProviderOffer(provider: .runway, providerRef: e.id)]
                return e
            }
    }

    private static let byId: [String: RunwayModel] =
        Dictionary(models.map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func model(for id: String) -> RunwayModel? { byId[id] }

    /// Whether this Runway model consumes a source video (the restyle path) rather than an image.
    /// Read off the catalog caps, so the registry stays the single place that decides it.
    static func requiresSourceVideo(_ model: RunwayModel) -> Bool {
        guard case .video(let caps) = model.entry.uiCapabilities else { return false }
        return caps.requiresSourceVideo
    }

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

    /// A source-video edit model: it consumes a clip and re-renders it. `requiresSourceVideo` is what
    /// routes it to the edit path — and what makes `PromptCompiler` apply the composition-preserving
    /// prompt profile, so a restyle can never be compiled like a generation.
    ///
    /// No durations: the output follows the SOURCE clip's length, so a duration would be a knob that
    /// does nothing. Aspect likewise follows the source — the ratio is derived from it at dispatch.
    private static func videoEdit(_ id: String, _ name: String, apiModel: String) -> RunwayModel {
        RunwayModel(
            entry: CatalogEntry(
                id: id, kind: .video, displayName: name,
                allowedEndpoints: [id], responseShape: .video,
                uiCapabilities: .video(VideoCaps(
                    durations: [], resolutions: nil,
                    aspectRatios: ["16:9", "9:16", "1:1"],
                    supportsFirstFrame: false, supportsLastFrame: false,
                    maxReferenceImages: 0, maxReferenceVideos: 0, maxReferenceAudios: 0,
                    maxTotalReferences: 0,
                    maxCombinedVideoRefSeconds: nil, maxCombinedAudioRefSeconds: nil,
                    framesAndReferencesExclusive: false, referenceTagNoun: "image",
                    requiresSourceVideo: true, requiresReferenceImage: false
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
