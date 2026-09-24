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
}

extension ClaudeCodeRuntime: ClaudeCodeRuntimeDriving {}

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
        state = .running(sessionID: request.sessionID, turnID: request.turnID)
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
        if let relay = activeRelay, let activeTurnID {
            state = .cancelling(sessionID: sessionID, turnID: activeTurnID)
            relay.finish(.cancelled)
        }
        runtime?.stop()
        runtime = nil
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

    private func configure(_ request: AgentRuntimeSessionRequest) throws {
        if let activeRelay, activeRelay.terminal == nil {
            throw AgentRuntimeContractError.turnAlreadyRunning
        }
        runtime?.stop()
        runtime = nil
        session = request
        descriptor = AgentBackend.claudeCode.runtimeDescriptor(
            toolNames: Set(request.hostContext.toolSchemas.map(\.name)),
            providerExtensions: request.providerExtensions
        )
        state = .ready(sessionID: request.sessionID)
    }

    private func makeRuntime(_ request: AgentRuntimeSessionRequest) -> any ClaudeCodeRuntimeDriving {
        runtimeFactory(
            request,
            .init(
                events: { [weak self] in self?.receive($0) },
                failure: { [weak self] in self?.receive($0) },
                resumeFailed: { [weak self] in
                    self?.activeRelay?.yield(.providerSessionInvalidated)
                },
                streamingChanged: { [weak self] in self?.streamingChanged($0) }
            )
        )
    }

    private func receive(_ events: [ClaudeStreamEvent]) {
        guard let relay = activeRelay, relay.terminal == nil else { return }
        for event in events where relay.terminal == nil {
            switch event {
            case .sessionStarted(let sessionID):
                relay.yield(.providerSessionStarted(sessionID))
            case .assistantBlock(let messageID, let block):
                switch block {
                case .text(let value):
                    relay.yield(.text(messageID: messageID, value: value, isDelta: false))
                case .toolUse(let id, let name, let inputJSON):
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
            case .toolUse, .toolResult:
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
}
