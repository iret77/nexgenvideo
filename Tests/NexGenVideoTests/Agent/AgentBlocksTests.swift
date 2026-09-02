import Foundation
import Testing

@testable import NexGenVideo

@Suite("AgentBlocks — strict schema parse")
struct AgentBlocksTests {

    private func blocks(_ items: [[String: Any]]) throws -> [AgentBlock] {
        try AgentBlocks.parse([
            "version": AgentBlocks.currentVersion,
            "blocks": items,
        ])
    }

    @Test func parsesTheFullVocabulary() throws {
        let parsed = try blocks([
            ["type": "headline", "text": "Where we are"],
            ["type": "text", "body": "Rough is fine — I'll shape it."],
            ["type": "status", "badges": [["label": "Mode", "value": "beat"], ["label": "Budget", "value": "€50"]]],
            ["type": "keyvalue", "title": "Brief", "rows": [["Mission", "Launch video"], ["Platform", "TikTok"]]],
            ["type": "callout", "tone": "info", "text": "Nothing spent yet."],
        ])
        #expect(parsed.count == 5)
        #expect(parsed[0] == .headline(text: "Where we are", symbol: nil))
        #expect(parsed[4] == .callout(tone: .info, text: "Nothing spent yet."))
        if case .status(let badges) = parsed[2] {
            #expect(badges.count == 2)
            #expect(badges[1].symbol == nil)
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
        #expect(throws: ToolError.self) {
            _ = try blocks([["type": "headline", "text": "hi", "symbol": "sparkles"]])
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
        #expect(throws: ToolError.self) {
            _ = try AgentBlocks.parse([
                "version": AgentBlocks.currentVersion,
                "blocks": [[String: Any]](),
            ])
        }
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
        #expect(throws: ToolError.self) {
            _ = try blocks([
                ["type": "text", "body": "One"],
                ["type": "text", "body": "Two"],
            ])
        }
        #expect(throws: ToolError.self) {
            _ = try blocks([
                ["type": "status", "badges": [["label": "State", "value": "Done"]]],
                ["type": "text", "body": "Late body"],
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
            + [[
                "type": "headline",
                "text": "Legacy trailing headline",
                "symbol": "film",
            ] as [String: Any]]

        #expect(throws: ToolError.self) {
            _ = try blocks(legacy)
        }
        let rendered = try #require(AgentBlocks.parseForRendering(["blocks": legacy]))
        #expect(rendered.count == 9)
        #expect(rendered.last == .headline(text: "Legacy trailing headline", symbol: "film"))

        #expect(AgentBlocks.parseForRendering([
            "version": AgentBlocks.currentVersion,
            "blocks": [["type": "headline", "text": "Unsafe", "symbol": "sparkles"]],
        ]) == nil)
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

    @Test func currentPayloadsAreVersionedAndRootClosed() {
        #expect(throws: ToolError.self) {
            _ = try AgentBlocks.parse([
                "blocks": [["type": "text", "body": "Unversioned"]],
            ])
        }
        #expect(throws: ToolError.self) {
            _ = try AgentBlocks.parse([
                "version": "2",
                "blocks": [["type": "text", "body": "Future"]],
            ])
        }
        #expect(throws: ToolError.self) {
            _ = try AgentBlocks.parse([
                "version": AgentBlocks.currentVersion,
                "blocks": [["type": "text", "body": "Current"]],
                "layout": "dashboard",
            ])
        }
    }
}
