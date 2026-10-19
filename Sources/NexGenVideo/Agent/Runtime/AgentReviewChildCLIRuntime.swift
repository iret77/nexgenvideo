import Foundation

@MainActor
final class AgentReviewChildCLIRuntime: AgentReviewChildRuntimeDriving {
    private let preflight: AgentReviewChildRuntime.CLIPreflight
    private var process: ClaudeCodeProcess?
    private var transport: AgentReviewChildMCPTransport?
    private var reader: Task<Void, Never>?
    private var relay: AgentRuntimeEventRelay?
    private var responses: [String: AgentModelResponseEvidence] = [:]
    private let rendezvous = AgentModelEvidenceRendezvous()
    private var stopping: Task<Void, Never>?
    private var workingDirectory: URL?
    private var policyTask: Task<Void, Never>?
    private var contextTokens = 0
    private var contextBytes = 0

    init(preflight: @escaping AgentReviewChildRuntime.CLIPreflight) { self.preflight = preflight }

    func start(request: AgentReviewChildRequest, generationID: UUID, sessionID: UUID, turnID: UUID,
               revalidate: @escaping @MainActor @Sendable () throws -> Void,
               execute: @escaping AgentRuntimeToolExecutor) async throws -> AsyncStream<AgentRuntimeEventEnvelope> {
        guard process == nil, stopping == nil else { throw AgentRuntimeContractError.turnAlreadyRunning }
        try revalidate()
        contextTokens = try AgentReviewChildContextBudget.initialCLI(request)
        contextBytes = contextTokens
        guard contextTokens <= request.bounds.maximumEstimatedInputTokens, contextBytes <= request.bounds.maximumRequestBytes else {
            throw ToolError("The complete review instructions exceed the authorized context estimate.")
        }
        guard let executable = ClaudeCodeLocator.locateOnly() else { throw ToolError("Claude Code is not installed.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        workingDirectory = directory
        try await preflight(executable, directory)
        try revalidate()
        let relay = AgentRuntimeEventRelay(sessionID: sessionID, turnID: turnID)
        self.relay = relay
        rendezvous.begin(sessionID: sessionID, turnID: turnID)
        let transport = AgentReviewChildMCPTransport(sessionID: sessionID, generationID: generationID,
            schemas: request.hostContext.toolSchemas) { [weak self] id, name, json in
                guard let self, self.stopping == nil, let relay = self.relay, relay.terminal == nil else {
                    return .error("The review context has ended.")
                }
                do { try revalidate(); try Self.requirePolicy() }
                catch { return .error(error.localizedDescription) }
                let result = await execute(id, name, json)
                guard self.stopping == nil, relay.terminal == nil else { return .error("The review context has ended.") }
                do {
                    let bytes = try JSONEncoder().encode(result.toMCPResult())
                    let estimate = try await Task.detached(priority: .userInitiated) {
                        try AgentReviewChildContextBudget.estimateRequest(bytes)
                    }.value
                    try revalidate()
                    try Self.requirePolicy()
                    self.contextTokens = try AgentReviewChildContextBudget.adding(self.contextTokens, estimate)
                    self.contextBytes = try AgentReviewChildContextBudget.adding(self.contextBytes, bytes.count)
                    guard self.contextTokens <= request.bounds.maximumEstimatedInputTokens,
                          self.contextBytes <= request.bounds.maximumRequestBytes else {
                        throw ToolError("The complete review history exceeds its authorized context estimate.")
                    }
                } catch {
                    self.relay?.yield(.error(.init(kind: .protocolViolation, message: error.localizedDescription)))
                    self.relay?.finish(.failed)
                    self.process?.terminate()
                    return .error(error.localizedDescription)
                }
                if name == AgentReviewChildRequest.writeTool, !result.isError, result.turnDisposition == .suspendTurn {
                    self.relay?.finish(.completed(.toolUse))
                }
                return result
            }
        self.transport = transport
        let port = try await transport.start()
        try await preflight(executable, directory)
        try revalidate()
        let process = ClaudeCodeProcess()
        let stream = try process.start(executableURL: executable,
            arguments: Self.arguments(request: request, port: port, sessionID: sessionID, generationID: generationID),
            workingDirectory: directory, environment: Self.environment(request: request))
        self.process = process
        guard process.send(line: ClaudeCodeLaunch.userMessageLine(request.bootstrap)) else {
            throw ToolError("The isolated review context could not receive its instructions.")
        }
        reader = Task { [weak self] in
            await self?.consume(stream, request: request, sessionID: sessionID,
                turnID: turnID, revalidate: revalidate, relay: relay)
        }
        policyTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(250))
                    try Self.requirePolicy()
                }
            } catch is CancellationError {
            } catch {
                self?.relay?.yield(.error(.init(kind: .protocolViolation, message: error.localizedDescription)))
                self?.relay?.finish(.failed)
                self?.process?.terminate()
            }
        }
        return relay.stream
    }

    func requireCurrent() throws {
        guard stopping == nil else { throw CancellationError() }
        if relay?.terminal == .cancelled { throw CancellationError() }
        if relay?.terminal == .failed { throw ToolError("The review context failed before its result was committed.") }
        try Self.requirePolicy()
    }

    func evidence(toolUseID: String, sessionID: UUID, turnID: UUID) async -> AgentModelResponseEvidence? {
        guard stopping == nil else { return nil }
        return await rendezvous.wait(for: .init(sessionID: sessionID, turnID: turnID, toolUseID: toolUseID))
    }

    func shutdown() async {
        if let stopping { await stopping.value; return }
        rendezvous.invalidate()
        relay?.finish(.cancelled)
        let process = process, reader = reader, transport = transport, policyTask = policyTask
        let task = Task { @MainActor in
            policyTask?.cancel()
            await policyTask?.value
            await process?.shutdownAndWait()
            reader?.cancel()
            await reader?.value
            await transport?.stop()
        }
        stopping = task
        await task.value
        self.process = nil; self.reader = nil; self.transport = nil; self.policyTask = nil
        if let workingDirectory {
            try? FileManager.default.trashItem(at: workingDirectory, resultingItemURL: nil)
        }
        workingDirectory = nil
    }

    private func consume(_ stream: AsyncThrowingStream<String, Error>, request: AgentReviewChildRequest,
                         sessionID: UUID, turnID: UUID,
                         revalidate: @escaping @MainActor @Sendable () throws -> Void,
                         relay: AgentRuntimeEventRelay) async {
        var authentication = ClaudeCodeAuthenticationEventBuffer()
        var models: [String: String] = [:]
        do {
            for try await line in stream {
                try Task.checkCancellation()
                try Self.requirePolicy()
                try revalidate()
                guard stopping == nil, line.utf8.count <= request.bounds.maximumRequestBytes else {
                    throw ToolError("The isolated review response exceeded its context bound.")
                }
                let wire = Data(line.utf8)
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if let object = try JSONSerialization.jsonObject(with: wire) as? [String: Any],
                   object["type"] as? String == "assistant", let message = object["message"] as? [String: Any] {
                    let bytes = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
                    let estimate = try await Task.detached(priority: .userInitiated) {
                        try AgentReviewChildContextBudget.estimateRequest(bytes)
                    }.value
                    try revalidate()
                    contextTokens = try AgentReviewChildContextBudget.adding(contextTokens, estimate)
                    contextBytes = try AgentReviewChildContextBudget.adding(contextBytes, bytes.count)
                    guard contextTokens <= request.bounds.maximumEstimatedInputTokens,
                          contextBytes <= request.bounds.maximumRequestBytes else {
                        throw ToolError("The review assistant history exceeds its authorized context estimate.")
                    }
                }
                let events: [ClaudeStreamEvent]
                switch authentication.receive(ClaudeStreamDecoder.decode(line: line)) {
                case .waiting: continue
                case .authenticationRequired: throw ToolError("Claude Code authentication is required.")
                case .events(let value): events = value
                }
                for event in events {
                    switch event {
                    case .responseMetadata(let messageID, let modelID):
                        guard models[messageID].map({ $0 == modelID }) ?? true,
                              models.values.allSatisfy({ $0 == modelID }),
                              request.modelID.map({ $0 == modelID }) ?? true,
                              models[messageID] != nil || models.count < request.bounds.maximumRequests else {
                            throw ToolError("The isolated review model or request bound changed.")
                        }
                        models[messageID] = modelID
                    case .assistantBlock(let messageID, .toolUse(let id, let name, let json)):
                        guard let modelID = models[messageID] else { throw ToolError("The review response did not identify its model.") }
                        let evidence = try AgentModelResponseEvidence(sessionID: sessionID, turnID: turnID,
                            messageID: messageID, modelID: modelID, toolUseID: id, toolName: name, inputJSON: json)
                        if let prior = responses[id], prior != evidence { throw ToolError("The review response changed a tool call.") }
                        responses[id] = evidence
                        rendezvous.receive(evidence)
                    case .turnFinished(let error, let message, let cost):
                        if let cost { relay.yield(.usage(.init(costUSD: cost))) }
                        if error { throw ToolError(message ?? "Claude Code review failed.") }
                        relay.finish(.completed(.endTurn))
                    case .sessionStarted(let id): relay.yield(.providerSessionStarted(id))
                    default: break
                    }
                }
            }
            try Task.checkCancellation()
            if relay.terminal == nil { throw ToolError("The review process ended before recording its page.") }
        } catch {
            relay.yield(.error(.init(kind: .protocolViolation, message: error.localizedDescription)))
            relay.finish(error is CancellationError ? .cancelled : .failed)
        }
    }

    static func arguments(request: AgentReviewChildRequest, port: Int, sessionID: UUID, generationID: UUID) -> [String] {
        var result = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--safe-mode", "--no-session-persistence", "--setting-sources", "",
            "--settings", "{\"disableAllHooks\":true}", "--tools", "", "--strict-mcp-config",
            "--mcp-config", ClaudeCodeLaunch.mcpConfigJSON(port: port, appSessionId: sessionID, runtimeGenerationId: generationID),
            "--allowedTools", "mcp__nexgen__get_render_review_page mcp__nexgen__write_render_review_page",
            "--max-turns", String(min(request.bounds.maximumTurns, request.bounds.maximumRequests)),
            "--system-prompt", request.hostContext.systemInstructions]
        if let modelID = request.modelID { result += ["--model", modelID] }
        return result
    }

    static func environment(request: AgentReviewChildRequest) -> [String: String] {
        var result = environmentForIsolation()
        result["MAX_MCP_OUTPUT_TOKENS"] = String(request.bounds.maximumMCPOutputTokens)
        result["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(request.bounds.maximumOutputTokens)
        return result
    }

    static func environmentForIsolation() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var result = inherited.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "PATH",
            "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN"].contains($0.key) }
        result["PATH"] = ClaudeCodeLocator.runtimePath(existing: result["PATH"], home: NSHomeDirectory())
        result["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        result["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] = "1"
        result["CLAUDE_CODE_RETRY_WATCHDOG"] = "0"
        result["CLAUDE_CODE_MAX_RETRIES"] = "0"
        return result
    }

    private static func requirePolicy() throws {
        let environment = environmentForIsolation()
        let config = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        try AgentReviewChildCLIIsolation.requirePolicyAbsent(configDirectory: config)
    }
}
