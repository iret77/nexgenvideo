import Foundation

@MainActor
protocol ClaudeCodeRuntimeDriving: AnyObject {
    @discardableResult
    func send(
        text: String,
        context: String?,
        imageBlocks: [[String: Any]],
        hidden: Bool,
        presentation: AgentUserPresentation?
    ) -> Bool
    func stop()
    func waitUntilStopped() async -> Bool
}

extension ClaudeCodeRuntime: ClaudeCodeRuntimeDriving {}

extension ClaudeCodeRuntimeDriving {
    func waitUntilStopped() async -> Bool { false }
}

@MainActor
final class ClaudeCodeRuntimeAdapter: AgentRuntimeAdapter {
    struct Callbacks {
        let events: @MainActor ([ClaudeStreamEvent]) -> Void
        let failure: @MainActor (AgentRuntimeFailure) -> Void
        let resumeFailed: @MainActor () -> Void
        let streamingChanged: @MainActor (Bool) -> Void
    }

    typealias RuntimeFactory = @MainActor (
        _ request: AgentRuntimeSessionRequest,
        _ callbacks: Callbacks
    ) -> any ClaudeCodeRuntimeDriving

    private let runtimeFactory: RuntimeFactory
    private var session: AgentRuntimeSessionRequest?
    private var runtime: (any ClaudeCodeRuntimeDriving)?
    private var activeRelay: AgentRuntimeEventRelay?
    private var activeTurnID: UUID?
    private var modelByMessageID: [String: String] = [:]
    private var responseByToolID: [String: AgentModelResponseEvidence] = [:]

    func modelResponseEvidence(toolUseID: String) -> AgentModelResponseEvidence? { responseByToolID[toolUseID] }
    var pendingModelEvidenceCount: Int { evidenceRendezvous.pendingCount }

    func awaitModelResponseEvidence(toolUseID: String, sessionID: UUID, turnID: UUID) async -> AgentModelResponseEvidence? {
        guard state == .running(sessionID: sessionID, turnID: turnID) else { return nil }
        let evidence = await evidenceRendezvous.wait(for: .init(sessionID: sessionID, turnID: turnID, toolUseID: toolUseID))
        guard !Task.isCancelled, state == .running(sessionID: sessionID, turnID: turnID) else { return nil }
        return evidence
    }

    private(set) var descriptor: AgentRuntimeDescriptor
    private(set) var state: AgentRuntimeState = .idle

    init(runtimeFactory: RuntimeFactory? = nil) {
        self.runtimeFactory = runtimeFactory ?? Self.liveRuntime
        descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: [])
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
        modelByMessageID = [:]
        responseByToolID = [:]
        state = .running(sessionID: request.sessionID, turnID: request.turnID)
        evidenceRendezvous.begin(sessionID: request.sessionID, turnID: request.turnID)
        let runtime = runtime ?? makeRuntime(session)
        self.runtime = runtime

        let input = Self.input(request.currentMessage)
        if !runtime.send(
            text: input.text,
            context: nil,
            imageBlocks: input.images,
            hidden: true,
            presentation: nil
        ), relay.terminal == nil {
            fail(
                .init(
                    kind: .backendUnavailable,
                    message: "Claude Code could not start the turn."
                ),
                relay: relay
            )
        }
        return relay.stream
    }

    func cancel(sessionID: UUID) {
        guard session?.sessionID == sessionID else { return }
        runtimeCallbackID = UUID()
        evidenceRendezvous.invalidate()
        responseByToolID = [:]
        modelByMessageID = [:]
        if let relay = activeRelay, let activeTurnID {
            state = .cancelling(sessionID: sessionID, turnID: activeTurnID)
            relay.finish(.cancelled)
        }
        stopRuntime()
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

    func endAndWait(sessionID: UUID) async -> Bool {
        guard session?.sessionID == sessionID else { return false }
        end(sessionID: sessionID)
        return await runtimeShutdown?.value ?? true
    }

    private func stopRuntime() {
        guard let stopping = runtime else { return }
        stopping.stop()
        runtime = nil
        let previous = runtimeShutdown
        runtimeShutdown = Task { @MainActor in
            let priorStopped = await previous?.value ?? true
            let stopped = await stopping.waitUntilStopped()
            return priorStopped && stopped
        }
    }

    private func configure(_ request: AgentRuntimeSessionRequest) throws {
        if let activeRelay, activeRelay.terminal == nil {
            throw AgentRuntimeContractError.turnAlreadyRunning
        }
        runtimeCallbackID = UUID()
        stopRuntime()
        responseByToolID = [:]
        modelByMessageID = [:]
        evidenceRendezvous.invalidate()
        session = request
        descriptor = AgentBackend.claudeCode.runtimeDescriptor(
            toolNames: Set(request.hostContext.toolSchemas.map(\.name)),
            providerExtensions: request.providerExtensions
        )
        state = .ready(sessionID: request.sessionID)
    }

    private func makeRuntime(_ request: AgentRuntimeSessionRequest) -> any ClaudeCodeRuntimeDriving {
        let callbackID = runtimeCallbackID
        return runtimeFactory(
            request,
            .init(
                events: { [weak self] events in
                    guard self?.runtimeCallbackID == callbackID else { return }
                    self?.receive(events)
                },
                failure: { [weak self] failure in
                    guard self?.runtimeCallbackID == callbackID else { return }
                    self?.receive(failure)
                },
                resumeFailed: { [weak self] in
                    guard self?.runtimeCallbackID == callbackID else { return }
                    self?.activeRelay?.yield(.providerSessionInvalidated)
                },
                streamingChanged: { [weak self] streaming in
                    guard self?.runtimeCallbackID == callbackID else { return }
                    self?.streamingChanged(streaming)
                }
            )
        )
    }

    private func receive(_ events: [ClaudeStreamEvent]) {
        guard let relay = activeRelay, relay.terminal == nil else { return }
        for event in events where relay.terminal == nil {
            switch event {
            case .responseMetadata(let messageID, let modelID):
                modelByMessageID[messageID] = modelID
            case .sessionStarted(let sessionID):
                relay.yield(.providerSessionStarted(sessionID))
            case .assistantBlock(let messageID, let block):
                switch block {
                case .text(let value):
                    relay.yield(.text(messageID: messageID, value: value, isDelta: false))
                case .toolUse(let id, let name, let inputJSON):
                    if let session, let turn = activeTurnID, let modelID = modelByMessageID[messageID] {
                        responseByToolID[id] = try? AgentModelResponseEvidence(sessionID: session.sessionID,
                            turnID: turn, messageID: messageID, modelID: modelID, toolUseID: id, toolName: name, inputJSON: inputJSON)
                        if let evidence = responseByToolID[id] { evidenceRendezvous.receive(evidence) }
                    }
                    relay.yield(.toolCall(
                        messageID: messageID,
                        id: id,
                        name: name,
                        inputJSON: inputJSON
                    ))
                }
            case .toolResult(let id, let content, let isError):
                relay.yield(.toolResult(id: id, content: content, isError: isError))
            case .turnFinished(let isError, let errorMessage, let costUSD):
                if let costUSD {
                    relay.yield(.usage(.init(costUSD: costUSD)))
                }
                if isError {
                    fail(
                        .init(
                            kind: .protocolViolation,
                            message: errorMessage ?? "Claude Code turn failed."
                        ),
                        relay: relay
                    )
                } else {
                    relay.finish(.completed(.endTurn))
                    finishActiveRelay(relay, failed: nil)
                }
            }
        }
    }

    private func receive(_ failure: AgentRuntimeFailure) {
        guard let relay = activeRelay, relay.terminal == nil else { return }
        fail(failure, relay: relay)
    }

    private func streamingChanged(_ isStreaming: Bool) {
        guard !isStreaming,
              let relay = activeRelay,
              relay.terminal == nil else { return }
        fail(
            .init(
                kind: .protocolViolation,
                message: "Claude Code ended without a terminal result."
            ),
            relay: relay
        )
    }

    private func fail(_ failure: AgentRuntimeFailure, relay: AgentRuntimeEventRelay) {
        relay.yield(.error(failure))
        relay.finish(.failed)
        finishActiveRelay(relay, failed: failure.message)
    }

    private func finishActiveRelay(_ relay: AgentRuntimeEventRelay, failed message: String?) {
        guard activeRelay === relay, let sessionID = session?.sessionID else { return }
        evidenceRendezvous.invalidate()
        activeRelay = nil
        activeTurnID = nil
        state = message.map { .failed(sessionID: sessionID, message: $0) }
            ?? .ready(sessionID: sessionID)
    }

    private static func input(_ message: AgentRuntimeMessage) -> (text: String, images: [[String: Any]]) {
        var text: [String] = []
        var images: [[String: Any]] = []
        for content in message.content {
            switch content {
            case .text(let value):
                text.append(value)
            case .image(let image):
                images.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": image.mediaType,
                        "data": image.base64,
                    ],
                ])
            case .thinking, .serverTool, .toolUse, .toolResult:
                break
            }
        }
        return (text.joined(separator: "\n\n"), images)
    }

    private static func liveRuntime(
        request: AgentRuntimeSessionRequest,
        callbacks: Callbacks
    ) -> any ClaudeCodeRuntimeDriving {
        ClaudeCodeRuntime(
            pluginDirectories: request.pluginDirectories,
            mcpPort: request.mcpPort,
            appSessionId: request.sessionID,
            runtimeGenerationID: request.runtimeGenerationID,
            resumeSessionId: request.providerSessionID,
            seedMessages: request.priorMessages,
            resolveWorkingDirectory: { request.workingDirectory },
            onResumeFailed: callbacks.resumeFailed,
            systemInstructions: request.hostContext.systemInstructions,
            onRuntimeEvents: callbacks.events,
            onRuntimeFailure: callbacks.failure,
            onUpdate: { _, isStreaming in callbacks.streamingChanged(isStreaming) }
        )
    }

    private let evidenceRendezvous = AgentModelEvidenceRendezvous()
    private var runtimeCallbackID = UUID()
    private var runtimeShutdown: Task<Bool, Never>?
}
