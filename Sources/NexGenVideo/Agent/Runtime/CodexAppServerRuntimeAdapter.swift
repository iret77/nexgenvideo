import Foundation

@MainActor
final class CodexAppServerRuntimeAdapter: AgentRuntimeAdapter {
    typealias DriverFactory = @MainActor () -> any CodexAppServerDriving
    typealias RuntimeLocations = @MainActor (_ session: AgentRuntimeSessionRequest) throws -> (home: URL, scratch: URL)

    private let driverFactory: DriverFactory
    private let runtimeLocations: RuntimeLocations
    private var session: AgentRuntimeSessionRequest?
    private var driver: (any CodexAppServerDriving)?
    private var activeRelay: AgentRuntimeEventRelay?
    private var activeTask: Task<Void, Never>?
    private var activeTurnID: UUID?
    private var providerThreadID: String?
    private var providerTurnID: String?

    private(set) var descriptor: AgentRuntimeDescriptor
    private(set) var state: AgentRuntimeState = .idle

    init(
        driverFactory: DriverFactory? = nil,
        runtimeLocations: RuntimeLocations? = nil
    ) {
        self.driverFactory = driverFactory ?? { CodexAppServerJSONRPCDriver() }
        self.runtimeLocations = runtimeLocations ?? Self.liveLocations
        descriptor = AgentBackend.codexAppServer.runtimeDescriptor(toolNames: [])
    }

    func start(_ request: AgentRuntimeSessionRequest) throws {
        guard request.providerSessionID == nil else {
            throw CodexAppServerError.resumeIsolationUnavailable
        }
        try configure(request)
    }

    func resume(_ request: AgentRuntimeSessionRequest) throws {
        throw CodexAppServerError.resumeIsolationUnavailable
    }

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
        activeTask = Task { [weak self] in
            await self?.run(request: request, session: session, relay: relay)
        }
        return relay.stream
    }

    func cancel(sessionID: UUID) {
        guard session?.sessionID == sessionID else { return }
        if let relay = activeRelay, let activeTurnID {
            state = .cancelling(sessionID: sessionID, turnID: activeTurnID)
            relay.finish(.cancelled)
        }
        let driver = self.driver
        let threadID = providerThreadID
        let turnID = providerTurnID
        Task { @MainActor in
            if let driver, let threadID, let turnID {
                _ = try? await driver.request(
                    method: "turn/interrupt",
                    params: ["threadId": threadID, "turnId": turnID]
                )
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            driver?.stop()
        }
        activeTask?.cancel()
        activeTask = nil
        self.driver = nil
        activeRelay = nil
        activeTurnID = nil
        providerTurnID = nil
        state = .ready(sessionID: sessionID)
    }

    func end(sessionID: UUID) {
        guard session?.sessionID == sessionID else { return }
        cancel(sessionID: sessionID)
        session = nil
        providerThreadID = nil
        state = .ended(sessionID: sessionID)
    }

    private func configure(_ request: AgentRuntimeSessionRequest) throws {
        if let activeRelay, activeRelay.terminal == nil {
            throw AgentRuntimeContractError.turnAlreadyRunning
        }
        driver?.stop()
        driver = nil
        session = request
        providerThreadID = request.providerSessionID
        providerTurnID = nil
        descriptor = AgentBackend.codexAppServer.runtimeDescriptor(
            toolNames: Set(request.hostContext.toolSchemas.map(\.name))
        )
        state = .ready(sessionID: request.sessionID)
    }

    private func run(
        request: AgentRuntimeTurnRequest,
        session: AgentRuntimeSessionRequest,
        relay: AgentRuntimeEventRelay
    ) async {
        let generationID = session.runtimeGenerationID
        do {
            let locations = try runtimeLocations(session)
            let driver: any CodexAppServerDriving
            let threadID: String
            if let existingDriver = self.driver, let existingThread = providerThreadID {
                driver = existingDriver
                threadID = existingThread
            } else {
                driver = driverFactory()
                guard isCurrent(session: session, request: request, relay: relay) else { return }
                self.driver = driver
                try await driver.start(home: locations.home, scratch: locations.scratch)
                try Task.checkCancellation()
                guard isCurrent(session: session, request: request, relay: relay),
                      self.session?.runtimeGenerationID == generationID else { return }
                updateAuthentication(driver.accountStatus)

                threadID = try await openThread(
                    driver: driver,
                    session: session,
                    scratch: locations.scratch
                )
                try Task.checkCancellation()
                guard isCurrent(session: session, request: request, relay: relay),
                      self.session?.runtimeGenerationID == generationID else { return }
                providerThreadID = threadID
                relay.yield(.providerSessionStarted(threadID))
            }

            let response = try await driver.request(method: "turn/start", params: [
                "threadId": threadID,
                "input": Self.input(request.currentMessage),
                "cwd": locations.scratch.path,
            ])
            guard let turn = response["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else {
                throw CodexAppServerError.malformedMessage
            }
            guard isCurrent(session: session, request: request, relay: relay) else { return }
            providerTurnID = turnID
            let eventTask = Task { [weak self] in
                guard let self else { return }
                for await inbound in driver.events {
                    await self.receive(
                        inbound,
                        driver: driver,
                        session: session,
                        request: request,
                        relay: relay
                    )
                    if relay.terminal != nil { break }
                }
            }
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: CodexAppServerContract.turnTimeout)
                guard !Task.isCancelled, let self else { return }
                self.protocolFailure("Codex turn timed out.", request: request, relay: relay)
            }
            await eventTask.value
            timeout.cancel()
            if relay.terminal == nil {
                throw CodexAppServerError.transportClosed
            }
        } catch is CancellationError {
            relay.finish(.cancelled)
        } catch {
            guard isCurrent(session: session, request: request, relay: relay) else { return }
            fail(Self.failure(error), sessionID: request.sessionID, relay: relay)
        }
        if activeRelay === relay {
            activeRelay = nil
            activeTask = nil
            activeTurnID = nil
            providerTurnID = nil
        }
    }

    private func openThread(
        driver: any CodexAppServerDriving,
        session: AgentRuntimeSessionRequest,
        scratch: URL
    ) async throws -> String {
        let common: [String: Any] = [
            "cwd": scratch.path,
            "runtimeWorkspaceRoots": [],
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "baseInstructions": session.hostContext.systemInstructions,
            "developerInstructions": Self.developerInstructions(for: session.hostContext),
            "config": Self.turnConfiguration,
        ]
        var params = common
        params["ephemeral"] = true
        params["allowProviderModelFallback"] = false
        params["environments"] = []
        params["dynamicTools"] = [Self.dynamicToolNamespace(session.hostContext.toolSchemas)]
        let response = try await driver.request(method: "thread/start", params: params)
        guard let thread = response["thread"] as? [String: Any],
              let threadID = thread["id"] as? String,
              response["cwd"] as? String == scratch.path else {
            throw CodexAppServerError.malformedMessage
        }
        let instructionSources = response["instructionSources"] as? [Any] ?? []
        guard instructionSources.isEmpty else {
            throw CodexAppServerError.remote(code: -32_001, message: "Inherited instructions are forbidden")
        }
        if let roots = response["runtimeWorkspaceRoots"] as? [Any], !roots.isEmpty {
            throw CodexAppServerError.remote(code: -32_001, message: "Runtime workspace access is forbidden")
        }
        return threadID
    }

    private func receive(
        _ inbound: CodexAppServerInbound,
        driver: any CodexAppServerDriving,
        session: AgentRuntimeSessionRequest,
        request: AgentRuntimeTurnRequest,
        relay: AgentRuntimeEventRelay
    ) async {
        guard isCurrent(session: session, request: request, relay: relay) else { return }
        switch inbound {
        case .closed(let error):
            fail(Self.failure(error), sessionID: request.sessionID, relay: relay)
        case .request(let id, let method, let params):
            if let inboundThreadID = params["threadId"] as? String,
               inboundThreadID != providerThreadID {
                try? driver.respond(id: id, errorCode: -32_602, message: "Stale host tool request")
                return
            }
            guard method == "item/tool/call" else {
                try? driver.respond(id: id, errorCode: -32_601, message: "Unsupported server request")
                protocolFailure("Codex requested a forbidden capability: \(method)", request: request, relay: relay)
                return
            }
            await executeTool(
                id: id,
                params: params,
                driver: driver,
                session: session,
                request: request,
                relay: relay
            )
        case .notification(let method, let params):
            receiveNotification(method: method, params: params, request: request, relay: relay)
        }
    }

    private func executeTool(
        id responseID: Any,
        params: [String: Any],
        driver: any CodexAppServerDriving,
        session: AgentRuntimeSessionRequest,
        request: AgentRuntimeTurnRequest,
        relay: AgentRuntimeEventRelay
    ) async {
        guard matchesThread(params) else {
            try? driver.respond(id: responseID, errorCode: -32_602, message: "Stale host tool request")
            return
        }
        guard params["turnId"] as? String == providerTurnID else {
            try? driver.respond(id: responseID, errorCode: -32_602, message: "Stale host tool request")
            return
        }
        guard params["namespace"] as? String == CodexAppServerContract.toolNamespace,
              let callID = params["callId"] as? String,
              let name = params["tool"] as? String,
              session.hostContext.toolSchemas.contains(where: { $0.name == name }),
              let arguments = params["arguments"],
              JSONSerialization.isValidJSONObject(arguments),
              let input = try? JSONSerialization.data(withJSONObject: arguments),
              let inputJSON = String(data: input, encoding: .utf8) else {
            try? driver.respond(id: responseID, errorCode: -32_602, message: "Invalid host tool request")
            protocolFailure("Codex requested an invalid host tool.", request: request, relay: relay)
            return
        }
        relay.yield(.toolCall(messageID: nil, id: callID, name: name, inputJSON: inputJSON))
        let result = await session.executeTool(callID, name, inputJSON)
        guard isCurrent(session: session, request: request, relay: relay),
              matchesActiveProviderTurn(params) else { return }
        relay.yield(.toolResult(id: callID, content: result.content, isError: result.isError))
        do {
            try driver.respond(id: responseID, result: [
                "contentItems": Self.contentItems(result.content),
                "success": !result.isError,
            ])
        } catch {
            fail(Self.failure(error), sessionID: request.sessionID, relay: relay)
            return
        }
        if result.turnDisposition == .suspendTurn {
            relay.finish(.completed(.toolUse))
            if let threadID = providerThreadID, let turnID = providerTurnID {
                Task { @MainActor in
                    _ = try? await driver.request(
                        method: "turn/interrupt",
                        params: ["threadId": threadID, "turnId": turnID]
                    )
                }
            }
            setStateIfActive(.ready(sessionID: request.sessionID), relay: relay)
        }
    }

    private func receiveNotification(
        method: String,
        params: [String: Any],
        request: AgentRuntimeTurnRequest,
        relay: AgentRuntimeEventRelay
    ) {
        if let inboundThreadID = params["threadId"] as? String,
           inboundThreadID != providerThreadID {
            return
        }
        switch method {
        case "thread/started", "thread/status/changed", "account/rateLimits/updated", "account/updated",
             "model/safetyBuffering/updated", "model/verification":
            break
        case "turn/started":
            guard matchesThread(params),
                  let turn = params["turn"] as? [String: Any],
                  turn["id"] as? String == providerTurnID else { return }
        case "thread/name/updated":
            guard matchesThread(params) else { return }
        case "serverRequest/resolved":
            guard matchesThread(params) else { return }
        case "thread/compacted", "turn/moderationMetadata":
            guard matchesActiveProviderTurn(params) else { return }
        case "item/reasoning/summaryPartAdded", "item/reasoning/summaryTextDelta",
             "item/reasoning/textDelta":
            guard matchesActiveProviderTurn(params) else { return }
        case "item/agentMessage/delta":
            guard matchesActiveProviderTurn(params),
                  let value = params["delta"] as? String else { return }
            relay.yield(.text(
                messageID: params["itemId"] as? String,
                value: value,
                isDelta: true
            ))
        case "thread/tokenUsage/updated":
            guard matchesActiveProviderTurn(params),
                  let usage = params["tokenUsage"] as? [String: Any],
                  let last = usage["last"] as? [String: Any] else { return }
            relay.yield(.usage(.init(
                inputTokens: Self.int(last["inputTokens"]),
                outputTokens: Self.int(last["outputTokens"]),
                cacheReadInputTokens: Self.int(last["cachedInputTokens"]),
                cacheCreationInputTokens: Self.int(last["cacheWriteInputTokens"])
            )))
        case "item/started", "item/completed":
            guard matchesActiveProviderTurn(params),
                  let item = params["item"] as? [String: Any],
                  let type = item["type"] as? String else { return }
            let allowed = [
                "userMessage", "agentMessage", "reasoning", "dynamicToolCall",
                "functionCallOutput", "contextCompaction",
            ]
            guard allowed.contains(type) else {
                protocolFailure("Codex exposed a forbidden \(type) capability.", request: request, relay: relay)
                return
            }
        case "turn/completed":
            guard matchesThread(params),
                  let turn = params["turn"] as? [String: Any],
                  turn["id"] as? String == providerTurnID,
                  let status = turn["status"] as? String else { return }
            switch status {
            case "completed":
                relay.finish(.completed(.endTurn))
                setStateIfActive(.ready(sessionID: request.sessionID), relay: relay)
            case "interrupted":
                relay.finish(.cancelled)
                setStateIfActive(.ready(sessionID: request.sessionID), relay: relay)
            default:
                runtimeFailure(
                    turn["error"] as? [String: Any],
                    fallback: "Codex turn ended with status \(status).",
                    request: request,
                    relay: relay
                )
            }
        case "error":
            guard matchesActiveProviderTurn(params) else { return }
            runtimeFailure(
                params["error"] as? [String: Any],
                fallback: "Codex reported a runtime error.",
                request: request,
                relay: relay
            )
        default:
            protocolFailure("Codex emitted an unsupported protocol event: \(method)", request: request, relay: relay)
        }
    }

    private func protocolFailure(
        _ message: String,
        request: AgentRuntimeTurnRequest,
        relay: AgentRuntimeEventRelay
    ) {
        fail(.init(kind: .protocolViolation, message: message), sessionID: request.sessionID, relay: relay)
    }

    private func runtimeFailure(
        _ details: [String: Any]?,
        fallback: String,
        request: AgentRuntimeTurnRequest,
        relay: AgentRuntimeEventRelay
    ) {
        let authenticationRequired = details?["codexErrorInfo"] as? String == "unauthorized"
        let failure = AgentRuntimeFailure(
            kind: authenticationRequired ? .authenticationRequired : .transport,
            message: authenticationRequired
                ? CodexAppServerError.authenticationRequired.localizedDescription
                : (details?["message"] as? String ?? fallback)
        )
        fail(failure, sessionID: request.sessionID, relay: relay)
    }

    private func fail(
        _ failure: AgentRuntimeFailure,
        sessionID: UUID,
        relay: AgentRuntimeEventRelay
    ) {
        guard relay.terminal == nil else { return }
        relay.yield(.error(failure))
        relay.finish(.failed)
        driver?.stop()
        driver = nil
        setStateIfActive(.failed(sessionID: sessionID, message: failure.message), relay: relay)
    }

    private func setStateIfActive(_ value: AgentRuntimeState, relay: AgentRuntimeEventRelay) {
        guard activeRelay === relay else { return }
        state = value
    }

    private func updateAuthentication(_ account: CodexAppServerAccountStatus?) {
        guard let account else { return }
        let authentication: AgentRuntimeAuthentication
        switch account.billing {
        case .apiKey:
            authentication = .apiKey(service: "OpenAI via isolated Codex")
        case .chatGPT(let plan):
            authentication = .isolatedExternalAccount(command: "Codex ChatGPT \(plan)")
        case .amazonBedrock(let managed):
            authentication = .isolatedExternalAccount(
                command: managed ? "Codex managed Amazon Bedrock" : "Amazon Bedrock"
            )
        }
        descriptor = AgentRuntimeDescriptor(
            identity: descriptor.identity,
            authentication: authentication,
            capabilities: descriptor.capabilities,
            toolExecutionTransport: descriptor.toolExecutionTransport
        )
    }

    private func isCurrent(
        session: AgentRuntimeSessionRequest,
        request: AgentRuntimeTurnRequest,
        relay: AgentRuntimeEventRelay
    ) -> Bool {
        self.session?.sessionID == session.sessionID
            && self.session?.runtimeGenerationID == session.runtimeGenerationID
            && activeRelay === relay
            && activeTurnID == request.turnID
            && relay.terminal == nil
    }

    private func matchesThread(_ params: [String: Any]) -> Bool {
        params["threadId"] as? String == providerThreadID
    }

    private func matchesActiveProviderTurn(_ params: [String: Any]) -> Bool {
        matchesThread(params) && params["turnId"] as? String == providerTurnID
    }

    private static func input(_ message: AgentRuntimeMessage) -> [[String: Any]] {
        message.content.compactMap { content in
            switch content {
            case .text(let value):
                ["type": "text", "text": value]
            case .image(let image):
                [
                    "type": "image",
                    "url": "data:\(image.mediaType);base64,\(image.base64)",
                ]
            case .toolUse, .toolResult:
                nil
            }
        }
    }

    private static func dynamicToolNamespace(_ schemas: [AgentRuntimeToolSchema]) -> [String: Any] {
        [
            "type": "namespace",
            "name": CodexAppServerContract.toolNamespace,
            "description": "NexGenVideo host tools. Every call is validated and executed by the host.",
            "tools": schemas.map {
                [
                    "type": "function",
                    "name": $0.name,
                    "description": $0.description,
                    "inputSchema": $0.inputSchema,
                    "deferLoading": false,
                ] as [String: Any]
            },
        ]
    }

    private static func contentItems(_ blocks: [ToolResult.Block]) -> [[String: Any]] {
        blocks.map { block in
            switch block {
            case .text(let value):
                ["type": "inputText", "text": value]
            case .image(let base64, let mediaType):
                ["type": "inputImage", "imageUrl": "data:\(mediaType);base64,\(base64)"]
            }
        }
    }

    private static var turnConfiguration: [String: Any] {
        [
            "approval_policy": "never",
            "sandbox_mode": "read-only",
            "web_search": "disabled",
            "tools": [
                "update_plan": ["enabled": false],
                "experimental_request_user_input": ["enabled": false],
            ],
            "features": [
                "shell_tool": false,
                "view_image": false,
                "sleep_tool": false,
                "unified_exec": false,
                "unified_exec_tty": false,
                "deferred_executor": false,
                "request_permissions_tool": false,
                "standalone_web_search": false,
                "hooks": false,
                "multi_agent": false,
                "apps": false,
                "enable_mcp_apps": false,
                "plugins": false,
                "image_generation": false,
                "send_message_to_user_async": false,
                "token_budget": false,
                "current_time_reminder": false,
                "realtime_conversation": false,
                "auth_elicitation": false,
                "tool_call_mcp_elicitation": false,
                "unbounded_connection_retries": false,
            ],
        ]
    }

    private static func developerInstructions(for context: AgentRuntimeHostContext) -> String {
        """
        Interface language: \(context.interfaceLanguage.instruction)
        Use only the host-provided \(CodexAppServerContract.toolNamespace) namespace. Audio and video are inspected through those host tools; they are not native model inputs. Host dialogs, spend approvals, output approvals, and pipeline gates remain host authority.
        """
    }

    private static func failure(_ error: Error) -> AgentRuntimeFailure {
        if let codex = error as? CodexAppServerError {
            switch codex {
            case .authenticationRequired:
                return .init(kind: .authenticationRequired, message: codex.localizedDescription)
            case .executableUnavailable, .incompatibleVersion, .resumeIsolationUnavailable:
                return .init(kind: .backendUnavailable, message: codex.localizedDescription)
            case .malformedMessage, .isolatedHomeMismatch:
                return .init(kind: .protocolViolation, message: codex.localizedDescription)
            case .remote, .requestTimedOut, .transportClosed, .launchFailed:
                return .init(kind: .transport, message: codex.localizedDescription)
            }
        }
        return .init(kind: .transport, message: error.localizedDescription)
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func liveLocations(
        _ session: AgentRuntimeSessionRequest
    ) throws -> (home: URL, scratch: URL) {
        let manager = FileManager.default
        guard let applicationSupport = manager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
              let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CodexAppServerError.launchFailed("Runtime directories are unavailable")
        }
        let home = applicationSupport
            .appendingPathComponent("NexGenVideo", isDirectory: true)
            .appendingPathComponent("CodexRuntime", isDirectory: true)
            .appendingPathComponent(CodexAppServerContract.cliVersion, isDirectory: true)
        let scratch = caches
            .appendingPathComponent("NexGenVideo", isDirectory: true)
            .appendingPathComponent("CodexRuntime", isDirectory: true)
            .appendingPathComponent(session.runtimeGenerationID.uuidString, isDirectory: true)
        return (home, scratch)
    }
}
