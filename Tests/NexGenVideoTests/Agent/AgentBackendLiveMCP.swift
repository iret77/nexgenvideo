import Foundation
import MCP
@testable import NexGenVideo

@MainActor
final class AgentBackendLiveMCP {
    let sessionID = UUID()
    let generationID = UUID()
    let nonce = UUID().uuidString
    let receipt = UUID().uuidString
    private(set) var calls: [(id: String, json: String)] = []
    private(set) var holdStarted = false
    private(set) var stopped = false
    private var hold: CheckedContinuation<Void, Never>?
    private var server: MCPHTTPServer?

    var schema: AgentRuntimeToolSchema {
        .init(name: "acceptance_echo", description: "Read-only acceptance receipt. Echo returns a new host receipt; hold waits for cancellation.",
            inputSchema: ["type": "object", "additionalProperties": false,
                "required": ["nonce", "operation"], "properties": [
                    "nonce": ["type": "string", "enum": [nonce]],
                    "operation": ["type": "string", "enum": ["echo", "hold"]]]])
    }

    func invoke(id: String, name: String, json: String) async -> ToolResult {
        do {
            guard !stopped, name == schema.name, let bytes = json.data(using: .utf8),
                  let args = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                return .error("Unrecognized live acceptance call.")
            }
            try validateToolInput(in: args, against: schema.inputSchema, path: name)
            guard args["nonce"] as? String == nonce, calls.isEmpty else {
                return .error("The live acceptance call was duplicated or changed its nonce.")
            }
            calls.append((id, json))
            if args["operation"] as? String == "hold" {
                holdStarted = true
                await withTaskCancellationHandler {
                    await withCheckedContinuation { hold = $0 }
                } onCancel: { Task { @MainActor [weak self] in self?.releaseHold() } }
                return .error("The host cancelled this acceptance operation.")
            }
            return .ok("Actual host receipt: " + receipt)
        } catch { return .error("The live acceptance tool input failed its actual schema.") }
    }

    func releaseHold() { hold?.resume(); hold = nil }

    func start() async throws -> Int {
        let server = MCPHTTPServer(port: 0, makeServer: { [weak self] origin in
            let sdk = Server(name: "nexgen", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
            await self?.register(sdk, origin: origin)
            return sdk
        }, modernHandler: { [weak self] request, origin in
            guard let self else { return .error(status: 503, code: -32603, message: "Acceptance ended.") }
            return await self.modern(request, origin: origin)
        })
        self.server = server
        try await server.start()
        guard let port = await server.boundPort else { throw ToolError("The isolated acceptance listener has no port.") }
        return Int(port)
    }

    func stop() async {
        stopped = true; releaseHold()
        let owned = server; server = nil
        await owned?.stop()
    }

    private func call(id: String?, name: String, json: String, origin: ToolCallOrigin) async -> ToolResult {
        guard origin == .embeddedRuntime(chatSessionID: sessionID, runtimeGenerationID: generationID), let id else {
            return .error("This call does not belong to the live acceptance runtime.")
        }
        return await invoke(id: id, name: name, json: json)
    }

    private func register(_ sdk: Server, origin: MCPHTTPServer.SessionOrigin) async {
        let value = schema
        let tool = Tool(name: value.name, description: value.description,
            inputSchema: MCP20260728.WireValue.fromAny(value.inputSchema).mcpValue)
        await sdk.withMethodHandler(ListTools.self) { _ in .init(tools: [tool]) }
        await sdk.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else { return ToolResult.error("Acceptance ended.").toMCPResult() }
            let args = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
            let bytes = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys, .withoutEscapingSlashes])
            return await self.call(id: MCPService.toolUseID(params), name: params.name,
                json: String(decoding: bytes, as: UTF8.self), origin: origin.value).toMCPResult()
        }
    }

    private func modern(_ request: MCP20260728.Request, origin: ToolCallOrigin) async -> MCP20260728.HandlerResult {
        guard !stopped else { return .error(status: 503, code: -32603, message: "Acceptance ended.") }
        switch request.method {
        case "server/discover":
            return .result(["supportedVersions": .array([.string(MCP20260728.version)]),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]), "ttlMs": .int(0), "cacheScope": .string("private")])
        case "tools/list":
            let value = schema
            return .result(["tools": .array([.object(["name": .string(value.name), "description": .string(value.description),
                "inputSchema": .fromAny(value.inputSchema)])]), "ttlMs": .int(0), "cacheScope": .string("private")])
        case "tools/call":
            guard let name = request.params["name"]?.stringValue, let args = request.params["arguments"]?.objectValue,
                  request.params["inputResponses"] == nil, request.params["requestState"] == nil else {
                return .error(status: 400, code: -32602, message: "Invalid acceptance call.")
            }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let json = try encoder.encode(MCP20260728.WireValue.object(args))
                let result = await call(id: MCPService.toolUseID(request), name: name, json: String(decoding: json, as: UTF8.self), origin: origin)
                let texts = result.content.compactMap { block -> MCP20260728.WireValue? in
                    guard case .text(let value) = block else { return nil }
                    return .object(["type": .string("text"), "text": .string(value)])
                }
                return .result(["content": .array(texts), "isError": .bool(result.isError)])
            } catch { return .error(status: 400, code: -32602, message: "Invalid acceptance JSON.") }
        default: return .error(status: 404, code: -32601, message: "Method unavailable in live acceptance.")
        }
    }
}
