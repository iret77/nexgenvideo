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
            makeServer: { [weak self] in
                let server = Server(
                    name: "nexgen",
                    version: "1.0.0",
                    instructions: AgentInstructions.serverInstructions,
                    capabilities: .init(
                        resources: .init(subscribe: false, listChanged: false),
                        tools: .init(listChanged: false)
                    )
                )
                await self?.registerTools(on: server)
                await self?.registerResources(on: server)
                return server
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

    private func registerTools(on server: Server) async {
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
            return await self.dispatchCall(params)
        }
    }

    // Convert args inside the actor so the non-Sendable dict never crosses the hop.
    private func dispatchCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        let args = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
        let result = await toolExecutor.execute(name: params.name, args: args)
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
