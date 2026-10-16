import Foundation
@testable import NexGenVideo

/// Entries in the documented `GET /v1/models` shape.
enum AnthropicModelFixtures {
    static func entry(
        id: String,
        name: String,
        created: String,
        line: String?,
        lifecycle: String = "active",
        maxTokens: Int? = 128_000,
        adaptive: Bool = true,
        enabled: Bool = false,
        effort: Bool = true
    ) -> [String: Any] {
        func flag(_ value: Bool) -> [String: Any] { ["supported": value] }
        return [
            "type": "model",
            "id": id,
            "display_name": name,
            "created_at": created,
            "lifecycle": lifecycle,
            "line": line.map { $0 as Any } ?? NSNull(),
            "deprecated_at": NSNull(),
            "retires_at": NSNull(),
            "max_input_tokens": 1_000_000,
            "max_tokens": maxTokens.map { $0 as Any } ?? NSNull(),
            "capabilities": [
                "image_input": flag(true),
                "thinking": [
                    "supported": adaptive || enabled,
                    "types": [
                        "adaptive": flag(adaptive),
                        "enabled": flag(enabled),
                        "disabled": flag(true),
                    ],
                ],
                "effort": [
                    "supported": effort,
                    "low": flag(effort),
                    "medium": flag(effort),
                    "high": flag(effort),
                    "max": flag(effort),
                    "xhigh": NSNull(),
                ],
            ],
        ]
    }

    static func page(_ entries: [[String: Any]], hasMore: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "data": entries,
            "first_id": entries.first?["id"] ?? NSNull(),
            "last_id": entries.last?["id"] ?? NSNull(),
            "has_more": hasMore,
        ])
    }

    static var sonnet55: [String: Any] { entry(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", created: "2026-09-29T00:00:00Z", line: "sonnet") }
    static var opus55: [String: Any] { entry(id: "claude-opus-5-5", name: "Claude Opus 5.5", created: "2026-09-21T00:00:00Z", line: "opus") }
    static var haiku55: [String: Any] { entry(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", created: "2026-08-10T00:00:00Z", line: "haiku") }
    static var sonnet5: [String: Any] { entry(id: "claude-sonnet-5", name: "Claude Sonnet 5", created: "2026-05-12T00:00:00Z", line: "sonnet") }
    static var sonnet46: [String: Any] { entry(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", created: "2026-02-17T00:00:00Z", line: "sonnet") }
    static var haiku45: [String: Any] { entry(
        id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", created: "2025-10-01T00:00:00.000Z",
        line: "haiku", maxTokens: 64_000, adaptive: false, enabled: true, effort: false
    ) }

    static func models(_ entries: [[String: Any]]) -> [AnthropicModelInfo] {
        entries.compactMap(AnthropicModelsAPI.model(from:))
    }

    static func info(_ entry: [String: Any]) -> AnthropicModelInfo {
        AnthropicModelsAPI.model(from: entry)!
    }

    static func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ngv-model-catalog-\(UUID().uuidString)")!
    }
}

final class RecordingModelsTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [Result<Data, Error>]
    private var status: Int
    private(set) var requests: [URLRequest] = []

    init(pages: [Result<Data, Error>], status: Int = 200) {
        self.pages = pages
        self.status = status
    }

    var recorded: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var transport: AnthropicModelsAPI.Transport {
        { [self] request in
            try self.respond(to: request)
        }
    }

    private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        requests.append(request)
        let next = pages.isEmpty ? Result<Data, Error>.failure(URLError(.badServerResponse)) : pages.removeFirst()
        let code = status
        lock.unlock()
        let data = try next.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
