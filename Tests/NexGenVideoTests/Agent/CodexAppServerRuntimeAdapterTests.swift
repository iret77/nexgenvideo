import Foundation
import Testing
@testable import NexGenVideo

@MainActor
private final class FakeCodexAppServerDriver: CodexAppServerDriving {
    struct Call {
        let method: String
        let params: [String: Any]
    }

    let events: AsyncStream<CodexAppServerInbound>
    var accountStatus: CodexAppServerAccountStatus? = .init(billing: .apiKey)
    private let continuation: AsyncStream<CodexAppServerInbound>.Continuation
    var startError: Error?
    var inheritedInstructionSources: [String] = []
    var scriptedEvents: [CodexAppServerInbound] = []
    var completeAfterToolResponse = false
    private(set) var calls: [Call] = []
    private(set) var responses: [[String: Any]] = []
    private(set) var stopCount = 0

    init() {
        var continuation: AsyncStream<CodexAppServerInbound>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func start(home: URL, scratch: URL) async throws {
        if let startError { throw startError }
    }

    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(.init(method: method, params: params))
        switch method {
        case "thread/start":
            return [
                "thread": ["id": "thread-1"],
                "cwd": params["cwd"] as? String ?? "",
                "instructionSources": inheritedInstructionSources,
                "runtimeWorkspaceRoots": [],
            ]
        case "turn/start":
            Task { @MainActor in
                await Task.yield()
                for event in self.scriptedEvents { self.continuation.yield(event) }
            }
            return ["turn": ["id": "provider-turn-1"]]
        case "turn/interrupt":
            return [:]
        default:
            throw CodexAppServerError.remote(code: -32_601, message: method)
        }
    }

    func respond(id: Any, result: [String: Any]) throws {
        responses.append(result)
        if completeAfterToolResponse {
            continuation.yield(.notification(method: "turn/completed", params: [
                "threadId": "thread-1",
                "turn": ["id": "provider-turn-1", "status": "completed", "items": []],
            ]))
        }
    }

    func respond(id: Any, errorCode: Int, message: String) throws {
        responses.append(["error": ["code": errorCode, "message": message]])
    }

    func stop() {
        stopCount += 1
        continuation.finish()
    }

    func emit(_ event: CodexAppServerInbound) {
        continuation.yield(event)
    }
}

@MainActor
@Suite("Codex App Server runtime adapter")
struct CodexAppServerRuntimeAdapterTests {
    @Test("pinned contract disables inherited and built-in capability surfaces")
    func isolatedConfigurationIsExplicitAndFailClosed() {
        let config = CodexAppServerContract.isolatedConfig
        for required in [
            "cli_auth_credentials_store = \"keyring\"",
            "mcp_oauth_credentials_store = \"keyring\"",
            "sandbox_mode = \"read-only\"",
            "web_search = \"disabled\"",
            "shell_tool = false",
            "view_image = false",
            "hooks = false",
            "multi_agent = false",
            "apps = false",
            "enable_mcp_apps = false",
            "plugins = false",
            "image_generation = false",
            "send_message_to_user_async = false",
            "current_time_reminder = false",
            "unbounded_connection_retries = false",
        ] {
            #expect(config.contains(required))
        }
        #expect(!config.contains("mcp_servers."))
        #expect(CodexAppServerContract.cliVersion == "0.156.0")
        #expect(CodexAppServerContract.protocolRevision == "rust-v0.156.0")
        #expect(CodexAppServerContract.accepts(userAgent: "codex_cli_rs/0.156.0"))
        #expect(!CodexAppServerContract.accepts(userAgent: "codex_cli_rs/0.157.0"))
        let environment = CodexAppServerContract.childEnvironment(
            ambient: [
                "PATH": "/trusted/bin",
                "HOME": "/Users/person",
                "CODEX_HOME": "/Users/person/.codex",
                "OPENAI_API_KEY": "private-key",
                "CLAUDE_CODE_PLUGIN_DIR": "/Users/person/plugins",
            ],
            home: URL(fileURLWithPath: "/isolated/codex"),
            scratch: URL(fileURLWithPath: "/isolated/scratch")
        )
        #expect(environment["CODEX_HOME"] == "/isolated/codex")
        #expect(environment["HOME"] == "/isolated/codex")
        #expect(environment["TMPDIR"] == "/isolated/scratch")
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["XDG_CONFIG_HOME"] == "/isolated/codex/config")
        #expect(environment["XDG_CACHE_HOME"] == "/isolated/scratch/cache")
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["CLAUDE_CODE_PLUGIN_DIR"] == nil)
    }

    @Test("text, real image data, namespaced tool result, and usage preserve the host contract")
    func textImageAndToolRoundTrip() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.completeAfterToolResponse = true
        driver.scriptedEvents = [
            .notification(method: "turn/started", params: [
                "threadId": "thread-1",
                "turn": ["id": "provider-turn-1", "status": "inProgress", "items": []],
            ]),
            .notification(method: "item/agentMessage/delta", params: [
                "threadId": "thread-1",
                "turnId": "provider-turn-1",
                "itemId": "message-1",
                "delta": "Working",
            ]),
            .request(id: 91, method: "item/tool/call", params: [
                "threadId": "thread-1",
                "turnId": "provider-turn-1",
                "callId": "call-1",
                "namespace": "nexgen",
                "tool": "host_tool",
                "arguments": ["value": "safe"],
            ]),
        ]
        var executions: [(String, String, String)] = []
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.start(sessionRequest(sessionID: sessionID) { id, name, input in
            executions.append((id, name, input))
            return ToolResult(
                content: [
                    .text("host result"),
                    .image(base64: "aW1hZ2U=", mediaType: "image/png"),
                ],
                isError: false
            )
        })
        let current = AgentRuntimeMessage(role: .user, content: [
            .text("Inspect this frame"),
            .image(.init(mediaType: "image/jpeg", base64: "ZnJhbWU=")),
        ])
        let events = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))

        #expect(executions.count == 1)
        #expect(executions.first?.0 == "call-1")
        #expect(executions.first?.1 == "host_tool")
        #expect(executions.first?.2.contains("safe") == true)
        #expect(driver.responses.count == 1)
        let contentItems = driver.responses.first?["contentItems"] as? [[String: Any]]
        #expect(contentItems?.count == 2)
        #expect(contentItems?.last?["imageUrl"] as? String == "data:image/png;base64,aW1hZ2U=")
        let start = driver.calls.first(where: { $0.method == "thread/start" })
        #expect(start?.params["ephemeral"] as? Bool == true)
        #expect(start?.params["allowProviderModelFallback"] as? Bool == false)
        #expect((start?.params["environments"] as? [Any])?.isEmpty == true)
        #expect((start?.params["runtimeWorkspaceRoots"] as? [Any])?.isEmpty == true)
        let namespaces = start?.params["dynamicTools"] as? [[String: Any]]
        #expect(namespaces?.first?["name"] as? String == "nexgen")
        let turn = driver.calls.first(where: { $0.method == "turn/start" })
        let input = turn?.params["input"] as? [[String: Any]]
        #expect(input?.last?["url"] as? String == "data:image/jpeg;base64,ZnJhbWU=")
        #expect(events.map(\.event).contains(.providerSessionStarted("thread-1")))
        #expect(events.map(\.event).contains(.text(
            messageID: "message-1",
            value: "Working",
            isDelta: true
        )))
        #expect(codexTerminals(events) == [.completed(.endTurn)])
    }

    @Test("dialog or spend suspension returns the tool result and interrupts before continuation")
    func hostSuspensionStopsTheTurn() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.scriptedEvents = [
            .notification(method: "turn/started", params: [
                "threadId": "thread-1",
                "turn": ["id": "provider-turn-1", "status": "inProgress", "items": []],
            ]),
            .request(id: 1, method: "item/tool/call", params: [
                "threadId": "thread-1",
                "turnId": "provider-turn-1",
                "callId": "dialog-1",
                "namespace": "nexgen",
                "tool": "host_tool",
                "arguments": [:],
            ]),
        ]
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.start(sessionRequest(sessionID: sessionID) { _, _, _ in
            .suspended("Decision opened")
        })
        let current = AgentRuntimeMessage(role: .user, content: [.text("Ask")])
        let events = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))

        #expect(driver.responses.count == 1)
        #expect(codexTerminals(events) == [.completed(.toolUse)])
    }

    @Test("unknown protocol events fail closed and cannot append a late answer")
    func unknownEventFailsClosed() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.scriptedEvents = [
            .notification(method: "future/unsafeEvent", params: [:]),
            .notification(method: "item/agentMessage/delta", params: [
                "threadId": "thread-1",
                "turnId": "provider-turn-1",
                "itemId": "late",
                "delta": "late answer",
            ]),
        ]
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.start(sessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Hello")])
        let events = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))

        let failures = events.compactMap { envelope -> AgentRuntimeFailure? in
            guard case .error(let value) = envelope.event else { return nil }
            return value
        }
        #expect(failures.count == 1)
        #expect(failures.first?.kind == .protocolViolation)
        #expect(!events.map(\.event).contains(.text(messageID: "late", value: "late answer", isDelta: true)))
        #expect(codexTerminals(events) == [.failed])
    }

    @Test("events from an old provider thread cannot fail or append to the active turn")
    func staleProviderEventsAreDropped() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.scriptedEvents = [
            .notification(method: "future/unsafeEvent", params: [
                "threadId": "old-thread",
                "turnId": "old-turn",
            ]),
            .notification(method: "item/agentMessage/delta", params: [
                "threadId": "old-thread",
                "turnId": "old-turn",
                "itemId": "late",
                "delta": "late answer",
            ]),
            .notification(method: "turn/completed", params: [
                "threadId": "thread-1",
                "turn": ["id": "provider-turn-1", "status": "completed", "items": []],
            ]),
        ]
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.start(sessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Hello")])
        let events = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))

        #expect(!events.contains { envelope in
            guard case .text(_, let value, _) = envelope.event else { return false }
            return value == "late answer"
        })
        #expect(!events.contains { envelope in
            guard case .error = envelope.event else { return false }
            return true
        })
        #expect(codexTerminals(events) == [.completed(.endTurn)])
    }

    @Test("runtime unauthorized becomes an explicit authentication failure")
    func runtimeUnauthorizedIsVisible() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.scriptedEvents = [
            .notification(method: "error", params: [
                "threadId": "thread-1",
                "turnId": "provider-turn-1",
                "willRetry": false,
                "error": [
                    "message": "provider detail",
                    "codexErrorInfo": "unauthorized",
                ],
            ]),
        ]
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.start(sessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Hello")])
        let events = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))
        let failure = try #require(events.compactMap { envelope -> AgentRuntimeFailure? in
            guard case .error(let value) = envelope.event else { return nil }
            return value
        }.first)

        #expect(failure.kind == .authenticationRequired)
        #expect(failure.message == CodexAppServerError.authenticationRequired.localizedDescription)
        #expect(codexTerminals(events) == [.failed])
    }

    @Test("missing isolated auth fails before any thread or model request")
    func missingAuthenticationDoesNotStartAThread() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.startError = CodexAppServerError.authenticationRequired
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.start(sessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Hello")])
        let events = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))

        #expect(driver.calls.isEmpty)
        #expect(events.map(\.event).contains(.error(.init(
            kind: .authenticationRequired,
            message: CodexAppServerError.authenticationRequired.localizedDescription
        ))))
        #expect(codexTerminals(events) == [.failed])
    }

    @Test("incompatible CLI versions and EOF fail before stale output can mutate the chat")
    func incompatibleVersionAndEOFHaveExplicitFailures() async throws {
        for error in [
            CodexAppServerError.incompatibleVersion("codex_cli_rs/0.157.0"),
            CodexAppServerError.transportClosed,
        ] {
            let driver = FakeCodexAppServerDriver()
            driver.startError = error
            let sessionID = UUID()
            let adapter = makeAdapter(driver)
            try adapter.start(sessionRequest(sessionID: sessionID))
            let current = AgentRuntimeMessage(role: .user, content: [.text("Hello")])
            let events = await collectCodexEvents(try adapter.send(.init(
                sessionID: sessionID,
                turnID: UUID(),
                messages: [current],
                currentMessage: current
            )))
            let failure = try #require(events.compactMap { envelope -> AgentRuntimeFailure? in
                guard case .error(let value) = envelope.event else { return nil }
                return value
            }.first)
            #expect(failure.kind == (error == .transportClosed ? .transport : .backendUnavailable))
            #expect(codexTerminals(events) == [.failed])
        }
    }

    @Test("cold resume is rejected because 0.156.0 loses its isolated tools and environments")
    func coldResumeFailsClosed() throws {
        let driver = FakeCodexAppServerDriver()
        let sessionID = UUID()
        let adapter = makeAdapter(driver)

        #expect(throws: CodexAppServerError.resumeIsolationUnavailable) {
            try adapter.resume(sessionRequest(
                sessionID: sessionID,
                providerSessionID: "thread-1"
            ))
        }
        #expect(driver.calls.isEmpty)
    }

    @Test("an inherited instruction source rejects the runtime before a turn")
    func inheritedPersonalConfigurationIsRejected() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.inheritedInstructionSources = ["/Users/person/.codex/AGENTS.md"]
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.start(sessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Hello")])
        let events = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))

        #expect(!driver.calls.contains(where: { $0.method == "turn/start" }))
        #expect(codexTerminals(events) == [.failed])
    }

    @Test("cancellation closes the bounded process and drops late provider events")
    func cancellationDropsLateEvents() async throws {
        let driver = FakeCodexAppServerDriver()
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.start(sessionRequest(sessionID: sessionID))
        let current = AgentRuntimeMessage(role: .user, content: [.text("Wait")])
        let stream = try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        ))
        await Task.yield()
        adapter.cancel(sessionID: sessionID)
        driver.emit(.notification(method: "item/agentMessage/delta", params: [
            "threadId": "thread-1",
            "turnId": "provider-turn-1",
            "itemId": "late",
            "delta": "late",
        ]))
        let events = await collectCodexEvents(stream)

        #expect(codexTerminals(events) == [.cancelled])
        #expect(!events.map(\.event).contains(.text(messageID: "late", value: "late", isDelta: true)))
    }

    private func makeAdapter(_ driver: FakeCodexAppServerDriver) -> CodexAppServerRuntimeAdapter {
        CodexAppServerRuntimeAdapter(
            driverFactory: { driver },
            runtimeLocations: { session in
                (
                    URL(fileURLWithPath: "/tmp/ngv-codex-home"),
                    URL(fileURLWithPath: "/tmp/ngv-codex-scratch-\(session.runtimeGenerationID)")
                )
            }
        )
    }

    private func sessionRequest(
        sessionID: UUID,
        providerSessionID: String? = nil,
        executeTool: @escaping AgentRuntimeToolExecutor = { _, _, _ in .ok("ok") }
    ) -> AgentRuntimeSessionRequest {
        let schema = AgentRuntimeToolSchema(
            name: "host_tool",
            description: "A harmless host tool",
            inputSchema: [
                "type": "object",
                "properties": ["value": ["type": "string"]],
                "additionalProperties": false,
            ]
        )
        let context = AgentRuntimeHostContext(
            interfaceLanguage: .init(identifier: "de-DE", displayName: "German"),
            baseInstructions: "HOST INSTRUCTIONS",
            pack: .init(id: "musicvideo", version: "1", projectSchema: "1", currentPhase: "story"),
            phaseInstructions: "PHASE INSTRUCTIONS",
            toolSchemas: [schema],
            authority: [.toolSchemas, .toolExecution, .structuredDialogs, .outputApprovals, .gateRefusals]
        )
        return AgentRuntimeSessionRequest(
            sessionID: sessionID,
            runtimeGenerationID: UUID(),
            providerSessionID: providerSessionID,
            priorMessages: [],
            hostContext: context,
            workingDirectory: nil,
            pluginDirectories: [],
            providerExtensions: [],
            mcpPort: 0,
            executeTool: executeTool
        )
    }
}

@MainActor
private func collectCodexEvents(
    _ stream: AsyncStream<AgentRuntimeEventEnvelope>
) async -> [AgentRuntimeEventEnvelope] {
    var events: [AgentRuntimeEventEnvelope] = []
    for await event in stream { events.append(event) }
    return events
}

private func codexTerminals(_ events: [AgentRuntimeEventEnvelope]) -> [AgentRuntimeTerminal] {
    events.compactMap {
        guard case .terminal(let value) = $0.event else { return nil }
        return value
    }
}
