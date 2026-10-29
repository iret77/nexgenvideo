import Foundation
import Testing
@testable import NexGenVideo

@Suite("Actual model response evidence")
struct AgentModelResponseEvidenceTests {
    @Test func claudeCompletedMessageCarriesItsActualModelBeforeToolBlocks() throws {
        let events = ClaudeStreamDecoder.decode(line: #"{"type":"assistant","message":{"id":"response-1","model":"observed-model","content":[{"type":"tool_use","id":"review-1","name":"write_render_review","input":{"expected_fingerprint":"bound","findings":[]}}]}}"#)
        #expect(events.count == 2)
        guard let first = events.first, case .responseMetadata(let id, let model) = first else {
            Issue.record("The actual message metadata was discarded.")
            return
        }
        #expect(id == "response-1")
        #expect(model == "observed-model")
        guard let last = events.last, case .assistantBlock(let blockID, .toolUse(let toolID, _, _)) = last else {
            Issue.record("The model response lost its tool call.")
            return
        }
        #expect(blockID == id)
        #expect(toolID == "review-1")
    }

    @Test func missingModelNeverBecomesAnObservedModel() throws {
        let events = ClaudeStreamDecoder.decode(line: #"{"type":"assistant","message":{"id":"response-1","content":[{"type":"text","text":"review"}]}}"#)
        #expect(!events.contains { if case .responseMetadata = $0 { return true }; return false })
        var decoder = AnthropicSSE.Decoder()
        let api = try decoder.consume(Data(#"{"type":"message_start","message":{"id":"response-2","usage":{"input_tokens":1}}}"#.utf8))
        #expect(!api.contains { if case .responseMetadata = $0 { return true }; return false })
    }

    @Test func anthropicUsesResponseModelAndCanonicalToolArguments() throws {
        var decoder = AnthropicSSE.Decoder()
        let events = try decoder.consume(Data(#"{"type":"message_start","message":{"id":"api-response","model":"actual-api-model","usage":{"input_tokens":3}}}"#.utf8))
        guard let first = events.first, case .responseMetadata(let id, let model) = first else {
            Issue.record("The SSE response model was discarded.")
            return
        }
        #expect(id == "api-response")
        #expect(model == "actual-api-model")
        let evidence = try AgentModelResponseEvidence(sessionID: UUID(), turnID: UUID(), messageID: id,
            modelID: model, toolUseID: "review", inputJSON: #"{"findings":[],"expected_fingerprint":"current"}"#)
        #expect(evidence.toolInputSHA256 == (try AgentModelResponseEvidence.inputHash(
            #"{ "expected_fingerprint": "current", "findings": [] }"#)))
        #expect(evidence.toolInputSHA256 != (try AgentModelResponseEvidence.inputHash(
            #"{"expected_fingerprint":"changed","findings":[]}"#)))
    }
}
