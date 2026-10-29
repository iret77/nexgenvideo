import Foundation

extension Notification.Name {
    static let anthropicAPIKeyChanged = Notification.Name("anthropicAPIKeyChanged")
}

enum AnthropicKeychain {
    private static let account = "anthropic-api-key"

    @discardableResult
    static func save(_ key: String) -> Bool {
        guard KeychainStore.save(key, account: account) else { return false }
        NotificationCenter.default.post(name: .anthropicAPIKeyChanged, object: nil)
        return true
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    @discardableResult
    static func delete() -> Bool {
        guard KeychainStore.delete(account: account) else { return false }
        NotificationCenter.default.post(name: .anthropicAPIKeyChanged, object: nil)
        return true
    }
}

struct AnthropicClient: AgentClient {
    let apiKey: String
    let model: AnthropicModelInfo
    var maxTokens: Int? = nil
    var reviewStreamControl: AgentReviewChildStreamControl? = nil
    var urlSession: URLSession = .shared

    var supportsToolSearch: Bool { model.supportsToolSearch }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            reviewStreamControl?.register(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AnthropicClientError.missingAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: AnthropicRequestBody.build(
                model: model, maxTokens: maxTokens,
                system: system, tools: tools, messages: messages
            ),
            options: [.sortedKeys]
        )

        if let reviewStreamControl, let body = request.httpBody {
            try await reviewStreamControl.requireRequest(body)
        }
        try Task.checkCancellation()
        let (bytes, response) = try await urlSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw AnthropicClientError.httpError(status: http.statusCode, body: body)
        }

        try await AnthropicSSE.parse(bytes: bytes, continuation: continuation)
    }
}
