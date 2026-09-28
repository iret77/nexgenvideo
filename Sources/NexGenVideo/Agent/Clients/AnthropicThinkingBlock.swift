import Foundation

struct AnthropicThinkingBlock: Codable, Sendable, Equatable {
    private let encodedJSON: Data
    let summary: String?

    init(json: [String: Any]) throws {
        switch json["type"] as? String {
        case "thinking":
            guard json["thinking"] is String,
                  let signature = json["signature"] as? String, !signature.isEmpty else {
                throw AnthropicClientError.streamError("Thinking block is missing its signed content.")
            }
        case "redacted_thinking":
            guard let data = json["data"] as? String, !data.isEmpty else {
                throw AnthropicClientError.streamError("Redacted thinking block is incomplete.")
            }
        default:
            throw AnthropicClientError.streamError("Unexpected thinking block type.")
        }
        encodedJSON = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        if json["type"] as? String == "thinking", let text = json["thinking"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary = text
        } else {
            summary = nil
        }
    }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: encodedJSON) as? [String: Any]) ?? [:]
    }

    init(from decoder: any Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicClientError.streamError("Invalid saved thinking block.")
        }
        try self.init(json: json)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedJSON)
    }
}
