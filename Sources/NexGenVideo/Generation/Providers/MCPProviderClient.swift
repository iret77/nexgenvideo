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
        case cancellationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "The provider MCP is not connected."
            case .toolFailed(let message): message
            case .cancellationFailed(let message):
                "The provider MCP request could not be cancelled (\(message)). It may still run and incur charges."
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
        return try await payloads(from: context, client: client)
    }

    func callGenerationTool(
        name: String,
        arguments: [String: Value],
        onDispatched: @escaping @MainActor @Sendable () -> Void
    ) async throws -> [String] {
        let client = try await connectedClient()
        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: name,
            arguments: arguments
        )
        await onDispatched()
        return try await payloads(from: context, client: client)
    }

    private func payloads(
        from context: RequestContext<CallTool.Result>,
        client: Client
    ) async throws -> [String] {
        let result = try await Self.awaitRequest(context) { requestID in
            try await client.cancelRequest(
                requestID,
                reason: "The NexGenVideo request was cancelled."
            )
        }
        if result.isError == true {
            let message = Self.toolErrorMessage(result)
            throw ClientError.toolFailed(message.isEmpty ? "provider tool reported an error" : message)
        }
        return Self.payloadContents(result)
    }

    static func awaitRequest<Output: Sendable & Decodable>(
        _ context: RequestContext<Output>,
        cancelRequest: @escaping @Sendable (ID) async throws -> Void
    ) async throws -> Output {
        let settlement = RequestSettlement<Output> {
            try await cancelRequest(context.requestID)
        }
        let requestTask = Task {
            do {
                settlement.receive(.success(try await context.value))
            } catch {
                settlement.receive(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            defer { requestTask.cancel() }
            return try await settlement.value()
        } onCancel: {
            settlement.cancel()
        }
    }

    private final class RequestSettlement<Output: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let cancelAction: @Sendable () async throws -> Void
        private var continuation: CheckedContinuation<Output, Error>?
        private var result: Result<Output, Error>?
        private var cancellationRequested = false

        init(cancelAction: @escaping @Sendable () async throws -> Void) {
            self.cancelAction = cancelAction
        }

        func value() async throws -> Output {
            try await withCheckedThrowingContinuation { continuation in
                let completed = lock.withLock { () -> Result<Output, Error>? in
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let completed { continuation.resume(with: completed) }
            }
        }

        func receive(_ result: Result<Output, Error>) {
            let continuation = lock.withLock {
                guard !cancellationRequested, self.result == nil else { return nil }
                self.result = result
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(with: result)
        }

        func cancel() {
            let shouldSend = lock.withLock {
                guard result == nil, !cancellationRequested else { return false }
                cancellationRequested = true
                return true
            }
            guard shouldSend else { return }
            let cancelAction = self.cancelAction
            Task { [self] in
                do {
                    try await cancelAction()
                    settle(.failure(CancellationError()))
                } catch {
                    settle(.failure(ClientError.cancellationFailed(
                        error.localizedDescription
                    )))
                }
            }
        }

        private func settle(_ result: Result<Output, Error>) {
            let continuation = lock.withLock {
                guard self.result == nil else { return nil }
                self.result = result
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(with: result)
        }
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
                let extraction = inlineMediaPayloads(
                    in: Data(text.utf8),
                    remainingCharacters: &remainingInlineCharacters
                )
                if extraction.foundCandidate {
                    if let sanitizedPayload = extraction.sanitizedPayload {
                        payloads.append(sanitizedPayload)
                    }
                } else {
                    payloads.append(text)
                }
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
        guard MCPGenerationLifecycle.isSupportedInlineMIMEType(mimeType) else {
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

        func sanitized(_ value: Any, context: InlineMediaContext) -> Any {
            if let object = value as? [String: Any] {
                let effectiveContext: InlineMediaContext = if context == .excluded
                    || (object["type"] as? String).map(
                        MCPGenerationLifecycle.isExcludedOutputFieldName
                    ) == true {
                    .excluded
                } else {
                    context
                }
                var sanitizedObject: [String: Any] = [:]
                var inlineMarker: [String: Any]?
                let inlineMedia = MCPGenerationLifecycle.inlineMediaStrings(in: object)
                let containsInlineBytes = inlineMedia != nil
                if let (encoded, mimeType) = inlineMedia {
                    foundCandidate = true
                    let characterCount = encoded.utf8.count
                    if effectiveContext == .rootRecord || effectiveContext == .output,
                       MCPGenerationLifecycle.isSupportedInlineMIMEType(mimeType),
                       characterCount <= remainingCharacters {
                        inlineMarker = ["data": encoded, "mime_type": mimeType]
                        remainingCharacters -= characterCount
                    }
                }
                for (key, child) in object {
                    if containsInlineBytes, (key == "data" || key == "blob") { continue }
                    let childContext: InlineMediaContext
                    if effectiveContext == .excluded
                        || MCPGenerationLifecycle.isExcludedOutputFieldName(key) {
                        childContext = .excluded
                    } else if MCPGenerationLifecycle.isOutputEnvelopeFieldName(key) {
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
