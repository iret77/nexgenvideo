import Foundation

/// Minimal async client for the fal.ai queue API.
/// https://docs.fal.ai/model-endpoints/queue
///
/// Boundary types are kept `Sendable` (`Data` in / `Data` out) so callers on
/// other isolation domains can use it under Swift 6 strict concurrency; the
/// non-`Sendable` JSON dictionaries live only inside the actor.
actor FalClient {
    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private static let queueBase = "https://queue.fal.run"
    private static let pollInterval: UInt64 = 1_500_000_000 // 1.5s
    private static let maxWait: TimeInterval = 10 * 60 // 10 min

    /// Submit a job to the queue; `inputBody` is the serialized input object with its fields at
    /// the top level (the HTTP queue API's shape — not the SDK's `{"input": …}`). Returns the request id.
    func submit(endpoint: String, inputBody: Data) async throws -> String {
        guard let url = URL(string: "\(Self.queueBase)/\(endpoint)") else {
            throw GenerationBackendError.transport("Invalid fal endpoint: \(endpoint)")
        }
        let (data, status) = try await send(makeRequest(url: url, method: "POST", body: inputBody))
        let json = Self.parse(data)
        try Self.throwIfError(status: status, json: json)
        guard let requestId = json?["request_id"] as? String else {
            throw GenerationBackendError.transport("fal submit: missing request_id")
        }
        return requestId
    }

    /// Poll the queue until the job completes, then fetch and return the raw
    /// output JSON as `Data` for the caller to parse.
    func result(endpoint: String, requestId: String) async throws -> Data {
        guard
            let statusURL = URL(string: "\(Self.queueBase)/\(endpoint)/requests/\(requestId)/status"),
            let resultURL = URL(string: "\(Self.queueBase)/\(endpoint)/requests/\(requestId)")
        else {
            throw GenerationBackendError.transport("Invalid fal endpoint: \(endpoint)")
        }

        let deadline = Date().addingTimeInterval(Self.maxWait)
        while true {
            let (data, status) = try await send(makeRequest(url: statusURL, method: "GET", body: nil))
            let json = Self.parse(data)
            try Self.throwIfError(status: status, json: json)
            switch (json?["status"] as? String) ?? "" {
            case "COMPLETED":
                let (out, outStatus) = try await send(makeRequest(url: resultURL, method: "GET", body: nil))
                try Self.throwIfError(status: outStatus, json: Self.parse(out))
                return out
            case "FAILED", "ERROR":
                throw GenerationBackendError.transport(Self.errorMessage(in: json) ?? "fal generation failed")
            default:
                if Date() >= deadline {
                    throw GenerationBackendError.transport("fal generation timed out")
                }
                try await Task.sleep(nanoseconds: Self.pollInterval)
            }
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

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch {
            throw GenerationBackendError.transport(error.localizedDescription)
        }
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func throwIfError(status: Int, json: [String: Any]?) throws {
        guard status >= 400 else { return }
        let message = errorMessage(in: json) ?? "fal request failed (HTTP \(status))"
        throw GenerationBackendError.api(status: status, code: "\(status)", message: message)
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
