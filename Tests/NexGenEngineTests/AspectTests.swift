import Foundation
import Testing
@testable import NexGenEngine

/// Ports the aspect assertions from `engine/tests/test_smoke.py::test_aspect_pure_functions` plus
/// coverage of the provider tables, freeform parse (incl. pixel→ratio GCD reduction), brief
/// resolution, and tolerance matching (the seedance2 "960:1280 == 3:4" cap-mismatch bug class).
@Suite("Aspect")
struct AspectTests {

    // MARK: - test_aspect_pure_functions

    @Test("aspect_float and parse_freeform basics")
    func pureFunctions() {
        #expect(abs((Aspect.aspectFloat("16:9") ?? 0) - (16.0 / 9.0)) < 1e-6)
        #expect(Aspect.parseFreeform("16:9") == "16:9")
    }

    // MARK: - provider tables

    @Test("runway and openai pixel mappings, with fallbacks")
    func providerTables() {
        #expect(Aspect.toRunwayRatio("16:9") == "1280:720")
        #expect(Aspect.toRunwayRatio("3:4") == "720:960")
        #expect(Aspect.toRunwayRatio("nonsense") == "1280:720")   // never empty
        #expect(Aspect.toOpenAIRatio("9:16") == "1024x1536")
        #expect(Aspect.toOpenAIRatio("nonsense") == "1024x1024")
        #expect(Aspect.aspectFloat("nope") == nil)
    }

    // MARK: - freeform parse

    @Test("freeform parse reduces pixel pairs to their semantic ratio")
    func freeformPixelReduction() {
        #expect(Aspect.parseFreeform("3:4 (960x1280)") == "3:4")
        #expect(Aspect.parseFreeform("960x1280") == "3:4")
        #expect(Aspect.parseFreeform("no numbers here") == nil)
        #expect(Aspect.parseFreeform("0:5") == nil)
    }

    // MARK: - brief resolution

    @Test("resolve_brief_aspect returns enum value directly and parses OTHER")
    func resolveBriefAspect() throws {
        #expect(try Aspect.resolveBriefAspect(aspectRatio: "16:9", aspectRatioOther: nil) == "16:9")
        #expect(try Aspect.resolveBriefAspect(aspectRatio: "other", aspectRatioOther: "3:4 (960x1280)") == "3:4")
    }

    @Test("resolve_brief_aspect throws when OTHER has no parseable freeform")
    func resolveBriefAspectThrows() {
        #expect(throws: Aspect.Unresolvable.self) {
            try Aspect.resolveBriefAspect(aspectRatio: "other", aspectRatioOther: "")
        }
        #expect(throws: Aspect.Unresolvable.self) {
            try Aspect.resolveBriefAspect(aspectRatio: nil, aspectRatioOther: nil)
        }
    }

    // MARK: - tolerance matching (bug class claude_mouse)

    @Test("resolve_for_model matches 3:4 against a differently-scaled 960:1280 within tolerance")
    func toleranceMatch() {
        // Same float ratio (0.75), different pixel resolution — a pure string match would miss it.
        let matched = Aspect.resolveForModel("3:4", supportedRatios: ["1280:720", "960:1280"])
        #expect(matched == "960:1280")
    }

    @Test("resolve_for_model prefers the highest-resolution match")
    func highestResolutionWins() {
        let matched = Aspect.resolveForModel("16:9", supportedRatios: ["1280:720", "1920:1080"])
        #expect(matched == "1920:1080")
    }

    @Test("resolve_for_model returns nil on a real cap mismatch")
    func realMismatchIsNil() {
        #expect(Aspect.resolveForModel("1:1", supportedRatios: ["1280:720", "720:1280"]) == nil)
    }

    @Test("resolve_for_provider falls back to the first supported ratio on mismatch")
    func providerFallback() {
        #expect(Aspect.resolveForProvider("1:1", supportedRatios: ["1280:720", "720:1280"]) == "1280:720")
        #expect(Aspect.resolveForProvider("16:9", supportedRatios: ["1280:720"]) == "1280:720")
    }
}
