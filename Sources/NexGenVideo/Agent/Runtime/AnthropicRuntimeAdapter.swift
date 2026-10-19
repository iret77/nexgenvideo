import Foundation

@MainActor
final class AnthropicRuntimeAdapter: AgentRuntimeAdapter {
    static let maximumPauseContinuations = 5

    private let client: any AgentClient
    private var session: AgentRuntimeSessionRequest?
    private var activeRelay: AgentRuntimeEventRelay?
    private var activeTask: Task<Void, Never>?
    private var activeTurnID: UUID?
    private var responseByToolID: [String: AgentModelResponseEvidence] = [:]

    func modelResponseEvidence(toolUseID: String) -> AgentModelResponseEvidence? { responseByToolID[toolUseID] }

    private(set) var descriptor: AgentRuntimeDescriptor
    private(set) var state: AgentRuntimeState = .idle

    init(client: any AgentClient) {
        self.client = client
        descriptor = AgentBackend.anthropicAPI.runtimeDescriptor(toolNames: [])
    }

    func start(_ request: AgentRuntimeSessionRequest) throws { try configure(request) }
    func resume(_ request: AgentRuntimeSessionRequest) throws { try configure(request) }

    func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
        guard let session else { throw AgentRuntimeContractError.sessionNotStarted }
        guard session.sessionID == request.sessionID else { throw AgentRuntimeContractError.sessionMismatch }
        guard activeRelay == nil else { throw AgentRuntimeContractError.turnAlreadyRunning }
        guard request.currentMessage.role == .user,
              request.messages.last == request.currentMessage else {
            throw AgentRuntimeContractError.invalidCurrentMessage
        }

        let relay = AgentRuntimeEventRelay(sessionID: request.sessionID, turnID: request.turnID)
        activeRelay = relay
        activeTurnID = request.turnID
        responseByToolID = [:]
        state = .running(sessionID: request.sessionID, turnID: request.turnID)
        activeTask = Task { [weak self] in
            await self?.consume(request: request, session: session, relay: relay)
        }
        return relay.stream
    }

    func cancel(sessionID: UUID) {
        guard session?.sessionID == sessionID else { return }
        responseByToolID = [:]
        if let relay = activeRelay, let activeTurnID {
            state = .cancelling(sessionID: sessionID, turnID: activeTurnID)
            relay.finish(.cancelled)
        }
        activeTask?.cancel()
        activeTask = nil
        activeRelay = nil
        activeTurnID = nil
        state = .ready(sessionID: sessionID)
    }

    func end(sessionID: UUID) {
        guard session?.sessionID == sessionID else { return }
        cancel(sessionID: sessionID)
        session = nil
        state = .ended(sessionID: sessionID)
    }

    func endAndWait(sessionID: UUID) async {
        guard session?.sessionID == sessionID else { return }
        let task = activeTask
        end(sessionID: sessionID)
        await task?.value
    }

    private func configure(_ request: AgentRuntimeSessionRequest) throws {
        if let active = activeRelay, active.terminal == nil {
            throw AgentRuntimeContractError.turnAlreadyRunning
        }
        session = request
        responseByToolID = [:]
        descriptor = AgentBackend.anthropicAPI.runtimeDescriptor(
            toolNames: Set(request.hostContext.toolSchemas.map(\.name))
        )
        state = .ready(sessionID: request.sessionID)
    }

    private func consume(
        request: AgentRuntimeTurnRequest,
        session: AgentRuntimeSessionRequest,
        relay: AgentRuntimeEventRelay
    ) async {
        var messages = request.messages
        let pinned = request.toolSearchPinnedTools
        let tools = session.hostContext.toolSchemas.map {
            AnthropicToolSchema(
                name: $0.name, description: $0.description, inputSchema: $0.inputSchema,
                loadsUpFront: pinned.contains($0.name)
            )
        }
        let toolSearch = client.supportsToolSearch
        let searchActive = AnthropicToolSearch.loadedToolNames(
            tools.map(\.name), enabled: toolSearch, pinned: pinned
        ) != nil
        var pauseContinuations = 0
        do {
            run: while !Task.isCancelled {
                var assistantContent: [AgentRuntimeContent] = []
                var toolCalls: [(id: String, name: String, inputJSON: String)] = []
                var stopReason: AgentRuntimeStopReason?
                var responseMetadata: (messageID: String, modelID: String)?
                let wire = AnthropicReplay.wireMessages(messages, keepingServerTools: searchActive)
                relay.yield(.providerRequest(prefixDigest: AnthropicPrefixDigest.of(
                    system: session.hostContext.systemInstructions,
                    tools: session.hostContext.toolSchemas,
                    toolSearch: toolSearch,
                    pinnedTools: pinned,
                    messages: wire
                )))
                let stream = client.stream(
                    system: session.hostContext.systemInstructions,
                    tools: tools,
                    messages: wire.map(Self.anthropicMessage)
                )
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .responseMetadata(let messageID, let modelID):
                        responseMetadata = (messageID, modelID)
                    case .thinkingComplete(let block):
                        assistantContent.append(.thinking(block))
                        relay.yield(.thinking(messageID: nil, block: block))
                    case .serverToolComplete(let block):
                        assistantContent.append(.serverTool(block))
                        relay.yield(.serverTool(messageID: nil, block: block))
                    case .textDelta(let value):
                        if case .text(let existing)? = assistantContent.last {
                            assistantContent[assistantContent.count - 1] = .text(existing + value)
                        } else {
                            assistantContent.append(.text(value))
                        }
                        relay.yield(.text(messageID: nil, value: value, isDelta: true))
                    case .toolUseComplete(let id, let name, let inputJSON):
                        if let metadata = responseMetadata {
                            responseByToolID[id] = try? AgentModelResponseEvidence(sessionID: request.sessionID,
                                turnID: request.turnID, messageID: metadata.messageID, modelID: metadata.modelID,
                                toolUseID: id, toolName: name, inputJSON: inputJSON)
                        }
                        toolCalls.append((id, name, inputJSON))
                        assistantContent.append(.toolUse(id: id, name: name, inputJSON: inputJSON))
                        relay.yield(.toolCall(messageID: nil, id: id, name: name, inputJSON: inputJSON))
                    case .usage(let usage):
                        relay.yield(.usage(usage))
                    case .messageStop(let reason):
                        stopReason = Self.stopReason(reason)
                    }
                }
                if Task.isCancelled || relay.terminal != nil {
                    break run
                }
                guard let stopReason else {
                    fail(
                        .init(
                            kind: .protocolViolation,
                            message: "Anthropic ended the stream without a terminal stop reason."
                        ),
                        sessionID: request.sessionID,
                        relay: relay
                    )
                    break run
                }
                // The server paused its own tool loop; resending the turn as-is lets it resume.
                if stopReason == .pauseTurn, toolCalls.isEmpty, !assistantContent.isEmpty,
                   pauseContinuations < Self.maximumPauseContinuations {
                    pauseContinuations += 1
                    messages.append(.init(role: .assistant, content: assistantContent))
                    continue run
                }
                guard stopReason == .toolUse else {
                    relay.finish(.completed(stopReason))
                    setStateIfActive(.ready(sessionID: request.sessionID), relay: relay)
                    break run
                }
                guard !toolCalls.isEmpty else {
                    fail(
                        .init(
                            kind: .protocolViolation,
                            message: "Anthropic stopped for tool use without a complete tool call."
                        ),
                        sessionID: request.sessionID,
                        relay: relay
                    )
                    break run
                }

                messages.append(.init(role: .assistant, content: assistantContent))
                var resultContent: [AgentRuntimeContent] = []
                var suspended = false
                for call in toolCalls {
                    let result: ToolResult
                    if suspended {
                        result = .error(
                            "Not executed: an earlier tool opened a host decision and suspended this turn."
                        )
                    } else if Task.isCancelled {
                        result = .error("Cancelled")
                    } else {
                        result = await session.executeTool(call.id, call.name, call.inputJSON)
                    }
                    resultContent.append(.toolResult(
                        id: call.id,
                        content: result.content,
                        isError: result.isError
                    ))
                    relay.yield(.toolResult(
                        id: call.id,
                        content: result.content,
                        isError: result.isError
                    ))
                    suspended = suspended || result.turnDisposition == .suspendTurn
                }
                messages.append(.init(role: .user, content: resultContent))
                pauseContinuations = 0
                if suspended {
                    relay.finish(.completed(.toolUse))
                    setStateIfActive(.ready(sessionID: request.sessionID), relay: relay)
                    break run
                }
            }
        } catch is CancellationError {
            relay.finish(.cancelled)
            setStateIfActive(.ready(sessionID: request.sessionID), relay: relay)
        } catch {
            fail(
                .init(kind: Self.failureKind(error), message: error.localizedDescription),
                sessionID: request.sessionID,
                relay: relay
            )
        }
        if activeRelay === relay {
            activeRelay = nil
            activeTask = nil
            activeTurnID = nil
        }
    }

    private func fail(
        _ failure: AgentRuntimeFailure,
        sessionID: UUID,
        relay: AgentRuntimeEventRelay
    ) {
        relay.yield(.error(failure))
        relay.finish(.failed)
        setStateIfActive(.failed(sessionID: sessionID, message: failure.message), relay: relay)
    }

    private func setStateIfActive(_ state: AgentRuntimeState, relay: AgentRuntimeEventRelay) {
        guard activeRelay === relay else { return }
        self.state = state
    }

    private static func anthropicMessage(_ message: AgentRuntimeMessage) -> AnthropicMessage {
        AnthropicMessage(
            role: message.role == .user ? .user : .assistant,
            content: message.content.map(anthropicContent)
        )
    }

    static func anthropicContent(_ content: AgentRuntimeContent) -> [String: Any] {
        switch content {
        case .thinking(let block):
            block.json
        case .serverTool(let block):
            block.json
        case .text(let value):
            ["type": "text", "text": value]
        case .image(let image):
            imageBlock(image)
        case .toolUse(let id, let name, let inputJSON):
            [
                "type": "tool_use",
                "id": id,
                "name": name,
                "input": jsonObject(inputJSON),
            ]
        case .toolResult(let id, let content, let isError):
            [
                "type": "tool_result",
                "tool_use_id": id,
                "content": content.map { block -> [String: Any] in
                    switch block {
                    case .text(let value): ["type": "text", "text": value]
                    case .image(let base64, let mediaType):
                        imageBlock(.init(mediaType: mediaType, base64: base64))
                    }
                },
                "is_error": isError,
            ]
        }
    }

    private static func imageBlock(_ image: AgentRuntimeImage) -> [String: Any] {
        [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": image.mediaType,
                "data": image.base64,
            ],
        ]
    }

    private static func jsonObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func stopReason(_ reason: AnthropicStopReason) -> AgentRuntimeStopReason {
        switch reason {
        case .endTurn: .endTurn
        case .toolUse: .toolUse
        case .maxTokens: .maxTokens
        case .stopSequence: .stopSequence
        case .pauseTurn: .pauseTurn
        case .refusal: .refusal
        case .other: .other
        }
    }

    private static func failureKind(_ error: Error) -> AgentRuntimeFailureKind {
        guard let error = error as? AnthropicClientError else { return .transport }
        switch error {
        case .missingAPIKey:
            return .authenticationRequired
        case .httpError(let status, _) where status == 401 || status == 403:
            return .authenticationRequired
        case .httpError, .streamError:
            return .transport
        }
    }
}
