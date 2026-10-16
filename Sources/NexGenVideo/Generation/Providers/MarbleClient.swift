import Foundation

/// Minimal async client for the World Labs Marble world-model API.
/// https://platform.worldlabs.ai/
///
/// Lifecycle mirrors the reference Python client (`scene3d/marble.py`):
/// `POST /worlds:generate` returns a long-running operation, then
/// `GET /operations/{id}` is polled until `done`. Auth is the `WLT-Api-Key`
/// header (not bearer). Boundary types stay `Sendable` (`Data` in / `Data` out)
/// so callers on other isolation domains can use it under Swift 6 strict
/// concurrency; the non-`Sendable` JSON dictionaries live only inside the actor.
actor MarbleClient {
    let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    static let defaultModel = "marble-1.1"

    /// The request may have reached Marble but no response arrived; it may still run and bill.
    struct SubmissionOutcomeUnknownError: LocalizedError, Sendable, ProviderRunEndReporting {
        let ledgerRequestID: String
        let message: String

        var errorDescription: String? { message }
        var providerRunEnded: Bool { false }
    }

    /// Marble accepted the request without a usable operation id; it may still run and bill.
    struct SubmissionAcknowledgedError: LocalizedError, Sendable, ProviderRunEndReporting {
        let ledgerRequestID: String
        let message: String

        var errorDescription: String? { message }
        var providerRunEnded: Bool { false }
    }

    private static let endpointBase = "https://api.worldlabs.ai/marble/v1"
    // Marble generation runs ~10 min empirically; poll slowly and allow a wide ceiling.
    private static let pollInterval: UInt64 = 15_000_000_000 // 15s
    private static let maxWait: TimeInterval = 30 * 60 // 30 min

    /// Submit a world-generation job. `body` is the serialized request payload
    /// (`{"display_name", "model", "world_prompt"}`). Returns the operation id.
    func submit(body: Data) async throws -> String {
        guard let url = URL(string: "\(Self.endpointBase)/worlds:generate") else {
            throw GenerationBackendError.transport("Invalid Marble endpoint")
        }
        let response: (Data, Int)
        do {
            response = try await send(makeRequest(url: url, method: "POST", body: body))
        } catch {
            throw SubmissionOutcomeUnknownError(
                ledgerRequestID: "marble-unknown-\(UUID().uuidString)",
                message: "Marble did not return a submission receipt. The request may still be running, so NexGenVideo will not retry it automatically."
            )
        }
        let (data, status) = response
        let json = Self.parse(data)
        try Self.throwIfError(status: status, json: json)
        guard let operationId = Self.operationId(in: json) else {
            throw SubmissionAcknowledgedError(
                ledgerRequestID: "marble-missing-operation-id-\(UUID().uuidString)",
                message: "Marble accepted the submission without an operation id. The request may still be running, so NexGenVideo will not retry it automatically."
            )
        }
        return operationId
    }

    /// Poll the operation until it completes, then return the raw final
    /// operation JSON as `Data` for the caller to parse.
    func result(operationId: String) async throws -> Data {
        guard let statusURL = URL(string: "\(Self.endpointBase)/operations/\(operationId)") else {
            throw GenerationBackendError.transport("Invalid Marble operation id: \(operationId)")
        }

        let deadline = Date().addingTimeInterval(Self.maxWait)
        while true {
            let (data, status) = try await send(makeRequest(url: statusURL, method: "GET", body: nil))
            // Transient non-200 on a poll is retried (matches marble.py), not fatal.
            if status == 200 {
                let json = Self.parse(data)
                if json?["error"] != nil, let message = Self.errorMessage(in: json) {
                    throw ProviderRunEndedError(message: message)
                }
                if let message = Self.errorMessage(in: json) {
                    throw GenerationBackendError.transport(message)
                }
                if (json?["done"] as? Bool) == true {
                    return data
                }
                ProviderStatusSignal.confirmRunning()
            } else if status >= 400, status != 404, status != 408, status != 429, status < 500 {
                // A hard client error (other than the few that can be transient) is fatal.
                try Self.throwIfError(status: status, json: Self.parse(data))
            }
            if Date() >= deadline {
                throw GenerationBackendError.transport("Marble generation timed out")
            }
            try await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    /// One status read for an operation; never polls it.
    func status(operationId: String) async throws -> ProviderRunStatus {
        guard let url = URL(string: "\(Self.endpointBase)/operations/\(operationId)") else {
            throw GenerationBackendError.transport("Invalid Marble operation id: \(operationId)")
        }
        let (data, status) = try await send(makeRequest(url: url, method: "GET", body: nil))
        guard status == 200, let json = Self.parse(data) else {
            throw GenerationBackendError.transport("Marble operation status returned HTTP \(status).")
        }
        if json["error"] != nil {
            let message = Self.errorMessage(in: json) ?? "Marble reported the operation as failed"
            return .failed(message, ProviderReportedCost.marble(operation: data))
        }
        if (json["done"] as? Bool) == true {
            return .completed(ProviderReportedCost.marble(operation: data))
        }
        return .running
    }

    private func makeRequest(url: URL, method: String, body: Data?) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "WLT-Api-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
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
        let message = errorMessage(in: json) ?? "Marble request failed (HTTP \(status))"
        throw GenerationBackendError.api(status: status, code: "\(status)", message: message)
    }

    /// The submit response identifies the operation under one of a few keys
    /// (`operation_id` / `id` / `name`); `name` can be a path like
    /// `operations/<id>`, so take the trailing segment.
    private static func operationId(in json: [String: Any]?) -> String? {
        guard let json else { return nil }
        for key in ["operation_id", "id", "name"] {
            if let raw = json[key] as? String, let last = raw.split(separator: "/").last, !last.isEmpty {
                return String(last)
            }
        }
        return nil
    }

    /// Pull a human-readable message out of Marble's error shapes. The
    /// operation carries failures under `error` (object with `message`, or a
    /// bare string); HTTP errors may use `message` / `detail`.
    private static func errorMessage(in json: [String: Any]?) -> String? {
        guard let json else { return nil }
        if let dict = json["error"] as? [String: Any], let m = dict["message"] as? String { return m }
        if let s = json["error"] as? String { return s }
        if let m = json["message"] as? String { return m }
        if let detail = json["detail"] as? String { return detail }
        return nil
    }
}
