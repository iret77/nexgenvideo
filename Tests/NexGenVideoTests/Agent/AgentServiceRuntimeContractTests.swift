import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("AgentService runtime contract")
struct AgentServiceRuntimeContractTests {
    @Test("both backends receive the same canonical messages and host-owned context")
    func backendNeutralCanonicalTurnAndContext() async throws {
        let language = AgentInterfaceLanguage(identifier: "de-DE", displayName: "German")
        let schema = AgentRuntimeToolSchema(
            name: "host_tool",
            description: "Host-owned tool",
            inputSchema: [
                "type": "object",
                "properties": ["value": ["type": "string"]],
                "required": ["value"],
                "additionalProperties": false,
            ]
        )
        let context = AgentRuntimeHostContext(
            interfaceLanguage: language,
            baseInstructions: "BASE\n\(language.instruction)",
            pack: .init(
                id: "musicvideo",
                version: "3.2.1",
                projectSchema: "7",
                currentPhase: "story"
            ),
            phaseInstructions: "Write the canonical story artifact.",
            toolSchemas: [schema],
            authority: [
                .toolSchemas,
                .toolExecution,
                .structuredDialogs,
                .outputApprovals,
                .gateRefusals,
            ]
        )
        let history = [
            AgentMessage(role: .user, blocks: [.text("Earlier question")]),
            AgentMessage(role: .assistant, blocks: [
                .text("Earlier answer"),
                .toolUse(id: "old-tool", name: "host_tool", inputJSON: #"{"value":"old"}"#),
            ]),
            AgentMessage(role: .user, blocks: [
                .toolResult(
                    toolUseId: "old-tool",
                    content: [.text("Old result")],
                    isError: false
                ),
            ]),
        ]
        var fixtures: [(service: AgentService, adapter: FakeRuntimeAdapter)] = []

        for backend in AgentBackend.allCases {
            let adapter = FakeRuntimeAdapter(backend: backend, toolNames: [schema.name])
            let service = makeService(backend: backend, adapter: adapter, context: context)
            service.messages = history

            #expect(service.send(text: "Continue", mentions: []))
            await waitUntil { adapter.sendRequests.count == 1 }
            fixtures.append((service, adapter))
        }

        let claudeRequest = try #require(
            fixtures.first(where: { $0.service.backend == .claudeCode })?.adapter.sendRequests.first
        )
        let anthropicRequest = try #require(
            fixtures.first(where: { $0.service.backend == .anthropicAPI })?.adapter.sendRequests.first
        )
        #expect(claudeRequest.messages == anthropicRequest.messages)
        #expect(claudeRequest.currentMessage == anthropicRequest.currentMessage)
        #expect(claudeRequest.currentMessage == .init(
            role: .user,
            content: [.text("Continue")]
        ))

        for fixture in fixtures {
            let session = try #require(fixture.adapter.resumeRequests.first)
            #expect(fixture.adapter.startRequests.isEmpty)
            #expect(session.priorMessages.count == history.count + 1)
            #expect(session.hostContext.interfaceLanguage == language)
            #expect(session.hostContext.pack == context.pack)
            #expect(session.hostContext.phaseInstructions == context.phaseInstructions)
            #expect(session.hostContext.systemInstructions == context.systemInstructions)
            #expect(session.hostContext.authority == context.authority)
            #expect(session.hostContext.toolSchemas.map(\.name) == [schema.name])
            #expect(session.hostContext.toolSchemas.map(\.description) == [schema.description])
            #expect(
                canonicalJSON(session.hostContext.toolSchemas[0].inputSchema)
                    == canonicalJSON(schema.inputSchema)
            )

            let turn = try #require(fixture.adapter.sendRequests.first)
            fixture.adapter.emit(.terminal(.completed(.endTurn)), for: turn)
            fixture.adapter.finish(turn)
            await waitUntil { !fixture.service.isStreaming }
        }
    }

    @Test("hidden seeds stay out of the transcript while remaining model-visible")
    func hiddenSeedVisibility() async throws {
        let adapter = FakeRuntimeAdapter(backend: .anthropicAPI)
        let service = makeService(backend: .anthropicAPI, adapter: adapter)

        #expect(service.send(text: "Private kickoff", mentions: [], hidden: true))
        await waitUntil { adapter.sendRequests.count == 1 }

        let turn = try #require(adapter.sendRequests.first)
        #expect(turn.currentMessage == .init(
            role: .user,
            content: [.text("Private kickoff")]
        ))
        #expect(service.messages.first?.hidden == true)
        #expect(AgentTranscriptProjection.turns(
            messages: service.messages,
            isStreaming: service.isStreaming
        ).isEmpty)

        adapter.emit(
            .text(messageID: "answer", value: "Started.", isDelta: true),
            for: turn
        )
        adapter.emit(.terminal(.completed(.endTurn)), for: turn)
        adapter.finish(turn)
        await waitUntil { !service.isStreaming }

        let turns = AgentTranscriptProjection.turns(messages: service.messages, isStreaming: false)
        #expect(turns.count == 1)
        #expect(!turns.flatMap(\.items).contains(where: { item in
            if case .userIntent = item { return true }
            return false
        }))
    }

    @Test("foreign session, foreign turn, and post-terminal events cannot repaint the transcript")
    func staleRuntimeEventsAreFenced() async throws {
        let adapter = FakeRuntimeAdapter(backend: .claudeCode)
        let service = makeService(backend: .claudeCode, adapter: adapter)

        #expect(service.send(text: "Current turn", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let turn = try #require(adapter.sendRequests.first)

        adapter.emit(
            .text(messageID: nil, value: "foreign session", isDelta: true),
            for: turn,
            sessionID: UUID()
        )
        adapter.emit(
            .text(messageID: nil, value: "foreign turn", isDelta: true),
            for: turn,
            turnID: UUID()
        )
        adapter.emit(.text(messageID: nil, value: "fresh", isDelta: true), for: turn)
        adapter.emit(.terminal(.completed(.endTurn)), for: turn)
        adapter.emit(.text(messageID: nil, value: "after terminal", isDelta: true), for: turn)
        adapter.finish(turn)
        await waitUntil { !service.isStreaming }

        #expect(assistantText(in: service.messages) == "fresh")
        #expect(service.messages.count == 2)
        #expect(service.streamError == nil)
    }

    @Test("cancel is routed to the active adapter exactly once")
    func cancellationRoutesExactlyOnce() async throws {
        let adapter = FakeRuntimeAdapter(backend: .anthropicAPI)
        let service = makeService(backend: .anthropicAPI, adapter: adapter)

        #expect(service.send(text: "Keep running", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let turn = try #require(adapter.sendRequests.first)

        service.cancel()
        service.cancel()
        await Task.yield()

        #expect(adapter.cancelledSessionIDs == [turn.sessionID])
        #expect(!service.isStreaming)
    }

    @Test("a second send cannot replace an in-flight runtime turn")
    func backToBackSendIsRejectedWithoutChangingTranscript() async {
        let adapter = FakeRuntimeAdapter(backend: .claudeCode)
        let service = makeService(backend: .claudeCode, adapter: adapter)
        defer { service.cancel() }

        #expect(service.send(text: "First turn", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        #expect(service.isStreaming)
        let transcript = service.messages

        #expect(!service.send(text: "Second turn", mentions: []))

        #expect(service.messages == transcript)
        #expect(service.messages.filter { $0.role == .user }.count == 1)
        #expect(adapter.sendRequests.count == 1)
    }

    @Test("runtime descriptor keeps host capabilities before startup and after rotation")
    func runtimeDescriptorIsStableWithoutAnActiveAdapter() async throws {
        let toolNames = Set(ToolDefinitions.all.map { $0.name.rawValue })
        let context = AgentRuntimeHostContext.hostOwned(tools: ToolDefinitions.all)

        for backend in AgentBackend.allCases {
            let extensions = configuredProviderExtensions(for: backend)
            let adapter = FakeRuntimeAdapter(
                backend: backend,
                toolNames: toolNames,
                providerExtensions: extensions
            )
            let service = makeService(backend: backend, adapter: adapter, context: context)
            let editor = EditorViewModel()
            service.editor = editor

            assertHostCapabilities(
                service.runtimeDescriptor,
                backend: backend,
                toolNames: toolNames,
                providerExtensions: extensions
            )

            #expect(service.send(text: "Start", mentions: []))
            await waitUntil { adapter.sendRequests.count == 1 }
            let session = try #require(adapter.startRequests.first)
            #expect(Set(session.hostContext.toolSchemas.map(\.name)) == toolNames)
            #expect(session.providerExtensions == extensions)

            service.cancel()

            assertHostCapabilities(
                service.runtimeDescriptor,
                backend: backend,
                toolNames: toolNames,
                providerExtensions: extensions
            )
        }
    }

    @Test("normalized runtime events project text, tools, results, usage, session, and terminal state")
    func normalizedEventsProjectIntoServiceState() async throws {
        let adapter = FakeRuntimeAdapter(backend: .anthropicAPI, toolNames: ["inspect_project"])
        let service = makeService(backend: .anthropicAPI, adapter: adapter)

        #expect(service.send(text: "Inspect it", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let turn = try #require(adapter.sendRequests.first)

        adapter.emit(.providerSessionStarted("provider-session-42"), for: turn)
        adapter.emit(.text(messageID: "message-1", value: "Plan ", isDelta: false), for: turn)
        adapter.emit(.text(messageID: "message-1", value: "ready", isDelta: true), for: turn)
        adapter.emit(.toolCall(
            messageID: "message-1",
            id: "tool-1",
            name: "inspect_project",
            inputJSON: #"{"scope":"timeline"}"#
        ), for: turn)
        adapter.emit(.toolResult(
            id: "tool-1",
            content: [.text("Timeline ready")],
            isError: false
        ), for: turn)
        adapter.emit(.usage(.init(
            inputTokens: 120,
            cacheCreationInputTokens: 30
        )), for: turn)
        adapter.emit(.usage(.init(
            outputTokens: 45,
            cacheReadInputTokens: 80,
            costUSD: 0.012
        )), for: turn)
        adapter.emit(.terminal(.completed(.toolUse)), for: turn)
        adapter.finish(turn)
        await waitUntil { !service.isStreaming }

        #expect(service.messages.count == 3)
        #expect(service.messages[1].role == .assistant)
        #expect(service.messages[1].blocks == [
            .text("Plan ready"),
            .toolUse(
                id: "tool-1",
                name: "inspect_project",
                inputJSON: #"{"scope":"timeline"}"#
            ),
        ])
        #expect(service.messages[2].role == .user)
        #expect(service.messages[2].blocks == [
            .toolResult(
                toolUseId: "tool-1",
                content: [.text("Timeline ready")],
                isError: false
            ),
        ])
        #expect(service.lastRuntimeUsage == .init(
            inputTokens: 120,
            outputTokens: 45,
            cacheCreationInputTokens: 30,
            cacheReadInputTokens: 80,
            costUSD: 0.012
        ))
        #expect(service.sessions.first?.claudeSessionId == "provider-session-42")
        #expect(service.runtimeDescriptor == adapter.descriptor)
        #expect(!service.isStreaming)
        #expect(service.streamError == nil)
    }

    private func makeService(
        backend: AgentBackend,
        adapter: FakeRuntimeAdapter,
        context: AgentRuntimeHostContext = .hostOwned(tools: [])
    ) -> AgentService {
        let service = AgentService(
            backend: backend,
            refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { requestedBackend in
                #expect(requestedBackend == backend)
                return adapter
            },
            runtimeReadinessOverride: { nil },
            runtimeHostContextOverride: { context }
        )
        service.loadSessions(from: nil)
        return service
    }

    private func assertHostCapabilities(
        _ descriptor: AgentRuntimeDescriptor,
        backend: AgentBackend,
        toolNames: Set<String>,
        providerExtensions: Set<String>
    ) {
        #expect(descriptor.identity == backend.runtimeIdentity)
        #expect(descriptor.capabilities.toolNames == toolNames)
        #expect(descriptor.capabilities.providerExtensions == providerExtensions)
        #expect(descriptor.capabilities.supports(.executeHostTools))
        #expect(descriptor.capabilities.supports(.structuredDialogs))
        #expect(descriptor.capabilities.supports(.approvalSuspension))

        switch backend {
        case .anthropicAPI:
            #expect(descriptor.toolExecutionTransport == .hostRoundTrip)
            #expect(descriptor.capabilities.supports(.resumeFromTranscript))
            #expect(descriptor.capabilities.supports(.reportTokenUsage))
            #expect(!descriptor.capabilities.supports(.resumeNativeSession))
            #expect(!descriptor.capabilities.supports(.externalClaudeCodePlugins))
        case .claudeCode:
            #expect(descriptor.toolExecutionTransport == .providerManagedMCP)
            #expect(descriptor.capabilities.supports(.resumeNativeSession))
            #expect(descriptor.capabilities.supports(.reportCostUsage))
            #expect(descriptor.capabilities.supports(.readProjectFiles))
            #expect(
                descriptor.capabilities.supports(.externalClaudeCodePlugins)
                    == !providerExtensions.isEmpty
            )
            #expect(!descriptor.capabilities.supports(.resumeFromTranscript))
        }
    }

    private func configuredProviderExtensions(for backend: AgentBackend) -> Set<String> {
        guard backend == .claudeCode else { return [] }
        var extensions = Set(
            ClaudeCodeRuntime.externalMcpServers().keys.map { "mcp:\($0)" }
        )
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "claudeRuntimePluginDir"),
           !path.isEmpty {
            extensions.insert(
                "claude-code-plugin:\(URL(fileURLWithPath: path).lastPathComponent)"
            )
        }
        #endif
        return extensions
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for AgentService runtime state")
    }
}

@MainActor
private final class FakeRuntimeAdapter: AgentRuntimeAdapter {
    let descriptor: AgentRuntimeDescriptor
    private(set) var state: AgentRuntimeState = .idle
    private(set) var startRequests: [AgentRuntimeSessionRequest] = []
    private(set) var resumeRequests: [AgentRuntimeSessionRequest] = []
    private(set) var sendRequests: [AgentRuntimeTurnRequest] = []
    private(set) var cancelledSessionIDs: [UUID] = []
    private(set) var endedSessionIDs: [UUID] = []

    private var continuations: [UUID: AsyncStream<AgentRuntimeEventEnvelope>.Continuation] = [:]
    private var activeTurnID: UUID?

    init(
        backend: AgentBackend,
        toolNames: Set<String> = [],
        providerExtensions: Set<String> = []
    ) {
        descriptor = backend.runtimeDescriptor(
            toolNames: toolNames,
            providerExtensions: providerExtensions
        )
    }

    func start(_ request: AgentRuntimeSessionRequest) throws {
        startRequests.append(request)
        state = .ready(sessionID: request.sessionID)
    }

    func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
        sendRequests.append(request)
        state = .running(sessionID: request.sessionID, turnID: request.turnID)
        activeTurnID = request.turnID
        var captured: AsyncStream<AgentRuntimeEventEnvelope>.Continuation?
        let stream = AsyncStream<AgentRuntimeEventEnvelope> { captured = $0 }
        continuations[request.turnID] = captured
        return stream
    }

    func cancel(sessionID: UUID) {
        cancelledSessionIDs.append(sessionID)
        if let activeTurnID {
            continuations[activeTurnID]?.finish()
            continuations[activeTurnID] = nil
            self.activeTurnID = nil
        }
        state = .ready(sessionID: sessionID)
    }

    func resume(_ request: AgentRuntimeSessionRequest) throws {
        resumeRequests.append(request)
        state = .ready(sessionID: request.sessionID)
    }

    func end(sessionID: UUID) {
        endedSessionIDs.append(sessionID)
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
        activeTurnID = nil
        state = .ended(sessionID: sessionID)
    }

    func emit(
        _ event: AgentRuntimeEvent,
        for request: AgentRuntimeTurnRequest,
        sessionID: UUID? = nil,
        turnID: UUID? = nil
    ) {
        continuations[request.turnID]?.yield(.init(
            sessionID: sessionID ?? request.sessionID,
            turnID: turnID ?? request.turnID,
            event: event
        ))
    }

    func finish(_ request: AgentRuntimeTurnRequest) {
        continuations[request.turnID]?.finish()
        continuations[request.turnID] = nil
        if activeTurnID == request.turnID {
            activeTurnID = nil
        }
        state = .ready(sessionID: request.sessionID)
    }
}

private func canonicalJSON(_ object: [String: Any]) -> Data? {
    try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func assistantText(in messages: [AgentMessage]) -> String {
    messages
        .filter { $0.role == .assistant }
        .flatMap(\.blocks)
        .compactMap { block in
            guard case .text(let text) = block else { return nil }
            return text
        }
        .joined()
}
