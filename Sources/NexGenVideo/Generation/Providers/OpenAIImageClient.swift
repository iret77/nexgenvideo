import Foundation

/// Direct client for the OpenAI Images API (api.openai.com), used when the user has an OpenAI key in
/// Settings → Providers — their own OpenAI account is billed instead of routing through a hosted copy
/// (#212: someone holding only an OpenAI key must still be able to make images). Port of the direct-
/// provider half of `render/images/openai_provider.py`.
///
/// Returns raw image BYTES (no hosted URL), like `ElevenLabsClient` — `gpt-image-1` answers with
/// base64 regardless of `response_format`, so we never depend on a short-lived CDN link.
actor OpenAIImageClient {
    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private static let base = "https://api.openai.com/v1"

    enum ClientError: LocalizedError {
        case http(status: Int, message: String)
        case noImage(String)

        var errorDescription: String? {
            switch self {
            case .http(let status, let message):
                return "OpenAI API error \(status): \(message)"
            case .noImage(let detail):
                return "OpenAI returned no image: \(detail)"
            }
        }
    }

    // MARK: - Availability

    /// `GET /v1/models` — the model ids this key can actually reach, so the catalog only offers what
    /// the user can really run (#159). An id the account isn't entitled to (image models are gated
    /// behind org verification) simply never appears, instead of failing at spend time.
    func availableModelIds() async throws -> Set<String> {
        var request = URLRequest(url: URL(string: "\(Self.base)/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else { return [] }
        return Set(models.compactMap { $0["id"] as? String })
    }

    // MARK: - Generation

    /// `POST /v1/images/generations`. `size` is OpenAI's own enum — the registry maps NGV's aspect
    /// label to it, and only advertises the ratios this model genuinely produces.
    func generate(
        model: String, prompt: String, size: String, quality: String?, count: Int
    ) async throws -> [Data] {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "size": size,
            "n": max(1, min(4, count)),
        ]
        if let quality, !quality.isEmpty { body["quality"] = quality }
        let data = try await post(path: "images/generations", body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]], !entries.isEmpty else {
            throw ClientError.noImage(Self.snippet(data))
        }
        let images = entries.compactMap { entry -> Data? in
            (entry["b64_json"] as? String).flatMap { Data(base64Encoded: $0) }
        }
        guard !images.isEmpty else { throw ClientError.noImage(Self.snippet(data)) }
        return images
    }

    // MARK: - Transport

    private func post(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(Self.base)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        // Image generation is slow enough that the default 60s timeout bites on larger sizes.
        var request = request
        request.timeoutInterval = 180
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClientError.http(status: status, message: Self.errorMessage(data))
        }
        return data
    }

    /// OpenAI's error envelope is `{"error":{"message":…}}`; fall back to a bounded raw snippet.
    private static func errorMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return snippet(data)
    }

    private static func snippet(_ data: Data) -> String {
        String(decoding: data.prefix(400), as: UTF8.self)
    }
}
