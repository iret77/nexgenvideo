import Foundation
import MCP

/// HTTP adapter. Tool handling lives in `ToolExecutor`.
@Observable
@MainActor
final class MCPService {

    static let port: UInt16 = 19789

    private static let enabledKey = "de.h5ventures.nexgenvideo.mcp.enabled"

    static var isEnabledPreference: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    private(set) var isRunning: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored
    private let toolExecutor: ToolExecutor
    @ObservationIgnored
    private var httpServer: MCPHTTPServer?
    @ObservationIgnored
    private var startGeneration = 0
    @ObservationIgnored
    private var stopInProgress = false
    @ObservationIgnored
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored
    private var isStopped = false

    init(editorProvider: @escaping () -> EditorViewModel?) {
        self.toolExecutor = ToolExecutor(editorProvider: editorProvider)
    }

    func start() {
        guard !isStopped else { return }
        startGeneration &+= 1
        let generation = startGeneration
        lastError = nil
        let httpServer = MCPHTTPServer(
            port: Self.port,
            makeServer: { [weak self] origin in
                let server = Server(
                    name: "nexgen",
                    version: "1.0.0",
                    instructions: AgentInstructions.serverInstructions,
                    capabilities: .init(
                        resources: .init(subscribe: false, listChanged: false),
                        tools: .init(listChanged: false)
                    )
                )
                await self?.registerTools(on: server, origin: origin)
                await self?.registerResources(on: server)
                return server
            },
            modernHandler: { [weak self] request, origin in
                guard let self else {
                    return .error(
                        status: 500,
                        code: -32603,
                        message: "Editor not available"
                    )
                }
                return await self.handleModernRequest(
                    request,
                    origin: origin
                )
            },
            onFailure: { [weak self] message in
                await self?.serverFailed(
                    message,
                    generation: generation
                )
            }
        )
        self.httpServer = httpServer
        Task { @MainActor [weak self] in
            do {
                try await httpServer.start()
                guard self?.startGeneration == generation else {
                    await httpServer.stop()
                    return
                }
                Log.mcp.notice("http server started port=\(Self.port)")
                self?.isRunning = true
            } catch {
                guard self?.startGeneration == generation else { return }
                Log.mcp.error("http server failed to start: \(error.localizedDescription)")
                self?.isRunning = false
                self?.lastError = error.localizedDescription
            }
        }
    }

    func stop() async {
        isStopped = true
        startGeneration &+= 1
        lastError = nil
        await stopCurrentServer()
        Log.mcp.notice("http server stopped")
    }

    func restart() {
        guard !isStopped else { return }
        startGeneration &+= 1
        let generation = startGeneration
        isRunning = false
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopCurrentServer()
            guard self.startGeneration == generation else { return }
            self.start()
        }
    }

    private func stopCurrentServer() async {
        if stopInProgress {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        stopInProgress = true
        let server = httpServer
        httpServer = nil
        isRunning = false
        if let server {
            await server.stop()
        }
        stopInProgress = false
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func serverFailed(_ message: String, generation: Int) {
        guard startGeneration == generation, !isStopped else { return }
        isRunning = false
        lastError = message
    }

    private func registerTools(
        on server: Server,
        origin: MCPHTTPServer.SessionOrigin
    ) async {
        let tools: [Tool] = ToolDefinitions.all.map { def in
            Tool(name: def.name.rawValue, description: def.description, inputSchema: def.mcpSchemaValue)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return ToolResult.error("Editor not available").toMCPResult()
            }
            return await self.dispatchCall(params, origin: origin.value)
        }
    }

    // Convert args inside the actor so the non-Sendable dict never crosses the hop.
    private func dispatchCall(
        _ params: CallTool.Parameters,
        origin: ToolCallOrigin
    ) async -> CallTool.Result {
        let args = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
        let result = await toolExecutor.execute(
            name: params.name,
            args: args,
            origin: origin
        )
        return result.toMCPResult()
    }

    private func registerResources(on server: Server) async {
        let resources = [
            Resource(
                name: "Video Models",
                uri: "nexgen://models/video",
                description: "Available AI video generation models and their capabilities",
                mimeType: "application/json"
            ),
            Resource(
                name: "Image Models",
                uri: "nexgen://models/image",
                description: "Available AI image generation models and their capabilities",
                mimeType: "application/json"
            ),
        ]

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: resources)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            await Self.readResource(uri: params.uri)
        }
    }

    private func handleModernRequest(
        _ request: MCP20260728.Request,
        origin: ToolCallOrigin
    ) async -> MCP20260728.HandlerResult {
        switch request.method {
        case "server/discover":
            return .result([
                "supportedVersions": .array([.string(MCP20260728.version)]),
                "capabilities": .object([
                    "resources": .object([
                        "subscribe": .bool(false),
                        "listChanged": .bool(false),
                    ]),
                    "tools": .object(["listChanged": .bool(false)]),
                ]),
                "instructions": .string(AgentInstructions.serverInstructions),
                "ttlMs": .int(0),
                "cacheScope": .string("private"),
            ])
        case "tools/list":
            guard request.params["cursor"] == nil else {
                return .error(
                    status: 400,
                    code: -32602,
                    message: "Invalid params: this tool list has no additional page."
                )
            }
            let tools = ToolDefinitions.all
                .sorted { $0.name.rawValue < $1.name.rawValue }
                .map { definition in
                    MCP20260728.WireValue.object([
                        "name": .string(definition.name.rawValue),
                        "description": .string(definition.description),
                        "inputSchema": .fromMCP(definition.mcpSchemaValue),
                    ])
                }
            return .result([
                "tools": .array(tools),
                "ttlMs": .int(0),
                "cacheScope": .string("private"),
            ])
        case "tools/call":
            guard let name = request.params["name"]?.stringValue else {
                return .error(
                    status: 400,
                    code: -32602,
                    message: "Invalid params: tool name is required."
                )
            }
            guard ToolDefinitions.all.contains(where: {
                $0.name.rawValue == name
            }) else {
                return .error(
                    status: 200,
                    code: -32602,
                    message: "Tool not found: \(name)"
                )
            }
            guard request.params["inputResponses"] == nil,
                  request.params["requestState"] == nil else {
                return .error(
                    status: 400,
                    code: -32602,
                    message: "Invalid params: this server does not issue MCP input requests."
                )
            }
            let arguments: [String: Any]
            if let value = request.params["arguments"] {
                guard let object = value.objectValue else {
                    return .error(
                        status: 400,
                        code: -32602,
                        message: "Invalid params: tool arguments must be an object."
                    )
                }
                arguments = object.mapValues { $0.anyValue }
            } else {
                arguments = [:]
            }
            let result = await toolExecutor.execute(
                name: name,
                args: arguments,
                origin: origin
            )
            let content = result.content.map { block -> MCP20260728.WireValue in
                switch block {
                case .text(let text):
                    .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ])
                case .image(let base64, let mediaType):
                    .object([
                        "type": .string("image"),
                        "data": .string(base64),
                        "mimeType": .string(mediaType),
                    ])
                }
            }
            var fields: [String: MCP20260728.WireValue] = [
                "content": .array(content),
            ]
            if result.isError { fields["isError"] = .bool(true) }
            return .result(fields)
        case "resources/list":
            guard request.params["cursor"] == nil else {
                return .error(
                    status: 400,
                    code: -32602,
                    message: "Invalid params: this resource list has no additional page."
                )
            }
            return .result([
                "resources": .array(Self.modernResources),
                "ttlMs": .int(0),
                "cacheScope": .string("private"),
            ])
        case "resources/read":
            guard let uri = request.params["uri"]?.stringValue else {
                return .error(
                    status: 400,
                    code: -32602,
                    message: "Invalid params: resource URI is required."
                )
            }
            guard let text = Self.modernResourceText(uri: uri) else {
                return .error(
                    status: 404,
                    code: -32002,
                    message: "Resource not found: \(uri)"
                )
            }
            return .result([
                "contents": .array([.object([
                    "uri": .string(uri),
                    "mimeType": .string("application/json"),
                    "text": .string(text),
                ])]),
                "ttlMs": .int(0),
                "cacheScope": .string("private"),
            ])
        default:
            return .error(
                status: 404,
                code: -32601,
                message: "Method not found: \(request.method)"
            )
        }
    }

    private static let modernResources: [MCP20260728.WireValue] = [
        .object([
            "name": .string("Image Models"),
            "uri": .string("nexgen://models/image"),
            "description": .string(
                "Available AI image generation models and their capabilities"
            ),
            "mimeType": .string("application/json"),
        ]),
        .object([
            "name": .string("Video Models"),
            "uri": .string("nexgen://models/video"),
            "description": .string(
                "Available AI video generation models and their capabilities"
            ),
            "mimeType": .string("application/json"),
        ]),
    ]

    private static func modernResourceText(uri: String) -> String? {
        switch uri {
        case "nexgen://models/video":
            ToolExecutor.jsonString(
                VideoModelConfig.allModels.map { ToolExecutor.videoModelInfo($0) }
            ) ?? "[]"
        case "nexgen://models/image":
            ToolExecutor.jsonString(
                ImageModelConfig.allModels.map { ToolExecutor.imageModelInfo($0) }
            ) ?? "[]"
        default:
            nil
        }
    }

    @MainActor
    private static func readResource(uri: String) -> ReadResource.Result {
        switch uri {
        case "nexgen://models/video":
            let json = ToolExecutor.jsonString(VideoModelConfig.allModels.map { ToolExecutor.videoModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        case "nexgen://models/image":
            let json = ToolExecutor.jsonString(ImageModelConfig.allModels.map { ToolExecutor.imageModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        default:
            return .init(contents: [.text("Unknown resource: \(uri)", uri: uri)])
        }
    }

}
