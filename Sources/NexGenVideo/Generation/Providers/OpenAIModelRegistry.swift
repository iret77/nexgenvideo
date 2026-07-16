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

    /// gpt-image-1 renders three shapes: square, landscape 3:2, portrait 2:3. It has **no 16:9**.
    /// Advertising 16:9 and quietly returning 3:2 would be a lie the pipeline itself catches —
    /// `frame_ratio` compares each frame's real pixel aspect against the brief's within 2%, and
    /// 3:2 (1.50) vs 16:9 (1.78) is far outside that. So the honest caps are these, and a 16:9
    /// project reaches this model through `crop_to_aspect`, not through a silent mismatch.
    private static let gptImageSizes = [
        "1:1": "1024x1024",
        "3:2": "1536x1024",
        "2:3": "1024x1536",
    ]

    static let models: [OpenAIImageModel] = [
        OpenAIImageModel(
            entry: CatalogEntry(
                id: "openai/gpt-image-1", kind: .image, displayName: "GPT Image 1",
                allowedEndpoints: ["openai/gpt-image-1"], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil, aspectRatios: Array(gptImageSizes.keys).sorted(),
                    qualities: ["low", "medium", "high"],
                    supportsImageReference: false, maxImages: 4))),
            apiModelCandidates: ["gpt-image-1"],
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
