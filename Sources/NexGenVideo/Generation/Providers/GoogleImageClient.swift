import Foundation
import ImageIO

/// Direct client for Google's Generative Language API (generativelanguage.googleapis.com), used when
/// the user has a Google AI key in Settings → Providers — so their own Google account is billed
/// instead of routing through fal's hosted copies of the same models (#212: fal is *a* way to images,
/// not *the* way). Port of the direct-provider half of `render/images/google_provider.py`.
///
/// One request shape: `:generateContent` — a contents/parts envelope with
/// `responseModalities: ["IMAGE"]`, images back as inline base64 parts, and reference images riding
/// along as extra `inline_data` parts (that is how this family does image-to-image).
///
/// Imagen's `:predict` envelope is deliberately NOT here: every `imagen-4.0-*` variant answers 404
/// ("no longer available to new users") on this API, so a client for it would be code for a route
/// nothing can take.
///
/// Every generation endpoint returns raw image BYTES (no hosted URL), like `ElevenLabsClient`.
actor GoogleImageClient {
    let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private static let base = "https://generativelanguage.googleapis.com/v1beta"
    static let catalogPageSize = 200
    static let catalogPageLimit = 20

    struct PreparedGeminiImageRequest: @unchecked Sendable {
        fileprivate let request: URLRequest
    }

    enum ClientError: LocalizedError {
        case noImage(String)
        case corruptReference
        case unsupportedReference

        var errorDescription: String? {
            switch self {
            case .noImage(let detail):
                return "Google AI returned no image: \(detail)"
            case .corruptReference:
                return "Reference image is corrupt or has an unreadable image container."
            case .unsupportedReference:
                return "Reference image is not a PNG, JPEG, WebP or HEIC file."
            }
        }
    }

    /// Gemini decodes `inline_data` by its DECLARED mime type, so a mislabeled reference fails the
    /// call. The bytes come from whatever the user imported — commonly JPEG or HEIC, not PNG — so
    /// sniff the real format from the magic numbers rather than trusting a name or a default.
    /// An unrecognized format fails HERE, with a sentence that names the problem, instead of being
    /// dressed up as a PNG and coming back as an opaque Google 400.
    static func mimeType(of data: Data) throws -> String {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 12 else { throw ClientError.unsupportedReference }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        // ISO-BMFF: "ftyp" at offset 4, brand at 8. Covers HEIC and its HEIF siblings, which Apple
        // hands out by default — the format most likely to reach this from a Mac photo library.
        if Array(b[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            switch String(decoding: b[8..<12], as: UTF8.self) {
            case "heic", "heix", "hevc", "hevx": return "image/heic"
            case "mif1", "msf1", "heim", "heis": return "image/heif"
            default: throw ClientError.unsupportedReference
            }
        }
        throw ClientError.unsupportedReference
    }

    // MARK: - Availability

    /// `GET /v1beta/models` — the model ids this key can actually reach. Used to keep the catalog
    /// honest: a registry entry whose id Google doesn't expose to this key never reaches the user
    /// (#159), instead of 404-ing after they've committed to a render.
    func availableModelIds() async throws -> Set<String> {
        var modelIds: Set<String> = []
        var requestedTokens: Set<String> = []
        var pageToken: String?

        for pageIndex in 0..<Self.catalogPageLimit {
            var components = URLComponents(string: "\(Self.base)/models")!
            var queryItems = [
                URLQueryItem(name: "pageSize", value: String(Self.catalogPageSize))
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

            let data = try await send(request)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["models"] as? [Any],
                  models.count <= Self.catalogPageSize else {
                throw Self.malformedCatalog("page \(pageIndex + 1) has an invalid models array")
            }
            for (entryIndex, entry) in models.enumerated() {
                guard let model = entry as? [String: Any],
                      let name = model["name"] as? String,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Self.malformedCatalog(
                        "page \(pageIndex + 1) entry \(entryIndex + 1) has no valid name"
                    )
                }
                let normalized = name.hasPrefix("models/")
                    ? String(name.dropFirst("models/".count)) : name
                guard !normalized.isEmpty,
                      !normalized.unicodeScalars.contains(where: {
                          CharacterSet.whitespacesAndNewlines.contains($0)
                      }) else {
                    throw Self.malformedCatalog(
                        "page \(pageIndex + 1) entry \(entryIndex + 1) has no valid name"
                    )
                }
                modelIds.insert(normalized)
            }

            let nextToken: String?
            if let rawToken = object["nextPageToken"] {
                guard let token = rawToken as? String,
                      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Self.malformedCatalog(
                        "page \(pageIndex + 1) has an invalid nextPageToken"
                    )
                }
                nextToken = token
            } else {
                nextToken = nil
            }

            if models.isEmpty, nextToken != nil {
                throw Self.malformedCatalog(
                    "page \(pageIndex + 1) is empty but includes nextPageToken"
                )
            }
            guard let nextToken else {
                guard models.count < Self.catalogPageSize else {
                    throw Self.malformedCatalog(
                        "page \(pageIndex + 1) is full but omits nextPageToken"
                    )
                }
                return modelIds
            }
            guard requestedTokens.insert(nextToken).inserted else {
                throw Self.malformedCatalog(
                    "page \(pageIndex + 1) repeats nextPageToken"
                )
            }
            guard pageIndex + 1 < Self.catalogPageLimit else {
                throw GenerationBackendError.transport(
                    "Google AI model catalog exceeded the \(Self.catalogPageLimit)-page safety limit."
                )
            }
            pageToken = nextToken
        }

        throw GenerationBackendError.transport(
            "Google AI model catalog exceeded the \(Self.catalogPageLimit)-page safety limit."
        )
    }

    // MARK: - Generation

    /// Gemini image via `:generateContent`. `referenceImages` ride along as inline parts, which is how
    /// this family does image-to-image — the same call, one more part.
    ///
    /// `aspectRatio` goes in `generationConfig.imageConfig` and is NOT optional in practice: without it
    /// the model picks its own shape, and `frame_ratio` compares every frame's real pixel aspect against
    /// the brief within 2% — so an unsent ratio flags on every sheet. Google's enum (verified live)
    /// is 1:1 / 1:4 / 1:8 / 2:3 / 3:2 / 3:4 / 4:1 / 4:3 / 4:5 / 5:4 / 8:1 / 9:16 / 16:9 / 21:9, which
    /// covers everything NGV speaks; an empty value is simply omitted.
    func prepareGeminiImageRequest(
        model: String, prompt: String, aspectRatio: String = "", referenceImages: [Data] = []
    ) throws -> PreparedGeminiImageRequest {
        var parts: [[String: Any]] = [["text": prompt]]
        for image in referenceImages {
            let mime = try Self.mimeType(of: image)
            try Self.validateImageContainer(image)
            parts.append(["inline_data": ["mime_type": mime, "data": image.base64EncodedString()]])
        }
        var generationConfig: [String: Any] = ["responseModalities": ["IMAGE"]]
        if !aspectRatio.isEmpty {
            generationConfig["imageConfig"] = ["aspectRatio": aspectRatio]
        }
        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": generationConfig,
        ]
        return PreparedGeminiImageRequest(
            request: try makePostRequest(path: "models/\(model):generateContent", body: body)
        )
    }

    func geminiImage(prepared: PreparedGeminiImageRequest) async throws -> [Data] {
        let data = try await send(prepared.request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]] else {
            throw ClientError.noImage(Self.snippet(data))
        }
        var images: [Data] = []
        for candidate in candidates {
            let content = candidate["content"] as? [String: Any]
            for part in (content?["parts"] as? [[String: Any]] ?? []) {
                // The wire key is camelCase on the way out even though requests take snake_case.
                let inline = (part["inlineData"] ?? part["inline_data"]) as? [String: Any]
                if let b64 = inline?["data"] as? String, let bytes = Data(base64Encoded: b64) {
                    images.append(bytes)
                }
            }
        }
        guard !images.isEmpty else { throw ClientError.noImage(Self.snippet(data)) }
        return images
    }

    func geminiImage(
        model: String, prompt: String, aspectRatio: String = "", referenceImages: [Data] = []
    ) async throws -> [Data] {
        let prepared = try prepareGeminiImageRequest(
            model: model,
            prompt: prompt,
            aspectRatio: aspectRatio,
            referenceImages: referenceImages
        )
        return try await geminiImage(prepared: prepared)
    }

    // MARK: - Transport

    private func makePostRequest(path: String, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: "\(Self.base)/\(path)") else {
            throw GenerationBackendError.transport("Could not prepare the Google AI request URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Header auth, not `?key=` — keeps the key out of URLs (and out of any logged request line).
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GenerationBackendError.api(
                status: status,
                code: String(status),
                message: "Google AI API error \(status): \(Self.errorMessage(data))"
            )
        }
        return data
    }

    /// Google's error envelope is `{"error":{"message":…}}`; fall back to a bounded raw snippet.
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

    private static func malformedCatalog(_ detail: String) -> GenerationBackendError {
        .transport("Google AI returned a malformed model catalog: \(detail).")
    }

    private static func validateImageContainer(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetStatus(source) == .statusComplete,
           CGImageSourceGetCount(source) > 0,
           CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
           CGImageSourceCreateImageAtIndex(
               source,
               0,
               [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
           ) != nil else {
            throw ClientError.corruptReference
        }
    }
}
