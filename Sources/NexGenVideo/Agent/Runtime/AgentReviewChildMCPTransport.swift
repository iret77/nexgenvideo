import Foundation
import MCP

@MainActor
final class AgentReviewChildMCPTransport {
    private let sessionID: UUID
    private let generationID: UUID
    private let schemas: [AgentRuntimeToolSchema]
    private let execute: AgentRuntimeToolExecutor
    private var server: MCPHTTPServer?
    private var stopped = false

    init(sessionID: UUID, generationID: UUID, schemas: [AgentRuntimeToolSchema],
         execute: @escaping AgentRuntimeToolExecutor) {
        self.sessionID = sessionID; self.generationID = generationID
        self.schemas = schemas; self.execute = execute
    }

    func start() async throws -> Int {
        guard server == nil, !stopped else { throw CancellationError() }
        let server = MCPHTTPServer(port: 0, makeServer: { [weak self] origin in
            let value = Server(name: "nexgen", version: "1.0.0",
                capabilities: .init(tools: .init(listChanged: false)))
            await self?.register(on: value, origin: origin)
            return value
        }, modernHandler: { [weak self] request, origin in
            guard let self else { return .error(status: 503, code: -32603, message: "The review context ended.") }
            return await self.modern(request, origin: origin)
        })
        self.server = server
        try await server.start()
        guard !stopped, let port = await server.boundPort, port > 0 else {
            await server.stop()
            throw CancellationError()
        }
        return Int(port)
    }

    func stop() async {
        stopped = true
        let server = server
        self.server = nil
        await server?.stop()
    }

    private func register(on server: Server, origin: MCPHTTPServer.SessionOrigin) async {
        let tools = schemas.map { Tool(name: $0.name, description: $0.description,
            inputSchema: MCP20260728.WireValue.fromAny($0.inputSchema).mcpValue) }
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else { return ToolResult.error("The review context ended.").toMCPResult() }
            let arguments = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
            let bytes = try JSONSerialization.data(withJSONObject: arguments,
                options: [.sortedKeys, .withoutEscapingSlashes])
            return await self.call(name: params.name, json: String(decoding: bytes, as: UTF8.self),
                toolUseID: MCPService.toolUseID(params), origin: origin.value).toMCPResult()
        }
    }

    private func call(name: String, json: String, toolUseID: String?, origin: ToolCallOrigin) async -> ToolResult {
        guard !stopped,
              origin == .embeddedRuntime(chatSessionID: sessionID, runtimeGenerationID: generationID),
              let toolUseID, schemas.contains(where: { $0.name == name }) else {
            return .error("The review call does not belong to this child context.")
        }
        return await execute(toolUseID, name, json)
    }

    private func modern(_ request: MCP20260728.Request, origin: ToolCallOrigin) async -> MCP20260728.HandlerResult {
        guard !stopped else { return .error(status: 503, code: -32603, message: "The review context ended.") }
        switch request.method {
        case "server/discover":
            return .result(["supportedVersions": .array([.string(MCP20260728.version)]),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "ttlMs": .int(0), "cacheScope": .string("private")])
        case "tools/list":
            guard request.params["cursor"] == nil else {
                return .error(status: 400, code: -32602, message: "The review tool list has no additional page.")
            }
            return .result(["tools": .array(schemas.map { .object([
                "name": .string($0.name), "description": .string($0.description),
                "inputSchema": .fromAny($0.inputSchema)]) }), "ttlMs": .int(0), "cacheScope": .string("private")])
        case "tools/call":
            guard let name = request.params["name"]?.stringValue,
                  request.params["inputResponses"] == nil, request.params["requestState"] == nil,
                  let arguments = request.params["arguments"]?.objectValue else {
                return .error(status: 400, code: -32602, message: "Invalid review call parameters.")
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let json = try encoder.encode(MCP20260728.WireValue.object(arguments))
                let result = await call(name: name, json: String(decoding: json, as: UTF8.self),
                    toolUseID: MCPService.toolUseID(request), origin: origin)
                return .result(["content": .array(result.content.map { block in
                    switch block {
                    case .text(let text): .object(["type": .string("text"), "text": .string(text)])
                    case .image(let base64, let mediaType): .object(["type": .string("image"),
                        "data": .string(base64), "mimeType": .string(mediaType)])
                    }
                }), "isError": .bool(result.isError)])
            } catch { return .error(status: 400, code: -32602, message: "Invalid review JSON arguments.") }
        default:
            return .error(status: 404, code: -32601, message: "Method not available in a review context.")
        }
    }
}
