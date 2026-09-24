import Foundation
import Testing
@testable import NexGenVideo

private enum AnthropicTestStep: @unchecked Sendable {
    case event(AnthropicStreamEvent)
    case failure(AnthropicClientError)
}

private final class ScriptedAnthropicClient: AgentClient, @unchecked Sendable {
    struct Call: @unchecked Sendable {
        let system: String
        let tools: [AnthropicToolSchema]
        let messages: [AnthropicMessage]
    }

    private let lock = NSLock()
    private var scripts: [[AnthropicTestStep]]
    private var calls: [Call] = []

    init(scripts: [[AnthropicTestStep]]) {
        self.scripts = scripts
    }

    var recordedCalls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        lock.lock()
        calls.append(.init(system: system, tools: tools, messages: messages))
        let script = scripts.isEmpty ? [] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for step in script {
                switch step {
                case .event(let event):
                    continuation.yield(event)
                case .failure(let error):
                    continuation.finish(throwing: error)
                    return
                }
            }
            continuation.finish()
        }
    }
}

private final class ControlledAnthropicClient: AgentClient, @unchecked Sendable {
    let started: AsyncStream<Void>

    private let lock = NSLock()
    private let startedContinuation: AsyncStream<Void>.Continuation
    private var responseContinuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation?

    init() {
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
    }

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            responseContinuation = continuation
            lock.unlock()
            startedContinuation.yield()
        }
    }

    func yield(_ event: AnthropicStreamEvent) {
        lock.lock()
        let continuation = responseContinuation
        lock.unlock()
        continuation?.yield(event)
    }

    func finish() {
        lock.lock()
        let continuation = responseContinuation
        lock.unlock()
        continuation?.finish()
    }
}

@MainActor
@Suite("Anthropic runtime adapter")
struct AnthropicRuntimeAdapterTests {
    @Test("host owns the Anthropic tool round trip and executes each call once")
    func hostRoundTripExecutesOneToolExactlyOnce() async throws {
        let usage = AgentRuntimeUsage(
            inputTokens: 41,
            outputTokens: 7,
            cacheCreationInputTokens: 9,
            cacheReadInputTokens: 22
        )
        let client = ScriptedAnthropicClient(scripts: [
            [
                .event(.textDelta("Checking.")),
                .event(.toolUseComplete(id: "tool-1", name: "host_tool", inputJSON: #"{"value":"x"}"#)),
                .event(.usage(usage)),
                .event(.messageStop(stopReason: .toolUse)),
            ],
            [
                .event(.textDelta("Done.")),
                .event(.messageStop(stopReason: .endTurn)),
            ],
        ])
        let adapter = AnthropicRuntimeAdapter(client: client)
        let sessionID = UUID()
        var executions: [(String, String, String)] = []
        let hostContext = testHostContext()
        try adapter.start(testSessionRequest(
            sessionID: sessionID,
            hostContext: hostContext,
            executeTool: { id, name, inputJSON in
                executions.append((id, name, inputJSON))
                return .ok("host result")
            }
        ))
        let current = AgentRuntimeMessage(role: .user, content: [
            .text("Create it"),
            .image(.init(mediaType: "image/png", base64: "aW1hZ2U=")),
        ])

        let stream = try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        ))
        let events = await collectAnthropicEvents(stream)
        let payloads = events.map(\.event)

        #expect(executions.count == 1)
        #expect(executions.first?.0 == "tool-1")
        #expect(executions.first?.1 == "host_tool")
        #expect(executions.first?.2 == #"{"value":"x"}"#)
        #expect(payloads.contains(.usage(usage)))
        #expect(payloads.contains(.toolCall(
            messageID: nil,
            id: "tool-1",
            name: "host_tool",
            inputJSON: #"{"value":"x"}"#
        )))
        #expect(payloads.contains(.toolResult(
            id: "tool-1",
            content: [.text("host result")],
            isError: false
        )))
        #expect(anthropicTerminals(events) == [.completed(.endTurn)])
        #expect(adapter.state == .ready(sessionID: sessionID))

        let calls = client.recordedCalls
        #expect(calls.count == 2)
        #expect(calls.first?.system == hostContext.systemInstructions)
        #expect(calls.first?.tools.map(\.name) == ["host_tool"])
        #expect(calls.first?.messages.count == 1)
        #expect(calls.last?.messages.count == 3)
        let initialBlocks = try #require(calls.first?.messages.first?.content)
        #expect(initialBlocks.count == 2)
        #expect(initialBlocks[0]["type"] as? String == "text")
        #expect(initialBlocks[0]["text"] as? String == "Create it")
        #expect(initialBlocks[1]["type"] as? String == "image")
        let imageSource = initialBlocks[1]["source"] as? [String: String]
        #expect(imageSource?["media_type"] == "image/png")
        #expect(imageSource?["data"] == "aW1hZ2U=")
        let resultBlock = try #require(calls.last?.messages.last?.content.first)
        #expect(resultBlock["type"] as? String == "tool_result")
        #expect(resultBlock["tool_use_id"] as? String == "tool-1")
        #expect(resultBlock["is_error"] as? Bool == false)
    }

    @Test("host decision suspends the turn and later calls are not executed")
    func suspensionStopsProviderLoopAndSkipsLaterExecution() async throws {
        let client = ScriptedAnthropicClient(scripts: [[
            .event(.toolUseComplete(id: "dialog", name: "show_dialog", inputJSON: "{}")),
            .event(.toolUseComplete(id: "late", name: "host_tool", inputJSON: "{}")),
            .event(.messageStop(stopReason: .toolUse)),
        ]])
        let adapter = AnthropicRuntimeAdapter(client: client)
        let sessionID = UUID()
        var executed: [String] = []
        try adapter.start(testSessionRequest(
            sessionID: sessionID,
            hostContext: testHostContext(toolNames: ["show_dialog", "host_tool"]),
            executeTool: { _, name, _ in
                executed.append(name)
                return name == "show_dialog"
                    ? .suspended("Waiting for the user")
                    : .ok("must not run")
            }
        ))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Ask me")])

        let events = await collectAnthropicEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))
        let payloads = events.map(\.event)

        #expect(executed == ["show_dialog"])
        #expect(client.recordedCalls.count == 1)
        #expect(payloads.contains(.toolResult(
            id: "dialog",
            content: [.text("Waiting for the user")],
            isError: false
        )))
        #expect(payloads.contains(.toolResult(
            id: "late",
            content: [.text("Not executed: an earlier tool opened a host decision and suspended this turn.")],
            isError: true
        )))
        #expect(anthropicTerminals(events) == [.completed(.toolUse)])
    }

    @Test("EOF without a stop reason is a protocol failure with one terminal")
    func eofWithoutStopReasonFails() async throws {
        let client = ScriptedAnthropicClient(scripts: [[
            .event(.textDelta("partial")),
        ]])
        let adapter = AnthropicRuntimeAdapter(client: client)
        let sessionID = UUID()
        try adapter.start(testSessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Hello")])

        let events = await collectAnthropicEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))

        let failures = events.compactMap { event -> AgentRuntimeFailure? in
            guard case .error(let failure) = event.event else { return nil }
            return failure
        }
        #expect(failures.count == 1)
        #expect(failures.first?.kind == .protocolViolation)
        #expect(failures.first?.message.contains("without a terminal stop reason") == true)
        #expect(anthropicTerminals(events) == [.failed])
        guard case .failed(let failedSession, _) = adapter.state else {
            Issue.record("Expected failed runtime state")
            return
        }
        #expect(failedSession == sessionID)
    }

    @Test("cancellation wins over late Anthropic events and emits one terminal")
    func cancellationDropsLateProviderEvents() async throws {
        let client = ControlledAnthropicClient()
        let adapter = AnthropicRuntimeAdapter(client: client)
        let sessionID = UUID()
        try adapter.start(testSessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Wait")])
        var started = client.started.makeAsyncIterator()
        let stream = try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        ))
        let collector = Task { await collectAnthropicEvents(stream) }
        _ = await started.next()

        adapter.cancel(sessionID: sessionID)
        client.yield(.textDelta("late"))
        client.yield(.messageStop(stopReason: .endTurn))
        client.finish()

        let events = await collector.value
        let payloads = events.map(\.event)
        #expect(anthropicTerminals(events) == [.cancelled])
        #expect(!payloads.contains(.text(messageID: nil, value: "late", isDelta: true)))
        #expect(adapter.state == .ready(sessionID: sessionID))
    }

    @Test("contract rejects missing, foreign, concurrent, and non-user turns")
    func validatesSessionAndTurnOwnership() async throws {
        let client = ControlledAnthropicClient()
        let adapter = AnthropicRuntimeAdapter(client: client)
        let sessionID = UUID()
        let user = AgentRuntimeMessage(role: .user, content: [.text("hello")])
        let assistant = AgentRuntimeMessage(role: .assistant, content: [.text("not input")])

        #expect(throws: AgentRuntimeContractError.sessionNotStarted) {
            _ = try adapter.send(.init(
                sessionID: sessionID,
                turnID: UUID(),
                messages: [user],
                currentMessage: user
            ))
        }
        try adapter.start(testSessionRequest(sessionID: sessionID))
        #expect(throws: AgentRuntimeContractError.sessionMismatch) {
            _ = try adapter.send(.init(
                sessionID: UUID(),
                turnID: UUID(),
                messages: [user],
                currentMessage: user
            ))
        }
        #expect(throws: AgentRuntimeContractError.invalidCurrentMessage) {
            _ = try adapter.send(.init(
                sessionID: sessionID,
                turnID: UUID(),
                messages: [assistant],
                currentMessage: assistant
            ))
        }
        let differentUser = AgentRuntimeMessage(role: .user, content: [.text("different")])
        #expect(throws: AgentRuntimeContractError.invalidCurrentMessage) {
            _ = try adapter.send(.init(
                sessionID: sessionID,
                turnID: UUID(),
                messages: [user],
                currentMessage: differentUser
            ))
        }
        let stream = try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [user],
            currentMessage: user
        ))
        #expect(throws: AgentRuntimeContractError.turnAlreadyRunning) {
            _ = try adapter.send(.init(
                sessionID: sessionID,
                turnID: UUID(),
                messages: [user],
                currentMessage: user
            ))
        }
        adapter.cancel(sessionID: sessionID)
        _ = await collectAnthropicEvents(stream)
        adapter.end(sessionID: sessionID)
        #expect(adapter.state == .ended(sessionID: sessionID))
    }

    @Test("authentication errors are normalized and terminate once")
    func authenticationFailureIsNormalized() async throws {
        let client = ScriptedAnthropicClient(scripts: [[
            .failure(.httpError(status: 401, body: "expired")),
        ]])
        let adapter = AnthropicRuntimeAdapter(client: client)
        let sessionID = UUID()
        try adapter.start(testSessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Hello")])

        let events = await collectAnthropicEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))
        let payloads = events.map(\.event)

        #expect(payloads.contains(.error(.init(
            kind: .authenticationRequired,
            message: "Anthropic API error (401): expired"
        ))))
        #expect(anthropicTerminals(events) == [.failed])
    }
}

@MainActor
private func testSessionRequest(
    sessionID: UUID,
    hostContext: AgentRuntimeHostContext = testHostContext(),
    executeTool: @escaping AgentRuntimeToolExecutor = { _, _, _ in .ok("unused") }
) -> AgentRuntimeSessionRequest {
    AgentRuntimeSessionRequest(
        sessionID: sessionID,
        providerSessionID: nil,
        priorMessages: [],
        hostContext: hostContext,
        workingDirectory: URL(fileURLWithPath: "/tmp/project"),
        pluginDirectories: [],
        providerExtensions: [],
        mcpPort: 19_789,
        executeTool: executeTool
    )
}

private func testHostContext(
    toolNames: [String] = ["host_tool"]
) -> AgentRuntimeHostContext {
    AgentRuntimeHostContext(
        interfaceLanguage: .init(identifier: "en-GB", displayName: "English"),
        baseInstructions: "Host instructions",
        pack: .init(id: "musicvideo", version: "1.0.0", projectSchema: "1", currentPhase: "story"),
        phaseInstructions: "Write the story.",
        toolSchemas: toolNames.map {
            .init(name: $0, description: "Schema for \($0)", inputSchema: ["type": "object"])
        },
        authority: [.toolSchemas, .toolExecution, .structuredDialogs, .outputApprovals, .gateRefusals]
    )
}

@MainActor
private func collectAnthropicEvents(
    _ stream: AsyncStream<AgentRuntimeEventEnvelope>
) async -> [AgentRuntimeEventEnvelope] {
    var result: [AgentRuntimeEventEnvelope] = []
    for await envelope in stream {
        result.append(envelope)
    }
    return result
}

private func anthropicTerminals(
    _ events: [AgentRuntimeEventEnvelope]
) -> [AgentRuntimeTerminal] {
    events.compactMap {
        guard case .terminal(let terminal) = $0.event else { return nil }
        return terminal
    }
}
