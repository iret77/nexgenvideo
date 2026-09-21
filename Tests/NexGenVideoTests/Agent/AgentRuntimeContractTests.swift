import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Agent runtime contract")
struct AgentRuntimeContractTests {
    @Test("event fence rejects foreign sessions, foreign turns, and every event after the terminal")
    func eventFenceEnforcesTurnIsolationAndOneTerminal() {
        let sessionID = UUID()
        let turnID = UUID()
        var fence = AgentRuntimeEventFence()
        fence.begin(sessionID: sessionID, turnID: turnID)

        #expect(!fence.accepts(.init(
            sessionID: UUID(),
            turnID: turnID,
            event: .text(messageID: nil, value: "foreign session", isDelta: true)
        )))
        #expect(!fence.accepts(.init(
            sessionID: sessionID,
            turnID: UUID(),
            event: .text(messageID: nil, value: "foreign turn", isDelta: true)
        )))
        #expect(fence.accepts(.init(
            sessionID: sessionID,
            turnID: turnID,
            event: .text(messageID: nil, value: "accepted", isDelta: true)
        )))
        #expect(fence.accepts(.init(
            sessionID: sessionID,
            turnID: turnID,
            event: .terminal(.completed(.endTurn))
        )))
        #expect(fence.receivedTerminal)
        #expect(!fence.accepts(.init(
            sessionID: sessionID,
            turnID: turnID,
            event: .terminal(.failed)
        )))
        #expect(!fence.accepts(.init(
            sessionID: sessionID,
            turnID: turnID,
            event: .text(messageID: nil, value: "late", isDelta: true)
        )))
    }

    @Test("relay emits exactly one terminal and closes against late provider events")
    func relayEmitsExactlyOneTerminal() async {
        let sessionID = UUID()
        let turnID = UUID()
        let relay = AgentRuntimeEventRelay(sessionID: sessionID, turnID: turnID)
        let stream = relay.stream

        relay.yield(.text(messageID: "m1", value: "before", isDelta: true))
        relay.finish(.cancelled)
        relay.finish(.failed)
        relay.yield(.text(messageID: "m1", value: "after", isDelta: true))

        let envelopes = await collectRuntimeEvents(stream)
        #expect(envelopes.map(\.sessionID) == [sessionID, sessionID])
        #expect(envelopes.map(\.turnID) == [turnID, turnID])
        #expect(envelopes.count == 2)
        #expect(terminalEvents(in: envelopes) == [.cancelled])
        #expect(relay.terminal == .cancelled)
    }

    @Test("usage snapshots merge fields without erasing earlier provider values")
    func usageMergingKeepsEarlierValues() {
        let initial = AgentRuntimeUsage(
            inputTokens: 120,
            outputTokens: nil,
            cacheCreationInputTokens: 30,
            cacheReadInputTokens: nil,
            costUSD: nil
        )
        let merged = initial.merging(.init(
            outputTokens: 45,
            cacheReadInputTokens: 80,
            costUSD: 0.012
        ))

        #expect(merged == .init(
            inputTokens: 120,
            outputTokens: 45,
            cacheCreationInputTokens: 30,
            cacheReadInputTokens: 80,
            costUSD: 0.012
        ))
    }

    @Test("host context owns locale, pack identity, phase instructions, schemas, and authorities")
    func hostContextCompositionIsBackendNeutral() {
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
            phaseInstructions: "  Write the canonical story artifact.  ",
            toolSchemas: [schema],
            authority: [
                .toolSchemas,
                .toolExecution,
                .structuredDialogs,
                .outputApprovals,
                .gateRefusals,
            ]
        )

        #expect(context.interfaceLanguage == language)
        #expect(context.toolSchemas.map(\.name) == ["host_tool"])
        #expect(context.authority == [
            .toolSchemas,
            .toolExecution,
            .structuredDialogs,
            .outputApprovals,
            .gateRefusals,
        ])
        #expect(context.systemInstructions.contains("German (de-DE)"))
        #expect(context.systemInstructions.contains("Format pack: musicvideo 3.2.1 (project schema 7)."))
        #expect(context.systemInstructions.contains("Current phase: story."))
        #expect(context.systemInstructions.contains("  Write the canonical story artifact.  "))
    }

    @Test("capabilities tell the truth for host-round-trip and provider-managed backends")
    func capabilitiesReflectExecutableOperations() {
        let names: Set<String> = [
            ToolName.showDialog.rawValue,
            ToolName.generateImage.rawValue,
            "host_tool",
        ]
        let anthropic = AgentBackend.anthropicAPI.runtimeDescriptor(
            toolNames: names,
            providerExtensions: ["ignored-by-anthropic"]
        )
        let claude = AgentBackend.claudeCode.runtimeDescriptor(
            toolNames: names,
            providerExtensions: ["mcp:ace", "claude-code-plugin:review"]
        )

        #expect(anthropic.toolExecutionTransport == .hostRoundTrip)
        #expect(anthropic.identity.backendID == .anthropicAPI)
        #expect(anthropic.authentication == .apiKey(service: "Anthropic"))
        #expect(anthropic.capabilities.toolNames == names)
        #expect(anthropic.capabilities.providerExtensions.isEmpty)
        #expect(anthropic.capabilities.supports(.executeHostTools))
        #expect(anthropic.capabilities.supports(.structuredDialogs))
        #expect(anthropic.capabilities.supports(.approvalSuspension))
        #expect(anthropic.capabilities.supports(.resumeFromTranscript))
        #expect(anthropic.capabilities.supports(.reportTokenUsage))
        #expect(!anthropic.capabilities.supports(.resumeNativeSession))
        #expect(!anthropic.capabilities.supports(.reportCostUsage))
        #expect(!anthropic.capabilities.supports(.externalClaudeCodePlugins))
        #expect(!anthropic.capabilities.supports(.readProjectFiles))
        #expect(!anthropic.capabilities.supports(.webResearch))

        #expect(claude.toolExecutionTransport == .providerManagedMCP)
        #expect(claude.identity.backendID == .claudeCode)
        #expect(claude.authentication == .externalSubscription(command: "claude"))
        #expect(claude.capabilities.toolNames == names)
        #expect(claude.capabilities.providerExtensions == ["mcp:ace", "claude-code-plugin:review"])
        #expect(claude.capabilities.supports(.executeHostTools))
        #expect(claude.capabilities.supports(.structuredDialogs))
        #expect(claude.capabilities.supports(.approvalSuspension))
        #expect(claude.capabilities.supports(.resumeNativeSession))
        #expect(claude.capabilities.supports(.reportCostUsage))
        #expect(claude.capabilities.supports(.externalClaudeCodePlugins))
        #expect(claude.capabilities.supports(.readProjectFiles))
        #expect(!claude.capabilities.supports(.resumeFromTranscript))
        #expect(!claude.capabilities.supports(.reportTokenUsage))
        #expect(!claude.capabilities.supports(.webResearch))
    }
}

@MainActor
private func collectRuntimeEvents(
    _ stream: AsyncStream<AgentRuntimeEventEnvelope>
) async -> [AgentRuntimeEventEnvelope] {
    var result: [AgentRuntimeEventEnvelope] = []
    for await event in stream {
        result.append(event)
    }
    return result
}

private func terminalEvents(
    in envelopes: [AgentRuntimeEventEnvelope]
) -> [AgentRuntimeTerminal] {
    envelopes.compactMap {
        guard case .terminal(let terminal) = $0.event else { return nil }
        return terminal
    }
}
