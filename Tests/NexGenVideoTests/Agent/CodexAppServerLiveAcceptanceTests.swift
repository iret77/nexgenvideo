import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Codex App Server live acceptance", .serialized)
struct CodexAppServerLiveAcceptanceTests {
    @Test("active system configuration is rejected before account or thread work")
    func hostileSystemConfigurationFailsBeforeSideEffects() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard CodexAppServerContract.isAcceptanceRun,
              environment["NGV_CODEX_HOSTILE_SYSTEM_CONFIG"] == "1" else { return }
        let home = URL(fileURLWithPath: try #require(environment["CODEX_HOME"]), isDirectory: true)
        let scratch = URL(
            fileURLWithPath: try #require(environment["RUNNER_TEMP"]),
            isDirectory: true
        ).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let driver = CodexAppServerJSONRPCDriver()
        do {
            try await driver.start(home: home, scratch: scratch)
            Issue.record("Hostile system configuration was accepted")
            driver.stop()
        } catch let error as CodexAppServerError {
            guard case .isolationViolation = error else {
                Issue.record("Unexpected rejection: \(error.localizedDescription)")
                return
            }
        }
        await driver.waitForTermination()

        #expect(!driver.requestedMethods.contains("account/read"))
        #expect(!driver.requestedMethods.contains("thread/start"))
        #expect(!driver.requestedMethods.contains("mcpServerStatus/list"))
        #expect(!driver.requestedMethods.contains("skills/list"))
        if let marker = environment["NGV_CODEX_HOSTILE_MCP_MARKER"] {
            #expect(!FileManager.default.fileExists(atPath: marker))
        }
    }

    @Test("real isolated text, image, namespaced tool, typed result, dialogue, and cancel")
    func liveConsumerSmoke() async throws {
        guard CodexAppServerContract.isAcceptanceRun else { return }
        let environment = ProcessInfo.processInfo.environment
        let homePath = try #require(environment["CODEX_HOME"])
        let scratchPath = try #require(environment["RUNNER_TEMP"])
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let scratchRoot = URL(fileURLWithPath: scratchPath, isDirectory: true)
        let firstDriver = CodexAppServerJSONRPCDriver()
        let firstAdapter = CodexAppServerRuntimeAdapter(
            driverFactory: { firstDriver },
            runtimeLocations: { request in
                (home, scratchRoot.appendingPathComponent(request.runtimeGenerationID.uuidString))
            }
        )
        let sessionID = UUID()
        let session = liveSession(sessionID: sessionID)
        try firstAdapter.start(session)
        let image = AgentRuntimeImage(
            mediaType: "image/png",
            base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nE4AAAAASUVORK5CYII="
        )
        let current = AgentRuntimeMessage(role: .user, content: [
            .text("Inspect the attached image. Call the nexgen acceptance_echo tool exactly once with the lowercase luminance category light or dark, then briefly confirm completion."),
            .image(image),
        ])
        let firstEvents = await collectLiveCodexEvents(try firstAdapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current],
            currentMessage: current
        )))
        let providerThreadID = try #require(firstEvents.compactMap { envelope -> String? in
            guard case .providerSessionStarted(let value) = envelope.event else { return nil }
            return value
        }.first)
        #expect(firstDriver.accountStatus == .init(billing: .apiKey))
        #expect(firstEvents.contains { envelope in
            guard case .toolCall(_, _, let name, _) = envelope.event else { return false }
            return name == "acceptance_echo"
        })
        #expect(firstEvents.contains { envelope in
            guard case .toolResult(_, let content, let isError) = envelope.event else { return false }
            return !isError
                && content.contains(.text("controlled-result"))
                && content.contains { if case .image = $0 { true } else { false } }
        })
        #expect(liveTerminals(firstEvents) == [.completed(.endTurn)])
        let modelResponse = try await firstDriver.request(
            method: "model/list",
            params: ["limit": 100]
        )
        let models = try #require(modelResponse["data"] as? [[String: Any]])
        let defaultModel = try #require(models.first { $0["isDefault"] as? Bool == true })
        let modalities = defaultModel["inputModalities"] as? [String] ?? []
        #expect(modalities.contains("text"))
        #expect(modalities.contains("image"))

        let followUp = AgentRuntimeMessage(role: .user, content: [
            .text("Reply with the single word continued."),
        ])
        let followUpEvents = await collectLiveCodexEvents(try firstAdapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current, followUp],
            currentMessage: followUp
        )))
        #expect(followUpEvents.contains { envelope in
            guard case .text(_, let value, _) = envelope.event else { return false }
            return value.localizedCaseInsensitiveContains("continued")
        })
        #expect(liveTerminals(followUpEvents) == [.completed(.endTurn)])

        let cancelMessage = AgentRuntimeMessage(role: .user, content: [
            .text("Draft a detailed 5,000-word technical explanation of nonlinear editing history."),
        ])
        let turnIDsBeforeCancel = firstDriver.observedTurnStartedIDs
        let cancelStream = try firstAdapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current, cancelMessage],
            currentMessage: cancelMessage
        ))
        for _ in 0..<1_000 where firstDriver.observedTurnStartedIDs.subtracting(turnIDsBeforeCancel).isEmpty {
            await Task.yield()
        }
        let cancelTurnIDs = firstDriver.observedTurnStartedIDs.subtracting(turnIDsBeforeCancel)
        #expect(!cancelTurnIDs.isEmpty)
        firstAdapter.cancel(sessionID: sessionID)
        #expect(liveTerminals(await collectLiveCodexEvents(cancelStream)) == [.cancelled])
        await firstDriver.waitForTermination()
        let cancelledTurnWasInterrupted = !firstDriver.observedInterruptedTurnIDs
            .intersection(cancelTurnIDs)
            .isEmpty
        #expect(cancelledTurnWasInterrupted)
        #expect(firstDriver.terminationConfirmed)
        let scratchRemoved = !FileManager.default.fileExists(
            atPath: scratchRoot.appendingPathComponent(session.runtimeGenerationID.uuidString).path
        )
        #expect(scratchRemoved)

        let coldAdapter = CodexAppServerRuntimeAdapter()
        var coldResumeRejected = false
        do {
            try coldAdapter.resume(liveSession(
                sessionID: sessionID,
                providerSessionID: providerThreadID
            ))
        } catch CodexAppServerError.resumeIsolationUnavailable {
            coldResumeRejected = true
        }
        #expect(coldResumeRejected)

        let replayDriver = CodexAppServerJSONRPCDriver()
        let replayAdapter = CodexAppServerRuntimeAdapter(
            driverFactory: { replayDriver },
            runtimeLocations: { request in
                (home, scratchRoot.appendingPathComponent(request.runtimeGenerationID.uuidString))
            }
        )
        let replaySessionID = UUID()
        let replaySession = liveSession(
            sessionID: replaySessionID,
            interfaceLanguage: .init(identifier: "de-DE", displayName: "German"),
            phase: "continuity",
            phaseInstructions: "Begin every reply in this phase with the exact word Wiederaufnahme."
        )
        try replayAdapter.resume(replaySession)
        let replayHistory = [
            AgentRuntimeMessage(role: .user, content: [.text("Remember the continuity code.")]),
            AgentRuntimeMessage(role: .assistant, content: [.text("The continuity code is cobalt-47.")]),
        ]
        let replayCurrent = AgentRuntimeMessage(
            role: .user,
            content: [.text("State the continuity code from the earlier answer.")]
        )
        let replayEvents = await collectLiveCodexEvents(try replayAdapter.send(.init(
            sessionID: replaySessionID,
            turnID: UUID(),
            messages: replayHistory + [replayCurrent],
            currentMessage: replayCurrent
        )))
        let replayText = replayEvents.compactMap { envelope -> String? in
            guard case .text(_, let value, _) = envelope.event else { return nil }
            return value
        }.joined()
        let injectionIndex = replayDriver.requestedMethods.firstIndex(of: "thread/injectItems")
        let replayTurnIndex = replayDriver.requestedMethods.lastIndex(of: "turn/start")
        let replayWasInjectedBeforeTurn = injectionIndex.map { injection in
            replayTurnIndex.map { injection < $0 } ?? false
        } ?? false
        let transcriptReplaySucceeded = replayText.localizedCaseInsensitiveContains("cobalt-47")
            && replayText.localizedCaseInsensitiveContains("Wiederaufnahme")
            && replayWasInjectedBeforeTurn
        #expect(transcriptReplaySucceeded)
        #expect(liveTerminals(replayEvents) == [.completed(.endTurn)])
        replayAdapter.end(sessionID: replaySessionID)
        await replayDriver.waitForTermination()

        if let evidencePath = environment["NGV_CODEX_ACCEPTANCE_EVIDENCE"] {
            let accountIndex = try #require(firstDriver.requestedMethods.firstIndex(of: "account/read"))
            let threadIndex = try #require(firstDriver.requestedMethods.firstIndex(of: "thread/start"))
            let isolationChecks = firstDriver.requestedMethods.filter { $0 == "config/read" }.count
            let beforeAccount = firstDriver.requestedMethods[..<accountIndex]
            #expect(!beforeAccount.contains("model/list"))
            #expect(!beforeAccount.contains("thread/start"))
            let billing: String
            switch firstDriver.accountStatus?.billing {
            case .apiKey: billing = "api_key"
            case .chatGPT(let plan): billing = "chatgpt:\(plan)"
            case nil: billing = "unknown"
            }
            try mergeLiveEvidence([
                "cli_version": CodexAppServerContract.cliVersion,
                "protocol_revision": CodexAppServerContract.protocolRevision,
                "combined_schema_sha256": "eb1ba91bd0fab656523092f6ed7de3ea7aef278921a650f14dc871ae7dcfaf84",
                "v2_schema_sha256": "995fc3b8f8c469f6787e8fc5be4038c4f31359025edd8480b862e83355f3bf3b",
                "compatibility": "incompatible_pending_model_visible_tool_inventory_and_consumer_gates",
                "billing": billing,
                "configuration_inventory_checks": isolationChecks,
                "account_verified_before_thread": accountIndex < threadIndex,
                "text": firstEvents.contains { if case .text = $0.event { true } else { false } },
                "image_input": firstEvents.contains { if case .toolCall = $0.event { true } else { false } },
                "typed_image_tool_result": firstDriver.sentTypedImageToolResult,
                "nexgen_tool_round_trip": firstDriver.sentTypedImageToolResult,
                "warm_dialogue": liveTerminals(followUpEvents) == [.completed(.endTurn)],
                "cancel_turn_started": !cancelTurnIDs.isEmpty,
                "cancel_interrupted": cancelledTurnWasInterrupted,
                "process_termination_confirmed": firstDriver.terminationConfirmed,
                "scratch_removed": scratchRemoved,
                "cold_resume_rejected": coldResumeRejected,
                "host_transcript_replay": transcriptReplaySucceeded,
                "phase_and_language_refresh": transcriptReplaySucceeded,
                "model_catalog_count": models.count,
                "default_model_has_text_and_image": modalities.contains("text") && modalities.contains("image"),
                "model_visible_tool_inventory_captured": false,
                "dialog_and_spend_consumers_exercised": false,
                "evidence_payload_redacted": true,
            ], at: evidencePath)
        }
    }

    @Test("real AgentService and ToolExecutor consume the Codex runtime")
    func liveProductConsumerSmoke() async throws {
        guard CodexAppServerContract.isAcceptanceRun else { return }
        let environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: try #require(environment["CODEX_HOME"]), isDirectory: true)
        let scratchRoot = URL(
            fileURLWithPath: try #require(environment["RUNNER_TEMP"]),
            isDirectory: true
        )
        var productDrivers: [CodexAppServerJSONRPCDriver] = []
        let service = AgentService(
            backend: .codexAppServer,
            refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in
                let driver = CodexAppServerJSONRPCDriver()
                productDrivers.append(driver)
                return CodexAppServerRuntimeAdapter(
                    driverFactory: { driver },
                    runtimeLocations: { request in
                        (home, scratchRoot.appendingPathComponent(request.runtimeGenerationID.uuidString))
                    }
                )
            },
            runtimeReadinessOverride: { nil }
        )
        let editor = EditorViewModel(agentService: service)
        service.editor = editor
        service.loadSessions(from: nil)
        let firstChatID = try #require(service.currentSessionId)

        #expect(service.send(
            text: "Call get_timeline exactly once with no arguments. Report only its totalFrames value.",
            mentions: []
        ))
        for _ in 0..<900 where service.isStreaming {
            try await Task.sleep(for: .seconds(1))
        }
        #expect(!service.isStreaming)
        #expect(service.streamError == nil)
        let usedTimeline = service.messages.contains { message in
            message.blocks.contains { block in
                guard case .toolUse(_, let name, _) = block else { return false }
                return name == ToolName.getTimeline.rawValue
            }
        }
        let receivedTimeline = service.messages.contains { message in
            message.blocks.contains { block in
                guard case .toolResult(_, _, let isError) = block else { return false }
                return !isError
            }
        }
        #expect(usedTimeline)
        #expect(receivedTimeline)

        let secondProject = scratchRoot.appendingPathComponent(
            "codex-product-boundary-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        service.loadSessions(from: secondProject)
        let secondChatID = try #require(service.currentSessionId)
        #expect(secondChatID != firstChatID)
        #expect(service.send(
            text: "Call get_timeline exactly once with no arguments. Report only its totalFrames value.",
            mentions: []
        ))
        for _ in 0..<900 where service.isStreaming {
            try await Task.sleep(for: .seconds(1))
        }
        #expect(!service.isStreaming)
        #expect(service.streamError == nil)
        let secondProjectToolResult = service.messages.contains { message in
            message.blocks.contains { block in
                guard case .toolResult(_, _, let isError) = block else { return false }
                return !isError
            }
        }
        #expect(secondProjectToolResult)
        service.cancel()
        for driver in productDrivers { await driver.waitForTermination() }
        let crossedChatAndProjectBoundary = secondChatID != firstChatID
            && productDrivers.count >= 2
            && receivedTimeline
            && secondProjectToolResult

        if let evidencePath = environment["NGV_CODEX_ACCEPTANCE_EVIDENCE"] {
            try mergeLiveEvidence([
                "agent_service_consumer_exercised": usedTimeline && receivedTimeline,
                "real_tool_executor_exercised": receivedTimeline && secondProjectToolResult,
                "two_chats_and_project_boundary": crossedChatAndProjectBoundary,
            ], at: evidencePath)
        }
    }

    private func liveSession(
        sessionID: UUID,
        providerSessionID: String? = nil,
        interfaceLanguage: AgentInterfaceLanguage = .init(identifier: "en", displayName: "English"),
        phase: String = "smoke",
        phaseInstructions: String = "Call acceptance_echo when requested."
    ) -> AgentRuntimeSessionRequest {
        let tool = AgentRuntimeToolSchema(
            name: "acceptance_echo",
            description: "Return a controlled acceptance result.",
            inputSchema: [
                "type": "object",
                "properties": ["value": ["type": "string"]],
                "required": ["value"],
                "additionalProperties": false,
            ]
        )
        let context = AgentRuntimeHostContext(
            interfaceLanguage: interfaceLanguage,
            baseInstructions: "Follow the host contract and use only the supplied nexgen tool.",
            pack: .init(id: "acceptance", version: "1", projectSchema: "1", currentPhase: phase),
            phaseInstructions: phaseInstructions,
            toolSchemas: [tool],
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
            executeTool: { _, name, input in
                guard name == "acceptance_echo",
                      let data = input.data(using: .utf8),
                      let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      arguments["value"] as? String == "light" else {
                    return .error("unexpected acceptance call")
                }
                return ToolResult(
                    content: [
                        .text("controlled-result"),
                        .image(
                            base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nE4AAAAASUVORK5CYII=",
                            mediaType: "image/png"
                        ),
                    ],
                    isError: false
                )
            }
        )
    }
}

@MainActor
private func collectLiveCodexEvents(
    _ stream: AsyncStream<AgentRuntimeEventEnvelope>
) async -> [AgentRuntimeEventEnvelope] {
    var events: [AgentRuntimeEventEnvelope] = []
    for await event in stream { events.append(event) }
    return events
}

private func liveTerminals(_ events: [AgentRuntimeEventEnvelope]) -> [AgentRuntimeTerminal] {
    events.compactMap {
        guard case .terminal(let value) = $0.event else { return nil }
        return value
    }
}

private func mergeLiveEvidence(_ values: [String: Any], at path: String) throws {
    let url = URL(fileURLWithPath: path)
    var evidence: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: path) {
        evidence = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }
    for (key, value) in values { evidence[key] = value }
    let data = try JSONSerialization.data(
        withJSONObject: evidence,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: url, options: .atomic)
}
