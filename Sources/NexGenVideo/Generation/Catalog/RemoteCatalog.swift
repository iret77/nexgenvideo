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
        if let entries = decode(cachedData()), !entries.isEmpty { ModelCatalog.shared.load(entries: entries) }
        guard let data = await fetchData(), let entries = decode(data), !entries.isEmpty else { return }
        cache(data)
        ModelCatalog.shared.load(entries: entries)
        Log.generation.notice("remote catalog applied: \(entries.count) models")
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
