import Foundation

/// Google's image models reached on the user's OWN Google AI key (#212) — the Gemini image line.
/// fal hosts a copy of one of them; this registry declares the DIRECT route so a user holding only a
/// Google key can still make images, and so a user holding both gets the cheaper binding rather than
/// the fal middleman.
///
/// Where a model HAS a fal counterpart its id is deliberately SHARED with the fal entry
/// (`fal-ai/gemini-25-flash-image/edit`) rather than namespaced under `google/`: the catalog merges
/// entries by id and unions their offers, so one logical model carries both a `.fal` and a `.google`
/// offer and the resolver picks by activation — the whole point of "the same model can be reachable
/// through several providers". A model with no fal counterpart gets its own `google/` id.
///
/// **Imagen is deliberately absent.** All three variants (`imagen-4.0-{,fast-,ultra-}generate-001`)
/// answer `404 NOT_FOUND: "no longer available to new users. Please update your code to use a newer
/// model."` — while still being listed by `GET /v1beta/models` with `methods: ["predict"]`. Offering
/// it would 404 at spend time, which is the one thing #159 forbids. Google's own guidance is the
/// Gemini image line, which is what this registry carries and what is verified to actually run.
///
/// These entries are NOT in the launch seed: `DirectImageDiscovery` layers them on. Note what that
/// filter can and cannot do — see its own note: absence from the list is proof of unavailability;
/// presence is NOT proof of availability.
struct GoogleImageModel: Sendable {
    let entry: CatalogEntry
    /// Google model strings to try, in order — the first the key exposes wins. A list rather than one
    /// id because Google renames across GA/preview (`…-preview-…` → `…-001`), and a stale single id
    /// would silently drop the model. Discovery resolves it against the live model list.
    let apiModelCandidates: [String]
}

enum GoogleModelRegistry {
    static let idPrefix = "google/"

    /// The Gemini image family takes its ratio in `generationConfig.imageConfig.aspectRatio`. Its enum
    /// is wider than Imagen's (it also does 2:3, 3:2, 4:5, 5:4, 21:9 and some extreme strips), but
    /// these are the five NGV actually speaks — advertising ratios the brief can never ask for would
    /// be noise, not honesty. Verified live against the API's own error enum.
    private static let geminiAspects = ["1:1", "16:9", "9:16", "4:3", "3:4"]

    static let models: [GoogleImageModel] = [
        // Shares the fal id for the Gemini 2.5 edit model. Kept as the fal-hosted model's direct route;
        // the 3.x line below supersedes it for quality, but this id is fal's and stays reachable.
        GoogleImageModel(
            entry: CatalogEntry(
                id: "fal-ai/gemini-25-flash-image/edit", kind: .image, displayName: "Gemini 2.5 Flash (edit)",
                allowedEndpoints: ["fal-ai/gemini-25-flash-image/edit"], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil, aspectRatios: geminiAspects, qualities: nil,
                    supportsImageReference: true, maxImages: 1))),
            apiModelCandidates: ["gemini-2.5-flash-image", "gemini-2.5-flash-image-preview"]),
        // The current Gemini image line. No fal counterpart in the registry, so these carry their own
        // `google/` ids. Two tiers, because that is the real choice: quality vs speed/price. (The
        // account also exposes `gemini-3.1-flash-lite-image`; left out until a cheaper-still tier has
        // a consumer, rather than adding a row on spec.)
        GoogleImageModel(
            entry: CatalogEntry(
                id: "google/gemini-3-pro-image", kind: .image, displayName: "Gemini 3 Pro Image",
                allowedEndpoints: ["google/gemini-3-pro-image"], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil, aspectRatios: geminiAspects, qualities: nil,
                    supportsImageReference: true, maxImages: 1))),
            apiModelCandidates: ["gemini-3-pro-image", "gemini-3-pro-image-preview"]),
        GoogleImageModel(
            entry: CatalogEntry(
                id: "google/gemini-3.1-flash-image", kind: .image, displayName: "Gemini 3.1 Flash Image",
                allowedEndpoints: ["google/gemini-3.1-flash-image"], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil, aspectRatios: geminiAspects, qualities: nil,
                    supportsImageReference: true, maxImages: 1))),
            apiModelCandidates: ["gemini-3.1-flash-image", "gemini-3.1-flash-image-preview"]),
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
