import Foundation

/// Fetches the curated model catalog (models + capabilities + pricing + the LLM-education cards)
/// from a remotely-hosted JSON file, so new models and ranking changes reach every client WITHOUT
/// an app release — the model landscape moves weekly. Cached to Application Support; the in-code
/// provider registries (loaded synchronously at launch) are the offline fallback and first-run seed.
/// HTTPS only. The hosted file is a JSON array of `CatalogEntry`.
enum RemoteCatalog {
    /// Same repo that serves the appcast; swap models.json to ship catalog changes release-free.
    static let url = URL(string: "https://raw.githubusercontent.com/iret77/nexgenvideo/main/catalog/models.json")!

    private static var cacheURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("NexGenVideo/model-catalog.json")
    }

    /// Apply the last cached remote catalog (instant, freshest known), then fetch the live one and
    /// apply + cache it. On any failure the already-loaded catalog (cache, or the launch-seeded
    /// registries) stays — the app is never left without a catalog.
    @MainActor
    static func refresh() async {
        if let entries = decode(cachedData()), !entries.isEmpty {
            ModelCatalog.shared.load(entries: overlay(entries, on: ModelCatalog.launchEntries))
        }
        guard let data = await fetchData(), let entries = decode(data), !entries.isEmpty else { return }
        cache(data)
        ModelCatalog.shared.load(entries: overlay(entries, on: ModelCatalog.launchEntries))
        Log.generation.notice("remote catalog applied: \(entries.count) models")
    }

    /// Preserve seed routing fields when a remote entry omits them.
    static func overlay(_ remote: [CatalogEntry], on seed: [CatalogEntry]) -> [CatalogEntry] {
        let seedById = Dictionary(seed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteIds = Set(remote.map(\.id))
        let overlaid = remote.map { entry -> CatalogEntry in
            guard let fallback = seedById[entry.id] else { return entry }
            return CatalogEntry(
                id: entry.id,
                kind: entry.kind,
                displayName: entry.displayName,
                allowedEndpoints: entry.allowedEndpoints.isEmpty ? fallback.allowedEndpoints : entry.allowedEndpoints,
                responseShape: entry.responseShape,
                uiCapabilities: entry.uiCapabilities,
                creditsPerSecond: entry.creditsPerSecond,
                audioDiscountRate: entry.audioDiscountRate,
                creditsPerImage: entry.creditsPerImage,
                qualities: entry.qualities,
                audioPricing: entry.audioPricing,
                creditsPerSecondUpscale: entry.creditsPerSecondUpscale,
                card: entry.card,
                offers: entry.offers ?? fallback.offers
            )
        }
        return seed.filter { !remoteIds.contains($0.id) } + overlaid
    }

    private static func fetchData() async -> Data? {
        guard url.scheme == "https" else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            Log.generation.notice("remote catalog fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func decode(_ data: Data?) -> [CatalogEntry]? {
        data.flatMap { try? JSONDecoder().decode([CatalogEntry].self, from: $0) }
    }

    private static func cachedData() -> Data? {
        guard let cacheURL else { return nil }
        return try? Data(contentsOf: cacheURL)
    }

    private static func cache(_ data: Data) {
        guard let cacheURL else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL)
    }
}
