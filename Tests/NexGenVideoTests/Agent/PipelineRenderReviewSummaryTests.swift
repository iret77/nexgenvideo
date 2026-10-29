import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Bounded review summaries preserve complete findings and exact item coverage")
struct PipelineRenderReviewSummaryTests {
    private typealias Receipt = PipelineRenderReviewRunReceipt
    private let manifest = String(repeating: "a", count: 64)
    private let page = String(repeating: "b", count: 64)
    private let source = CanonicalArtifactReferenceV1(id: "frame", role: "evidence", path: "frames/frame.png", sha256: String(repeating: "c", count: 64))

    private func submission(items: [String], text: String, findingCount: Int = 0) -> Receipt.Submission {
        .init(manifestID: manifest, pageID: page,
            observations: items.map { .init(itemID: $0, text: text) },
            findings: (0..<findingCount).map { index in
                .init(id: "finding-\(index)", kind: .unresolved, category: .stateAndProps,
                    shotIDs: ["shot-1"], message: String(repeating: "\"\\", count: 512), evidence: [source])
            })
    }

    @Test func completeFindingsAndUnicodeSurviveChunkingAndNoSummaryCanReplaceTheirUnion() throws {
        let text = String(repeating: "Ä 🎬 ", count: 25)
        let value = submission(items: (0..<8).map { "item-\($0)" }, text: text, findingCount: 8)
        try value.validate(manifestID: manifest, pageID: page, itemIDs: value.observations.map(\.itemID),
            shotIDs: ["shot-1"], references: [source])
        let bytes = try PlanningWriterIO.json(value)
        let ref = PlanningWriterIO.reference("render-review/runs/fixture/page.v2.json", id: page,
            role: "host.render-review-child-page", bytes: bytes)
        let units = try PipelineRenderReviewSummary.units(reference: ref, submission: value, includeFindings: true)
        #expect(Data(units.map(\.text).joined().utf8) == bytes)
        #expect(units.allSatisfy { $0.text.utf8.count <= 4096 })
        #expect(units.map(\.ordinal) == Array(units.indices))
        #expect(units.allSatisfy { $0.count == units.count && $0.source == ref })
        let contexts = try PipelineRenderReviewSummary.contexts(manifestID: manifest, units: units, kind: .reducer)
        #expect(contexts.flatMap(\.units) == units)
        #expect(contexts.allSatisfy { $0.units.count <= 4 })
        #expect(try PipelineRenderReviewSummary.contexts(manifestID: manifest, units: units, kind: .reducer) == contexts)
        #expect(value.namespacedFindings(reviewID: ref.sha256).count == 8)
        let another = Receipt.Submission(manifestID: manifest, pageID: String(repeating: "d", count: 64),
            observations: [], findings: value.findings)
        #expect(Set((value.namespacedFindings(reviewID: ref.sha256) + another.namespacedFindings(reviewID: ref.sha256)).map(\.id)).count == 16)
        #expect(Set((value.namespacedFindings(reviewID: ref.sha256)
            + value.namespacedFindings(reviewID: String(repeating: "e", count: 64))).map(\.id)).count == 16)
    }

    @Test func worstCaseQuotedObservationsShrinkEachReductionAndRemainWithinTheContextBound() throws {
        let items = (0..<4).map { index in String(repeating: String(index), count: 64) }
        for text in [String(repeating: "\"", count: 512), String(repeating: "\\", count: 512), "x" + String(repeating: "\t", count: 511)] {
            let value = submission(items: items, text: text)
            try value.validate(manifestID: manifest, pageID: page, itemIDs: items, shotIDs: ["shot-1"], references: [source], kind: .reducer)
            let ref = PlanningWriterIO.reference("render-review/runs/fixture/reducer.v2.json", id: page,
                role: "host.render-review-child-page", bytes: try PlanningWriterIO.json(value))
            let reduced = try PipelineRenderReviewSummary.units(reference: ref, submission: value, includeFindings: false)
            #expect(reduced.count <= 2)
            let large = (0..<4).map { index in
                PipelineRenderReviewSummary.Unit(id: items[index], source: ref, ordinal: index, count: 4,
                    text: String(repeating: text, count: 8))
            }
            let context = try #require(PipelineRenderReviewSummary.contexts(manifestID: manifest, units: large, kind: .reducer).first)
            let result = try context.content()
            let actual = try AgentReviewChildContextBudget.estimateRequest(JSONEncoder().encode(result.toMCPResult()))
            #expect(actual + 16_384 < PipelineRenderReviewRunStore.bounds().maximumEstimatedInputTokens)
        }
        for count in [1, 2, 32, 51, 1000] { #expect(try PipelineRenderReviewSummary.maximumContexts(pageCount: count) > 0) }
        #expect(throws: GateBlocked.self) { try PipelineRenderReviewSummary.maximumContexts(pageCount: Int.max) }
        #expect(throws: GateBlocked.self) { try PipelineRenderReviewSummary.maximumContexts(pageCount: 0) }
    }

    @Test func missingDuplicatedOverlongAndControlCharacterObservationsCannotPublish() throws {
        for value in [submission(items: [], text: "observed"), submission(items: ["one", "one"], text: "observed"),
                      submission(items: ["one"], text: String(repeating: "x", count: 513)),
                      submission(items: ["one"], text: "observed\u{0001}"), submission(items: ["one"], text: "  ")] {
            #expect(throws: GateBlocked.self) {
                try value.validate(manifestID: manifest, pageID: page, itemIDs: ["one"], shotIDs: ["shot-1"], references: [source])
            }
        }
        let extra = #"{"manifestID":"a","pageID":"b","observations":[],"findings":[],"acceptance":"approved"}"#
        #expect(throws: GateBlocked.self) { try Receipt.decodeSubmission(extra) }
    }

    @Test func contextualJoinersAndEmojiPreserveMultilingualTextAndOriginalBytes() throws {
        let england = "\u{1f3f4}\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}"
        let scotland = "\u{1f3f4}\u{e0067}\u{e0062}\u{e0073}\u{e0063}\u{e0074}\u{e007f}"
        let wales = "\u{1f3f4}\u{e0067}\u{e0062}\u{e0077}\u{e006c}\u{e0073}\u{e007f}"
        for text in ["e\u{0301}", "می\u{200c}خواهم", "ن\u{064e}\u{200c}ا", "क्\u{200c}ष", "क्\u{200d}ष",
                     "क्\u{0301}\u{200c}\u{0301}ष", "क्\u{200d}", "ශ්\u{200d}රී ලංකා", "ദൃക്\u{200c}സാക്ഷി",
                     "❤️", "❤︎", "1️⃣", "👍🏽", "🇩🇪", "👩🏽‍🎬", "👨‍👩‍👧‍👦", "👩‍❤️‍💋‍👩", "🏴‍☠️",
                     england, scotland, wales, "e\u{0301} " + england, "日本語 العربية עברית\r\nObserved\t🎬"] {
            let value = Receipt.Submission(manifestID: manifest, pageID: page,
                observations: [.init(itemID: "one", text: text)],
                findings: [.init(id: "finding", kind: .unresolved, category: .stateAndProps,
                    shotIDs: ["shot-1"], message: text, evidence: [source])])
            try value.validate(manifestID: manifest, pageID: page, itemIDs: ["one"], shotIDs: ["shot-1"], references: [source])
            let decoded = try JSONDecoder().decode(Receipt.Submission.self, from: PlanningWriterIO.json(value))
            #expect(Data(decoded.observations[0].text.utf8) == Data(text.utf8))
            #expect(Data(decoded.findings[0].message.utf8) == Data(text.utf8))
        }
    }

    @Test func visibleBasesCannotAuthorizeInvisibleRunsOrUnrelatedJoinControls() throws {
        let run = "Observed" + String(repeating: "\u{200c}\u{200d}\u{fe0f}\u{fe0e}", count: 24)
        for text in [run, "a\u{200c}", "a\u{200c}b", "a\u{200d}b", "a\u{fe0f}", "a\u{fe0e}",
                     "👩\u{200d}\u{200d}🎬", "👩\u{200d}", "👩\u{200d}a", "❤️\u{fe0f}", "❤\u{fe0e}\u{fe0f}",
                     "👍🏽\u{fe0f}", "😀\u{fe0f}", "🇩\u{fe0f}", "ب\u{200c}\u{200c}ب", "न\u{200d}म",
                     "a्\u{200d}", "क्\u{200c}a", "ب\u{200c}ܐ", "क्\u{200d}ा", "क्\u{200d}\u{200c}ष",
                     "Visible\u{2029}", "Visible\u{0085}", "Visible\u{000b}", "Visible\u{000c}",
                     "Visible\u{200e}", "Visible\u{200f}", "Visible\u{061c}", "Visible\u{00ad}", "Visible\u{034f}",
                     "a\u{fe00}", "a\u{fe0d}", "\u{1f3f4}\u{e0067}\u{e007f}", "\u{1f3f4}\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}"] {
            #expect(text.utf8.count <= 512)
            let observation = submission(items: ["one"], text: text)
            #expect(throws: GateBlocked.self) {
                try observation.validate(manifestID: manifest, pageID: page, itemIDs: ["one"], shotIDs: ["shot-1"], references: [source])
            }
            let finding = Receipt.Submission(manifestID: manifest, pageID: page,
                observations: [.init(itemID: "one", text: "Observed")],
                findings: [.init(id: "finding", kind: .unresolved, category: .stateAndProps,
                    shotIDs: ["shot-1"], message: text, evidence: [source])])
            #expect(throws: GateBlocked.self) {
                try finding.validate(manifestID: manifest, pageID: page, itemIDs: ["one"], shotIDs: ["shot-1"], references: [source])
            }
        }
    }

    @Test func encodedReceiptsCannotExceedTheirAuthorizedPageOrReducerUnits() throws {
        let longSource = CanonicalArtifactReferenceV1(id: "frame", role: "evidence",
            path: "frames/" + String(repeating: "景", count: 800) + ".png", sha256: source.sha256)
        let findings = (0..<8).map { index in
            RenderReviewV1.Finding(id: "finding-\(index)", kind: .unresolved, category: .stateAndProps,
                shotIDs: ["shot-1"], message: "Inspect source", evidence: Array(repeating: longSource, count: 4))
        }
        let value = Receipt.Submission(manifestID: manifest, pageID: page,
            observations: [.init(itemID: "one", text: "Observed")], findings: findings)
        #expect(try PlanningWriterIO.json(value).count > 65_536)
        #expect(throws: GateBlocked.self) {
            try value.validate(manifestID: manifest, pageID: page, itemIDs: ["one"], shotIDs: ["shot-1"], references: [longSource])
        }
        #expect(throws: GateBlocked.self) {
            try PipelineRenderReviewSummary.units(reference: source, submission: value, includeFindings: true)
        }
        let items = (0..<8).map { String(repeating: "x", count: 64) + String($0) }
        let reducer = submission(items: items, text: String(repeating: "\"", count: 512))
        #expect(throws: GateBlocked.self) {
            try reducer.validate(manifestID: manifest, pageID: page, itemIDs: items,
                shotIDs: ["shot-1"], references: [source], kind: .reducer)
        }
    }

    @Test func findingsRejectDirectionalControlsButPreserveNormalMultilingualText() throws {
        for message in ["Visible\u{202e}hidden", "Visible\u{0001}", "Visible\u{2066}hidden", "\u{200b}", "\u{feff}",
                        "\u{2800}", "\u{3164}", "\u{200d}", "\u{fe0f}", "\u{0301}", "Visible\u{e0061}",
                        "Visible\u{e0100}", "Visible\u{2028}", "Visible\u{fff9}", "Visible\u{ffff}", "Visible\u{e000}"] {
            let observation = submission(items: ["one"], text: message)
            #expect(throws: GateBlocked.self) {
                try observation.validate(manifestID: manifest, pageID: page, itemIDs: ["one"], shotIDs: ["shot-1"], references: [source])
            }
            let value = Receipt.Submission(manifestID: manifest, pageID: page,
                observations: [.init(itemID: "one", text: "Observed")],
                findings: [.init(id: "finding", kind: .unresolved, category: .stateAndProps,
                    shotIDs: ["shot-1"], message: message, evidence: [source])])
            #expect(throws: GateBlocked.self) {
                try value.validate(manifestID: manifest, pageID: page, itemIDs: ["one"], shotIDs: ["shot-1"], references: [source])
            }
        }
        let text = "日本語 العربية 👩‍🎬\r\nObserved"
        let value = Receipt.Submission(manifestID: manifest, pageID: page,
            observations: [.init(itemID: "one", text: text)],
            findings: [.init(id: String(repeating: "a", count: 96), kind: .unresolved, category: .stateAndProps,
                shotIDs: ["shot-1"], message: text, evidence: [source])])
        try value.validate(manifestID: manifest, pageID: page, itemIDs: ["one"], shotIDs: ["shot-1"], references: [source])
        var raw = try #require(JSONSerialization.jsonObject(with: PlanningWriterIO.json(value)) as? [String: Any])
        var finding = try #require((raw["findings"] as? [[String: Any]])?.first)
        finding["acceptance"] = "approved"
        raw["findings"] = [finding]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
        do {
            _ = try Receipt.decodeSubmission(json)
            Issue.record("A model finding cannot declare its own acceptance.")
        } catch let error as ToolError {
            #expect(error.message.hasSuffix(": unknown field 'acceptance'"))
        }
    }

    @Test func immutableReceiptPublicationRejectsReplacementLinksAndProjectHomeFallbacks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("pipeline")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = "render-review/runs/receipt.json"
        let first = try Receipt.publish(["text": "original"], path: path, id: "receipt", role: "host", dataRoot: root)
        #expect(try Receipt.publish(["text": "original"], path: path, id: "receipt", role: "host", dataRoot: root) == first)
        #expect(throws: (any Error).self) { try Receipt.publish(["text": "replacement"], path: path, id: "receipt", role: "host", dataRoot: root) }
        #expect(try FileDigest.sha256(of: root.appendingPathComponent(path)) == first.sha256)
        let blocked = "render-review/runs/blocked.json"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(blocked), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("render-review/runs"), withIntermediateDirectories: true)
        try PlanningWriterIO.json(["text": "original"]).write(to: home.appendingPathComponent(blocked))
        #expect(throws: (any Error).self) { try Receipt.publish(["text": "original"], path: blocked, id: "blocked", role: "host", dataRoot: root) }
        let linked = "render-review/runs/link.json"
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(linked), withDestinationURL: home.appendingPathComponent(blocked))
        #expect(throws: (any Error).self) { try Receipt.publish(["text": "original"], path: linked, id: "link", role: "host", dataRoot: root) }
        for prefix in ["", "pipeline/"] {
            for suffix in ["manifests/a.v2.json", "runs/run/authorizations/auth.v2.json", "runs/run/page/page.v2.json", "input-images/a.png"] {
                #expect(throws: (any Error).self) { try ToolExecutor.requirePipelineAssetCopyPath(prefix + "render-review/" + suffix, source: false) }
            }
        }
    }
}
