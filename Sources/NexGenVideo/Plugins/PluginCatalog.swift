import Foundation

/// The `catalog.json` published on the stable `plugins` channel, listing every available
/// pack — possibly in SEVERAL versions per pack, so an older app still finds its last
/// compatible one (`PluginManager.selectCompatiblePerPack` picks). The picker fetches it to
/// offer install/update; a fetch failure is a calm offline state (installed packs keep working).
struct PluginCatalog: Decodable, Equatable {
    let plugins: [Entry]

    struct Entry: Decodable, Equatable, Identifiable {
        let id: String
        let displayName: String
        let tagline: String
        /// A bold one-line card pitch (optional; card falls back to `tagline`).
        let headline: String?
        /// A short benefit line under the headline (optional).
        let benefit: String?
        let version: String
        let minAppVersion: String
        /// Download URL of the pack's zipped `.ngvpack`.
        let url: URL
        /// Lowercase hex SHA-256 of the zip, verified before install.
        let sha256: String
        /// Optional https URL of the pack's badge art, published as its own release
        /// asset so the gallery can show the real badge BEFORE install. Absent → the
        /// gallery paints its gradient fallback.
        let badge: URL?
    }
}

/// Fetches the catalog. Kept separate from the model so it can be unit-tested
/// against decoded JSON without the network.
enum PluginCatalogService {
    /// The catalog on the `plugins` channel — a dedicated release that is only ever appended to,
    /// decoupled from the app/DMG release cycle. Deliberately NOT the rolling `dev-latest`, which is
    /// deleted and recreated on every push to main: that made a versioned release ship a fixed pack
    /// the app never read (0.7.7 "Damaged pack" stayed broken in the field until dev-latest was
    /// re-run by hand). Pack assets here are version-stamped, so a URL always addresses one version.
    static let catalogURL = URL(
        string: "https://github.com/iret77/nexgenvideo/releases/download/plugins/catalog.json")!

    enum FetchError: Error { case http(Int); case empty; case insecureURL(String) }

    /// Fetch + decode the catalog. Errors (offline, 404 before the first release,
    /// malformed, or a non-https URL) are returned so the caller can fall back to
    /// installed-only.
    static func fetch(from url: URL = catalogURL) async -> Result<PluginCatalog, Error> {
        // Finding 5: the catalog itself is only ever fetched over https.
        guard url.scheme?.lowercased() == "https" else {
            return .failure(FetchError.insecureURL(url.absoluteString))
        }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(FetchError.http(http.statusCode))
            }
            guard !data.isEmpty else { return .failure(FetchError.empty) }
            return .success(try decode(data))
        } catch {
            return .failure(error)
        }
    }

    /// Pure decode — the unit-testable core.
    static func decode(_ data: Data) throws -> PluginCatalog {
        try JSONDecoder().decode(PluginCatalog.self, from: data)
    }
}
