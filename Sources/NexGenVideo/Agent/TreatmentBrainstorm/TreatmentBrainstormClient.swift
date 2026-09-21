import Foundation
import NexGenEngine

struct TreatmentBrainstormOutput: Codable, Sendable, Equatable {
    let title: String
    let summary: String
    let bodyMarkdown: String

    private enum CodingKeys: String, CodingKey {
        case title
        case summary
        case bodyMarkdown = "body_markdown"
    }
}

struct TreatmentBrainstormProviderResponse: Sendable, Equatable {
    let responseID: String?
    let outputJSON: String
    let output: TreatmentBrainstormOutput
    let inputTokens: Int?
    let outputTokens: Int?
}

enum TreatmentBrainstormClientError: LocalizedError, Sendable, Equatable {
    case missingCredential(String)
    case requestFailed(Int, String)
    case invalidResponse(String)
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let provider): "Connect \(provider) before running Treatment Brainstorm."
        case .requestFailed(let status, let detail): "Treatment Brainstorm provider error (\(status)): \(detail.prefix(300))"
        case .invalidResponse(let detail): "Treatment Brainstorm returned an invalid structured result: \(detail)"
        case .modelUnavailable(let model): "The activated model \(model) is not currently offered by its provider."
        }
    }
}

struct TreatmentBrainstormRequest: Sendable, Equatable {
    let model: TreatmentBrainstormModel
    let system: String
    let input: String
}

struct TreatmentBrainstormHTTPClient: @unchecked Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func offeredModelIDs(provider: TreatmentBrainstormProvider, apiKey: String) async throws -> Set<String> {
        switch provider {
        case .anthropic:
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1000")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let object = try await json(request)
            let models = (object["data"] as? [[String: Any]]) ?? []
            return Set(models.compactMap { $0["id"] as? String })
        case .openai:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let object = try await json(request)
            let models = (object["data"] as? [[String: Any]]) ?? []
            return Set(models.compactMap { $0["id"] as? String })
        case .google:
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let object = try await json(request)
            let models = (object["models"] as? [[String: Any]]) ?? []
            return Set(models.compactMap { model in
                let actions = model["supportedGenerationMethods"] as? [String] ?? []
                guard actions.contains("generateContent"),
                      let name = model["name"] as? String else { return nil }
                return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            })
        }
    }

    func generate(_ request: TreatmentBrainstormRequest, apiKey: String) async throws -> TreatmentBrainstormProviderResponse {
        switch request.model.provider {
        case .anthropic:
            return try await anthropic(request, apiKey: apiKey)
        case .openai:
            return try await openAI(request, apiKey: apiKey)
        case .google:
            return try await google(request, apiKey: apiKey)
        }
    }

    private func anthropic(
        _ value: TreatmentBrainstormRequest,
        apiKey: String
    ) async throws -> TreatmentBrainstormProviderResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": value.model.id,
            "max_tokens": 4096,
            "system": value.system,
            "messages": [["role": "user", "content": value.input]],
            "output_config": ["format": [
                "type": "json_schema",
                "schema": Self.outputSchema,
            ]],
        ], options: [.sortedKeys])
        let object = try await json(request)
        let blocks = object["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw TreatmentBrainstormClientError.invalidResponse("Anthropic response has no text block.")
        }
        let usage = object["usage"] as? [String: Any]
        return try Self.parsed(
            text,
            responseID: object["id"] as? String,
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int
        )
    }

    private func openAI(
        _ value: TreatmentBrainstormRequest,
        apiKey: String
    ) async throws -> TreatmentBrainstormProviderResponse {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": value.model.id,
            "store": false,
            "max_output_tokens": 4096,
            "instructions": value.system,
            "input": value.input,
            "text": ["format": [
                "type": "json_schema",
                "name": "treatment_idea",
                "strict": true,
                "schema": Self.outputSchema,
            ]],
        ], options: [.sortedKeys])
        let object = try await json(request)
        let output = object["output"] as? [[String: Any]] ?? []
        let content = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        guard let text = content.first(where: { $0["type"] as? String == "output_text" })?["text"] as? String else {
            throw TreatmentBrainstormClientError.invalidResponse("OpenAI response has no output_text block.")
        }
        let usage = object["usage"] as? [String: Any]
        return try Self.parsed(
            text,
            responseID: object["id"] as? String,
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int
        )
    }

    private func google(
        _ value: TreatmentBrainstormRequest,
        apiKey: String
    ) async throws -> TreatmentBrainstormProviderResponse {
        let encoded = value.model.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value.model.id
        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encoded):generateContent")!
        )
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": value.system]]],
            "contents": [["role": "user", "parts": [["text": value.input]]]],
            "generationConfig": [
                "maxOutputTokens": 4096,
                "responseMimeType": "application/json",
                "responseJsonSchema": Self.outputSchema,
            ],
        ], options: [.sortedKeys])
        let object = try await json(request)
        let candidates = object["candidates"] as? [[String: Any]] ?? []
        let content = candidates.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]] ?? []
        guard let text = parts.compactMap({ $0["text"] as? String }).first else {
            throw TreatmentBrainstormClientError.invalidResponse("Google response has no text part.")
        }
        let usage = object["usageMetadata"] as? [String: Any]
        return try Self.parsed(
            text,
            responseID: object["responseId"] as? String,
            inputTokens: usage?["promptTokenCount"] as? Int,
            outputTokens: usage?["candidatesTokenCount"] as? Int
        )
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TreatmentBrainstormClientError.invalidResponse("Missing HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TreatmentBrainstormClientError.requestFailed(
                http.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TreatmentBrainstormClientError.invalidResponse("Response is not a JSON object.")
        }
        return object
    }

    static func parsed(
        _ json: String,
        responseID: String?,
        inputTokens: Int?,
        outputTokens: Int?
    ) throws -> TreatmentBrainstormProviderResponse {
        let data = Data(json.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["title", "summary", "body_markdown"]),
              let title = object["title"] as? String,
              let summary = object["summary"] as? String,
              let body = object["body_markdown"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TreatmentBrainstormClientError.invalidResponse("Output does not match the closed Treatment idea schema.")
        }
        let output = TreatmentBrainstormOutput(title: title, summary: summary, bodyMarkdown: body)
        return TreatmentBrainstormProviderResponse(
            responseID: responseID,
            outputJSON: json,
            output: output,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    static let outputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "body_markdown": ["type": "string"],
        ],
        "required": ["title", "summary", "body_markdown"],
    ]
}
