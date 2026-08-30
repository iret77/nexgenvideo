import Foundation
import MCP

/// NGV as an MCP **client** to a provider's own MCP server (OpenArt, Runway, Higgsfield, ACE, …).
/// This is the `.mcp` transport of the provider layer: the LLM never touches the raw endpoint —
/// NGV connects, and the generation path calls the provider's tool with an ALREADY-COMPILED prompt
/// (the prompt-engine gate runs upstream in `GenerationController`, exactly like the `.api` transport).
/// Distinct from the embedded Claude runtime's external-MCP config: there Claude is the client; here
/// NGV is, so the gate and the resolver stay in force.
actor MCPProviderClient {
    struct Config: Sendable, Equatable {
        /// Hosted server URL (e.g. https://mcp.openart.ai/mcp). stdio/local support lands with ACE.
        let endpoint: URL
        /// Optional bearer token for the provider's subscription/OAuth session.
        let bearerToken: String?

        init(endpoint: URL, bearerToken: String? = nil) {
            self.endpoint = endpoint
            self.bearerToken = bearerToken
        }
    }

    enum ClientError: LocalizedError, Sendable {
        case notConnected
        case toolFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "The provider MCP is not connected."
            case .toolFailed(let message): message
            }
        }
    }

    /// A tool the provider's MCP server advertises via `tools/list` — discovered at runtime, never
    /// hardcoded, so a provider changing its MCP tools needs no NGV update. Feeds the manifest/catalog
    /// (which capabilities this provider offers over `.mcp`) and the resolver.
    struct DiscoveredTool: Sendable, Equatable {
        let name: String
        let description: String?
        let inputSchema: Value
        let outputSchema: Value?

        init(
            name: String,
            description: String?,
            inputSchema: Value,
            outputSchema: Value? = nil
        ) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.outputSchema = outputSchema
        }
    }

    private let config: Config
    private var client: Client?

    init(config: Config) { self.config = config }

    private func connectedClient() async throws -> Client {
        if let client { return client }
        let client = Client(name: "nexgen", version: "1.0.0")
        let transport: HTTPClientTransport
        if let token = config.bearerToken, !token.isEmpty {
            transport = HTTPClientTransport(endpoint: config.endpoint, requestModifier: { request in
                var request = request
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            })
        } else {
            transport = HTTPClientTransport(endpoint: config.endpoint)
        }
        try await client.connect(transport: transport)
        self.client = client
        return client
    }

    /// Call a provider tool with a pre-compiled argument set and return its textual contents
    /// (result URLs / payload the host then imports onto the timeline). Arguments are already
    /// gate-compiled by the caller.
    func callTool(name: String, arguments: [String: Value]) async throws -> [String] {
        let client = try await connectedClient()
        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: name,
            arguments: arguments
        )
        let result = try await context.value
        if result.isError == true {
            let message = Self.toolErrorMessage(result)
            throw ClientError.toolFailed(message.isEmpty ? "provider tool reported an error" : message)
        }
        return Self.payloadContents(result)
    }

    func callTool(name: String, arguments: [String: String]) async throws -> [String] {
        try await callTool(name: name, arguments: arguments.mapValues(Value.string))
    }

    /// Enumerate the provider's tools (`tools/list`). This is how NGV learns what a provider offers
    /// over `.mcp` without a per-provider hardcoded table — the self-describing MCP handshake.
    func discoverTools() async throws -> [DiscoveredTool] {
        let client = try await connectedClient()
        var discovered: [DiscoveredTool] = []
        var byName: [String: DiscoveredTool] = [:]
        var seenCursors = Set<String>()
        var cursor: String?
        var pages = 0
        repeat {
            let (tools, nextCursor) = try await client.listTools(cursor: cursor)
            for tool in tools {
                let mapped = DiscoveredTool(
                    name: tool.name,
                    description: tool.description,
                    inputSchema: tool.inputSchema,
                    outputSchema: tool.outputSchema
                )
                if let existing = byName[mapped.name] {
                    guard existing == mapped else {
                        throw ClientError.toolFailed(
                            "The provider returned conflicting definitions for tool \(mapped.name)."
                        )
                    }
                    continue
                }
                byName[mapped.name] = mapped
                discovered.append(mapped)
                guard discovered.count <= 1_000 else {
                    throw ClientError.toolFailed("The provider returned too many tools.")
                }
            }
            pages += 1
            if let nextCursor, !nextCursor.isEmpty {
                guard seenCursors.insert(nextCursor).inserted else {
                    throw ClientError.toolFailed("The provider repeated its tools cursor.")
                }
                cursor = nextCursor
            } else {
                cursor = nil
            }
        } while cursor != nil && pages < 20
        guard cursor == nil else {
            throw ClientError.toolFailed("The provider tool list exceeded the paging limit.")
        }
        return discovered
    }

    func disconnect() async {
        await client?.disconnect()
        client = nil
    }

    private static func toolErrorMessage(_ result: CallTool.Result) -> String {
        let maximumCharacters = 16_384
        let message = result.content.compactMap { part -> String? in
            guard case let .text(text, _, _) = part else { return nil }
            return text
        }.joined(separator: " ")
        guard message.count > maximumCharacters else { return message }
        return String(message.prefix(maximumCharacters)) + "…"
    }

    static func payloadContents(_ result: CallTool.Result) -> [String] {
        var payloads: [String] = []
        var remainingInlineCharacters = MCPGenerationLifecycle.maxInlineMediaBase64Characters
        for part in result.content {
            switch part {
            case .text(let text, _, _):
                payloads.append(text)
            case .resource(let resource, _, _):
                if let data = try? JSONEncoder().encode(resource) {
                    let extraction = inlineMediaPayloads(
                        in: data,
                        remainingCharacters: &remainingInlineCharacters
                    )
                    if extraction.foundCandidate {
                        if let sanitizedPayload = extraction.sanitizedPayload {
                            payloads.append(sanitizedPayload)
                        }
                    } else if let json = String(data: data, encoding: .utf8) {
                        payloads.append(json)
                    }
                }
            case .resourceLink(let uri, _, _, _, let mimeType, _):
                let isMedia = mimeType?.lowercased().hasPrefix("image/") == true
                    || mimeType?.lowercased().hasPrefix("video/") == true
                    || mimeType?.lowercased().hasPrefix("audio/") == true
                if isMedia {
                    var object = ["resource_url": uri]
                    if let mimeType { object["mime_type"] = mimeType }
                    if let data = try? JSONSerialization.data(withJSONObject: object),
                       let json = String(data: data, encoding: .utf8) {
                        payloads.append(json)
                    }
                }
            case .image(let data, let mimeType, _, _),
                 .audio(let data, let mimeType, _, _):
                if let inline = inlineMediaPayload(
                    data: data,
                    mimeType: mimeType,
                    remainingCharacters: &remainingInlineCharacters
                ) {
                    payloads.append(inline)
                }
            }
        }
        if let structured = result.structuredContent,
           let data = try? JSONEncoder().encode(structured) {
            let extraction = inlineMediaPayloads(
                in: data,
                remainingCharacters: &remainingInlineCharacters
            )
            if extraction.foundCandidate {
                if let sanitizedPayload = extraction.sanitizedPayload {
                    payloads.append(sanitizedPayload)
                }
            } else if let json = String(data: data, encoding: .utf8) {
                payloads.append(json)
            }
        }
        return payloads
    }

    private static func inlineMediaPayload(
        data: String,
        mimeType: String,
        remainingCharacters: inout Int
    ) -> String? {
        let normalizedMIME = mimeType.lowercased()
        guard normalizedMIME.hasPrefix("image/") || normalizedMIME.hasPrefix("audio/") else {
            return nil
        }
        let characterCount = data.utf8.count
        guard characterCount <= remainingCharacters else { return nil }
        let object: [String: Any] = [
            "_ngv_inline_media": [
                "data": data,
                "mime_type": mimeType,
            ],
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        remainingCharacters -= characterCount
        return String(data: encoded, encoding: .utf8)
    }

    struct InlineMediaExtraction: Equatable {
        let foundCandidate: Bool
        let sanitizedPayload: String?
    }

    private enum InlineMediaContext: Equatable {
        case rootRecord
        case output
        case unknown
        case excluded
    }

    static func inlineMediaPayloads(
        in data: Data,
        remainingCharacters: inout Int
    ) -> InlineMediaExtraction {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return InlineMediaExtraction(
                foundCandidate: false,
                sanitizedPayload: nil
            )
        }
        var foundCandidate = false
        let excludedTokens = [
            "argument", "input", "parameter", "params", "prompt", "reference", "request",
            "source", "thumbnail",
        ]
        let outputKeys: Set<String> = [
            "audio", "audios", "data", "file", "files", "image", "images", "job",
            "jobs", "jobset", "media", "output", "outputs", "payload", "raw", "resource",
            "resources", "result", "results",
        ]

        func isExcluded(_ value: String) -> Bool {
            excludedTokens.contains { value.contains($0) }
        }

        func sanitized(_ value: Any, context: InlineMediaContext) -> Any {
            if let object = value as? [String: Any] {
                let declaredType = (object["type"] as? String)
                    .map(MCPGenerationLifecycle.normalizeFieldName)
                let effectiveContext: InlineMediaContext = if context == .excluded
                    || declaredType.map(isExcluded) == true {
                    .excluded
                } else {
                    context
                }
                var sanitizedObject: [String: Any] = [:]
                var inlineMarker: [String: Any]?
                let containsInlineBytes = (object["data"] ?? object["blob"]) is String
                    && (object["mimeType"]
                        ?? object["mime_type"]
                        ?? object["contentType"]
                        ?? object["content_type"]) is String
                if let encoded = (object["data"] ?? object["blob"]) as? String,
                   let mimeType = (object["mimeType"]
                        ?? object["mime_type"]
                        ?? object["contentType"]
                        ?? object["content_type"]) as? String {
                    foundCandidate = true
                    let normalizedMIME = mimeType.lowercased()
                    let characterCount = encoded.utf8.count
                    if effectiveContext == .rootRecord || effectiveContext == .output,
                       normalizedMIME.hasPrefix("image/") || normalizedMIME.hasPrefix("audio/"),
                       characterCount <= remainingCharacters {
                        inlineMarker = ["data": encoded, "mime_type": mimeType]
                        remainingCharacters -= characterCount
                    }
                }
                for (key, child) in object {
                    if containsInlineBytes, (key == "data" || key == "blob") { continue }
                    let normalized = MCPGenerationLifecycle.normalizeFieldName(key)
                    let childContext: InlineMediaContext
                    if effectiveContext == .excluded || isExcluded(normalized) {
                        childContext = .excluded
                    } else if outputKeys.contains(normalized) {
                        childContext = .output
                    } else if effectiveContext == .output {
                        childContext = .output
                    } else {
                        childContext = .unknown
                    }
                    sanitizedObject[key] = sanitized(child, context: childContext)
                }
                if let inlineMarker {
                    sanitizedObject["_ngv_inline_media"] = inlineMarker
                }
                return sanitizedObject
            } else if let array = value as? [Any] {
                return array.map { sanitized($0, context: context) }
            }
            return value
        }

        let sanitizedRoot = sanitized(root, context: .rootRecord)
        let sanitizedData = try? JSONSerialization.data(withJSONObject: sanitizedRoot)
        let sanitizedPayload = sanitizedData.flatMap { String(data: $0, encoding: .utf8) }
        return InlineMediaExtraction(
            foundCandidate: foundCandidate,
            sanitizedPayload: sanitizedPayload
        )
    }

}
