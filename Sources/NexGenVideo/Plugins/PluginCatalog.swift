import Foundation

/// The `plugins.json` catalog published as an asset on the `dev-latest` release,
/// listing every available pack. The picker fetches it to offer install/update;
/// a fetch failure is a calm offline state (installed packs keep working).
struct PluginCatalog: Decodable, Equatable {
    let plugins: [Entry]

    struct Entry: Decodable, Equatable, Identifiable {
        let id: String
        let displayName: String
        let tagline: String
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
    /// The catalog asset on the rolling `dev-latest` prerelease.
    static let catalogURL = URL(
        string: "https://github.com/iret77/nexgen-video/releases/download/dev-latest/plugins.json")!

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
