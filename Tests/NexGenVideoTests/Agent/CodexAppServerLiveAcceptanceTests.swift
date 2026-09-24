import AppKit
import Foundation
import NaturalLanguage
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Codex App Server live acceptance", .serialized)
struct CodexAppServerLiveAcceptanceTests {
    @Test("emitted isolated configuration starts with empty MCP and skill inventories")
    func isolatedConfigurationStartsCleanRuntime() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard CodexAppServerContract.isAcceptanceRun,
              environment["NGV_CODEX_CLEAN_CONFIGURATION"] == "1" else { return }
        let home = URL(fileURLWithPath: try #require(environment["CODEX_HOME"]), isDirectory: true)
        let scratch = URL(
            fileURLWithPath: try #require(environment["RUNNER_TEMP"]),
            isDirectory: true
        ).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let driver = CodexAppServerJSONRPCDriver()
        defer { driver.stop() }
        try await driver.start(home: home, scratch: scratch)

        let configIndex = try #require(driver.requestedMethods.firstIndex(of: "config/read"))
        let requirementsIndex = try #require(
            driver.requestedMethods.firstIndex(of: "configRequirements/read")
        )
        let mcpIndex = try #require(driver.requestedMethods.firstIndex(of: "mcpServerStatus/list"))
        let skillsIndex = try #require(driver.requestedMethods.firstIndex(of: "skills/list"))
        let accountIndex = try #require(driver.requestedMethods.firstIndex(of: "account/read"))
        #expect(configIndex < mcpIndex)
        #expect(requirementsIndex < mcpIndex)
        #expect(mcpIndex < accountIndex)
        #expect(skillsIndex < accountIndex)
        #expect(!driver.requestedMethods.contains("thread/start"))
        #expect(driver.accountStatus == .init(billing: .apiKey))

        driver.stop()
        await driver.waitForTermination()
        #expect(driver.terminationConfirmed)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

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
        let visualCode = randomAcceptanceCode()
        let image = try renderedAcceptanceImage(code: visualCode)
        let session = liveSession(
            sessionID: sessionID,
            expectedEchoValue: visualCode,
            toolOutputImage: image
        )
        try firstAdapter.start(session)
        let current = AgentRuntimeMessage(role: .user, content: [
            .text("Read the eight-character verification code printed in the attached image. Call the nexgen acceptance_echo tool exactly once with that exact code as value, then briefly confirm completion."),
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
        let imageToolCalls = firstEvents.compactMap { envelope -> (String, String)? in
            guard case .toolCall(_, _, let name, let inputJSON) = envelope.event,
                  let data = inputJSON.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = arguments["value"] as? String else { return nil }
            return (name, value)
        }
        let imageContentExactMatch = imageToolCalls.count == 1
            && imageToolCalls.first?.0 == "acceptance_echo"
            && imageToolCalls.first?.1 == visualCode
        #expect(imageContentExactMatch)
        let typedToolResultObserved = firstEvents.contains { envelope in
            guard case .toolResult(_, let content, let isError) = envelope.event else { return false }
            return !isError
                && content.contains(.text("controlled-result"))
                && content.contains { if case .image = $0 { true } else { false } }
        }
        #expect(typedToolResultObserved)
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
        let warmDialogueSucceeded = followUpEvents.contains { envelope in
            guard case .text(_, let value, _) = envelope.event else { return false }
            return value.localizedCaseInsensitiveContains("continued")
        } && liveTerminals(followUpEvents) == [.completed(.endTurn)]
        #expect(warmDialogueSucceeded)

        let cancelMessage = AgentRuntimeMessage(role: .user, content: [
            .text("Draft a detailed 5,000-word technical explanation of nonlinear editing history."),
        ])
        let cancelStream = try firstAdapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current, cancelMessage],
            currentMessage: cancelMessage
        ))
        let cancelTurnID = try #require(await waitForProviderTurn(
            firstAdapter,
            timeout: .seconds(30)
        ))
        firstAdapter.cancel(sessionID: sessionID)
        #expect(liveTerminals(await collectLiveCodexEvents(cancelStream)) == [.cancelled])
        await firstDriver.waitForTermination()
        let cancelledTurnWasInterrupted = firstDriver.observedInterruptedTurnIDs.contains(cancelTurnID)
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
        let replayUserCode = randomAcceptanceCode()
        let replayOutputCode = randomAcceptanceCode()
        let replayToolValue = "call-\(randomAcceptanceCode().lowercased())"
        let replayResultText = "archive-\(randomAcceptanceCode().lowercased())"
        let phaseMarker = "continuity-\(randomAcceptanceCode().lowercased())"
        let replaySession = liveSession(
            sessionID: replaySessionID,
            interfaceLanguage: .init(identifier: "de-DE", displayName: "German"),
            phase: phaseMarker,
            phaseInstructions: "Use the replayed evidence, state the exact active phase identifier supplied by the host, and answer naturally in the interface language."
        )
        try replayAdapter.resume(replaySession)
        let replayCallID = "replay-\(UUID().uuidString)"
        let replayUserImage = try renderedAcceptanceImage(code: replayUserCode)
        let replayOutputImage = try renderedAcceptanceImage(code: replayOutputCode)
        let replayHistory = [
            AgentRuntimeMessage(role: .user, content: [
                .text("Retain the code shown in this earlier user image."),
                .image(replayUserImage),
            ]),
            AgentRuntimeMessage(role: .assistant, content: [
                .text("I will preserve the host evidence."),
                .toolUse(
                    id: replayCallID,
                    name: "acceptance_echo",
                    inputJSON: try jsonString(["value": replayToolValue])
                ),
            ]),
            AgentRuntimeMessage(role: .user, content: [
                .toolResult(
                    id: replayCallID,
                    content: [
                        .text(replayResultText),
                        .image(
                            base64: replayOutputImage.base64,
                            mediaType: replayOutputImage.mediaType
                        ),
                    ],
                    isError: false
                ),
            ]),
            AgentRuntimeMessage(role: .assistant, content: [
                .text("The namespaced host result is part of the conversation history."),
            ]),
        ]
        let replayCurrent = AgentRuntimeMessage(
            role: .user,
            content: [.text("Using only the earlier conversation, report the user-image code, the host-tool argument, the host-result text, the tool-result-image code, and the active phase. Use several complete sentences and do not call a tool.")]
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
        let injectedItems = replayDriver.requestedParameters.first {
            $0.method == "thread/injectItems"
        }?.params["items"] as? [[String: Any]] ?? []
        let injectedCall = injectedItems.first {
            $0["type"] as? String == "function_call" && $0["call_id"] as? String == replayCallID
        }
        let injectedOutput = injectedItems.first {
            $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == replayCallID
        }
        let injectedOutputBlocks = injectedOutput?["output"] as? [[String: Any]] ?? []
        let replayStructureIsComplete = injectedCall?["namespace"] as? String
                == CodexAppServerContract.toolNamespace
            && injectedCall?["name"] as? String == "acceptance_echo"
            && injectedOutput?["namespace"] as? String == CodexAppServerContract.toolNamespace
            && injectedOutput?["name"] as? String == "acceptance_echo"
            && injectedOutputBlocks.contains { $0["text"] as? String == replayResultText }
            && injectedOutputBlocks.contains { $0["type"] as? String == "input_image" }
            && injectedItems.contains { item in
                guard item["type"] as? String == "message",
                      item["role"] as? String == "user",
                      let content = item["content"] as? [[String: Any]] else { return false }
                return content.contains { $0["type"] as? String == "input_image" }
            }
        let transcriptReplaySucceeded = replayText.contains(replayUserCode)
            && replayText.contains(replayToolValue)
            && replayText.contains(replayResultText)
            && replayText.contains(replayOutputCode)
            && replayWasInjectedBeforeTurn
            && replayStructureIsComplete
            && !replayEvents.contains { if case .toolCall = $0.event { true } else { false } }
        let phaseInstructionObserved = replayText.contains(phaseMarker)
        let languageRecognizer = NLLanguageRecognizer()
        languageRecognizer.processString(replayText)
        let detectedInterfaceLanguage = languageRecognizer.dominantLanguage?.rawValue ?? "unknown"
        #expect(transcriptReplaySucceeded)
        #expect(phaseInstructionObserved)
        #expect(detectedInterfaceLanguage == NLLanguage.german.rawValue)
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
                "typed_image_input": firstDriver.requestedParameters.contains { request in
                    guard request.method == "turn/start",
                          let input = request.params["input"] as? [[String: Any]] else { return false }
                    return input.contains {
                        $0["type"] as? String == "image"
                            && ($0["url"] as? String)?.hasPrefix("data:image/png;base64,") == true
                    }
                },
                "image_content_exact_match": imageContentExactMatch,
                "typed_image_tool_result": firstDriver.sentTypedImageToolResult,
                "nexgen_tool_round_trip": imageContentExactMatch
                    && typedToolResultObserved
                    && firstDriver.sentTypedImageToolResult,
                "warm_dialogue": warmDialogueSucceeded,
                "cancel_turn_id_confirmed": !cancelTurnID.isEmpty,
                "cancel_interrupted": cancelledTurnWasInterrupted,
                "process_termination_confirmed": firstDriver.terminationConfirmed,
                "scratch_removed": scratchRemoved,
                "cold_resume_rejected": coldResumeRejected,
                "host_transcript_replay": transcriptReplaySucceeded,
                "phase_instruction_observed": phaseInstructionObserved,
                "interface_language_detected": detectedInterfaceLanguage,
                "model_catalog_count": models.count,
                "default_model_has_text_and_image": modalities.contains("text") && modalities.contains("image"),
                "model_visible_tool_inventory_captured": false,
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
        let firstProject = scratchRoot.appendingPathComponent(
            "codex-product-first-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        let secondProject = scratchRoot.appendingPathComponent(
            "codex-product-second-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        let firstTimeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 73)]),
        ])
        let secondTimeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 211)]),
        ])
        try Fixtures.prepareProjectPackage(at: firstProject, timeline: firstTimeline)
        try Fixtures.prepareProjectPackage(at: secondProject, timeline: secondTimeline)
        defer {
            try? FileManager.default.removeItem(at: firstProject)
            try? FileManager.default.removeItem(at: secondProject)
        }

        var productDrivers: [CodexAppServerJSONRPCDriver] = []
        var productAdapters: [RecordingLiveRuntimeAdapter] = []
        let service = AgentService(
            backend: .codexAppServer,
            refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in
                let runtime = CodexAppServerRuntimeAdapter(
                    driverFactory: {
                        let driver = CodexAppServerJSONRPCDriver()
                        productDrivers.append(driver)
                        return driver
                    },
                    runtimeLocations: { request in
                        (home, scratchRoot.appendingPathComponent(request.runtimeGenerationID.uuidString))
                    }
                )
                let recording = RecordingLiveRuntimeAdapter(runtime)
                productAdapters.append(recording)
                return recording
            },
            runtimeReadinessOverride: { nil }
        )
        let firstEditor = EditorViewModel(agentService: service)
        firstEditor.projectURL = firstProject
        firstEditor.timeline = firstTimeline
        service.editor = firstEditor
        let firstRoot = try #require(firstEditor.workingRoot)
        service.loadSessions(from: firstRoot)
        let firstChatID = try #require(service.currentSessionId)

        #expect(service.send(
            text: "Call show_dialog exactly once with title Choose and one single-choice section whose options are Continue and Revise. After the host returns the selection, reply with dialog-result followed by the selected label and do not call another tool.",
            mentions: []
        ))
        #expect(await waitForServiceIdle(service, timeout: .seconds(300)))
        #expect(service.streamError == nil)
        let dialog = try #require(service.pendingDialog)
        #expect(dialog.title == "Choose")
        let choiceSection = try #require(dialog.sections.first { section in
            guard case .choices(let options, let multiSelect) = section.kind else { return false }
            return !multiSelect && options.contains {
                $0.label.localizedCaseInsensitiveCompare("Continue") == .orderedSame
            }
        })
        let continueChoice = try #require({ () -> AgentDialog.Choice? in
            guard case .choices(let options, _) = choiceSection.kind else { return nil }
            return options.first {
                $0.label.localizedCaseInsensitiveCompare("Continue") == .orderedSame
            }
        }())
        service.dialogChoiceSelections[choiceSection.id] = [continueChoice.id]
        let dialogSubmissionMessageStart = service.messages.endIndex
        service.submitDialog(
            dialog,
            result: AgentDialogResult(
                selectedLabels: [choiceSection.id: [continueChoice.label]],
                toggles: [:],
                direction: ""
            )
        )
        #expect(await waitForServiceIdle(service, timeout: .seconds(300)))
        #expect(service.streamError == nil)
        let dialogToolUses = service.messages.flatMap(\.blocks).filter {
            guard case .toolUse(_, let name, _) = $0 else { return false }
            return name == ToolName.showDialog.rawValue
        }
        let hostDialogResponseCarriedSelection = service.messages
            .dropFirst(dialogSubmissionMessageStart)
            .contains { message in
                guard message.role == .user else { return false }
                let modelTextHasSelection = message.blocks.contains {
                    guard case .text(let value) = $0 else { return false }
                    return value.contains("\(choiceSection.label): \(continueChoice.label)")
                }
                let presentationHasSelection = message.userPresentation?.choiceRecord?.selections.contains {
                    $0.label == choiceSection.shortLabel && $0.values == [continueChoice.shortLabel]
                } == true
                return modelTextHasSelection && presentationHasSelection
            }
        #expect(hostDialogResponseCarriedSelection)
        let dialogueFollowUpSucceeded = hostDialogResponseCarriedSelection
            && dialogToolUses.count == 1
            && service.messages.contains { message in
                message.role == .assistant && message.blocks.contains {
                    guard case .text(let value) = $0 else { return false }
                    return value.localizedCaseInsensitiveContains("dialog-result")
                        && value.localizedCaseInsensitiveContains("continue")
                }
            }
        #expect(dialogueFollowUpSucceeded)

        #expect(service.send(
            text: "Call get_timeline exactly once with no arguments. Report only its totalFrames value.",
            mentions: []
        ))
        #expect(await waitForServiceIdle(service, timeout: .seconds(300)))
        #expect(service.streamError == nil)
        let usedTimeline = service.messages.contains { message in
            message.blocks.contains { block in
                guard case .toolUse(_, let name, _) = block else { return false }
                return name == ToolName.getTimeline.rawValue
            }
        }
        let receivedFirstTimeline = transcriptContainsTimeline(service.messages, totalFrames: 73)
        #expect(usedTimeline)
        #expect(receivedFirstTimeline)
        let firstProjectSession = try #require(productAdapters.last?.latestSession)
        let firstProjectCallbackResult = await firstProjectSession.executeTool(
            "first-project-call",
            ToolName.getTimeline.rawValue,
            "{}"
        )
        let firstProjectCallbackSucceeded = !firstProjectCallbackResult.isError
            && timelineContentContains(firstProjectCallbackResult.content, totalFrames: 73)
        #expect(firstProjectCallbackSucceeded)
        let driverCountBeforeProjectSwitch = productDrivers.count

        let secondEditor = EditorViewModel(agentService: service)
        secondEditor.projectURL = secondProject
        secondEditor.timeline = secondTimeline
        service.editor = secondEditor
        let secondRoot = try #require(secondEditor.workingRoot)
        service.loadSessions(from: secondRoot)
        let secondChatID = try #require(service.currentSessionId)
        #expect(secondChatID != firstChatID)
        #expect(firstEditor !== secondEditor)
        #expect(firstRoot.standardizedFileURL != secondRoot.standardizedFileURL)
        let staleResult = await firstProjectSession.executeTool(
            "stale-project-call",
            ToolName.getTimeline.rawValue,
            "{}"
        )
        let staleGenerationWasRejected = staleResult.isError
            && staleResult.content.contains {
                guard case .text(let value) = $0 else { return false }
                return value.contains("originating chat session is no longer active")
            }
        #expect(staleGenerationWasRejected)
        #expect(service.send(
            text: "Call get_timeline exactly once with no arguments. Report only its totalFrames value.",
            mentions: []
        ))
        #expect(await waitForServiceIdle(service, timeout: .seconds(300)))
        #expect(service.streamError == nil)
        let receivedSecondTimeline = transcriptContainsTimeline(service.messages, totalFrames: 211)
        #expect(receivedSecondTimeline)
        let secondProjectDrivers = productDrivers.dropFirst(driverCountBeforeProjectSwitch)
        let firstChatWasNotInjected = !secondProjectDrivers.contains {
            $0.requestedMethods.contains("thread/injectItems")
        }
        #expect(firstChatWasNotInjected)
        service.cancel()
        for driver in productDrivers { await driver.waitForTermination() }
        firstEditor.releaseWorkingCopy()
        secondEditor.releaseWorkingCopy()
        let crossedChatAndProjectBoundary = secondChatID != firstChatID
            && firstEditor !== secondEditor
            && firstRoot.standardizedFileURL != secondRoot.standardizedFileURL
            && receivedFirstTimeline
            && firstProjectCallbackSucceeded
            && receivedSecondTimeline
            && staleGenerationWasRejected
            && firstChatWasNotInjected

        if let evidencePath = environment["NGV_CODEX_ACCEPTANCE_EVIDENCE"] {
            try mergeLiveEvidence([
                "agent_service_consumer_exercised": usedTimeline
                    && receivedFirstTimeline
                    && receivedSecondTimeline,
                "real_tool_executor_exercised": receivedFirstTimeline && receivedSecondTimeline,
                "dialog_consumer_follow_up": dialogueFollowUpSucceeded,
                "distinct_project_roots_and_editors": crossedChatAndProjectBoundary,
                "stale_project_generation_rejected": firstProjectCallbackSucceeded
                    && staleGenerationWasRejected,
                "first_chat_not_injected_into_second_project": firstChatWasNotInjected,
            ], at: evidencePath)
        }
    }

    private func liveSession(
        sessionID: UUID,
        providerSessionID: String? = nil,
        interfaceLanguage: AgentInterfaceLanguage = .init(identifier: "en", displayName: "English"),
        phase: String = "smoke",
        phaseInstructions: String = "Call acceptance_echo when requested.",
        expectedEchoValue: String? = nil,
        toolOutputImage: AgentRuntimeImage? = nil
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
                      let value = arguments["value"] as? String else {
                    return .error("unexpected acceptance call")
                }
                if let expectedEchoValue, value != expectedEchoValue {
                    return .error("unexpected acceptance call")
                }
                let returnedImage = toolOutputImage ?? AgentRuntimeImage(
                    mediaType: "image/png",
                    base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nE4AAAAASUVORK5CYII="
                )
                return ToolResult(
                    content: [
                        .text("controlled-result"),
                        .image(
                            base64: returnedImage.base64,
                            mediaType: returnedImage.mediaType
                        ),
                    ],
                    isError: false
                )
            }
        )
    }
}

@MainActor
private final class RecordingLiveRuntimeAdapter: AgentRuntimeAdapter {
    private let runtime: CodexAppServerRuntimeAdapter
    private(set) var latestSession: AgentRuntimeSessionRequest?

    init(_ runtime: CodexAppServerRuntimeAdapter) {
        self.runtime = runtime
    }

    var descriptor: AgentRuntimeDescriptor { runtime.descriptor }
    var state: AgentRuntimeState { runtime.state }

    func start(_ request: AgentRuntimeSessionRequest) throws {
        latestSession = request
        try runtime.start(request)
    }

    func resume(_ request: AgentRuntimeSessionRequest) throws {
        latestSession = request
        try runtime.resume(request)
    }

    func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
        try runtime.send(request)
    }

    func cancel(sessionID: UUID) {
        runtime.cancel(sessionID: sessionID)
    }

    func end(sessionID: UUID) {
        runtime.end(sessionID: sessionID)
    }
}

@MainActor
private func waitForProviderTurn(
    _ adapter: CodexAppServerRuntimeAdapter,
    timeout: Duration
) async -> String? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let turnID = adapter.activeProviderTurnIdentifier { return turnID }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

@MainActor
private func waitForServiceIdle(
    _ service: AgentService,
    timeout: Duration
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while service.isStreaming, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
    }
    return !service.isStreaming
}

private func transcriptContainsTimeline(
    _ messages: [AgentMessage],
    totalFrames: Int
) -> Bool {
    messages.contains { message in
        message.blocks.contains { block in
            guard case .toolResult(_, let content, let isError) = block, !isError else {
                return false
            }
            return timelineContentContains(content, totalFrames: totalFrames)
        }
    }
}

private func timelineContentContains(
    _ content: [ToolResult.Block],
    totalFrames: Int
) -> Bool {
    content.contains { resultBlock in
        guard case .text(let value) = resultBlock,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (object["totalFrames"] as? NSNumber)?.intValue == totalFrames
    }
}

private func randomAcceptanceCode() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
}

private func renderedAcceptanceImage(code: String) throws -> AgentRuntimeImage {
    let width = 720
    let height = 240
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(calibratedRed: 0.94, green: 0.96, blue: 1, alpha: 1).setFill()
    NSBezierPath(
        rect: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    ).fill()
    for (index, scalar) in code.unicodeScalars.enumerated() {
        let value = CGFloat(Int(scalar.value) % 97) / 96
        NSColor(
            calibratedRed: 0.15 + value * 0.45,
            green: 0.22 + CGFloat(index % 3) * 0.16,
            blue: 0.72 - value * 0.25,
            alpha: 0.42
        ).setFill()
        NSBezierPath(
            ovalIn: NSRect(x: CGFloat(22 + index * 84), y: 22, width: 58, height: 58)
        ).fill()
    }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 92, weight: .bold),
        .foregroundColor: NSColor.black,
        .kern: 5,
    ]
    NSAttributedString(string: code, attributes: attributes).draw(
        in: NSRect(x: 42, y: 88, width: CGFloat(width - 84), height: 120)
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return AgentRuntimeImage(mediaType: "image/png", base64: data.base64EncodedString())
}

private func jsonString(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
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

func mergeLiveEvidence(_ values: [String: Any], at path: String) throws {
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
