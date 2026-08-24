import Foundation

/// Minimal async client for the fal.ai queue API.
/// https://docs.fal.ai/model-endpoints/queue
///
/// Boundary types are kept `Sendable` (`Data` in / `Data` out) so callers on
/// other isolation domains can use it under Swift 6 strict concurrency; the
/// non-`Sendable` JSON dictionaries live only inside the actor.
actor FalClient {
    let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private static let queueBase = "https://queue.fal.run"
    private static let pollInterval: UInt64 = 1_500_000_000 // 1.5s
    private static let maxWait: TimeInterval = 10 * 60 // 10 min

    /// Submit a job to the queue; `inputBody` is the serialized input object with its fields at
    /// the top level (the HTTP queue API's shape — not the SDK's `{"input": …}`). Returns the request id.
    func submit(endpoint: String, inputBody: Data) async throws -> String {
        let route = try Self.route(endpoint: endpoint)
        let request = makeRequest(url: route.submitURL, method: "POST", body: inputBody)
        let response = try await send(request)
        let json = Self.parse(response.data)
        try Self.throwIfError(response, request: request, operation: "submit", json: json)
        guard let requestId = json?["request_id"] as? String else {
            throw GenerationBackendError.transport("fal submit: missing request_id")
        }
        return requestId
    }

    /// Poll the queue until the job completes, then fetch and return the raw
    /// output JSON as `Data` for the caller to parse.
    func result(endpoint: String, requestId: String) async throws -> Data {
        let route = try Self.route(endpoint: endpoint)
        let statusURL = try route.lifecycleURL(requestId: requestId, suffix: "status")
        let resultURL = try route.lifecycleURL(requestId: requestId)

        let deadline = Date().addingTimeInterval(Self.maxWait)
        while true {
            let statusRequest = makeRequest(url: statusURL, method: "GET", body: nil)
            let response = try await send(statusRequest)
            let json = Self.parse(response.data)
            try Self.throwIfError(
                response, request: statusRequest, operation: "status", json: json
            )
            switch (json?["status"] as? String) ?? "" {
            case "COMPLETED":
                let resultRequest = makeRequest(url: resultURL, method: "GET", body: nil)
                let resultResponse = try await send(resultRequest)
                try Self.throwIfError(
                    resultResponse, request: resultRequest, operation: "result",
                    json: Self.parse(resultResponse.data)
                )
                return resultResponse.data
            case "IN_QUEUE", "IN_PROGRESS":
                if Date() >= deadline {
                    throw GenerationBackendError.transport("fal generation timed out")
                }
                try await Task.sleep(nanoseconds: Self.pollInterval)
            case "FAILED", "ERROR", "CANCELLED":
                let detail = Self.errorMessage(in: json) ?? "provider reported failure"
                throw GenerationBackendError.transport(
                    "fal.ai generation failed for \(route.application): \(detail)"
                )
            case let status where !status.isEmpty:
                throw GenerationBackendError.transport(
                    "fal.ai status returned unsupported state '\(status)' for \(route.application)"
                )
            default:
                throw GenerationBackendError.transport(
                    "fal.ai status returned no state for \(route.application)"
                )
            }
        }
    }

    struct Route: Sendable, Equatable {
        let endpoint: String
        let application: String

        var submitURL: URL { URL(string: "\(FalClient.queueBase)/\(endpoint)")! }

        func lifecycleURL(requestId: String, suffix: String? = nil) throws -> URL {
            guard FalClient.isPathSegment(requestId) else {
                throw GenerationBackendError.transport("Invalid fal request id")
            }
            var value = "\(FalClient.queueBase)/\(application)/requests/\(requestId)"
            if let suffix { value += "/\(suffix)" }
            return URL(string: value)!
        }
    }

    /// fal endpoint ids are `owner/app[/submit-path]`. The submit path selects an operation such as
    /// `edit` or `image-to-video`, but queue lifecycle calls belong to the owning app and must drop it.
    /// `workflows` and `comfy` are fal namespaces, so their owning app spans three segments.
    static func route(endpoint: String) throws -> Route {
        guard endpoint == endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.hasPrefix("/"), !endpoint.hasSuffix("/"),
              !endpoint.contains("//"), !endpoint.contains("?") && !endpoint.contains("#")
        else {
            throw GenerationBackendError.transport("Invalid fal endpoint: \(endpoint)")
        }
        let parts = endpoint.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let rootCount = ["workflows", "comfy"].contains(parts.first ?? "") ? 3 : 2
        guard parts.count >= rootCount,
              parts.allSatisfy(Self.isPathSegment)
        else {
            throw GenerationBackendError.transport("Invalid fal endpoint: \(endpoint)")
        }
        return Route(endpoint: endpoint, application: parts.prefix(rootCount).joined(separator: "/"))
    }

    private static func isPathSegment(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-._~".unicodeScalars.contains($0)
            }
    }

    private func makeRequest(url: URL, method: String, body: Data?) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    private struct Response {
        let data: Data
        let status: Int
        let url: URL?
    }

    private func send(_ request: URLRequest) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return Response(data: data, status: http?.statusCode ?? 0, url: http?.url)
        } catch {
            throw GenerationBackendError.transport(
                "fal.ai \(request.httpMethod ?? "request") \(Self.safeLocation(request.url)) failed: "
                    + error.localizedDescription
            )
        }
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func throwIfError(
        _ response: Response,
        request: URLRequest,
        operation: String,
        json: [String: Any]?
    ) throws {
        guard response.status >= 400 else { return }
        let message = errorMessage(in: json) ?? "fal request failed"
        let method = request.httpMethod ?? "request"
        let location = safeLocation(response.url ?? request.url)
        throw GenerationBackendError.api(
            status: response.status,
            code: "\(response.status)",
            message: "fal.ai \(operation) \(method) \(location) returned HTTP \(response.status): \(message)"
        )
    }

    private static func safeLocation(_ url: URL?) -> String {
        guard let url else { return "<invalid URL>" }
        return (url.host ?? "") + url.path
    }

    /// Pull a human-readable message out of common fal error shapes.
    private static func errorMessage(in json: [String: Any]?) -> String? {
        guard let json else { return nil }
        if let s = json["error"] as? String { return s }
        if let dict = json["error"] as? [String: Any], let m = dict["message"] as? String { return m }
        if let detail = json["detail"] as? String { return detail }
        if let details = json["detail"] as? [[String: Any]],
           let first = details.first, let m = first["msg"] as? String { return m }
        return nil
    }
}
