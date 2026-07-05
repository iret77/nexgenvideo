import Foundation

/// Direct client for the Higgsfield platform API (platform.higgsfield.ai). Contract verified against
/// the official SDK source (higgsfield-ai/higgsfield-js v2): the input object is posted at the TOP
/// LEVEL ("send input directly (not wrapped in params)"), auth is `Authorization: Key ID:SECRET`,
/// and results are polled at GET /requests/{request_id}/status until completed/failed/nsfw.
actor HiggsfieldClient {
    /// The user's combined key string, "KEY_ID:KEY_SECRET".
    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private static let base = "https://platform.higgsfield.ai"
    private static let pollInterval: UInt64 = 3_000_000_000 // 3s
    private static let maxWait: TimeInterval = 10 * 60

    /// POST /v1/image2video/dop — Higgsfield's camera-motion image-to-video.
    func dopImageToVideo(model: String, prompt: String, imageURL: String) async throws -> [String] {
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "input_images": [["type": "image_url", "image_url": imageURL]],
        ]
        let (data, status) = try await send(method: "POST", path: "/v1/image2video/dop", body: body)
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestId = json["request_id"] as? String else {
            let detail = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw GenerationBackendError.transport("Higgsfield HTTP \(status): \(detail)")
        }
        return try await waitForOutput(requestId: requestId)
    }

    private func waitForOutput(requestId: String) async throws -> [String] {
        let deadline = Date().addingTimeInterval(Self.maxWait)
        while true {
            let (data, status) = try await send(method: "GET", path: "/requests/\(requestId)/status", body: nil)
            guard (200..<300).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["status"] as? String else {
                let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
                throw GenerationBackendError.transport("Higgsfield poll HTTP \(status): \(detail)")
            }
            switch state {
            case "completed":
                var urls: [String] = []
                if let video = json["video"] as? [String: Any], let url = video["url"] as? String {
                    urls.append(url)
                }
                if let images = json["images"] as? [[String: Any]] {
                    urls.append(contentsOf: images.compactMap { $0["url"] as? String })
                }
                guard !urls.isEmpty else {
                    throw GenerationBackendError.transport("Higgsfield returned no output")
                }
                return urls
            case "failed":
                throw GenerationBackendError.transport("Higgsfield generation failed")
            case "nsfw":
                throw GenerationBackendError.transport("Higgsfield rejected the content (nsfw filter)")
            default: // queued, in_progress
                if Date() >= deadline {
                    throw GenerationBackendError.transport("Higgsfield generation timed out")
                }
                try await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    private func send(method: String, path: String, body: [String: Any]?) async throws -> (Data, Int) {
        guard let url = URL(string: "\(Self.base)\(path)") else {
            throw GenerationBackendError.transport("Invalid Higgsfield endpoint: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
