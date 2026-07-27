import Foundation

/// Direct client for Runway's developer API (api.dev.runwayml.com). Task-based: POST a generation
/// task, then poll GET /v1/tasks/{id} until SUCCEEDED and return the output URLs. Field names and
/// enums verified against Runway's official SDK (runwayml/sdk-node).
actor RunwayClient {
    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private static let base = "https://api.dev.runwayml.com/v1"
    private static let versionHeader = "2024-11-06"
    private static let pollInterval: UInt64 = 3_000_000_000 // 3s
    private static let maxWait: TimeInterval = 10 * 60

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
    func createTextToImage(model: String, promptText: String, ratio: String) async throws -> String {
        try await createTask(path: "text_to_image", body: [
            "model": model,
            "promptText": promptText,
            "ratio": ratio,
        ])
    }

    func output(taskId: String) async throws -> [String] {
        try await waitForOutput(taskId: taskId)
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
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw GenerationBackendError.transport("Runway organization HTTP \(status): \(detail)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier = json["tier"] as? [String: Any],
              let models = tier["models"] as? [String: Any] else { return [] }
        return Set(models.keys)
    }

    // MARK: - Task flow

    private func createTask(path: String, body: [String: Any]) async throws -> String {
        let (data, status) = try await send(method: "POST", path: path, body: body)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status), let id = json?["id"] as? String else {
            let detail = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw GenerationBackendError.transport("Runway HTTP \(status): \(detail)")
        }
        return id
    }

    private func waitForOutput(taskId: String) async throws -> [String] {
        let deadline = Date().addingTimeInterval(Self.maxWait)
        while true {
            let (data, status) = try await send(method: "GET", path: "tasks/\(taskId)", body: nil)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (200..<300).contains(status), let state = json?["status"] as? String else {
                let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
                throw GenerationBackendError.transport("Runway task poll HTTP \(status): \(detail)")
            }
            switch state {
            case "SUCCEEDED":
                guard let output = json?["output"] as? [String], !output.isEmpty else {
                    throw GenerationBackendError.transport("Runway returned no output")
                }
                return output
            case "FAILED", "CANCELLED":
                let reason = (json?["failure"] as? String) ?? "Runway generation \(state.lowercased())"
                throw GenerationBackendError.transport(reason)
            default: // PENDING, THROTTLED, RUNNING
                if Date() >= deadline {
                    throw GenerationBackendError.transport("Runway generation timed out")
                }
                try await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
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
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
