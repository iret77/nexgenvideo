import Foundation

@MainActor
final class AgentReviewChildRuntime: AgentReviewChildRuntimeDriving {
    typealias CLIPreflight = @MainActor @Sendable (_ executable: URL, _ workingDirectory: URL) async throws -> Void

    private let apiClient: AnthropicClient?
    private let cliPreflight: CLIPreflight
    private var adapter: AnthropicRuntimeAdapter?
    private var streamControl: AgentReviewChildStreamControl?
    private var cli: AgentReviewChildCLIRuntime?
    private var sessionID: UUID?
    private var requestCount = 0
    private var stopping: Task<Void, Never>?
    private var revalidate: (@MainActor @Sendable () throws -> Void)?

    init(apiClient: AnthropicClient?, cliPreflight: @escaping CLIPreflight) {
        self.apiClient = apiClient; self.cliPreflight = cliPreflight
    }

    func start(request: AgentReviewChildRequest, generationID: UUID, sessionID: UUID, turnID: UUID,
               revalidate: @escaping @MainActor @Sendable () throws -> Void,
               execute: @escaping AgentRuntimeToolExecutor) async throws -> AsyncStream<AgentRuntimeEventEnvelope> {
        guard self.sessionID == nil, stopping == nil else { throw AgentRuntimeContractError.turnAlreadyRunning }
        try request.validate()
        self.revalidate = revalidate
        try revalidate()
        self.sessionID = sessionID
        switch request.backend {
        case .anthropicAPI:
            guard var client = apiClient, client.model.id == request.modelID else {
                throw ToolError("The review model differs from the selected Anthropic model.")
            }
            let control = AgentReviewChildStreamControl { [weak self] bytes in
                guard let self else { throw CancellationError() }
                try await self.requireRequest(bytes, request: request)
            }
            streamControl = control
            client.maxTokens = request.bounds.maximumOutputTokens
            client.reviewStreamControl = control
            let adapter = AnthropicRuntimeAdapter(client: client)
            self.adapter = adapter
            try adapter.start(.init(sessionID: sessionID, runtimeGenerationID: generationID,
                providerSessionID: nil, priorMessages: [], hostContext: request.hostContext,
                workingDirectory: nil, pluginDirectories: [], providerExtensions: [], mcpPort: 0, executeTool: execute))
            let input = AgentRuntimeMessage(role: .user, content: [.text(request.bootstrap)])
            return try adapter.send(.init(sessionID: sessionID, turnID: turnID,
                messages: [input], currentMessage: input,
                toolSearchPinnedTools: [AgentReviewChildRequest.readTool, AgentReviewChildRequest.writeTool]))
        case .claudeCode:
            let child = AgentReviewChildCLIRuntime(preflight: cliPreflight)
            cli = child
            return try await child.start(request: request, generationID: generationID,
                sessionID: sessionID, turnID: turnID, revalidate: revalidate, execute: execute)
        case .codexAppServer:
            throw ToolError("The selected backend does not support isolated image review.")
        }
    }

    func evidence(toolUseID: String, sessionID: UUID, turnID: UUID) async -> AgentModelResponseEvidence? {
        if let cli { return await cli.evidence(toolUseID: toolUseID, sessionID: sessionID, turnID: turnID) }
        return await adapter?.awaitModelResponseEvidence(toolUseID: toolUseID, sessionID: sessionID, turnID: turnID)
    }

    func requireCurrent() throws {
        guard stopping == nil else { throw CancellationError() }
        try cli?.requireCurrent()
    }

    func shutdown() async {
        if let stopping { await stopping.value; return }
        let adapter = adapter, control = streamControl, cli = cli, sessionID = sessionID
        let task = Task { @MainActor in
            if let sessionID { await adapter?.endAndWait(sessionID: sessionID) }
            await control?.shutdown()
            await cli?.shutdown()
        }
        stopping = task
        await task.value
        self.adapter = nil; streamControl = nil; self.cli = nil
    }

    private func requireRequest(_ bytes: Data, request: AgentReviewChildRequest) async throws {
        try Task.checkCancellation()
        try revalidate?()
        let estimate = try await Task.detached(priority: .userInitiated) {
            try AgentReviewChildContextBudget.estimateRequest(bytes)
        }.value
        try Task.checkCancellation()
        try revalidate?()
        guard stopping == nil, sessionID != nil,
              requestCount < request.bounds.maximumRequests,
              bytes.count <= request.bounds.maximumRequestBytes,
              estimate <= request.bounds.maximumEstimatedInputTokens,
              let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              body["model"] as? String == request.modelID,
              (body["max_tokens"] as? Int) == request.bounds.maximumOutputTokens,
              let tools = body["tools"] as? [[String: Any]],
              Set(tools.compactMap { $0["name"] as? String }) == [AgentReviewChildRequest.readTool, AgentReviewChildRequest.writeTool],
              tools.count == 2 else {
            throw ToolError("The review request exceeds its authorized context or request bound.")
        }
        requestCount += 1
    }
}
