import Foundation
import Testing

@testable import NexGenVideo

@Suite("AgentBlocks — strict schema parse")
struct AgentBlocksTests {

    private func blocks(_ items: [[String: Any]]) throws -> [AgentBlock] {
        try AgentBlocks.parse(["blocks": items])
    }

    @Test func parsesTheFullVocabulary() throws {
        let parsed = try blocks([
            ["type": "headline", "text": "Where we are", "symbol": "film"],
            ["type": "text", "body": "Rough is fine — I'll shape it."],
            ["type": "status", "badges": [["label": "Mode", "value": "beat"], ["label": "Budget", "value": "€50", "symbol": "eurosign.circle"]]],
            ["type": "keyvalue", "title": "Brief", "rows": [["Mission", "Launch video"], ["Platform", "TikTok"]]],
            ["type": "callout", "tone": "info", "text": "Nothing spent yet."],
        ])
        #expect(parsed.count == 5)
        #expect(parsed[0] == .headline(text: "Where we are", symbol: "film"))
        #expect(parsed[4] == .callout(tone: .info, text: "Nothing spent yet."))
        if case .status(let badges) = parsed[2] {
            #expect(badges.count == 2)
            #expect(badges[1].symbol == "eurosign.circle")
        } else {
            Issue.record("expected status block")
        }
    }

    @Test func rejectsUnknownBlockType() {
        #expect(throws: ToolError.self) {
            _ = try blocks([["type": "table", "rows": []]])
        }
    }

    @Test func rejectsUnknownKeys() {
        // additionalProperties: false — the constraint that keeps the solution space closed.
        #expect(throws: ToolError.self) {
            _ = try blocks([["type": "text", "body": "hi", "color": "red"]])
        }
    }

    @Test func rejectsBadTone() {
        #expect(throws: ToolError.self) {
            _ = try blocks([["type": "callout", "tone": "danger", "text": "x"]])
        }
    }

    @Test func rejectsEmptyRequiredText() {
        #expect(throws: ToolError.self) {
            _ = try blocks([["type": "headline", "text": "   "]])
        }
    }

    @Test func rejectsEmptyAndOversizedContainers() {
        #expect(throws: ToolError.self) { _ = try AgentBlocks.parse([:]) }
        #expect(throws: ToolError.self) { _ = try AgentBlocks.parse(["blocks": [[String: Any]]()]) }
        #expect(throws: ToolError.self) {
            _ = try blocks([["type": "status", "badges": [[String: Any]]()]])
        }
        #expect(throws: ToolError.self) {
            _ = try blocks([["type": "keyvalue", "rows": [["only-one-column"]]]])
        }
        let tooMany = Array(repeating: ["type": "text", "body": "x"] as [String: Any],
                            count: AgentBlocks.maxBlocks + 1)
        #expect(throws: ToolError.self) { _ = try blocks(tooMany) }
    }

    @Test func enforcesBoundedResultGrammar() {
        #expect(throws: ToolError.self) {
            _ = try blocks([
                ["type": "text", "body": "Result"],
                ["type": "headline", "text": "Late headline"],
            ])
        }
        #expect(throws: ToolError.self) {
            _ = try blocks([
                ["type": "callout", "tone": "info", "text": "Not last"],
                ["type": "text", "body": "Result"],
            ])
        }
        #expect(throws: ToolError.self) {
            _ = try blocks([
                ["type": "status", "badges": [["label": "One", "value": "Done"]]],
                ["type": "status", "badges": [["label": "Two", "value": "Done"]]],
            ])
        }
    }

    @Test func rejectsUnboundedRichText() {
        #expect(throws: ToolError.self) {
            _ = try blocks([[
                "type": "text",
                "body": String(repeating: "x", count: AgentBlocks.maxBodyLength + 1),
            ]])
        }
        #expect(throws: ToolError.self) {
            _ = try blocks([[
                "type": "keyvalue",
                "rows": [["", "value"]],
            ]])
        }
    }

    @Test func legacySavedPayloadsRemainRenderableWithoutWeakeningNewCalls() throws {
        let legacy = Array(repeating: ["type": "text", "body": "Saved result"] as [String: Any], count: 8)
            + [["type": "headline", "text": "Legacy trailing headline"] as [String: Any]]

        #expect(throws: ToolError.self) {
            _ = try blocks(legacy)
        }
        let rendered = try #require(AgentBlocks.parseForRendering(["blocks": legacy]))
        #expect(rendered.count == 9)

        #expect(AgentBlocks.parseForRendering([
            "blocks": [["type": "unknown", "text": "unsafe"]],
        ]) == nil)
        #expect(AgentBlocks.parseForRendering([
            "blocks": [[
                "type": "text",
                "body": String(repeating: "x", count: AgentBlocks.maxBodyLength + 1),
            ]],
        ]) == nil)
    }
}
