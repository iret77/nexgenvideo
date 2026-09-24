import Foundation
import NexGenEngine
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
        let codexRequest = try #require(
            fixtures.first(where: { $0.service.backend == .codexAppServer })?.adapter.sendRequests.first
        )
        #expect(claudeRequest.messages == anthropicRequest.messages)
        #expect(claudeRequest.currentMessage == anthropicRequest.currentMessage)
        #expect(codexRequest.messages == anthropicRequest.messages)
        #expect(codexRequest.currentMessage == anthropicRequest.currentMessage)
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

    @Test("cancelled turn completion cannot clear a replacement turn in the same chat")
    func cancelledTurnCannotFinishReplacementTurn() async throws {
        let adapter = FakeRuntimeAdapter(backend: .anthropicAPI)
        let service = makeService(backend: .anthropicAPI, adapter: adapter)

        #expect(service.send(text: "First turn", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let firstTurn = try #require(adapter.sendRequests.first)
        adapter.emit(
            .text(messageID: "first-answer", value: "Partial", isDelta: true),
            for: firstTurn
        )
        await waitUntil { assistantText(in: service.messages) == "Partial" }

        service.cancel()
        let sessionID = try #require(service.currentSessionId)
        let storedSession = try #require(service.sessions.first { $0.id == sessionID })
        #expect(assistantText(in: storedSession.messages) == "Partial")

        #expect(service.send(text: "Replacement turn", mentions: []))
        await waitUntil { adapter.sendRequests.count == 2 }
        let replacementTurn = adapter.sendRequests[1]
        await Task.yield()
        #expect(service.isStreaming)

        adapter.emit(
            .text(messageID: "replacement-answer", value: "Complete", isDelta: true),
            for: replacementTurn
        )
        adapter.emit(.terminal(.completed(.endTurn)), for: replacementTurn)
        adapter.finish(replacementTurn)
        await waitUntil { !service.isStreaming }

        #expect(assistantText(in: service.messages) == "PartialComplete")
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

    @Test("writer host state preserves one tool result and rich follow-up on both backends")
    func writerHostStateKeepsCanonicalHistory() async throws {
        for backend in AgentBackend.allCases {
            let cleanup = FileManager.default.temporaryDirectory
                .appendingPathComponent("runtime-host-state-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: cleanup) }
            let dataRoot = try ProjectScaffold.initProject(
                home: cleanup.appendingPathComponent("project"),
                name: "runtime",
                mode: .beat
            )
            let store = YAMLArtifactStore(dataRoot: dataRoot)
            var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
            GatesOperations.approve(&gates, phase: "project_init")
            try store.save(gates, to: PipelineLayout.gatesFile)

            let adapter = FakeRuntimeAdapter(
                backend: backend,
                toolNames: Set(ToolDefinitions.all.map { $0.name.rawValue })
            )
            let service = makeService(
                backend: backend,
                adapter: adapter,
                context: .hostOwned(tools: ToolDefinitions.all)
            )
            let editor = EditorViewModel(agentService: service)
            let writerArgs: [String: Any] = [
                "project_dir": dataRoot.path,
                "mission": "single_release",
                "target_platform": "YouTube",
                "aspect_ratio": "16:9",
                "project_mode": "section",
                "concept_type": "narrative",
                "visual_medium": "live_action_realistic",
                "figures": "artist_only",
                "lyrics_integration": "literal",
            ]
            let writerJSON = String(decoding: try JSONSerialization.data(
                withJSONObject: writerArgs,
                options: [.sortedKeys]
            ), as: UTF8.self)

            #expect(service.send(text: "Write the brief.", mentions: []))
            await waitUntil { adapter.sendRequests.count == 1 }
            let turn = try #require(adapter.sendRequests.first)
            if backend != .claudeCode {
                adapter.emit(.toolCall(
                    messageID: "writer-message",
                    id: "writer",
                    name: "write_brief",
                    inputJSON: writerJSON
                ), for: turn)
                await waitUntil {
                    service.messages.contains { message in
                        message.blocks.contains {
                            if case .toolUse(let id, _, _) = $0 { return id == "writer" }
                            return false
                        }
                    }
                }
            }
            let session = try #require(
                adapter.startRequests.first ?? adapter.resumeRequests.first
            )
            let writerResult: ToolResult
            if backend == .claudeCode {
                writerResult = await ToolExecutor(editor: editor).execute(
                    name: "write_brief",
                    args: writerArgs,
                    origin: .embeddedRuntime(
                        chatSessionID: turn.sessionID,
                        runtimeGenerationID: session.runtimeGenerationID
                    )
                )
            } else {
                writerResult = await session.executeTool(
                    "writer",
                    "write_brief",
                    writerJSON
                )
            }
            #expect(!writerResult.isError)
            if backend == .claudeCode {
                adapter.emit(.toolCall(
                    messageID: "writer-message",
                    id: "writer",
                    name: "write_brief",
                    inputJSON: writerJSON
                ), for: turn)
                await waitUntil {
                    service.messages.flatMap(\.hostStateRecords).contains {
                        $0.state == .persisted
                    }
                }
            }
            adapter.emit(.toolResult(
                id: "writer",
                content: writerResult.content,
                isError: writerResult.isError
            ), for: turn)
            adapter.emit(.text(
                messageID: "final-message",
                value: "The brief keeps the performance central.",
                isDelta: false
            ), for: turn)
            let richJSON = #"{"blocks":[{"type":"text","body":"Review the performance direction."}]}"#
            adapter.emit(.toolCall(
                messageID: "final-message",
                id: "rich",
                name: ToolName.showBlocks.rawValue,
                inputJSON: richJSON
            ), for: turn)
            let richResult = await session.executeTool(
                "rich",
                ToolName.showBlocks.rawValue,
                richJSON
            )
            #expect(!richResult.isError)
            adapter.emit(.toolResult(
                id: "rich",
                content: richResult.content,
                isError: richResult.isError
            ), for: turn)
            adapter.emit(.terminal(.completed(.endTurn)), for: turn)
            adapter.finish(turn)
            await waitUntil { !service.isStreaming }

            #expect(service.messages.flatMap(\.hostStateRecords).map(\.state) == [.persisted])
            let hostMessage = try #require(service.messages.first {
                !$0.hostStateRecords.isEmpty
            })
            if backend == .claudeCode {
                #expect(hostMessage.role == .user)
                #expect(hostMessage.id == service.messages.first?.id)
                #expect(hostMessage.hostStateRecords.first?.toolUseID == nil)
            } else {
                #expect(hostMessage.role == .assistant)
                #expect(hostMessage.hostStateRecords.first?.toolUseID == "writer")
            }
            #expect(!service.messages.contains { $0.role == .user && $0.blocks.isEmpty })
            let projected = AgentTranscriptProjection.turns(
                messages: service.messages,
                isStreaming: false
            ).flatMap(\.items)
            let assistant = try #require(projected.compactMap { item -> AgentMessage? in
                guard case .assistantResult(let message) = item else { return nil }
                return message
            }.first)
            #expect(assistant.blocks.contains(.text("The brief keeps the performance central.")))
            #expect(assistant.blocks.contains {
                if case .toolUse(let id, let name, _) = $0 {
                    return id == "rich" && name == ToolName.showBlocks.rawValue
                }
                return false
            })

            #expect(service.send(text: "Continue.", mentions: []))
            await waitUntil { adapter.sendRequests.count == 2 }
            let followUp = adapter.sendRequests[1]
            let writerResults = followUp.messages.flatMap(\.content).compactMap {
                content -> AgentRuntimeContent? in
                guard case .toolResult(let id, _, _) = content, id == "writer" else {
                    return nil
                }
                return content
            }
            #expect(writerResults.count == 1)
            #expect(!followUp.messages.flatMap(\.content).contains { content in
                guard case .toolResult(_, let blocks, _) = content else { return false }
                return blocks.contains(.text("Cancelled"))
            })
            adapter.emit(.terminal(.completed(.endTurn)), for: followUp)
            adapter.finish(followUp)
            await waitUntil { !service.isStreaming }
            withExtendedLifetime(editor) {}
        }
    }

    @Test("legacy empty host records do not orphan completed tool calls")
    func legacyHostRecordDoesNotCreateCancelledResult() async throws {
        for backend in AgentBackend.allCases {
            let adapter = FakeRuntimeAdapter(backend: backend)
            let service = makeService(backend: backend, adapter: adapter)
            let legacyState = AgentHostStateRecord(
                state: .persisted,
                phase: "brief",
                toolName: "write_brief",
                action: .reviewForApproval,
                artifactPath: PipelineLayout.briefFile,
                byteComparison: .changed,
                previousSHA256: nil,
                currentSHA256: String(repeating: "a", count: 64)
            )
            service.messages = [
                AgentMessage(role: .user, blocks: [.text("Earlier")]),
                AgentMessage(role: .assistant, blocks: [
                    .toolUse(id: "legacy-writer", name: "write_brief", inputJSON: "{}"),
                ]),
                AgentMessage(
                    role: .user,
                    blocks: [],
                    userPresentation: .init(
                        choiceRecord: nil,
                        typedText: nil,
                        hostStateRecord: legacyState
                    )
                ),
                AgentMessage(role: .user, blocks: [
                    .toolResult(
                        toolUseId: "legacy-writer",
                        content: [.text("written")],
                        isError: false
                    ),
                ]),
            ]

            #expect(service.send(text: "Resume.", mentions: []))
            await waitUntil { adapter.sendRequests.count == 1 }
            let request = try #require(adapter.sendRequests.first)
            let results = request.messages.flatMap(\.content).filter {
                if case .toolResult(let id, _, _) = $0 { return id == "legacy-writer" }
                return false
            }
            #expect(results.count == 1)
            #expect(!results.contains { content in
                guard case .toolResult(_, let blocks, _) = content else { return false }
                return blocks.contains(.text("Cancelled"))
            })
            adapter.emit(.terminal(.completed(.endTurn)), for: request)
            adapter.finish(request)
            await waitUntil { !service.isStreaming }
        }
    }

    @Test("an MCP-first writer in a resumed legacy chat stays on its new turn")
    func legacyWriterCannotCaptureAnMCPFirstHostState() async throws {
        let adapter = FakeRuntimeAdapter(backend: .claudeCode)
        let service = makeService(backend: .claudeCode, adapter: adapter)
        let legacyAssistant = AgentMessage(role: .assistant, blocks: [
            .toolUse(id: "legacy-writer", name: "write_brief", inputJSON: "{}"),
        ])
        service.messages = [
            AgentMessage(role: .user, blocks: [.text("Earlier turn")]),
            legacyAssistant,
            AgentMessage(role: .user, blocks: [
                .toolResult(
                    toolUseId: "legacy-writer",
                    content: [.text("legacy result")],
                    isError: false
                ),
            ]),
        ]

        #expect(service.send(text: "Write the new brief.", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let turn = try #require(adapter.sendRequests.first)
        let runtime = try #require(adapter.resumeRequests.first)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: turn.sessionID,
            runtimeGenerationID: runtime.runtimeGenerationID
        )
        let reference = try #require(service.captureHostTurnReference(origin: origin))
        let record = hostRecord(state: .persisted, suffix: "new")

        service.recordHostState(
            record,
            origin: origin,
            turnReference: reference
        )
        adapter.emit(.toolCall(
            messageID: "new-writer-message",
            id: "new-writer",
            name: "write_brief",
            inputJSON: "{}"
        ), for: turn)
        await waitUntil {
            service.messages.contains { message in
                message.blocks.contains {
                    if case .toolUse(let id, _, _) = $0 { return id == "new-writer" }
                    return false
                }
            }
        }

        let old = try #require(service.messages.first { $0.id == legacyAssistant.id })
        #expect(old.hostStateRecords.isEmpty)
        let owner = try #require(service.messages.first { $0.id == reference.inputMessageID })
        #expect(owner.role == .user)
        #expect(owner.hostStateRecords == [record])
        #expect(owner.hostStateRecords.first?.toolUseID == nil)

        adapter.emit(.terminal(.completed(.endTurn)), for: turn)
        adapter.finish(turn)
        await waitUntil { !service.isStreaming }
    }

    @Test("an API host event keeps its real id inside the owning turn")
    func apiHostStateCannotCaptureAReusedLegacyToolID() async throws {
        let adapter = FakeRuntimeAdapter(backend: .anthropicAPI)
        let service = makeService(backend: .anthropicAPI, adapter: adapter)
        let legacyAssistant = AgentMessage(role: .assistant, blocks: [
            .toolUse(id: "reused", name: "write_brief", inputJSON: "{}"),
        ])
        service.messages = [
            AgentMessage(role: .user, blocks: [.text("Earlier turn")]),
            legacyAssistant,
            AgentMessage(role: .user, blocks: [
                .toolResult(
                    toolUseId: "reused",
                    content: [.text("legacy result")],
                    isError: false
                ),
            ]),
        ]

        #expect(service.send(text: "Write again.", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let turn = try #require(adapter.sendRequests.first)
        let origin = ToolCallOrigin.inAppChat(sessionID: turn.sessionID)
        let reference = try #require(service.captureHostTurnReference(origin: origin))
        let record = hostRecord(state: .persisted, suffix: "api")
        service.recordHostState(
            record,
            origin: origin,
            toolUseID: "reused",
            turnReference: reference
        )
        adapter.emit(.toolCall(
            messageID: "current-writer",
            id: "reused",
            name: "write_brief",
            inputJSON: "{}"
        ), for: turn)

        let old = try #require(service.messages.first { $0.id == legacyAssistant.id })
        let owner = try #require(service.messages.first {
            $0.id == reference.inputMessageID
        })
        #expect(old.hostStateRecords.isEmpty)
        #expect(owner.hostStateRecords.map(\.id) == [record.id])
        #expect(owner.hostStateRecords.first?.toolUseID == "reused")

        adapter.emit(.terminal(.completed(.endTurn)), for: turn)
        adapter.finish(turn)
        await waitUntil { !service.isStreaming }
    }

    @Test("same-name calls keep real API ids while MCP records claim no id")
    func reorderedSameNameHostEventsKeepProvenIdentity() async throws {
        for backend in AgentBackend.allCases {
            let adapter = FakeRuntimeAdapter(backend: backend)
            let service = makeService(backend: backend, adapter: adapter)
            #expect(service.send(text: "Write twice.", mentions: []))
            await waitUntil { adapter.sendRequests.count == 1 }
            let turn = try #require(adapter.sendRequests.first)
            adapter.emit(.toolCall(
                messageID: "writers",
                id: "first",
                name: "write_brief",
                inputJSON: "{}"
            ), for: turn)
            adapter.emit(.toolCall(
                messageID: "writers",
                id: "second",
                name: "write_brief",
                inputJSON: "{}"
            ), for: turn)
            await waitUntil {
                service.messages.flatMap(\.blocks).filter {
                    if case .toolUse = $0 { return true }
                    return false
                }.count == 2
            }
            let first = hostRecord(state: .writeRejected, suffix: "first")
            let second = hostRecord(state: .persisted, suffix: "second")

            if backend != .claudeCode {
                let origin = ToolCallOrigin.inAppChat(sessionID: turn.sessionID)
                service.recordHostState(second, origin: origin, toolUseID: "second")
                service.recordHostState(first, origin: origin, toolUseID: "first")

                let records = service.messages
                    .filter { $0.role == .assistant }
                    .flatMap(\.hostStateRecords)
                #expect(Dictionary(uniqueKeysWithValues: records.compactMap {
                    record in record.toolUseID.map { ($0, record.id) }
                }) == ["first": first.id, "second": second.id])
            } else {
                let runtime = try #require(
                    adapter.startRequests.first ?? adapter.resumeRequests.first
                )
                let origin = ToolCallOrigin.embeddedRuntime(
                    chatSessionID: turn.sessionID,
                    runtimeGenerationID: runtime.runtimeGenerationID
                )
                let reference = try #require(
                    service.captureHostTurnReference(origin: origin)
                )
                service.recordHostState(
                    second,
                    origin: origin,
                    turnReference: reference
                )
                service.recordHostState(
                    first,
                    origin: origin,
                    turnReference: reference
                )

                let owner = try #require(service.messages.first {
                    $0.id == reference.inputMessageID
                })
                #expect(owner.hostStateRecords.map(\.id) == [second.id, first.id])
                #expect(owner.hostStateRecords.allSatisfy { $0.toolUseID == nil })
                #expect(service.messages.filter { $0.role == .assistant }
                    .flatMap(\.hostStateRecords).isEmpty)
            }

            adapter.emit(.terminal(.completed(.endTurn)), for: turn)
            adapter.finish(turn)
            await waitUntil { !service.isStreaming }
        }
    }

    @Test("late MCP completion after cancel remains on the cancelled turn")
    func cancelLateCompletionAndResendStaySeparated() async throws {
        let adapter = FakeRuntimeAdapter(backend: .claudeCode)
        let service = makeService(backend: .claudeCode, adapter: adapter)
        #expect(service.send(text: "Original request", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let originalTurn = try #require(adapter.sendRequests.first)
        let originalRuntime = try #require(adapter.startRequests.first)
        let originalOrigin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: originalTurn.sessionID,
            runtimeGenerationID: originalRuntime.runtimeGenerationID
        )
        let originalReference = try #require(
            service.captureHostTurnReference(origin: originalOrigin)
        )

        service.cancel()
        let completed = hostRecord(state: .persisted, suffix: "late")
        service.recordHostState(
            completed,
            origin: originalOrigin,
            turnReference: originalReference
        )

        #expect(service.send(text: "Resend request", mentions: []))
        await waitUntil { adapter.sendRequests.count == 2 }
        let resendTurn = adapter.sendRequests[1]
        let resendRuntime = try #require(adapter.resumeRequests.last)
        let resendOrigin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: resendTurn.sessionID,
            runtimeGenerationID: resendRuntime.runtimeGenerationID
        )
        let resendReference = try #require(
            service.captureHostTurnReference(origin: resendOrigin)
        )
        let rejected = hostRecord(state: .writeRejected, suffix: "resend")
        service.recordHostState(
            rejected,
            origin: resendOrigin,
            turnReference: resendReference
        )
        adapter.emit(.toolCall(
            messageID: "resend-writer-message",
            id: "resend-writer",
            name: "write_brief",
            inputJSON: "{}"
        ), for: resendTurn)

        let originalOwner = try #require(service.messages.first {
            $0.id == originalReference.inputMessageID
        })
        let resendOwner = try #require(service.messages.first {
            $0.id == resendReference.inputMessageID
        })
        #expect(originalOwner.hostStateRecords.map(\.id) == [completed.id])
        #expect(resendOwner.hostStateRecords.map(\.id) == [rejected.id])
        #expect(originalOwner.hostStateRecords.first?.toolUseID == nil)
        #expect(resendOwner.hostStateRecords.first?.toolUseID == nil)
        #expect(originalReference.runtimeGenerationID != resendReference.runtimeGenerationID)
        #expect(originalReference.logicalTurnID != resendReference.logicalTurnID)

        adapter.emit(.terminal(.completed(.endTurn)), for: resendTurn)
        adapter.finish(resendTurn)
        await waitUntil { !service.isStreaming }
    }

    @Test("host turn references cannot cross chat or project generations")
    func hostTurnReferenceRespectsSessionAndProjectBoundaries() async throws {
        let adapter = FakeRuntimeAdapter(backend: .claudeCode)
        let service = makeService(backend: .claudeCode, adapter: adapter)
        #expect(service.send(text: "Project-scoped request", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let turn = try #require(adapter.sendRequests.first)
        let runtime = try #require(adapter.startRequests.first)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: turn.sessionID,
            runtimeGenerationID: runtime.runtimeGenerationID
        )
        let reference = try #require(service.captureHostTurnReference(origin: origin))
        let wrongSessionOrigin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: UUID(),
            runtimeGenerationID: runtime.runtimeGenerationID
        )
        #expect(service.captureHostTurnReference(origin: wrongSessionOrigin) == nil)

        service.loadSessions(from: nil)
        service.recordHostState(
            hostRecord(state: .persisted, suffix: "stale-project"),
            origin: origin,
            turnReference: reference
        )

        #expect(service.messages.flatMap(\.hostStateRecords).isEmpty)
        #expect(service.sessions.flatMap(\.messages)
            .flatMap(\.hostStateRecords).isEmpty)
    }

    @Test("a reloaded embedded draft rejects its old project-generation completion")
    func reloadedEmbeddedDraftRejectsStaleCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ngv-host-state-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = FakeRuntimeAdapter(backend: .claudeCode)
        let service = makeService(backend: .claudeCode, adapter: adapter)
        #expect(service.send(text: "Write the brief.", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let turn = try #require(adapter.sendRequests.first)
        let runtime = try #require(adapter.startRequests.first)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: turn.sessionID,
            runtimeGenerationID: runtime.runtimeGenerationID
        )
        let reference = try #require(service.captureHostTurnReference(origin: origin))
        let draft = hostRecord(state: .draft, suffix: "draft")
        service.recordHostState(draft, origin: origin, turnReference: reference)
        let stored = try #require(service.sessions.first { $0.id == turn.sessionID })
        try persistSession(stored, at: root)

        service.loadSessions(from: root)
        let before = try #require(service.sessions.first {
            $0.id == turn.sessionID
        }).messages
        var changeNotifications = 0
        service.onSessionsChanged = { changeNotifications += 1 }
        service.recordHostState(
            hostRecord(state: .persisted, suffix: "late", id: draft.id),
            origin: origin,
            turnReference: reference
        )

        let after = try #require(service.sessions.first {
            $0.id == turn.sessionID
        }).messages
        #expect(after == before)
        #expect(changeNotifications == 0)
    }

    @Test("a reloaded API tool use rejects its old project-generation completion")
    func reloadedAPIToolUseRejectsStaleCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ngv-host-state-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = FakeRuntimeAdapter(backend: .anthropicAPI)
        let service = makeService(backend: .anthropicAPI, adapter: adapter)
        #expect(service.send(text: "Write the brief.", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let turn = try #require(adapter.sendRequests.first)
        let origin = ToolCallOrigin.inAppChat(sessionID: turn.sessionID)
        let reference = try #require(service.captureHostTurnReference(origin: origin))
        adapter.emit(.toolCall(
            messageID: "writer-message",
            id: "real-writer-id",
            name: "write_brief",
            inputJSON: "{}"
        ), for: turn)
        await waitUntil {
            service.messages.flatMap(\.blocks).contains {
                if case .toolUse(let id, _, _) = $0 { return id == "real-writer-id" }
                return false
            }
        }
        try persistSession(
            ChatSession(id: turn.sessionID, messages: service.messages),
            at: root
        )

        service.loadSessions(from: root)
        let before = try #require(service.sessions.first {
            $0.id == turn.sessionID
        }).messages
        var changeNotifications = 0
        service.onSessionsChanged = { changeNotifications += 1 }
        service.recordHostState(
            hostRecord(state: .persisted, suffix: "late-api"),
            origin: origin,
            toolUseID: "real-writer-id",
            turnReference: reference
        )

        let after = try #require(service.sessions.first {
            $0.id == turn.sessionID
        }).messages
        #expect(after == before)
        #expect(changeNotifications == 0)
    }

    @Test("an exact host record id remains inside its referenced turn")
    func exactHostRecordIDIsTurnScoped() async throws {
        let adapter = FakeRuntimeAdapter(backend: .claudeCode)
        let service = makeService(backend: .claudeCode, adapter: adapter)
        #expect(service.send(text: "First write.", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let firstTurn = try #require(adapter.sendRequests.first)
        let firstRuntime = try #require(adapter.startRequests.first)
        let firstOrigin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: firstTurn.sessionID,
            runtimeGenerationID: firstRuntime.runtimeGenerationID
        )
        let firstReference = try #require(
            service.captureHostTurnReference(origin: firstOrigin)
        )
        let first = hostRecord(state: .persisted, suffix: "first")
        service.recordHostState(first, origin: firstOrigin, turnReference: firstReference)
        adapter.emit(.terminal(.completed(.endTurn)), for: firstTurn)
        adapter.finish(firstTurn)
        await waitUntil { !service.isStreaming }

        #expect(service.send(text: "Second write.", mentions: []))
        await waitUntil { adapter.sendRequests.count == 2 }
        let secondTurn = adapter.sendRequests[1]
        let secondOrigin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: secondTurn.sessionID,
            runtimeGenerationID: firstRuntime.runtimeGenerationID
        )
        let secondReference = try #require(
            service.captureHostTurnReference(origin: secondOrigin)
        )
        let second = hostRecord(
            state: .writeRejected,
            suffix: "second",
            id: first.id
        )
        service.recordHostState(second, origin: secondOrigin, turnReference: secondReference)

        let firstOwner = try #require(service.messages.first {
            $0.id == firstReference.inputMessageID
        })
        let secondOwner = try #require(service.messages.first {
            $0.id == secondReference.inputMessageID
        })
        #expect(firstOwner.hostStateRecords == [first])
        #expect(secondOwner.hostStateRecords == [second])

        adapter.emit(.terminal(.completed(.endTurn)), for: secondTurn)
        adapter.finish(secondTurn)
        await waitUntil { !service.isStreaming }
    }

    @Test("same-project session switching preserves a late completion on its owner")
    func sessionSwitchKeepsLateCompletionOnOwningTurn() async throws {
        let adapter = FakeRuntimeAdapter(backend: .claudeCode)
        let service = makeService(backend: .claudeCode, adapter: adapter)
        #expect(service.send(text: "Write before switching.", mentions: []))
        await waitUntil { adapter.sendRequests.count == 1 }
        let turn = try #require(adapter.sendRequests.first)
        let runtime = try #require(adapter.startRequests.first)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: turn.sessionID,
            runtimeGenerationID: runtime.runtimeGenerationID
        )
        let reference = try #require(service.captureHostTurnReference(origin: origin))
        let draft = hostRecord(state: .draft, suffix: "draft")
        service.recordHostState(draft, origin: origin, turnReference: reference)

        service.newChat()
        let newSessionID = try #require(service.currentSessionId)
        service.recordHostState(
            hostRecord(state: .persisted, suffix: "late", id: draft.id),
            origin: origin,
            turnReference: reference
        )

        #expect(service.currentSessionId == newSessionID)
        #expect(service.messages.isEmpty)
        let oldSession = try #require(service.sessions.first { $0.id == turn.sessionID })
        #expect(oldSession.messages.flatMap(\.hostStateRecords).map(\.state) == [.persisted])
    }

    @Test("fresh projection sees only the final same-record service state")
    func projectionUsesFinalServiceRecordState() throws {
        func projectedStates(_ service: AgentService) -> [AgentHostStateRecord.State] {
            AgentTranscriptProjection.turns(
                messages: service.messages,
                isStreaming: false
            ).flatMap(\.items).compactMap { item in
                guard case .hostState(let state) = item else { return nil }
                return state.record.state
            }
        }

        let persistedService = AgentService(refreshBackendStatusOnInit: false)
        persistedService.loadSessions(from: nil)
        let persistedSessionID = try #require(persistedService.currentSessionId)
        persistedService.messages = [
            AgentMessage(role: .user, blocks: [.text("Write twice.")]),
            AgentMessage(role: .assistant, blocks: [
                .toolUse(id: "repair", name: "write_brief", inputJSON: "{}"),
                .toolUse(id: "retry", name: "write_brief", inputJSON: "{}"),
            ]),
        ]
        persistedService.recordHostState(
            hostRecord(state: .persistedPhaseRecordFailed, suffix: "repair"),
            origin: .inAppChat(sessionID: persistedSessionID),
            toolUseID: "repair"
        )
        #expect(projectedStates(persistedService) == [.persistedPhaseRecordFailed])
        let retryDraft = hostRecord(state: .draft, suffix: "retry")
        persistedService.recordHostState(
            retryDraft,
            origin: .inAppChat(sessionID: persistedSessionID),
            toolUseID: "retry"
        )
        #expect(projectedStates(persistedService) == [.persistedPhaseRecordFailed, .draft])
        persistedService.recordHostState(
            hostRecord(state: .persisted, suffix: "retry", id: retryDraft.id),
            origin: .inAppChat(sessionID: persistedSessionID),
            toolUseID: "retry"
        )
        #expect(projectedStates(persistedService) == [.persisted])

        let uncertainService = AgentService(refreshBackendStatusOnInit: false)
        uncertainService.loadSessions(from: nil)
        let uncertainSessionID = try #require(uncertainService.currentSessionId)
        uncertainService.messages = [
            AgentMessage(role: .user, blocks: [.text("Check then retry.")]),
            AgentMessage(role: .assistant, blocks: [
                .toolUse(id: "checked", name: "write_brief", inputJSON: "{}"),
                .toolUse(id: "uncertain", name: "write_brief", inputJSON: "{}"),
            ]),
        ]
        uncertainService.recordHostState(
            hostRecord(state: .checked, suffix: "checked"),
            origin: .inAppChat(sessionID: uncertainSessionID),
            toolUseID: "checked"
        )
        #expect(projectedStates(uncertainService) == [.checked])
        let uncertainDraft = hostRecord(state: .draft, suffix: "uncertain")
        uncertainService.recordHostState(
            uncertainDraft,
            origin: .inAppChat(sessionID: uncertainSessionID),
            toolUseID: "uncertain"
        )
        #expect(projectedStates(uncertainService) == [.checked, .draft])
        uncertainService.recordHostState(
            hostRecord(
                state: .writeOutcomeUnavailable,
                suffix: "uncertain",
                id: uncertainDraft.id
            ),
            origin: .inAppChat(sessionID: uncertainSessionID),
            toolUseID: "uncertain"
        )
        #expect(projectedStates(uncertainService) == [.writeOutcomeUnavailable])
    }

    private func hostRecord(
        state: AgentHostStateRecord.State,
        suffix: String,
        id: UUID = UUID()
    ) -> AgentHostStateRecord {
        AgentHostStateRecord(
            id: id,
            state: state,
            phase: "brief",
            toolName: "write_brief",
            action: state == .persisted ? .reviewForApproval : .agentCorrection,
            artifactPath: PipelineLayout.briefFile,
            byteComparison: state == .persisted ? .changed : .unchanged,
            previousSHA256: String(repeating: "a", count: 64),
            currentSHA256: String(repeating: suffix == "second" ? "c" : "b", count: 64)
        )
    }

    private func persistSession(_ session: ChatSession, at root: URL) throws {
        let chat = root.appendingPathComponent(ChatSessionStore.dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        let data = try #require(ChatSessionStore.encodeSession(session))
        try data.write(
            to: chat.appendingPathComponent("\(session.id.uuidString).json"),
            options: .atomic
        )
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
        case .codexAppServer:
            #expect(descriptor.toolExecutionTransport == .hostRoundTrip)
            #expect(!descriptor.capabilities.supports(.resumeNativeSession))
            #expect(descriptor.capabilities.supports(.reportTokenUsage))
            #expect(!descriptor.capabilities.supports(.reportCostUsage))
            #expect(!descriptor.capabilities.supports(.readProjectFiles))
            #expect(!descriptor.capabilities.supports(.externalClaudeCodePlugins))
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
