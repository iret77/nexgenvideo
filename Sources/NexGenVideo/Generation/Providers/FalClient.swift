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
    private let pollIntervalNanoseconds: UInt64
    private let retryBaseDelayNanoseconds: UInt64
    private let maxWaitSeconds: TimeInterval
    private let maxInvalidStatusResponses: Int
    private var lifecycleByRequestID: [String: LifecycleURLs] = [:]

    init(
        apiKey: String,
        session: URLSession = .shared,
        pollIntervalNanoseconds: UInt64 = 1_500_000_000,
        retryBaseDelayNanoseconds: UInt64 = 1_000_000_000,
        maxWaitSeconds: TimeInterval = 30 * 60,
        maxInvalidStatusResponses: Int = 5
    ) {
        self.apiKey = apiKey
        self.session = session
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.retryBaseDelayNanoseconds = retryBaseDelayNanoseconds
        self.maxWaitSeconds = maxWaitSeconds.isFinite
            ? min(max(0, maxWaitSeconds), 24 * 60 * 60)
            : 24 * 60 * 60
        self.maxInvalidStatusResponses = max(1, maxInvalidStatusResponses)
    }

    private static let queueBase = "https://queue.fal.run"
    private static let statusRetryPolicy = RetryPolicy(
        maxRetries: 5,
        statusCodes: [429, 500, 502, 503, 504]
    )
    private static let resultRetryPolicy = RetryPolicy(
        maxRetries: 3,
        statusCodes: [429, 500, 502, 503, 504]
    )

    /// Submit a job to the queue; `inputBody` is the serialized input object with its fields at
    /// the top level (the HTTP queue API's shape — not the SDK's `{"input": …}`). Returns the request id.
    func submit(endpoint: String, inputBody: Data) async throws -> String {
        let route = try Self.route(endpoint: endpoint)
        let request = makeRequest(url: route.submitURL, method: "POST", body: inputBody)
        let response: Response
        do {
            response = try await send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubmissionOutcomeUnknownError(
                ledgerRequestID: "unknown-\(UUID().uuidString)",
                message: "fal.ai did not return a submission receipt. The request may still be running, so NexGenVideo will not retry it automatically."
            )
        }
        let json = Self.parse(response.data)
        try Self.throwIfError(response, request: request, operation: "submit", json: json)
        guard let requestId = json?["request_id"] as? String else {
            throw SubmissionAcknowledgedError(
                ledgerRequestID: "missing-request-id",
                message: "fal submit succeeded without a request_id"
            )
        }
        guard Self.isRequestIDSegment(requestId) else {
            throw SubmissionAcknowledgedError(
                ledgerRequestID: "unusable-\(requestId.utf8.count)-byte-request-id",
                message: "fal submit returned an unusable request_id"
            )
        }
        lifecycleByRequestID[requestId] = Self.lifecycleURLs(
            from: json,
            requestId: requestId,
            fallback: route
        )
        return requestId
    }

    struct SubmissionAcknowledgedError: LocalizedError, Sendable {
        let ledgerRequestID: String
        let message: String

        var errorDescription: String? { message }
    }

    struct SubmissionOutcomeUnknownError: LocalizedError, Sendable {
        let ledgerRequestID: String
        let message: String

        var errorDescription: String? { message }
    }

    /// Poll the queue until the job completes, then fetch and return the raw
    /// output JSON as `Data` for the caller to parse.
    func result(endpoint: String, requestId: String) async throws -> Data {
        let route = try Self.route(endpoint: endpoint)
        let lifecycle = try lifecycleByRequestID[requestId] ?? LifecycleURLs(
            status: route.lifecycleURL(requestId: requestId, suffix: "status"),
            response: route.lifecycleURL(requestId: requestId),
            cancel: route.lifecycleURL(requestId: requestId, suffix: "cancel")
        )
        let statusURL = lifecycle.status
        let resultURL = lifecycle.response
        let cancelURL = lifecycle.cancel
        defer { lifecycleByRequestID.removeValue(forKey: requestId) }

        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        var invalidStatusResponses = 0
        var finalPollAvailable = true
        do {
            while true {
                try Task.checkCancellation()
                let statusRequest = makeRequest(url: statusURL, method: "GET", body: nil)
                let response = try await send(
                    statusRequest,
                    retryPolicy: Self.statusRetryPolicy,
                    deadline: deadline
                )
                let json = Self.parse(response.data)
                do {
                    try Self.throwIfError(
                        response, request: statusRequest, operation: "status", json: json
                    )
                } catch let error as GenerationBackendError {
                    if case .api(let status, _, _) = error,
                       Self.statusRetryPolicy.statusCodes.contains(status) {
                        await cancelIndependently(url: cancelURL)
                    }
                    throw error
                }
                guard let status = json?["status"] as? String, !status.isEmpty else {
                    invalidStatusResponses += 1
                    guard invalidStatusResponses < maxInvalidStatusResponses else {
                        await cancelIndependently(url: cancelURL)
                        throw GenerationBackendError.transport(
                            "fal.ai status returned no valid state after \(invalidStatusResponses) attempts for request \(Self.safeRequestID(requestId))"
                        )
                    }
                    finalPollAvailable = try await waitForNextPoll(
                        deadline: deadline,
                        finalPollAvailable: finalPollAvailable
                    )
                    continue
                }
                switch status {
                case "COMPLETED":
                    invalidStatusResponses = 0
                    let resultRequest = makeRequest(url: resultURL, method: "GET", body: nil)
                    let resultResponse = try await send(
                        resultRequest,
                        retryPolicy: Self.resultRetryPolicy,
                        deadline: Date().addingTimeInterval(30)
                    )
                    try Self.throwIfError(
                        resultResponse, request: resultRequest, operation: "result",
                        json: Self.parse(resultResponse.data)
                    )
                    return resultResponse.data
                case "IN_QUEUE", "IN_PROGRESS":
                    invalidStatusResponses = 0
                    finalPollAvailable = try await waitForNextPoll(
                        deadline: deadline,
                        finalPollAvailable: finalPollAvailable
                    )
                case "FAILED", "ERROR", "CANCELLED":
                    let detail = Self.errorMessage(in: json) ?? "provider reported failure"
                    throw GenerationBackendError.transport(
                        "fal.ai generation failed for \(route.application), request \(Self.safeRequestID(requestId)): \(detail)"
                    )
                default:
                    invalidStatusResponses += 1
                    guard invalidStatusResponses < maxInvalidStatusResponses else {
                        await cancelIndependently(url: cancelURL)
                        throw GenerationBackendError.transport(
                            "fal.ai status returned unsupported state '\(status)' after \(invalidStatusResponses) attempts for \(route.application), request \(Self.safeRequestID(requestId))"
                        )
                    }
                    finalPollAvailable = try await waitForNextPoll(
                        deadline: deadline,
                        finalPollAvailable: finalPollAvailable
                    )
                }
            }
        } catch is DeadlineExceeded {
            let error = await timeoutError(
                route: route,
                requestId: requestId,
                cancelURL: cancelURL
            )
            throw error
        } catch is CancellationError {
            await cancelIndependently(url: cancelURL)
            throw CancellationError()
        }
    }

    struct Route: Sendable, Equatable {
        let endpoint: String
        let application: String
        let submitURL: URL

        fileprivate init(endpoint: String, application: String, submitURL: URL) {
            self.endpoint = endpoint
            self.application = application
            self.submitURL = submitURL
        }

        func lifecycleURL(requestId: String, suffix: String? = nil) throws -> URL {
            guard FalClient.isRequestIDSegment(requestId) else {
                throw GenerationBackendError.transport("Invalid fal request id")
            }
            var value = "\(FalClient.queueBase)/\(application)/requests/\(requestId)"
            if let suffix { value += "/\(suffix)" }
            guard let url = URL(string: value) else {
                throw GenerationBackendError.transport("Invalid fal lifecycle URL")
            }
            return url
        }
    }

    private struct LifecycleURLs: Sendable {
        let status: URL
        let response: URL
        let cancel: URL
    }

    private static func lifecycleURLs(
        from response: [String: Any]?,
        requestId: String,
        fallback route: Route
    ) -> LifecycleURLs? {
        guard let response,
              let fallbackStatus = try? route.lifecycleURL(requestId: requestId, suffix: "status"),
              let fallbackResponse = try? route.lifecycleURL(requestId: requestId),
              let fallbackCancel = try? route.lifecycleURL(requestId: requestId, suffix: "cancel")
        else { return nil }
        let status = validatedLifecycleURL(
            response["status_url"] as? String,
            requestId: requestId
        ) ?? fallbackStatus
        let result = validatedLifecycleURL(
            response["response_url"] as? String,
            requestId: requestId
        ) ?? fallbackResponse
        let cancel = validatedLifecycleURL(
            response["cancel_url"] as? String,
            requestId: requestId
        ) ?? fallbackCancel
        return LifecycleURLs(status: status, response: result, cancel: cancel)
    }

    private static func validatedLifecycleURL(_ raw: String?, requestId: String) -> URL? {
        guard let raw,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "queue.fal.run",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.pathComponents.contains(requestId)
        else { return nil }
        return url
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
              parts.allSatisfy(Self.isEndpointSegment)
        else {
            throw GenerationBackendError.transport("Invalid fal endpoint: \(endpoint)")
        }
        guard let submitURL = URL(string: "\(queueBase)/\(endpoint)") else {
            throw GenerationBackendError.transport("Invalid fal endpoint: \(endpoint)")
        }
        return Route(
            endpoint: endpoint,
            application: parts.prefix(rootCount).joined(separator: "/"),
            submitURL: submitURL
        )
    }

    private static func isEndpointSegment(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.utf8.count <= 1_024
            && value.utf8.allSatisfy {
                isASCIIAlphaNumeric($0) || [45, 46, 95, 126].contains($0)
            }
    }

    private static func isRequestIDSegment(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.utf8.count <= 1_024
            && value.utf8.allSatisfy {
                isASCIIAlphaNumeric($0)
                    || [33, 36, 38, 39, 40, 41, 42, 43, 44, 45, 46, 58, 59, 61, 64, 95, 126]
                        .contains($0)
            }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }

    private static func safeRequestID(_ value: String) -> String {
        isRequestIDSegment(value) ? value : "<invalid>"
    }

    private func waitForNextPoll(
        deadline: Date,
        finalPollAvailable: Bool
    ) async throws -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw DeadlineExceeded() }
        let remainingNanoseconds = UInt64(remaining * 1_000_000_000)
        guard pollIntervalNanoseconds < remainingNanoseconds else {
            guard finalPollAvailable else {
                try await Task.sleep(nanoseconds: remainingNanoseconds)
                throw DeadlineExceeded()
            }
            let requestBudget = min(remainingNanoseconds, 1_000_000_000)
            try await Task.sleep(nanoseconds: remainingNanoseconds - requestBudget)
            return false
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        return finalPollAvailable
    }

    private func timeoutError(
        route: Route,
        requestId: String,
        cancelURL: URL
    ) async -> GenerationBackendError {
        await cancelIndependently(url: cancelURL)
        return GenerationBackendError.transport(
            "fal.ai generation timed out for \(route.application), request \(Self.safeRequestID(requestId))"
        )
    }

    private func cancelForFailure(url: URL) async {
        guard let failure = await cancel(url: url) else { return }
        switch failure {
        case .response(let status, let message)
            where (400..<500).contains(status) && ![401, 403, 404, 405].contains(status):
            Log.generation.notice(
                "fal request was no longer cancellable at \(Self.safeLocation(url)): \(message)"
            )
        case .response(_, let message), .transport(let message):
            Log.generation.error(
                "fal cancellation failed at \(Self.safeLocation(url)): \(message)"
            )
        }
    }

    private func cancelIndependently(url: URL) async {
        let cancellation = Task.detached { [self] in
            await cancelForFailure(url: url)
        }
        await cancellation.value
    }

    private enum CancellationFailure {
        case response(status: Int, message: String)
        case transport(String)
    }

    private func cancel(url: URL) async -> CancellationFailure? {
        let request = makeRequest(url: url, method: "PUT", body: nil, timeoutInterval: 3)
        do {
            let response = try await send(request)
            guard response.status >= 400 else { return nil }
            let message = Self.errorMessage(in: Self.parse(response.data)) ?? "fal request failed"
            return .response(status: response.status, message: message)
        } catch {
            return .transport(error.localizedDescription)
        }
    }

    private func makeRequest(
        url: URL,
        method: String,
        body: Data?,
        timeoutInterval: TimeInterval? = nil
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        if let timeoutInterval {
            req.timeoutInterval = max(0.1, min(timeoutInterval, 30))
        }
        return req
    }

    private struct Response {
        let data: Data
        let status: Int
        let url: URL?
        let retryAfterNanoseconds: UInt64?
    }

    private struct RetryPolicy {
        let maxRetries: Int
        let statusCodes: Set<Int>
    }

    private struct DeadlineExceeded: Error {}

    private func send(
        _ request: URLRequest,
        retryPolicy: RetryPolicy? = nil,
        deadline: Date? = nil
    ) async throws -> Response {
        var attempt = 0
        while true {
            do {
                try Self.checkDeadline(deadline)
                var request = request
                if let deadline {
                    request.timeoutInterval = max(
                        1,
                        min(30, min(request.timeoutInterval, deadline.timeIntervalSinceNow))
                    )
                }
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let result = Response(
                    data: data,
                    status: http?.statusCode ?? 0,
                    url: http?.url,
                    retryAfterNanoseconds: Self.retryAfterNanoseconds(from: http)
                )
                if let retryPolicy,
                   attempt < retryPolicy.maxRetries,
                   retryPolicy.statusCodes.contains(result.status) {
                    try await waitBeforeRetry(
                        attempt: attempt,
                        minimumDelayNanoseconds: result.retryAfterNanoseconds,
                        deadline: deadline
                    )
                    attempt += 1
                    continue
                }
                return result
            } catch is DeadlineExceeded {
                throw DeadlineExceeded()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if let retryPolicy,
                   attempt < retryPolicy.maxRetries,
                   Self.isRetryableTransportError(error) {
                    try await waitBeforeRetry(
                        attempt: attempt,
                        minimumDelayNanoseconds: nil,
                        deadline: deadline
                    )
                    attempt += 1
                    continue
                }
                throw GenerationBackendError.transport(
                    "fal.ai \(request.httpMethod ?? "request") \(Self.safeLocation(request.url)) failed: "
                        + error.localizedDescription
                )
            }
        }
    }

    private func waitBeforeRetry(
        attempt: Int,
        minimumDelayNanoseconds: UInt64?,
        deadline: Date?
    ) async throws {
        let multiplier = UInt64(1 << min(attempt, 5))
        let multiplied = retryBaseDelayNanoseconds.multipliedReportingOverflow(by: multiplier)
        let baseDelay = multiplied.overflow
            ? 30_000_000_000
            : min(multiplied.partialValue, 30_000_000_000)
        let jitteredDelay = baseDelay == 0
            ? 0
            : UInt64(Double(baseDelay) * Double.random(in: 0.75...1.25))
        let delay = max(jitteredDelay, minimumDelayNanoseconds ?? 0)
        if let deadline {
            try await sleep(delay, boundedBy: deadline)
        } else {
            try await Task.sleep(nanoseconds: delay)
        }
    }

    private func sleep(_ nanoseconds: UInt64, boundedBy deadline: Date) async throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw DeadlineExceeded() }
        let remainingNanoseconds = UInt64(remaining * 1_000_000_000)
        guard nanoseconds < remainingNanoseconds else {
            try await Task.sleep(nanoseconds: remainingNanoseconds)
            throw DeadlineExceeded()
        }
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private static func checkDeadline(_ deadline: Date?) throws {
        if let deadline, Date() >= deadline { throw DeadlineExceeded() }
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
        ].contains(code)
    }

    private static func retryAfterNanoseconds(from response: HTTPURLResponse?) -> UInt64? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let seconds = Double(raw) {
            return nanoseconds(seconds: seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return nanoseconds(seconds: max(0, date.timeIntervalSinceNow))
    }

    private static func nanoseconds(seconds: Double) -> UInt64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return UInt64((min(seconds, 86_400) * 1_000_000_000).rounded(.up))
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
