import Foundation

/// Google's image models reached on the user's OWN Google AI key (#212). fal hosts copies of these
/// same models; this registry declares the DIRECT route so a user holding only a Google key can still
/// make images — and so a user holding both gets the cheaper binding rather than the fal middleman.
///
/// Ids are deliberately SHARED with the fal entry for the same model (`fal-ai/imagen4`), not
/// namespaced under `google/`. The catalog merges entries by id and unions their offers, so one
/// logical model ends up carrying both a `.fal` and a `.google` offer and the resolver picks by
/// activation — which is the whole point of "the same model can be reachable through several
/// providers". A model with no fal counterpart gets its own `google/` id.
///
/// These entries are NOT in the launch seed: they are layered on by `DirectImageDiscovery` only for
/// the models the user's key actually exposes (#159 — the catalog shows what is really runnable).
struct GoogleImageModel: Sendable {
    /// How Google serves this model — the two surfaces need different request envelopes.
    enum Surface: Sendable {
        /// Imagen: `:predict`, instances/parameters, `bytesBase64Encoded` back.
        case predict
        /// Gemini image ("nano-banana"): `:generateContent`, contents/parts, inline base64 back.
        case generateContent
    }

    let entry: CatalogEntry
    let surface: Surface
    /// Google model strings to try, in order — the first the key exposes wins. A list rather than one
    /// id because Google renames across GA/preview (`…-preview-…` → `…-001`), and a stale single id
    /// would silently drop the model. Discovery resolves it against the live model list.
    let apiModelCandidates: [String]
}

enum GoogleModelRegistry {
    static let idPrefix = "google/"

    /// Google's `aspectRatio` enum for Imagen — the same labels NGV uses, so no lossy mapping.
    private static let imagenAspects = ["1:1", "16:9", "9:16", "4:3", "3:4"]

    static let models: [GoogleImageModel] = [
        // Shares the fal id: one logical "Imagen 4", two offers.
        GoogleImageModel(
            entry: CatalogEntry(
                id: "fal-ai/imagen4", kind: .image, displayName: "Imagen 4",
                allowedEndpoints: ["fal-ai/imagen4"], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil, aspectRatios: imagenAspects, qualities: nil,
                    supportsImageReference: false, maxImages: 4))),
            surface: .predict,
            apiModelCandidates: ["imagen-4.0-generate-001", "imagen-4.0-generate-preview-06-06"]),
        // Shares the fal id for the Gemini edit model.
        GoogleImageModel(
            entry: CatalogEntry(
                id: "fal-ai/gemini-25-flash-image/edit", kind: .image, displayName: "Gemini 2.5 Flash (edit)",
                allowedEndpoints: ["fal-ai/gemini-25-flash-image/edit"], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil, aspectRatios: [], qualities: nil,
                    supportsImageReference: true, maxImages: 1))),
            surface: .generateContent,
            apiModelCandidates: ["gemini-2.5-flash-image", "gemini-2.5-flash-image-preview"]),
    ]

    /// The entries whose Google model string this key actually exposes, each carrying a `.google` offer
    /// whose `providerRef` is that resolved model string (what `GenerationService` dispatches on).
    /// A model none of whose candidates are available is dropped — never offered, never a 404 at spend.
    static func entries(availableModelIds: Set<String>) -> [CatalogEntry] {
        models.compactMap { model in
            guard let apiModel = model.apiModelCandidates.first(where: { availableModelIds.contains($0) })
            else { return nil }
            var entry = model.entry
            entry.offers = [ProviderOffer(provider: .google, providerRef: apiModel)]
            return entry
        }
    }

    /// The model behind a dispatch reference — either the resolved `providerRef` (Google's own model
    /// string) or the catalog id. Both, because dispatch passes the API model when a binding resolved
    /// and falls back to the catalog id when the provider isn't activated; matching only the former
    /// would answer that case with "unsupported model" instead of "add a Google AI API key".
    static func model(for ref: String) -> GoogleImageModel? {
        models.first { $0.apiModelCandidates.contains(ref) || $0.entry.id == ref }
    }
}
