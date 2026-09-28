import Foundation
import Testing
@testable import NexGenVideo

@MainActor
private final class FakeClaudeCodeDriver: ClaudeCodeRuntimeDriving {
    struct SendCall {
        let text: String
        let context: String?
        let imageBlocks: [[String: Any]]
        let hidden: Bool
        let presentation: AgentUserPresentation?
    }

    var callbacks: ClaudeCodeRuntimeAdapter.Callbacks?
    var sendResult = true
    private(set) var sends: [SendCall] = []
    private(set) var stopCount = 0

    func send(
        text: String,
        context: String?,
        imageBlocks: [[String: Any]],
        hidden: Bool,
        presentation: AgentUserPresentation?
    ) -> Bool {
        sends.append(.init(
            text: text,
            context: context,
            imageBlocks: imageBlocks,
            hidden: hidden,
            presentation: presentation
        ))
        return sendResult
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
@Suite("Claude Code runtime adapter")
struct ClaudeCodeRuntimeAdapterTests {
    @Test("provider-managed MCP events are mapped without host double execution")
    func providerManagedMCPMapsEventsWithoutExecutingHostTool() async throws {
        let driver = FakeClaudeCodeDriver()
        var factoryRequest: AgentRuntimeSessionRequest?
        let adapter = ClaudeCodeRuntimeAdapter { request, callbacks in
            factoryRequest = request
            driver.callbacks = callbacks
            return driver
        }
        let sessionID = UUID()
        var hostExecutionCount = 0
        let session = claudeSessionRequest(
            sessionID: sessionID,
            providerSessionID: "resume-123",
            providerExtensions: ["mcp:ace"],
            executeTool: { _, _, _ in
                hostExecutionCount += 1
                return .ok("must not execute")
            }
        )
        try adapter.resume(session)
        let current = AgentRuntimeMessage(role: .user, content: [
            .text("Use the tool"),
            .text("with this reference"),
            .image(.init(mediaType: "image/jpeg", base64: "anBlZw==")),
        ])
        let stream = try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        ))

        driver.callbacks?.events([
            .sessionStarted(sessionId: "provider-new"),
            .assistantBlock(messageId: "m1", block: .text("Working.")),
            .assistantBlock(
                messageId: "m1",
                block: .toolUse(id: "tool-1", name: "host_tool", inputJSON: #"{"value":1}"#)
            ),
            .toolResult(toolUseId: "tool-1", blocks: [.text("provider result")], isError: false),
            .turnFinished(isError: false, errorMessage: nil, costUSD: 0.025),
        ])
        let events = await collectClaudeEvents(stream)
        let payloads = events.map(\.event)

        #expect(factoryRequest?.providerSessionID == "resume-123")
        #expect(factoryRequest?.providerExtensions == ["mcp:ace"])
        #expect(hostExecutionCount == 0)
        #expect(driver.sends.count == 1)
        #expect(driver.sends.first?.text == "Use the tool\n\nwith this reference")
        #expect(driver.sends.first?.context == nil)
        #expect(driver.sends.first?.hidden == true)
        #expect(driver.sends.first?.presentation == nil)
        let source = driver.sends.first?.imageBlocks.first?["source"] as? [String: String]
        #expect(source?["media_type"] == "image/jpeg")
        #expect(source?["data"] == "anBlZw==")
        #expect(payloads.contains(.providerSessionStarted("provider-new")))
        #expect(payloads.contains(.toolCall(
            messageID: "m1",
            id: "tool-1",
            name: "host_tool",
            inputJSON: #"{"value":1}"#
        )))
        #expect(payloads.contains(.toolResult(
            id: "tool-1",
            content: [.text("provider result")],
            isError: false
        )))
        #expect(payloads.contains(.usage(.init(costUSD: 0.025))))
        #expect(claudeTerminals(events) == [.completed(.endTurn)])
        #expect(adapter.state == .ready(sessionID: sessionID))
        #expect(adapter.descriptor.toolExecutionTransport == .providerManagedMCP)
        #expect(adapter.descriptor.capabilities.providerExtensions == ["mcp:ace"])
    }

    @Test("resume invalidation is normalized for the host")
    func resumeFailureInvalidatesProviderSession() async throws {
        let driver = FakeClaudeCodeDriver()
        let adapter = ClaudeCodeRuntimeAdapter { _, callbacks in
            driver.callbacks = callbacks
            return driver
        }
        let sessionID = UUID()
        try adapter.resume(claudeSessionRequest(
            sessionID: sessionID,
            providerSessionID: "dead-session"
        ))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Resume")])
        let stream = try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        ))

        driver.callbacks?.resumeFailed()
        driver.callbacks?.events([
            .sessionStarted(sessionId: "fresh-session"),
            .turnFinished(isError: false, errorMessage: nil, costUSD: nil),
        ])
        let events = await collectClaudeEvents(stream)
        let payloads = events.map(\.event)

        #expect(payloads.contains(.providerSessionInvalidated))
        #expect(payloads.contains(.providerSessionStarted("fresh-session")))
        #expect(claudeTerminals(events) == [.completed(.endTurn)])
    }

    @Test("process EOF without a result is a protocol failure with one terminal")
    func eofWithoutResultFails() async throws {
        let driver = FakeClaudeCodeDriver()
        let adapter = ClaudeCodeRuntimeAdapter { _, callbacks in
            driver.callbacks = callbacks
            return driver
        }
        let sessionID = UUID()
        try adapter.start(claudeSessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Hello")])
        let stream = try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        ))

        driver.callbacks?.events([
            .assistantBlock(messageId: "m1", block: .text("partial")),
        ])
        driver.callbacks?.streamingChanged(false)
        driver.callbacks?.streamingChanged(false)
        let events = await collectClaudeEvents(stream)

        let failures = events.compactMap { event -> AgentRuntimeFailure? in
            guard case .error(let failure) = event.event else { return nil }
            return failure
        }
        #expect(failures.count == 1)
        #expect(failures.first?.kind == .protocolViolation)
        #expect(failures.first?.message.contains("ended without a terminal result") == true)
        #expect(claudeTerminals(events) == [.failed])
    }

    @Test("cancellation terminates once, stops the process, and drops late callbacks")
    func cancellationDropsLateEvents() async throws {
        let driver = FakeClaudeCodeDriver()
        let adapter = ClaudeCodeRuntimeAdapter { _, callbacks in
            driver.callbacks = callbacks
            return driver
        }
        let sessionID = UUID()
        try adapter.start(claudeSessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Long task")])
        let stream = try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        ))

        adapter.cancel(sessionID: sessionID)
        driver.callbacks?.events([
            .assistantBlock(messageId: "m1", block: .text("late")),
            .turnFinished(isError: false, errorMessage: nil, costUSD: 1),
        ])
        driver.callbacks?.failure(.init(kind: .transport, message: "later failure"))
        driver.callbacks?.streamingChanged(false)
        let events = await collectClaudeEvents(stream)
        let payloads = events.map(\.event)

        #expect(driver.stopCount == 1)
        #expect(claudeTerminals(events) == [.cancelled])
        #expect(!payloads.contains(.text(messageID: "m1", value: "late", isDelta: false)))
        #expect(adapter.state == .ready(sessionID: sessionID))
    }

    @Test("send refusal becomes one backend-unavailable failure")
    func refusedSendFailsOnce() async throws {
        let driver = FakeClaudeCodeDriver()
        driver.sendResult = false
        let adapter = ClaudeCodeRuntimeAdapter { _, callbacks in
            driver.callbacks = callbacks
            return driver
        }
        let sessionID = UUID()
        try adapter.start(claudeSessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Hello")])

        let events = await collectClaudeEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))
        let payloads = events.map(\.event)

        #expect(payloads.contains(.error(.init(
            kind: .backendUnavailable,
            message: "Claude Code could not start the turn."
        ))))
        #expect(claudeTerminals(events) == [.failed])
    }

    @Test("contract rejects missing, foreign, concurrent, and non-user turns")
    func validatesSessionAndTurnOwnership() async throws {
        let driver = FakeClaudeCodeDriver()
        let adapter = ClaudeCodeRuntimeAdapter { _, callbacks in
            driver.callbacks = callbacks
            return driver
        }
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
        try adapter.start(claudeSessionRequest(sessionID: sessionID))
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
        _ = await collectClaudeEvents(stream)
        adapter.end(sessionID: sessionID)
        #expect(adapter.state == .ended(sessionID: sessionID))
    }
}

@MainActor
private func claudeSessionRequest(
    sessionID: UUID,
    providerSessionID: String? = nil,
    providerExtensions: Set<String> = [],
    executeTool: @escaping AgentRuntimeToolExecutor = { _, _, _ in .ok("unused") }
) -> AgentRuntimeSessionRequest {
    AgentRuntimeSessionRequest(
        sessionID: sessionID,
        providerSessionID: providerSessionID,
        priorMessages: [AgentMessage(role: .assistant, blocks: [.text("Earlier")])],
        hostContext: AgentRuntimeHostContext(
            interfaceLanguage: .init(identifier: "en", displayName: "English"),
            baseInstructions: "Host instructions",
            pack: nil,
            phaseInstructions: nil,
            toolSchemas: [
                .init(name: "host_tool", description: "Host tool", inputSchema: ["type": "object"]),
            ],
            authority: [.toolSchemas, .toolExecution]
        ),
        workingDirectory: URL(fileURLWithPath: "/tmp/project"),
        pluginDirectories: [],
        providerExtensions: providerExtensions,
        mcpPort: 19_789,
        executeTool: executeTool
    )
}

@MainActor
private func collectClaudeEvents(
    _ stream: AsyncStream<AgentRuntimeEventEnvelope>
) async -> [AgentRuntimeEventEnvelope] {
    var result: [AgentRuntimeEventEnvelope] = []
    for await envelope in stream {
        result.append(envelope)
    }
    return result
}

private func claudeTerminals(
    _ events: [AgentRuntimeEventEnvelope]
) -> [AgentRuntimeTerminal] {
    events.compactMap {
        guard case .terminal(let terminal) = $0.event else { return nil }
        return terminal
    }
}
