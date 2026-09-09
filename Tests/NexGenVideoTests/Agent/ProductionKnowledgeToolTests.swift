import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Production knowledge retrieval")
@MainActor
struct ProductionKnowledgeToolTests {
    private func text(_ result: ToolResult) throws -> String {
        guard let first = result.content.first, case .text(let value) = first else {
            throw ToolError("Expected knowledge text.")
        }
        return value
    }

    @Test("named recipes are searchable and the complete blueprint index is pageable")
    func recipeSearch() throws {
        let executor = ToolExecutor(editorProvider: { nil })
        let named = try text(executor.getProductionKnowledge(["operation": "search", "query": "Wes Anderson"]))
        #expect(named.contains("director-wes-anderson-symmetry-deadpan"))
        let first = try text(executor.getProductionKnowledge(["operation": "search", "query": "film-production-blueprints"]))
        let object = try #require(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        #expect(object["total"] as? Int == 42)
        #expect(object["nextOffset"] as? Int == 25)
        let last = try text(executor.getProductionKnowledge(["operation": "search", "query": "film-production-blueprints", "offset": 25]))
        let remaining = try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        #expect((remaining["entries"] as? [[String: String]])?.count == 17)
        #expect(remaining["nextOffset"] == nil)
    }

    @Test("a complete runbook retains its final constraints and NGV precedence")
    func completeProcedure() throws {
        let executor = ToolExecutor(editorProvider: { nil })
        let result = try text(executor.getProductionKnowledge([
            "operation": "read", "entryID": "film-production-workflows/workflows-a32d2b8635bd",
        ]))
        #expect(result.contains("W10 — Storyboard-first production model"))
        #expect(result.contains("a document beside the bible is ignored by the next session"))
        #expect(result.contains("ngv-phase-order"))
        #expect(result.contains("0333751214c7af17977dd33f0ba88ba9c352421e"))
        #expect(result.contains("not_observed"))
    }

    @Test("style recommendation exposes aliases and source tradeoffs as structured JSON")
    func styleRecommendation() throws {
        let executor = ToolExecutor(editorProvider: { nil })
        let result = try text(executor.getProductionKnowledge([
            "operation": "recommend_style",
            "named_styles": ["Jarmusch"],
            "constraints": ["low_reroll_budget"],
        ]))
        let decoded = try JSONDecoder().decode(ProductionStyleRecommendationV1.self, from: Data(result.utf8))
        let candidate = try #require(decoded.candidates.first)
        #expect(decoded.candidates.count == 1)
        #expect(candidate.kind == .alias)
        #expect(candidate.proposedSelection?.directorID == "director-wim-wenders-the-seeing-road")
        #expect(candidate.proposedSelection?.signatureID == "dop-robby-m-ller")
        #expect(candidate.synthesisSourceIDs == ["director-yasujir-ozu-domestic-stillness"])
    }

    @Test("retrieved procedures preserve operational counterexamples")
    func operationalCounterexamples() throws {
        let executor = ToolExecutor(editorProvider: { nil })
        let always = try text(executor.getProductionKnowledge([
            "operation": "read",
            "entryID": "film-production-skill/skill-f468f0c333ce",
        ]))
        #expect(always.contains("reflections as texture are green"))
        #expect(always.contains("a hand close-up is allowed only as a short single-action beat"))
        #expect(always.contains("cut away before the fine work"))

        let extensionDoctrine = try text(executor.getProductionKnowledge([
            "operation": "read",
            "entryID": "film-production-video-prompting/video-prompting-2d077c405e26",
        ]))
        #expect(extensionDoctrine.contains("never extend the draft"))
        #expect(extensionDoctrine.contains("video_extension"))

        let environment = try text(executor.getProductionKnowledge([
            "operation": "read",
            "entryID": "film-production-pixar-look/pixar-look-fdcec6b2c0f0",
        ]))
        #expect(environment.contains("Brightness is the deciding factor"))
        #expect(environment.contains("dark target scenes"))

        let ozu = try text(executor.getProductionKnowledge([
            "operation": "read",
            "entryID": "film-production-blueprints/director-yasujir-ozu-domestic-stillness",
        ]))
        #expect(ozu.contains("the 360° assembly happens in the NLE, not inside a take"))
        #expect(ozu.contains("state the axis in every one of those prompts"))
    }
}
