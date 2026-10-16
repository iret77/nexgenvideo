import Foundation

struct AnthropicModelInfo: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let createdAt: Date?
    let family: String?
    let lifecycle: String?
    let maxOutputTokens: Int?
    let supportsAdaptiveThinking: Bool
    let supportsHighEffort: Bool

    var isRetired: Bool { lifecycle == "retired" }
    var isActive: Bool { lifecycle == nil || lifecycle == "active" }
    var supportsToolSearch: Bool { AnthropicToolSearch.isDocumented(modelID: id) }

    /// A stored id the provider has not listed (yet): no capability is assumed.
    static func unlisted(_ id: String, family: String? = nil) -> AnthropicModelInfo {
        AnthropicModelInfo(
            id: id,
            displayName: id,
            createdAt: nil,
            family: family ?? derivedFamily(fromID: id),
            lifecycle: nil,
            maxOutputTokens: nil,
            supportsAdaptiveThinking: false,
            supportsHighEffort: false
        )
    }

    /// Fallback only for payloads or stored ids without the API's `line` field.
    static func derivedFamily(fromID id: String) -> String? {
        let parts = id.split(separator: "-")
        guard parts.count >= 3, parts[0] == "claude" else { return nil }
        let candidate = parts[1]
        guard !candidate.isEmpty, candidate.allSatisfy({ $0.isLetter }) else { return nil }
        return candidate.lowercased()
    }
}

enum AnthropicModelsAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/models")!
    static let pageLimit = 1000
    static let maximumPages = 20

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    struct Page: Sendable, Equatable {
        let models: [AnthropicModelInfo]
        let hasMore: Bool
        let lastID: String?
    }

    enum DiscoveryError: LocalizedError, Sendable, Equatable {
        case http(status: Int)
        case invalidResponse
        case emptyList
        case incompletePagination
        case pageLimitReached

        var errorDescription: String? {
            switch self {
            case .http(let status): "The Anthropic model list returned HTTP \(status)."
            case .invalidResponse: "The Anthropic model list could not be read."
            case .emptyList: "The Anthropic API key has no models available."
            case .incompletePagination: "The Anthropic model list reported more pages without a new cursor."
            case .pageLimitReached: "The Anthropic model list has more pages than NexGenVideo reads."
            }
        }
    }

    static let liveTransport: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    static func request(apiKey: String, afterID: String?) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "limit", value: String(pageLimit))]
        if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return request
    }

    /// Succeeds only on the page that reports `has_more: false`; anything short of that is an error.
    static func fetchAll(apiKey: String, transport: Transport) async throws -> [AnthropicModelInfo] {
        var models: [AnthropicModelInfo] = []
        var seen: Set<String> = []
        var cursors: Set<String> = []
        var afterID: String?
        for _ in 0..<maximumPages {
            let (data, response) = try await transport(request(apiKey: apiKey, afterID: afterID))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DiscoveryError.http(status: http.statusCode)
            }
            let parsed = try Self.page(from: data)
            for model in parsed.models where seen.insert(model.id).inserted {
                models.append(model)
            }
            guard parsed.hasMore else {
                guard !models.isEmpty else { throw DiscoveryError.emptyList }
                return models
            }
            guard let next = parsed.lastID, !next.isEmpty, cursors.insert(next).inserted else {
                throw DiscoveryError.incompletePagination
            }
            afterID = next
        }
        throw DiscoveryError.pageLimitReached
    }

    static func page(from data: Data) throws -> Page {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else {
            throw DiscoveryError.invalidResponse
        }
        return Page(
            models: entries.compactMap(model(from:)),
            hasMore: object["has_more"] as? Bool ?? false,
            lastID: object["last_id"] as? String
        )
    }

    static func model(from entry: [String: Any]) -> AnthropicModelInfo? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        let capabilities = entry["capabilities"] as? [String: Any]
        func supported(_ path: [String]) -> Bool {
            var node: Any? = capabilities
            for key in path { node = (node as? [String: Any])?[key] }
            return (node as? [String: Any])?["supported"] as? Bool ?? false
        }
        let family: String?
        if entry.keys.contains("line") {
            family = (entry["line"] as? String)?.lowercased()
        } else {
            family = AnthropicModelInfo.derivedFamily(fromID: id)
        }
        let name = (entry["display_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AnthropicModelInfo(
            id: id,
            displayName: name?.isEmpty == false ? name! : id,
            createdAt: (entry["created_at"] as? String).flatMap { releaseDate($0) },
            family: family,
            lifecycle: entry["lifecycle"] as? String,
            maxOutputTokens: entry["max_tokens"] as? Int,
            supportsAdaptiveThinking: supported(["thinking", "types", "adaptive"]),
            supportsHighEffort: supported(["effort"]) && supported(["effort", "high"])
        )
    }

    /// RFC 3339; the API uses an epoch value when the release date is unknown.
    static func releaseDate(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: value) ?? fractional.date(from: value),
              date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}

enum AnthropicModelSelection {
    static let defaultFamily = "sonnet"

    struct PickerGroups: Equatable {
        let current: [AnthropicModelInfo]
        let older: [AnthropicModelInfo]
    }

    /// Newest release first; the API's own order breaks ties and covers unknown dates.
    static func ordered(_ models: [AnthropicModelInfo]) -> [AnthropicModelInfo] {
        models.enumerated().sorted { lhs, rhs in
            let left = lhs.element.createdAt ?? .distantPast
            let right = rhs.element.createdAt ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map { $0.element }
    }

    static func newest(in models: [AnthropicModelInfo], family: String) -> AnthropicModelInfo? {
        let candidates = ordered(models.filter { $0.family == family && !$0.isRetired })
        return candidates.first(where: \.isActive) ?? candidates.first
    }

    static func defaultModel(in models: [AnthropicModelInfo]) -> AnthropicModelInfo? {
        let usable = ordered(models.filter { !$0.isRetired })
        return newest(in: models, family: defaultFamily)
            ?? usable.first(where: \.isActive)
            ?? usable.first
    }

    /// Without a current list the stored id is kept as-is: a stale cache cannot prove it is gone.
    static func resolve(
        storedID: String?,
        storedFamily: String?,
        models: [AnthropicModelInfo],
        listIsCurrent: Bool = true
    ) -> AnthropicModelInfo? {
        let stored = storedID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = stored?.isEmpty == false ? stored : nil
        if let id, let offered = models.first(where: { $0.id == id && !$0.isRetired }) {
            return offered
        }
        if let id, !listIsCurrent || models.isEmpty {
            return AnthropicModelInfo.unlisted(id, family: storedFamily)
        }
        if let id,
           let family = storedFamily ?? AnthropicModelInfo.derivedFamily(fromID: id),
           let successor = newest(in: models, family: family) {
            return successor
        }
        return defaultModel(in: models)
    }

    static func pickerGroups(_ models: [AnthropicModelInfo]) -> PickerGroups {
        var current: [AnthropicModelInfo] = []
        var older: [AnthropicModelInfo] = []
        var seenFamilies: Set<String> = []
        let usable = models.filter { !$0.isRetired }
        let byFamily = Dictionary(grouping: usable) { $0.family ?? "id:" + $0.id }
        let newestPerFamily = Set(byFamily.values.compactMap { members -> String? in
            let ranked = ordered(members)
            return (ranked.first(where: \.isActive) ?? ranked.first)?.id
        })
        for model in ordered(usable) {
            let family = model.family ?? "id:" + model.id
            if newestPerFamily.contains(model.id), seenFamilies.insert(family).inserted {
                current.append(model)
            } else {
                older.append(model)
            }
        }
        return PickerGroups(current: current, older: older)
    }
}

/// Persists the user's choice as a plain id plus the last successful model list.
struct AnthropicModelCatalogStore {
    static let modelKey = "agentModel"
    static let familyKey = "agentModelFamily"
    static let catalogKey = "anthropicModelCatalog"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var storedModelID: String? {
        get { defaults.string(forKey: Self.modelKey) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Self.modelKey) }
            else { defaults.removeObject(forKey: Self.modelKey) }
        }
    }

    var storedFamily: String? {
        get { defaults.string(forKey: Self.familyKey) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Self.familyKey) }
            else { defaults.removeObject(forKey: Self.familyKey) }
        }
    }

    func cachedModels() -> [AnthropicModelInfo] {
        guard let data = defaults.data(forKey: Self.catalogKey),
              let models = try? JSONDecoder().decode([AnthropicModelInfo].self, from: data)
        else { return [] }
        return models
    }

    func saveCatalog(_ models: [AnthropicModelInfo]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: Self.catalogKey)
    }

    /// Family pinned or concrete id pinned, resolved against the last discovered list.
    func resolveRoute(_ value: String) -> (family: String?, modelID: String?) {
        let models = cachedModels()
        if let exact = models.first(where: { $0.id == value }) {
            return (exact.family, exact.id)
        }
        let family = value.lowercased()
        if let newest = AnthropicModelSelection.newest(in: models, family: family) {
            return (family, newest.id)
        }
        let isFamilyToken = !value.isEmpty && value.allSatisfy { $0.isLetter }
        return (isFamilyToken ? family : AnthropicModelInfo.derivedFamily(fromID: value), nil)
    }
}
