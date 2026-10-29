import Foundation
import MCP
import Testing
@testable import NexGenVideo

@Suite("MCP model-response identity")
struct MCPModelResponseIdentityTests {
    @Test func sdkMetadataCarriesClaudeIdentityWithoutUsingRequestOrArgumentIDs() throws {
        let params = try JSONDecoder().decode(CallTool.Parameters.self, from: Data(#"{"name":"write_render_review","arguments":{"toolUseId":"untrusted-argument"},"_meta":{"progressToken":"not-the-tool","claudecode/toolUseId":"toolu_actual"}}"#.utf8))
        #expect(MCPService.toolUseID(params) == "toolu_actual")
        let absent = try JSONDecoder().decode(CallTool.Parameters.self, from: Data(#"{"name":"write_render_review","arguments":{"toolUseId":"untrusted-argument"},"_meta":{"progressToken":"not-the-tool"}}"#.utf8))
        #expect(MCPService.toolUseID(absent) == nil)
    }

    @Test func modernMetadataPreservesTheSameIdentity() throws {
        let body = try MCP20260728.requestBody(id: .string("rpc-id"), method: "tools/call",
            params: ["name": .string("write_render_review"), "arguments": .object([:])])
        var wire = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        var params = try #require(wire["params"] as? [String: Any])
        var meta = try #require(params["_meta"] as? [String: Any])
        meta["claudecode/toolUseId"] = "toolu_actual"
        params["_meta"] = meta
        wire["params"] = params
        let headers = MCP20260728.requestHeaders(method: "tools/call", name: "write_render_review")
        guard case .success(let request) = MCP20260728.validate(
            body: try JSONSerialization.data(withJSONObject: wire), headers: headers) else {
            Issue.record("The actual modern MCP envelope was rejected."); return
        }
        #expect(MCPService.toolUseID(request) == "toolu_actual")
        #expect(request.id == .string("rpc-id"))
    }

    @Test(arguments: ["", " toolu_actual", "toolu_actual\n"])
    func malformedIdentityIsNotRepaired(_ value: String) {
        let params = CallTool.Parameters(name: "write_render_review",
            meta: Metadata(additionalFields: ["claudecode/toolUseId": .string(value)]))
        #expect(MCPService.toolUseID(params) == nil)
    }

    @Test func onlyExactToolServerTurnAndArgumentBytesAreAdmitted() throws {
        let turn = AgentHostTurnReference(projectGenerationID: UUID(), chatSessionID: UUID(),
            runtimeGenerationID: UUID(), logicalTurnID: UUID(), inputMessageID: UUID())
        let origin = ToolCallOrigin.embeddedRuntime(chatSessionID: turn.chatSessionID, runtimeGenerationID: turn.runtimeGenerationID)
        func evidence(name: String = "mcp__nexgen__write_render_review", session: UUID? = nil, logicalTurn: UUID? = nil) throws -> AgentModelResponseEvidence {
            try .init(sessionID: session ?? turn.chatSessionID, turnID: logicalTurn ?? turn.logicalTurnID,
                messageID: "msg_actual", modelID: "actual-model", toolUseID: "toolu_actual", toolName: name,
                inputJSON: #"{"expected_fingerprint":"current","findings":[]}"#)
        }
        let args: [String: Any] = ["findings": [], "expected_fingerprint": "current"]
        let good = try evidence()
        try good.requireHostCall(tool: "write_render_review", origin: origin, turn: turn, toolUseID: "toolu_actual", arguments: args)
        #expect(good.toolName == "mcp__nexgen__write_render_review")
        #expect(good.matchesHostTool("write_render_review"))
        for name in ["mcp__other__write_render_review", "write_render_review", "mcp__nexgen__get_render_review_inputs"] {
            #expect(throws: (any Error).self) {
                try evidence(name: name).requireHostCall(tool: "write_render_review", origin: origin, turn: turn, toolUseID: "toolu_actual", arguments: args)
            }
        }
        #expect(throws: (any Error).self) { try evidence(session: UUID()).requireHostCall(tool: "write_render_review", origin: origin, turn: turn, toolUseID: "toolu_actual", arguments: args) }
        #expect(throws: (any Error).self) { try evidence(logicalTurn: UUID()).requireHostCall(tool: "write_render_review", origin: origin, turn: turn, toolUseID: "toolu_actual", arguments: args) }
        #expect(throws: (any Error).self) { try good.requireHostCall(tool: "write_render_review", origin: origin, turn: turn, toolUseID: "other-tool", arguments: args) }
        #expect(throws: (any Error).self) { try good.requireHostCall(tool: "write_render_review", origin: origin, turn: turn, toolUseID: "toolu_actual", arguments: ["findings": [], "expected_fingerprint": "changed"]) }
        #expect(throws: (any Error).self) { try good.requireHostCall(tool: "write_render_review", origin: .externalMCP(sessionID: UUID()), turn: turn, toolUseID: "toolu_actual", arguments: args) }
        #expect(throws: (any Error).self) { try good.requireHostCall(tool: "write_render_review", origin: .embeddedRuntime(chatSessionID: turn.chatSessionID, runtimeGenerationID: UUID()), turn: turn, toolUseID: "toolu_actual", arguments: args) }
        let api = try evidence(name: "write_render_review")
        try api.requireHostCall(tool: "write_render_review", origin: .inAppChat(sessionID: turn.chatSessionID), turn: turn, toolUseID: "toolu_actual", arguments: args)
        #expect(!((try evidence(name: "mcp__other__write_render_review")).matchesHostTool("write_render_review")))
    }
}

@MainActor
@Suite("Model-response rendezvous")
struct AgentModelEvidenceRendezvousTests {
    private func evidence(session: UUID, turn: UUID, tool: String = "toolu_actual", input: String = "{}") throws -> AgentModelResponseEvidence {
        try .init(sessionID: session, turnID: turn, messageID: "msg_actual", modelID: "actual-model",
            toolUseID: tool, toolName: "mcp__nexgen__write_render_review", inputJSON: input)
    }

    private func registered(_ rendezvous: AgentModelEvidenceRendezvous) async throws {
        for _ in 0..<100 where rendezvous.pendingCount == 0 { await Task.yield() }
        try #require(rendezvous.pendingCount == 1)
    }

    @Test(arguments: [false, true])
    func bothPipeAndHTTPArrivalOrdersUseTheActualResponse(responseFirst: Bool) async throws {
        let rendezvous = AgentModelEvidenceRendezvous(), session = UUID(), turn = UUID()
        rendezvous.begin(sessionID: session, turnID: turn)
        let actual = try evidence(session: session, turn: turn)
        if responseFirst { rendezvous.receive(actual) }
        let task = Task { await rendezvous.wait(for: .init(sessionID: session, turnID: turn, toolUseID: actual.toolUseID)) }
        if !responseFirst {
            try await registered(rendezvous)
            rendezvous.receive(try evidence(session: session, turn: turn, tool: "another-call"))
            #expect(rendezvous.pendingCount == 1)
            rendezvous.receive(actual)
        }
        #expect(await task.value == actual)
        #expect(rendezvous.pendingCount == 0)
    }

    @Test(arguments: ["cancel", "rotate", "finish"])
    func pendingCallsCannotSurviveCancellationOrRotation(_ end: String) async throws {
        let rendezvous = AgentModelEvidenceRendezvous(), session = UUID(), turn = UUID()
        rendezvous.begin(sessionID: session, turnID: turn)
        let task = Task { await rendezvous.wait(for: .init(sessionID: session, turnID: turn, toolUseID: "toolu_actual")) }
        try await registered(rendezvous)
        if end == "cancel" { task.cancel() }
        else if end == "rotate" { rendezvous.begin(sessionID: session, turnID: UUID()) }
        else { rendezvous.invalidate() }
        #expect(await task.value == nil)
        #expect(rendezvous.pendingCount == 0)
    }

    @Test func absentMetadataTimesOutAndConflictingResponseNeverReplacesTheOriginal() async throws {
        let rendezvous = AgentModelEvidenceRendezvous(), session = UUID(), turn = UUID()
        rendezvous.begin(sessionID: session, turnID: turn)
        #expect(await rendezvous.wait(for: .init(sessionID: session, turnID: turn, toolUseID: "absent"), timeout: .milliseconds(10)) == nil)
        #expect(rendezvous.pendingCount == 0)
        rendezvous.receive(try evidence(session: session, turn: turn))
        rendezvous.receive(try evidence(session: session, turn: turn, input: #"{"changed":true}"#))
        #expect(await rendezvous.wait(for: .init(sessionID: session, turnID: turn, toolUseID: "toolu_actual")) == nil)
        #expect(await rendezvous.wait(for: .init(sessionID: session, turnID: UUID(), toolUseID: "toolu_actual")) == nil)
    }
}
