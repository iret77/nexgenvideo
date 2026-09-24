import Foundation

struct HiggsfieldCredentials: Sendable {
    let value: String

    init(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              !value.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw GenerationBackendError.transport("Enter the Higgsfield key ID and secret as KEY_ID:KEY_SECRET.")
        }
        self.value = value
    }
}

struct HiggsfieldJobReceipt: Codable, Sendable, Equatable {
    let requestID: String
    let statusURL: URL
    let cancelURL: URL

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", statusURL = "status_url", cancelURL = "cancel_url"
    }

    func validate() throws {
        guard UUID(uuidString: requestID) != nil,
              HiggsfieldClient.isAPIURL(statusURL), HiggsfieldClient.isAPIURL(cancelURL),
              statusURL.path == "/requests/\(requestID)/status",
              cancelURL.path == "/requests/\(requestID)/cancel" else {
            throw GenerationBackendError.transport("Higgsfield returned an invalid job receipt.")
        }
    }
}

actor HiggsfieldClient {
    static let base = "https://api.higgsfield.ai"
    static let catalogURL = URL(string: "https://dash.higgsfield.ai/api/v2/pricing/models/?page_size=50")!
    private let credentials: HiggsfieldCredentials
    private let session: URLSession
    private let pollInterval: TimeInterval
    private let maxWait: TimeInterval

    init(apiKey: String, session: URLSession = .shared,
         pollInterval: TimeInterval = 2, maxWait: TimeInterval = 30 * 60) throws {
        credentials = try HiggsfieldCredentials(apiKey)
        self.session = session
        self.pollInterval = pollInterval.isFinite ? min(max(0, pollInterval), 10) : 2
        self.maxWait = maxWait.isFinite ? min(max(0, maxWait), 24 * 60 * 60) : 30 * 60
    }

    struct SubmissionUncertain: LocalizedError, Sendable {
        let requestID: String
        var errorDescription: String? {
            "Higgsfield may have accepted this request. NexGenVideo will not submit it again automatically. Check the API console before retrying."
        }
    }

    struct TerminalFailure: LocalizedError, Sendable {
        let status: String
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated static func isAPIURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "api.higgsfield.ai"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
    }

    nonisolated static func endpointURL(_ endpoint: String, estimate: Bool = false) throws -> URL {
        guard !endpoint.isEmpty,
              endpoint.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
                      && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
              }),
              let url = URL(string: "\(base)/\(estimate ? "estimate/" : "")\(endpoint)") else {
            throw GenerationBackendError.transport("Invalid Higgsfield model endpoint.")
        }
        return url
    }

    func submit(endpoint: String, body: Data) async throws -> HiggsfieldJobReceipt {
        let url = try Self.endpointURL(endpoint)
        try Task.checkCancellation()
        let response: (Data, HTTPURLResponse)
        do { response = try await send(url: url, method: "POST", body: body) }
        catch { throw SubmissionUncertain(requestID: "higgsfield-unknown-\(UUID().uuidString)") }
        let (data, http) = response
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode >= 500 || http.statusCode == 408 {
                throw SubmissionUncertain(requestID: "higgsfield-unknown-\(UUID().uuidString)")
            }
            throw apiError(data, status: http.statusCode)
        }
        do {
            let receipt = try JSONDecoder().decode(HiggsfieldJobReceipt.self, from: data)
            try receipt.validate()
            return receipt
        } catch {
            let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["request_id"] as? String
            throw SubmissionUncertain(requestID: id.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() } ?? "higgsfield-missing-id-\(UUID().uuidString)")
        }
    }

    func estimate(endpoint: String, body: Data) async throws -> Double {
        let (data, response) = try await send(url: Self.endpointURL(endpoint, estimate: true), method: "POST", body: body)
        guard (200..<300).contains(response.statusCode) else { throw apiError(data, status: response.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["usd"] as? String, let amount = Double(value), amount.isFinite, amount >= 0 else {
            throw GenerationBackendError.transport("Higgsfield returned no valid USD estimate.")
        }
        return amount
    }

    func output(receipt: HiggsfieldJobReceipt, shape: CatalogEntry.ResponseShape) async throws -> [String] {
        try receipt.validate()
        let deadline = Date().addingTimeInterval(maxWait)
        var delay = pollInterval
        var failures = 0
        while Date() < deadline {
            try Task.checkCancellation()
            let data: Data
            do {
                let response = try await send(url: receipt.statusURL, method: "GET")
                if response.1.statusCode == 429 || response.1.statusCode >= 500 {
                    throw URLError(.resourceUnavailable)
                }
                guard (200..<300).contains(response.1.statusCode) else {
                    throw apiError(response.0, status: response.1.statusCode)
                }
                data = response.0
                failures = 0
            } catch let error as URLError {
                if Task.isCancelled { throw CancellationError() }
                failures += 1
                guard failures <= 5 else { throw error }
                try await pause(delay, deadline: deadline)
                delay = min(10, delay * 1.5)
                continue
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = object["status"] as? String else {
                throw GenerationBackendError.transport("Higgsfield returned a malformed job status.")
            }
            switch status {
            case "completed":
                let urls: [String]
                switch shape {
                case .images: urls = (object["images"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
                case .video: urls = ((object["video"] as? [String: Any])?["url"] as? String).map { [$0] } ?? []
                default: throw GenerationBackendError.transport("Unsupported Higgsfield output type.")
                }
                guard !urls.isEmpty, urls.allSatisfy(Self.isMediaURL) else {
                    throw GenerationBackendError.transport("Higgsfield completed the job without valid media URLs.")
                }
                return urls
            case "failed", "nsfw", "canceled":
                throw TerminalFailure(status: status, message: redacted(object["error"] as? String ?? "Higgsfield generation \(status)."))
            case "queued", "in_progress": break
            default: throw GenerationBackendError.transport("Higgsfield returned an unknown job status.")
            }
            try await pause(delay, deadline: deadline)
            delay = min(10, delay * 1.5)
        }
        throw GenerationBackendError.transport("Higgsfield status polling timed out. The provider job may still be running; resume its recorded request instead of submitting again.")
    }

    func cancel(receipt: HiggsfieldJobReceipt) async throws {
        try receipt.validate()
        let (data, response) = try await send(url: receipt.cancelURL, method: "POST")
        guard response.statusCode == 202 else { throw apiError(data, status: response.statusCode) }
    }

    func uploadReference(fileURL: URL) async throws -> String {
        let mime: String
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg": mime = "image/jpeg"
        case "png": mime = "image/png"
        case "webp": mime = "image/webp"
        case "gif": mime = "image/gif"
        case "wav": mime = "audio/wav"
        case "mp4": mime = "video/mp4"
        default: throw GenerationBackendError.transport("Higgsfield input requires JPEG, PNG, WebP, GIF, WAV, or MP4 media.")
        }
        guard fileURL.isFileURL,
              try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw GenerationBackendError.transport("Higgsfield input must be a local media file.")
        }
        let body = try JSONSerialization.data(withJSONObject: ["content_type": mime])
        let (data, http) = try await send(url: URL(string: "\(Self.base)/files/generate-upload-url")!, method: "POST", body: body)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let upload = object?["upload_url"] as? String, Self.isMediaURL(upload), let url = URL(string: upload),
              let result = object?["public_url"] as? String, Self.isMediaURL(result),
              let headers = object?["upload_headers"] as? [String: String],
              headers.first(where: { $0.key.lowercased() == "content-type" })?.value == mime,
              !headers.keys.contains(where: { ["authorization", "cookie", "host"].contains($0.lowercased()) }) else {
            throw GenerationBackendError.transport("Higgsfield returned an invalid upload contract.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 300
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (_, response) = try await session.upload(for: request, fromFile: fileURL, delegate: RejectRedirects())
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw GenerationBackendError.transport("Higgsfield media upload failed.")
        }
        return result
    }

    func availableModelIDs() async throws -> Set<String> {
        var page: URL? = Self.catalogURL
        var visited = Set<URL>()
        var ids = Set<String>()
        while let url = page {
            guard visited.insert(url).inserted, visited.count <= 100 else {
                throw GenerationBackendError.transport("Higgsfield returned a looping model catalog.")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await session.data(for: request, delegate: RejectRedirects())
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw GenerationBackendError.transport("Higgsfield model catalog is unavailable.")
            }
            let decoded = try JSONDecoder().decode(CatalogPage.self, from: data)
            for family in decoded.results where family.availability_state == "available" {
                for mode in family.modes where mode.availability_state == "available" { ids.insert(mode.slug) }
            }
            page = try Self.catalogPageURL(decoded.next)
        }
        guard let probe = HiggsfieldModelRegistry.models.first(where: {
            ids.contains($0.endpoint) && ($0.operation == .image || $0.operation == .textToVideo)
        }) else {
            throw GenerationBackendError.transport("Higgsfield lists no supported model for checking this API connection.")
        }
        let authenticationBody = try JSONSerialization.data(withJSONObject: ["prompt": "Connection check"])
        _ = try await estimate(endpoint: probe.endpoint, body: authenticationBody)
        return ids
    }

    nonisolated static func catalogPageURL(_ value: String?) throws -> URL? {
        guard let value else { return nil }
        guard var parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme ?? ""), parts.host == "dash.higgsfield.ai",
              parts.path == "/api/v2/pricing/models/", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else {
            throw GenerationBackendError.transport("Higgsfield returned an invalid catalog page URL.")
        }
        parts.scheme = "https"
        return parts.url
    }

    private struct CatalogPage: Decodable {
        let next: String?
        let results: [Family]
        struct Family: Decodable {
            let availability_state: String
            let modes: [Mode]
        }
        struct Mode: Decodable {
            let slug: String
            let availability_state: String
        }
    }

    nonisolated private static func isMediaURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    private func send(url: URL, method: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard Self.isAPIURL(url) else { throw GenerationBackendError.transport("Untrusted Higgsfield API URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Key \(credentials.value)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request, delegate: RejectRedirects())
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    private func apiError(_ data: Data, status: Int) -> GenerationBackendError {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let detail = object?["detail"] as? String
        let message = status == 403 ? "Check the Higgsfield API balance and account access." : detail ?? "Request rejected."
        return .api(status: status, code: "higgsfield_\(status)", message: "Higgsfield HTTP \(status): \(redacted(message))")
    }

    private func redacted(_ message: String) -> String {
        credentials.value.split(separator: ":").reduce(String(message.prefix(1000))) {
            $0.replacingOccurrences(of: String($1), with: "[redacted]")
        }
    }

    private func pause(_ seconds: TimeInterval, deadline: Date) async throws {
        let jitter = seconds > 0 ? Double.random(in: 0...0.5) : 0
        let remaining = max(0, deadline.timeIntervalSinceNow)
        try await Task.sleep(nanoseconds: UInt64(min(seconds + jitter, remaining) * 1_000_000_000))
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
