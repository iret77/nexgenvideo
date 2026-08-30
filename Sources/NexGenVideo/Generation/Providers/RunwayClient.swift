import Foundation

/// Direct client for Runway's developer API (api.dev.runwayml.com). Task-based: POST a generation
/// task, then poll GET /v1/tasks/{id} until SUCCEEDED and return the output URLs. Field names and
/// enums verified against Runway's official SDK (runwayml/sdk-node).
actor RunwayClient {
    let apiKey: String
    private let session: URLSession
    private let pollIntervalNanoseconds: UInt64
    private let retryBaseDelayNanoseconds: UInt64
    private let maxWaitSeconds: TimeInterval
    private let maxPollRetries: Int

    init(
        apiKey: String,
        session: URLSession = .shared,
        pollIntervalNanoseconds: UInt64 = 3_000_000_000,
        retryBaseDelayNanoseconds: UInt64 = 1_000_000_000,
        maxWaitSeconds: TimeInterval = 10 * 60,
        maxPollRetries: Int = 5
    ) {
        self.apiKey = apiKey
        self.session = session
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.retryBaseDelayNanoseconds = retryBaseDelayNanoseconds
        self.maxWaitSeconds = maxWaitSeconds.isFinite
            ? min(max(0, maxWaitSeconds), 24 * 60 * 60)
            : 24 * 60 * 60
        self.maxPollRetries = max(0, maxPollRetries)
    }

    private static let base = "https://api.dev.runwayml.com/v1"
    private static let versionHeader = "2024-11-06"
    private static let maxRetryDelayNanoseconds: UInt64 = 30_000_000_000

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

    private struct TerminalTaskError: LocalizedError, Sendable {
        let message: String

        var errorDescription: String? { message }
    }

    // MARK: - Generation

    /// POST /v1/image_to_video — promptImage is REQUIRED for every Runway video model.
    func createImageToVideo(
        model: String, promptImage: String, promptText: String, ratio: String, duration: Int
    ) async throws -> String {
        try await createTask(path: "image_to_video", body: [
            "model": model,
            "promptImage": promptImage,
            "promptText": promptText,
            "ratio": ratio,
            "duration": duration,
        ])
    }

    /// POST /v1/video_to_video — the Aleph restyle pass (#223). `videoUri` is the source clip; the
    /// model re-renders it under `promptText`. Same task+poll flow as every other Runway call.
    ///
    /// Body shape verified LIVE against the API: a probe with an unreachable `videoUri` is rejected
    /// only on that field (`path: ["videoUri"]`), i.e. model / promptText / ratio all validate — for
    /// `aleph2` and its sunset predecessor alike.
    func createVideoToVideo(
        model: String, videoUri: String, promptText: String, ratio: String
    ) async throws -> String {
        try await createTask(path: "video_to_video", body: [
            "model": model,
            "videoUri": videoUri,
            "promptText": promptText,
            "ratio": ratio,
        ])
    }

    /// POST /v1/text_to_image.
    func createTextToImage(model: RunwayModel, params: ImageGenerationParams) async throws -> String {
        try await createTask(
            path: "text_to_image",
            body: try Self.textToImageBody(model: model, params: params)
        )
    }

    static func textToImageBody(
        model: RunwayModel,
        params: ImageGenerationParams
    ) throws -> [String: Any] {
        guard let request = model.imageRequest,
              let ratio = RunwayModelRegistry.imageRatio(for: model, aspect: params.aspectRatio),
              case .image(let caps) = model.entry.uiCapabilities else {
            throw GenerationBackendError.transport(
                "\(model.entry.displayName) is not a Runway image-generation model."
            )
        }
        let config = ImageModelConfig(entry: model.entry, caps: caps)
        if let error = config.validate(
            aspectRatio: params.aspectRatio,
            resolution: params.resolution,
            quality: params.quality,
            imageRefCount: params.imageURLs.count,
            numImages: params.numImages
        ) {
            throw GenerationBackendError.transport(error)
        }
        var body: [String: Any] = [
            "model": model.apiModel,
            "promptText": params.prompt,
            "ratio": ratio,
        ]
        if !params.imageURLs.isEmpty {
            body["referenceImages"] = params.imageURLs.map { ["uri": $0] }
        }
        if request.sendsOutputCount, params.numImages > 1 {
            body["outputCount"] = params.numImages
        }
        if request.sendsQuality, let quality = params.quality {
            body["quality"] = quality
        }
        return body
    }

    func output(taskId: String) async throws -> [String] {
        do {
            return try await waitForOutput(taskId: taskId)
        } catch let error as TerminalTaskError {
            throw GenerationBackendError.transport(error.message)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            if let failure = await cancelIndependently(taskId: taskId) {
                throw GenerationBackendError.transport(
                    "\(cancelled ? "Generation was cancelled locally" : error.localizedDescription), but Runway task cancellation failed: \(failure). The provider task may still run and incur charges."
                )
            }
            if cancelled { throw CancellationError() }
            throw GenerationBackendError.transport(
                "\(error.localizedDescription) Runway cancelled the provider task."
            )
        }
    }

    // MARK: - Reference hosting

    /// `POST /v1/uploads` — host a reference on RUNWAY, so an image-to-video or restyle run needs no
    /// fal key (#244). Returns the `runway://…` URI that the generation endpoints take wherever they
    /// document a URL (`promptImage`, `videoUri`).
    ///
    /// Not a multipart/ETag flow: Runway answers with an **S3 presigned POST form** — `uploadUrl`,
    /// a `fields` dict to replay verbatim, and the finished `runwayUri` up front. There is no
    /// "complete" call. Verified live 2026-07-17 against the real account.
    ///
    /// What the API taught, each of which breaks the upload if ignored:
    /// - `type` must be exactly `"ephemeral"`; anything else is rejected by the body validator.
    /// - The content type is derived from the FILENAME EXTENSION and then pinned by the S3 policy,
    ///   so the filename must carry the file's real extension — the caller owns that.
    /// - S3 requires the `file` part LAST; every policy field has to precede it.
    /// - The policy enforces 512 B … 200 MB.
    /// - The URI carries a JWT that expires after ~24h, so it is a cache, never a durable record.
    func uploadReference(fileURL: URL, filename: String) async throws -> String {
        let bytes = try Data(contentsOf: fileURL)
        let (data, status) = try await send(method: "POST", path: "uploads", body: [
            "filename": filename,
            "numberOfParts": 1,
            "type": "ephemeral",
        ])
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status),
              let uploadURL = (json?["uploadUrl"] as? String).flatMap(URL.init(string:)),
              let fields = json?["fields"] as? [String: String],
              let runwayUri = json?["runwayUri"] as? String else {
            let detail = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw GenerationBackendError.transport("Runway upload HTTP \(status): \(detail)")
        }
        try await postForm(to: uploadURL, fields: fields, filename: filename, bytes: bytes)
        return runwayUri
    }

    /// The S3 side of `uploadReference`: a multipart/form-data POST of the policy fields plus the
    /// bytes. S3 answers 204 with an empty body on success and an XML error otherwise.
    private func postForm(to url: URL, fields: [String: String], filename: String, bytes: Data) async throws {
        let boundary = "ngv-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (key, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n\r\n")
        body.append(bytes)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw GenerationBackendError.transport("Runway reference upload HTTP \(status): \(detail)")
        }
    }

    // MARK: - Availability

    /// `GET /v1/organization` — the model ids THIS key's account is entitled to, from `tier.models`.
    ///
    /// Runway has no `GET /v1/models`; the organization endpoint is where the model list lives, and it
    /// is scoped to the account rather than global — so it answers the only question that matters:
    /// can this user actually run it (#159). Verified live: the payload keys `tier.models` by model id
    /// (`aleph2`, `gen4.5`, `gen4_image`, …).
    func availableModelIds() async throws -> Set<String> {
        let (data, status) = try await send(method: "GET", path: "organization", body: nil)
        guard (200..<300).contains(status) else {
            throw Self.apiError(data: data, status: status, operation: "organization")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier = json["tier"] as? [String: Any],
              let models = tier["models"] as? [String: Any] else {
            throw GenerationBackendError.transport(
                "Runway returned a malformed organization model catalog."
            )
        }
        return Set(models.keys)
    }

    // MARK: - Task flow

    private func createTask(path: String, body: [String: Any]) async throws -> String {
        let response: (Data, Int)
        do {
            response = try await send(method: "POST", path: path, body: body)
        } catch {
            throw SubmissionOutcomeUnknownError(
                ledgerRequestID: "runway-unknown-\(UUID().uuidString)",
                message: "Runway did not return a submission receipt. The request may still be running, so NexGenVideo will not retry it automatically."
            )
        }
        let (data, status) = response
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw Self.apiError(data: data, status: status, operation: "submission")
        }
        guard let id = json?["id"] as? String, !id.isEmpty else {
            throw SubmissionAcknowledgedError(
                ledgerRequestID: "runway-missing-task-id-\(UUID().uuidString)",
                message: "Runway accepted the submission without returning a usable task id. The request may still be running, so NexGenVideo will not retry it automatically."
            )
        }
        if Task.isCancelled {
            let cancellationFailure = await cancelIndependently(taskId: id)
            let message: String
            if let cancellationFailure {
                message = "Runway accepted task \(id), but its cancellation failed: \(cancellationFailure). The provider task may still run and incur charges."
            } else {
                message = "Runway accepted task \(id) before cancellation and then cancelled the provider task."
            }
            throw SubmissionAcknowledgedError(ledgerRequestID: id, message: message)
        }
        return id
    }

    private func waitForOutput(taskId: String) async throws -> [String] {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while true {
            if Date() >= deadline {
                throw GenerationBackendError.transport("Runway generation timed out.")
            }
            let (data, status) = try await pollTask(taskId: taskId, deadline: deadline)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (200..<300).contains(status), let state = json?["status"] as? String else {
                if !(200..<300).contains(status) {
                    throw Self.apiError(data: data, status: status, operation: "task poll")
                }
                throw GenerationBackendError.transport("Runway returned a malformed task status.")
            }
            switch state {
            case "SUCCEEDED":
                guard let output = json?["output"] as? [String], !output.isEmpty else {
                    throw TerminalTaskError(message: "Runway returned no output.")
                }
                return output
            case "FAILED", "CANCELLED":
                let reason = (json?["failure"] as? String) ?? "Runway generation \(state.lowercased())"
                throw TerminalTaskError(message: reason)
            case "PENDING", "THROTTLED", "RUNNING":
                if Date() >= deadline {
                    throw GenerationBackendError.transport("Runway generation timed out.")
                }
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            default:
                throw GenerationBackendError.transport(
                    "Runway returned an unknown task status: \(state)."
                )
            }
        }
    }

    private func pollTask(taskId: String, deadline: Date) async throws -> (Data, Int) {
        var retries = 0
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw GenerationBackendError.transport("Runway generation timed out.")
            }
            let response: (Data, Int)
            do {
                response = try await send(method: "GET", path: "tasks/\(taskId)", body: nil)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                guard Self.isRetryableTransport(error), retries < maxPollRetries, Date() < deadline else {
                    throw GenerationBackendError.transport(
                        "Runway task polling failed: \(error.localizedDescription)"
                    )
                }
                try await sleepBeforeRetry(retry: retries, deadline: deadline)
                retries += 1
                continue
            }
            if Self.isTransientStatus(response.1) {
                guard retries < maxPollRetries, Date() < deadline else {
                    throw GenerationBackendError.transport(
                        "Runway task polling remained unavailable after \(retries + 1) attempts (HTTP \(response.1))."
                    )
                }
                try await sleepBeforeRetry(retry: retries, deadline: deadline)
                retries += 1
                continue
            }
            return response
        }
    }

    private func sleepBeforeRetry(retry: Int, deadline: Date) async throws {
        if Date() >= deadline {
            throw GenerationBackendError.transport("Runway generation timed out.")
        }
        var delay = min(retryBaseDelayNanoseconds, Self.maxRetryDelayNanoseconds)
        for _ in 0..<min(retry, 5) {
            if delay >= Self.maxRetryDelayNanoseconds / 2 {
                delay = Self.maxRetryDelayNanoseconds
                break
            }
            delay *= 2
        }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let remainingNanoseconds = UInt64(
            min(Double(UInt64.max), remaining * 1_000_000_000)
        )
        try await Task.sleep(nanoseconds: min(delay, remainingNanoseconds))
    }

    private static func isTransientStatus(_ status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    private static func isRetryableTransport(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
             .internationalRoamingOff, .callIsActive, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func apiError(
        data: Data,
        status: Int,
        operation: String
    ) -> GenerationBackendError {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errorObject = json?["error"] as? [String: Any]
        let message = (json?["message"] as? String)
            ?? (json?["error"] as? String)
            ?? (errorObject?["message"] as? String)
            ?? String(data: data.prefix(500), encoding: .utf8)
            ?? "Runway request failed."
        let code = (json?["code"] as? String)
            ?? (errorObject?["code"] as? String)
            ?? "\(status)"
        return .api(
            status: status,
            code: code,
            message: "Runway \(operation) HTTP \(status): \(message)"
        )
    }

    private func cancelIndependently(taskId: String) async -> String? {
        let cancellation = Task.detached { [self] () -> String? in
            do {
                let (data, status) = try await send(
                    method: "DELETE",
                    path: "tasks/\(taskId)",
                    body: nil
                )
                guard (200..<300).contains(status) || status == 404 || status == 409 else {
                    let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
                    throw GenerationBackendError.transport(
                        "Runway task cancellation HTTP \(status): \(detail)"
                    )
                }
                return nil
            } catch {
                Log.generation.error(
                    "Runway task cancellation failed id=\(taskId) error=\(error.localizedDescription)"
                )
                return error.localizedDescription
            }
        }
        return await cancellation.value
    }

    private func send(method: String, path: String, body: [String: Any]?) async throws -> (Data, Int) {
        guard let url = URL(string: "\(Self.base)/\(path)") else {
            throw GenerationBackendError.transport("Invalid Runway endpoint: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.versionHeader, forHTTPHeaderField: "X-Runway-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
