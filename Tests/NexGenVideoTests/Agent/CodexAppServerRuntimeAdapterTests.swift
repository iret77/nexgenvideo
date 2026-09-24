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
    var isolationError: Error?
    var inheritedInstructionSources: [String] = []
    var scriptedEvents: [CodexAppServerInbound] = []
    var completeAfterToolResponse = false
    var completeInterrupt = true
    var pauseAtOperation: String?
    private var pausedContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var didPause = false
    private(set) var isolationChecks = 0
    private(set) var calls: [Call] = []
    private(set) var responses: [[String: Any]] = []
    private(set) var stopCount = 0
    private(set) var operations: [String] = []

    init() {
        var continuation: AsyncStream<CodexAppServerInbound>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func start(home: URL, scratch: URL) async throws {
        await pauseIfRequested("start")
        if let startError { throw startError }
    }

    func verifyIsolation(home: URL, scratch: URL) async throws {
        isolationChecks += 1
        if let isolationError { throw isolationError }
    }

    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(.init(method: method, params: params))
        operations.append("request:\(method)")
        await pauseIfRequested("request:\(method)")
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
        case "thread/injectItems":
            return [:]
        case "turn/interrupt":
            if completeInterrupt {
                Task { @MainActor in
                    await Task.yield()
                    self.continuation.yield(.notification(method: "turn/completed", params: [
                        "threadId": params["threadId"] as? String ?? "thread-1",
                        "turn": [
                            "id": params["turnId"] as? String ?? "provider-turn-1",
                            "status": "interrupted",
                            "items": [],
                        ],
                    ]))
                }
            }
            return [:]
        default:
            throw CodexAppServerError.remote(code: -32_601, message: method)
        }
    }

    func respond(id: Any, result: [String: Any]) throws {
        responses.append(result)
        operations.append("respond")
        if completeAfterToolResponse {
            continuation.yield(.notification(method: "turn/completed", params: [
                "threadId": "thread-1",
                "turn": ["id": "provider-turn-1", "status": "completed", "items": []],
            ]))
        }
    }

    func respond(id: Any, errorCode: Int, message: String) throws {
        responses.append(["error": ["code": errorCode, "message": message]])
        operations.append("respond:error")
    }

    func stop() {
        stopCount += 1
        continuation.finish()
    }

    func emit(_ event: CodexAppServerInbound) {
        continuation.yield(event)
    }

    func waitUntilPaused() async {
        if didPause { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func releasePausedOperation() {
        pausedContinuation?.resume()
        pausedContinuation = nil
    }

    private func pauseIfRequested(_ operation: String) async {
        guard pauseAtOperation == operation else { return }
        await withCheckedContinuation { continuation in
            pausedContinuation = continuation
            didPause = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
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
            "model_provider = \"openai\"",
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
            "[skills]",
            "include_instructions = false",
            "[skills.bundled]",
            "enabled = false",
        ] {
            #expect(config.contains(required))
        }
        #expect(config.contains("[features]\nshell_tool = false"))
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

    @Test("effective system, managed, MCP, and skill layers fail before a thread")
    func isolationInventoryIsValidated() throws {
        let home = URL(fileURLWithPath: "/isolated/codex")
        let scratch = URL(fileURLWithPath: "/isolated/scratch")
        let cleanConfig: [String: Any] = [
            "layers": [
                [
                    "name": ["type": "packagedDefaults", "file": "/bin/codex"],
                    "config": [:],
                    "version": "1",
                ],
                [
                    "name": ["type": "system", "file": "/etc/codex/config.toml"],
                    "config": [:],
                    "version": "1",
                ],
                [
                    "name": [
                        "type": "user",
                        "file": home.appendingPathComponent("config.toml").path,
                        "profile": NSNull(),
                    ],
                    "config": CodexAppServerContract.isolatedConfigurationLayer,
                    "version": "1",
                ],
            ],
            "config": [
                "approval_policy": "never",
                "sandbox_mode": "read-only",
                "web_search": "disabled",
                "model_provider": "openai",
                "skills": [
                    "include_instructions": false,
                    "bundled": ["enabled": false],
                ] as [String: Any],
            ],
            "origins": [
                "approval_policy": [
                    "name": [
                        "type": "user",
                        "file": home.appendingPathComponent("config.toml").path,
                    ],
                    "version": "1",
                ],
            ],
        ]
        let requirements: [String: Any] = ["requirements": NSNull()]
        let mcp: [String: Any] = ["data": [], "nextCursor": NSNull()]
        let skills: [String: Any] = [
            "data": [["cwd": scratch.path, "skills": [], "errors": []]],
        ]

        try CodexAppServerContract.validateIsolation(
            configResponse: cleanConfig,
            requirementsResponse: requirements,
            mcpResponse: mcp,
            skillsResponse: skills,
            home: home,
            scratch: scratch
        )

        var hostileConfig = cleanConfig
        var hostileLayers = try #require(hostileConfig["layers"] as? [[String: Any]])
        hostileLayers[1]["config"] = [
            "mcp_servers": ["foreign": ["command": "/usr/bin/touch"]],
        ]
        hostileConfig["layers"] = hostileLayers
        #expect(throws: CodexAppServerError.self) {
            try CodexAppServerContract.validateIsolation(
                configResponse: hostileConfig,
                requirementsResponse: requirements,
                mcpResponse: mcp,
                skillsResponse: skills,
                home: home,
                scratch: scratch
            )
        }
        #expect(throws: CodexAppServerError.self) {
            try CodexAppServerContract.validateIsolation(
                configResponse: cleanConfig,
                requirementsResponse: requirements,
                mcpResponse: ["data": [["name": "foreign"]]],
                skillsResponse: skills,
                home: home,
                scratch: scratch
            )
        }
    }

    @Test("runtime scratch rejects a Git ancestor instead of trusting a disabled project layer")
    func scratchRootMustNotInheritProjectConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ngv-codex-git-ancestor-\(UUID().uuidString)",
            isDirectory: true
        )
        let nested = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: CodexAppServerError.self) {
            try CodexAppServerRuntimeAdapter.requireUnversionedScratchRoot(
                nested,
                fileManager: .default
            )
        }
    }

    @Test("runtime scratch walk terminates at the root without a Git ancestor")
    func scratchRootWithoutGitAncestorTerminates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ngv-codex-clean-ancestor-\(UUID().uuidString)",
            isDirectory: true
        )
        let nested = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try CodexAppServerRuntimeAdapter.requireUnversionedScratchRoot(
            nested,
            fileManager: .default
        )
    }

    @Test("the production location selector checks the actual temporary root")
    func liveLocationsSelectAnUnversionedScratchRoot() throws {
        let session = sessionRequest(sessionID: UUID())
        let locations = try CodexAppServerRuntimeAdapter.liveLocations(session)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()

        #expect(locations.scratch.deletingLastPathComponent() == temporaryRoot)
        #expect(locations.scratch.lastPathComponent.contains(session.runtimeGenerationID.uuidString))
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

    @Test("dialog or spend suspension replays the authoritative host result on a fresh thread")
    func hostSuspensionReplaysResultWithoutRepeatingTool() async throws {
        let driver = FakeCodexAppServerDriver()
        var executions = 0
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
            .request(id: 2, method: "item/tool/call", params: [
                "threadId": "thread-1",
                "turnId": "provider-turn-1",
                "callId": "dialog-2",
                "namespace": "nexgen",
                "tool": "host_tool",
                "arguments": [:],
            ]),
        ]
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.start(sessionRequest(sessionID: sessionID) { _, _, _ in
            executions += 1
            return .suspended("Decision opened")
        })
        let current = AgentRuntimeMessage(role: .user, content: [.text("Ask")])
        let events = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))

        #expect(driver.responses.count == 1)
        #expect(executions == 1)
        #expect(driver.operations.filter { $0 == "respond" }.isEmpty)
        #expect(driver.operations.filter { $0 == "respond:error" }.count == 1)
        #expect(driver.operations.contains("request:turn/interrupt"))
        #expect(events.map(\.event).contains(.providerSessionInvalidated))
        #expect(codexTerminals(events) == [.completed(.toolUse)])

        let replayDriver = FakeCodexAppServerDriver()
        replayDriver.scriptedEvents = [.notification(method: "turn/completed", params: [
            "threadId": "thread-1",
            "turn": ["id": "provider-turn-1", "status": "completed", "items": []],
        ])]
        let replayAdapter = makeAdapter(replayDriver)
        try replayAdapter.resume(sessionRequest(sessionID: sessionID) { _, _, _ in
            executions += 1
            return .error("A replayed tool call must not execute again")
        })
        let earlierAssistant = AgentRuntimeMessage(role: .assistant, content: [
            .toolUse(id: "dialog-1", name: "host_tool", inputJSON: "{}"),
        ])
        let authoritativeResult = AgentRuntimeMessage(role: .user, content: [
            .toolResult(id: "dialog-1", content: [.text("Decision opened")], isError: false),
        ])
        let followUp = AgentRuntimeMessage(role: .user, content: [.text("Continue after the decision")])
        let replayEvents = await collectCodexEvents(try replayAdapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current, earlierAssistant, authoritativeResult, followUp],
            currentMessage: followUp
        )))

        let injection = try #require(replayDriver.calls.first { $0.method == "thread/injectItems" })
        let items = try #require(injection.params["items"] as? [[String: Any]])
        let output = try #require(items.first { $0["type"] as? String == "function_call_output" })
        #expect(output["call_id"] as? String == "dialog-1")
        #expect(output["name"] as? String == "host_tool")
        #expect(output["namespace"] as? String == CodexAppServerContract.toolNamespace)
        let blocks = try #require(output["output"] as? [[String: Any]])
        #expect(blocks.contains { $0["text"] as? String == "Decision opened" })
        #expect(executions == 1)
        #expect(codexTerminals(replayEvents) == [.completed(.endTurn)])
    }

    @Test("Codex reaches AgentService, ToolExecutor, and the real dialog suspension consumer")
    func productConsumerOwnsDialogSuspension() async throws {
        let firstDriver = FakeCodexAppServerDriver()
        firstDriver.scriptedEvents = [
            .notification(method: "turn/started", params: [
                "threadId": "thread-1",
                "turn": ["id": "provider-turn-1", "status": "inProgress", "items": []],
            ]),
            .request(id: 7, method: "item/tool/call", params: [
                "threadId": "thread-1",
                "turnId": "provider-turn-1",
                "callId": "dialog-1",
                "namespace": "nexgen",
                "tool": "show_dialog",
                "arguments": [
                    "title": "Choose",
                    "sections": [[
                        "id": "choice",
                        "label": "Choice",
                        "type": "choices",
                        "options": [
                            ["id": "continue", "label": "Continue"],
                            ["id": "revise", "label": "Revise"],
                        ],
                    ]],
                ],
            ]),
        ]
        let followUpDriver = FakeCodexAppServerDriver()
        followUpDriver.scriptedEvents = [
            .notification(method: "item/agentMessage/delta", params: [
                "threadId": "thread-1",
                "turnId": "provider-turn-1",
                "itemId": "message-2",
                "delta": "The host recorded Continue.",
            ]),
            .notification(method: "turn/completed", params: [
                "threadId": "thread-1",
                "turn": ["id": "provider-turn-1", "status": "completed", "items": []],
            ]),
        ]
        let adapters = [makeAdapter(firstDriver), makeAdapter(followUpDriver)]
        var adapterIndex = 0
        let service = AgentService(
            backend: .codexAppServer,
            refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in
                let adapter = adapters[adapterIndex]
                adapterIndex += 1
                return adapter
            },
            runtimeReadinessOverride: { nil },
            runtimeHostContextOverride: { .hostOwned(tools: ToolDefinitions.all) }
        )
        let editor = EditorViewModel(agentService: service)
        service.editor = editor
        service.loadSessions(from: nil)

        #expect(service.send(text: "Ask for the choice.", mentions: []))
        var deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while service.isStreaming, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(!service.isStreaming)
        let dialog = try #require(service.pendingDialog)
        #expect(dialog.title == "Choose")
        #expect(firstDriver.operations.contains("request:turn/interrupt"))
        #expect(firstDriver.operations.filter { $0 == "respond" }.isEmpty)
        service.submitDialog(
            dialog,
            result: AgentDialogResult(
                selectedLabels: ["choice": ["Continue"]],
                toggles: [:],
                direction: ""
            )
        )
        deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while service.isStreaming, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!service.isStreaming)

        let injection = try #require(followUpDriver.calls.first { $0.method == "thread/injectItems" })
        let items = try #require(injection.params["items"] as? [[String: Any]])
        let replayedResult = try #require(items.first {
            $0["type"] as? String == "function_call_output"
        })
        let output = try #require(replayedResult["output"] as? [[String: Any]])
        #expect(output.contains {
            ($0["text"] as? String)?.localizedCaseInsensitiveContains("dialog") == true
        })
        let dialogCalls = service.messages.flatMap(\.blocks).filter {
            guard case .toolUse(_, let name, _) = $0 else { return false }
            return name == "show_dialog"
        }
        #expect(dialogCalls.count == 1)
        #expect(service.messages.contains { message in
            message.blocks.contains {
                guard case .text(let value) = $0 else { return false }
                return value.contains("host recorded Continue")
            }
        })
        service.cancel()
    }

    @Test("Codex suspension reaches the real spend approval consumer")
    func productConsumerOwnsSpendSuspension() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.scriptedEvents = [
            .notification(method: "turn/started", params: [
                "threadId": "thread-1",
                "turn": ["id": "provider-turn-1", "status": "inProgress", "items": []],
            ]),
            .request(id: 8, method: "item/tool/call", params: [
                "threadId": "thread-1",
                "turnId": "provider-turn-1",
                "callId": "spend-1",
                "namespace": "nexgen",
                "tool": "host_tool",
                "arguments": [:],
            ]),
        ]
        var followUps: [String] = []
        let service = AgentService(
            backend: .codexAppServer,
            refreshBackendStatusOnInit: false,
            embeddedHostFollowUpSender: { text, _ in
                followUps.append(text)
                return true
            },
            runtimeReadinessOverride: { nil }
        )
        let editor = EditorViewModel(agentService: service)
        service.editor = editor
        service.loadSessions(from: nil)
        let sessionID = try #require(service.currentSessionId)
        let option = SpendOption(
            modelId: "acceptance-model",
            modelName: "Acceptance Model",
            target: ResolvedGenerationTarget(
                modelId: "acceptance-model",
                provider: .fal,
                endpoint: "acceptance-model",
                binding: nil
            ),
            credits: 1,
            requiresCatalogAvailability: false
        )
        let adapter = makeAdapter(driver)
        var providerGenerationCalls = 0
        try adapter.start(sessionRequest(sessionID: sessionID) { _, _, _ in
            do {
                return try service.requestSpendApproval(
                    SpendApproval(
                        id: "spend-approval",
                        recommendedOptionId: option.id,
                        options: [option],
                        actionLabel: "Generate image"
                    ),
                    origin: .inAppChat(sessionID: sessionID),
                    editor: editor,
                    execute: { _, _ in
                        providerGenerationCalls += 1
                        return .ok("unexpected")
                    }
                )
            } catch {
                return .error(error.localizedDescription)
            }
        })
        let current = AgentRuntimeMessage(role: .user, content: [.text("Prepare the spend decision")])
        let events = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))

        #expect(service.pendingSpendApproval?.id == "spend-approval")
        #expect(driver.operations.contains("request:turn/interrupt"))
        #expect(codexTerminals(events) == [.completed(.toolUse)])
        service.declineSpend(reason: "Acceptance fixture declined before provider execution.")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while followUps.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let declinedWithoutGeneration = providerGenerationCalls == 0
            && service.pendingSpendApproval == nil
            && followUps.count == 1
            && followUps[0].contains("declined before provider execution")
        #expect(declinedWithoutGeneration)
        if let evidencePath = ProcessInfo.processInfo.environment["NGV_CODEX_ACCEPTANCE_EVIDENCE"] {
            try mergeLiveEvidence([
                "spend_consumer_declined_without_provider_generation": declinedWithoutGeneration,
                "spend_consumer_evidence_source": "deterministic_fake_driver",
                "provider_generation_calls": providerGenerationCalls,
            ], at: evidencePath)
        }
        service.cancel()
        adapter.end(sessionID: sessionID)
    }

    @Test("retrying runtime errors remain inside the provider turn")
    func retryingErrorIsNotFatal() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.scriptedEvents = [
            .notification(method: "error", params: [
                "threadId": "thread-1",
                "turnId": "provider-turn-1",
                "willRetry": true,
                "error": ["message": "temporary"],
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

        #expect(!events.contains { if case .error = $0.event { true } else { false } })
        #expect(codexTerminals(events) == [.completed(.endTurn)])
    }

    @Test("a failed adapter refuses another turn instead of opening an empty thread")
    func failedAdapterCannotRestartWithoutTranscriptReplay() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.scriptedEvents = [.notification(method: "future/unsafeEvent", params: [:])]
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.start(sessionRequest(sessionID: sessionID))
        let first = AgentRuntimeMessage(role: .user, content: [.text("First")])
        _ = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [first],
            currentMessage: first
        )))
        let second = AgentRuntimeMessage(role: .user, content: [.text("Second")])

        #expect(throws: AgentRuntimeContractError.sessionNotStarted) {
            try adapter.send(.init(
                sessionID: sessionID,
                turnID: UUID(),
                messages: [first, second],
                currentMessage: second
            ))
        }
        #expect(driver.calls.filter { $0.method == "thread/start" }.count == 1)
    }

    @Test("resume opens an isolated ephemeral thread and replays canonical history")
    func transcriptReplayPreservesContextAndRefreshesHostInstructions() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.scriptedEvents = [.notification(method: "turn/completed", params: [
            "threadId": "thread-1",
            "turn": ["id": "provider-turn-1", "status": "completed", "items": []],
        ])]
        let sessionID = UUID()
        let adapter = makeAdapter(driver)
        try adapter.resume(sessionRequest(sessionID: sessionID))
        let earlierUser = AgentRuntimeMessage(role: .user, content: [.text("Earlier")])
        let earlierAssistant = AgentRuntimeMessage(role: .assistant, content: [
            .text("Answer"),
            .toolUse(id: "call-1", name: "host_tool", inputJSON: #"{"value":"safe"}"#),
        ])
        let earlierResult = AgentRuntimeMessage(role: .user, content: [
            .toolResult(id: "call-1", content: [.text("done")], isError: false),
        ])
        let current = AgentRuntimeMessage(role: .user, content: [.text("Continue")])
        let events = await collectCodexEvents(try adapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [earlierUser, earlierAssistant, earlierResult, current],
            currentMessage: current
        )))

        let replay = try #require(driver.calls.first { $0.method == "thread/injectItems" })
        let items = try #require(replay.params["items"] as? [[String: Any]])
        #expect(items.contains { $0["type"] as? String == "function_call" })
        #expect(items.contains { $0["type"] as? String == "function_call_output" })
        let start = try #require(driver.calls.first { $0.method == "thread/start" })
        #expect((start.params["baseInstructions"] as? String)?.contains("Current phase: story") == true)
        #expect((start.params["baseInstructions"] as? String)?.contains("PHASE INSTRUCTIONS") == true)
        #expect((start.params["developerInstructions"] as? String)?.contains("de-DE") == true)
        let turn = try #require(driver.calls.first { $0.method == "turn/start" })
        let input = try #require(turn.params["input"] as? [[String: Any]])
        #expect(input.first?["text"] as? String == "Continue")
        #expect(codexTerminals(events) == [.completed(.endTurn)])
    }

    @Test("informative warnings and events from an old turn do not abort the active turn")
    func informationalAndStaleNotificationsAreIgnored() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.scriptedEvents = [
            .notification(method: "configWarning", params: ["summary": "disabled feature"]),
            .notification(method: "warning", params: ["message": "notice"]),
            .notification(method: "deprecationNotice", params: ["summary": "notice"]),
            .notification(method: "future/oldEvent", params: [
                "threadId": "thread-1",
                "turn": ["id": "old-turn"],
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

        #expect(codexTerminals(events) == [.completed(.endTurn)])
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
        let retry = AgentRuntimeMessage(role: .user, content: [.text("Retry")])
        #expect(throws: AgentRuntimeContractError.sessionNotStarted) {
            try adapter.send(.init(
                sessionID: sessionID,
                turnID: UUID(),
                messages: [current, retry],
                currentMessage: retry
            ))
        }
    }

    @Test("cancel during startup, thread open, or replay prevents a new paid turn")
    func cancellationBeforeTurnSubmissionStopsFurtherMutations() async throws {
        for operation in ["start", "request:thread/start", "request:thread/injectItems"] {
            let driver = FakeCodexAppServerDriver()
            driver.pauseAtOperation = operation
            let sessionID = UUID()
            let adapter = makeAdapter(driver)
            let isReplay = operation == "request:thread/injectItems"
            let session = sessionRequest(sessionID: sessionID)
            if isReplay {
                try adapter.resume(session)
            } else {
                try adapter.start(session)
            }
            let previous = AgentRuntimeMessage(role: .user, content: [.text("Earlier")])
            let current = AgentRuntimeMessage(role: .user, content: [.text("Continue")])
            let stream = try adapter.send(.init(
                sessionID: sessionID,
                turnID: UUID(),
                messages: isReplay ? [previous, current] : [current],
                currentMessage: current
            ))

            await driver.waitUntilPaused()
            adapter.cancel(sessionID: sessionID)
            driver.releasePausedOperation()
            let events = await collectCodexEvents(stream)
            let expectedRequests: [String]
            switch operation {
            case "start": expectedRequests = []
            case "request:thread/start": expectedRequests = ["thread/start"]
            default: expectedRequests = ["thread/start", "thread/injectItems"]
            }

            #expect(driver.calls.map(\.method) == expectedRequests)
            #expect(driver.stopCount == 1)
            #expect(codexTerminals(events) == [.cancelled])
        }
    }

    @Test("cancel after turn submission interrupts its returned provider ID")
    func cancellationWaitsForSubmittedTurnIdentifier() async throws {
        let driver = FakeCodexAppServerDriver()
        driver.pauseAtOperation = "request:turn/start"
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

        await driver.waitUntilPaused()
        adapter.cancel(sessionID: sessionID)
        #expect(driver.stopCount == 0)
        driver.releasePausedOperation()
        let events = await collectCodexEvents(stream)
        let interrupt = try #require(driver.calls.first { $0.method == "turn/interrupt" })
        let stopDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while driver.stopCount == 0, ContinuousClock.now < stopDeadline {
            await Task.yield()
        }

        #expect(interrupt.params["threadId"] as? String == "thread-1")
        #expect(interrupt.params["turnId"] as? String == "provider-turn-1")
        #expect(driver.stopCount == 1)
        #expect(codexTerminals(events) == [.cancelled])
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
