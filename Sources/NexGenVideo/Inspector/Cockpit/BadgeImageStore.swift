import AppKit

/// In-memory badge-art loader + cache for the plugin gallery.
///
/// A badge is either a local file (an installed pack's own art) or a remote https
/// URL (a catalog badge shown BEFORE install). Loading happens off the main thread
/// and each URL's image is cached for the session, so the gallery never blocks on a
/// synchronous `NSImage(contentsOf:)`. A non-https remote URL (or any load failure)
/// simply doesn't load — the caller falls back to the gradient, never an error
/// (the finding-5 https rule, extended to badges).
@MainActor
final class BadgeImageStore {
    static let shared = BadgeImageStore()

    private var cache: [URL: NSImage] = [:]

    /// A badge URL we're willing to fetch: a local file, or https. Pure + testable.
    nonisolated static func isLoadable(_ url: URL) -> Bool {
        url.isFileURL || url.scheme?.lowercased() == "https"
    }

    /// The already-loaded image for `url`, if any (synchronous, no IO).
    func cached(_ url: URL) -> NSImage? { cache[url] }

    /// The badge image for `url`: cached, else loaded off-main and cached. Returns
    /// nil for a disallowed scheme or a load failure (caller shows the gradient).
    func image(for url: URL) async -> NSImage? {
        if let hit = cache[url] { return hit }
        guard Self.isLoadable(url) else { return nil }
        // Load bytes off-main (Data is Sendable); build the NSImage back on-main.
        let data: Data? = await Task.detached(priority: .utility) {
            if url.isFileURL { return try? Data(contentsOf: url) }
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            return data
        }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        cache[url] = image
        return image
    }
}
