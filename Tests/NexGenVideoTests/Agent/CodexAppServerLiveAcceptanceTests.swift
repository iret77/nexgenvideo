import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Codex App Server live acceptance")
struct CodexAppServerLiveAcceptanceTests {
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
            .text("Call the nexgen acceptance_echo tool exactly once with value image_received. Then briefly confirm completion."),
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
            return !isError && content.contains(.text("controlled-result"))
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
            .text("Wait before answering so cancellation can be verified."),
        ])
        let cancelStream = try firstAdapter.send(.init(
            sessionID: sessionID,
            turnID: UUID(),
            messages: [current, cancelMessage],
            currentMessage: cancelMessage
        ))
        await Task.yield()
        firstAdapter.cancel(sessionID: sessionID)
        #expect(liveTerminals(await collectLiveCodexEvents(cancelStream)) == [.cancelled])
        try await Task.sleep(for: .seconds(1))

        let coldAdapter = CodexAppServerRuntimeAdapter()
        #expect(throws: CodexAppServerError.resumeIsolationUnavailable) {
            try coldAdapter.resume(liveSession(
                sessionID: sessionID,
                providerSessionID: providerThreadID
            ))
        }
        if let evidencePath = environment["NGV_CODEX_ACCEPTANCE_EVIDENCE"] {
            let evidence: [String: Any] = [
                "cli_version": CodexAppServerContract.cliVersion,
                "protocol_revision": CodexAppServerContract.protocolRevision,
                "combined_schema_sha256": "eb1ba91bd0fab656523092f6ed7de3ea7aef278921a650f14dc871ae7dcfaf84",
                "v2_schema_sha256": "995fc3b8f8c469f6787e8fc5be4038c4f31359025edd8480b862e83355f3bf3b",
                "compatibility": "incompatible_pending_tool_inventory_and_safe_resume",
                "billing": "api_key",
                "isolated_home": true,
                "account_verified_before_thread": true,
                "text": true,
                "image_input": true,
                "typed_image_tool_result": true,
                "nexgen_tool_round_trip": true,
                "warm_dialogue": true,
                "cancel": true,
                "cold_resume_rejected": true,
                "model_catalog_count": models.count,
                "default_model_has_text_and_image": true,
                "model_visible_tool_inventory_captured": false,
                "evidence_payload_redacted": true,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: evidence,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
        }
    }

    private func liveSession(
        sessionID: UUID,
        providerSessionID: String? = nil
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
            interfaceLanguage: .init(identifier: "en", displayName: "English"),
            baseInstructions: "Follow the host contract and use only the supplied nexgen tool.",
            pack: .init(id: "acceptance", version: "1", projectSchema: "1", currentPhase: "smoke"),
            phaseInstructions: "Call acceptance_echo when requested.",
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
                guard name == "acceptance_echo", input.contains("image_received") else {
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
