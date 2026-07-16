import Foundation

/// OpenAI's image models on the user's OWN OpenAI key (#212). No fal counterpart ships in the
/// registry today, so these carry their own `openai/` ids rather than sharing one.
///
/// Not in the launch seed: layered on by `DirectImageDiscovery` only when the key really exposes the
/// model (#159). That matters more here than elsewhere — OpenAI gates image models behind org
/// verification, so a valid key is NOT proof the model is reachable.
struct OpenAIImageModel: Sendable {
    let entry: CatalogEntry
    let apiModelCandidates: [String]
    /// NGV aspect label → OpenAI `size`. Only the ratios the model genuinely renders are listed, so
    /// the mapping is exact.
    let sizeByAspect: [String: String]
}

enum OpenAIModelRegistry {
    static let idPrefix = "openai/"

    /// gpt-image-2 takes ARBITRARY resolutions, not a fixed enum: both edges a multiple of 16, long
    /// edge ≤ 3840, long:short ≤ 3:1, and 655,360–8,294,400 total pixels. So it renders every aspect
    /// NGV speaks — EXACTLY, with no crop and nothing to apologise for.
    ///
    /// (gpt-image-1 could only do square / 3:2 / 2:3, which is why an earlier cut of this registry
    /// advertised those and sent 16:9 through `crop_to_aspect`. That limitation is gone with image-2.)
    ///
    /// Two constraints picked these exact numbers rather than the obvious ones:
    /// - **Exact ratios.** `frame_ratio` compares a frame's real pixel aspect against the brief's
    ///   within 2%, so an approximation would flag on every sheet. Each pair below is the ratio
    ///   precisely (2048/1152 = 1.7778 = 16:9), not near it.
    /// - **Short edge ≥ 1024.** `frame_size` warns below that (Seedance's identity-drift floor), which
    ///   rules out the tempting 1280x720 — it is exact 16:9 and a multiple of 16, but its 720 short
    ///   edge would warn on every frame.
    private static let gptImageSizes = [
        "1:1": "1024x1024",
        "16:9": "2048x1152",
        "9:16": "1152x2048",
        "4:3": "2048x1536",
        "3:4": "1536x2048",
    ]

    static let models: [OpenAIImageModel] = [
        OpenAIImageModel(
            entry: CatalogEntry(
                id: "openai/gpt-image-2", kind: .image, displayName: "GPT Image 2",
                allowedEndpoints: ["openai/gpt-image-2"], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil, aspectRatios: Array(gptImageSizes.keys).sorted(),
                    qualities: ["low", "medium", "high"],
                    supportsImageReference: false, maxImages: 4))),
            // Only image-2. gpt-image-1 is deliberately NOT a fallback candidate: it is the older,
            // weaker model, and silently dropping to it would hand back worse pixels than the user
            // asked for. If image-2 isn't exposed to the key, the model simply doesn't appear.
            apiModelCandidates: ["gpt-image-2"],
            sizeByAspect: gptImageSizes),
    ]

    /// The entries this key actually exposes, each with an `.openai` offer whose `providerRef` is the
    /// resolved model string.
    static func entries(availableModelIds: Set<String>) -> [CatalogEntry] {
        models.compactMap { model in
            guard let apiModel = model.apiModelCandidates.first(where: { availableModelIds.contains($0) })
            else { return nil }
            var entry = model.entry
            entry.offers = [ProviderOffer(provider: .openai, providerRef: apiModel)]
            return entry
        }
    }

    /// The model behind a dispatch reference — the resolved `providerRef` (OpenAI's model string) or
    /// the catalog id. See the Google registry's note: the fallback path passes the catalog id, and it
    /// must still resolve so the user gets "add an OpenAI API key" rather than "unsupported model".
    static func model(for ref: String) -> OpenAIImageModel? {
        models.first { $0.apiModelCandidates.contains(ref) || $0.entry.id == ref }
    }

    /// OpenAI's `size` for an NGV aspect label, or nil when the model doesn't render that shape.
    static func size(forAspect aspect: String, model: OpenAIImageModel) -> String? {
        model.sizeByAspect[aspect]
    }
}
