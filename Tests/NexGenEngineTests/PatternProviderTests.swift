import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// The pack's PatternProviding seam — the agent-callable path to the Pattern-fit
/// contract (recommend + get).
@Suite("Pattern provider", .serialized)
struct PatternProviderTests {
    private func provider() throws -> any PatternProviding {
        PackCatalog.register(MusicvideoPack())
        return try #require(PackCatalog.registry(activePack: "musicvideo").patternProvider,
                            "musicvideo should register a PatternProviding")
    }

    private func brief() throws -> Brief {
        try Brief(
            project: "proj", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "section", conceptType: .narrative,
            visualMedium: .liveActionRealistic, tone: [.melancholic], figures: .artistPlusOthers,
            lyricsIntegration: .metaphorical)
    }

    /// Only the pilot ships a fit_profile today — and that is enough to answer the question. The
    /// seam ranks it and states what the ranking covers, so the agent can't pass a 1-of-23 field
    /// off as the whole library.
    @Test("recommend ranks the scored pattern and reports what it covers")
    func recommendRanksWhatIsScored() throws {
        let briefJSON = try JSONEncoder().encode(brief())
        let optionsJSON = Data("{\"perceived_bpm\": 92.0}".utf8)
        let data = try provider().recommend(briefJSON: briefJSON, optionsJSON: optionsJSON)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["available"] as? Bool == true)
        #expect(object["pattern_optional"] as? Bool == true, "taking a pattern is never mandatory")

        let recommendations = try #require(object["recommendations"] as? [String: Any])
        let results = try #require(recommendations["results"] as? [[String: Any]])
        #expect(!results.isEmpty, "the scored pattern is ranked rather than withheld")
        #expect(results.contains { $0["pattern_id"] as? String == "wong-kar-wai-doyle-neon-dream" })

        // Coverage is a RELATIONSHIP, never a fixed count: the library grows over time (1, 5, 22,
        // 145 — the code ranks whatever is authored). Pinning a number here would turn every new
        // pattern into a red test.
        let coverage = try #require(object["library_coverage"] as? [String: Any])
        let scored = try #require(coverage["scored"] as? [String])
        let unscored = try #require(coverage["unscored"] as? [String])
        #expect(scored.contains("wong-kar-wai-doyle-neon-dream"))
        #expect(!unscored.contains("wong-kar-wai-doyle-neon-dream"))
        #expect(coverage["total"] as? Int == scored.count + unscored.count)
        #expect(results.count == scored.count, "every scored pattern is ranked")
        #expect(object["invalid_profiles"] == nil, "nothing is broken, so nothing is reported broken")
    }

    @Test("get returns the full pattern JSON for a real id, nil for an unknown one")
    func getById() throws {
        let p = try provider()
        let id = "wong-kar-wai-doyle-neon-dream"
        let data = try #require(try p.get(id: id), "the pilot id must be loadable")
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["id"] as? String == id)
        #expect(obj["framing_mix"] != nil)  // the compose backbone PATTERN_DRIFT consumes
        #expect(obj["asl_range"] != nil)
        #expect(obj["fit_profile"] != nil, "the pilot carries its authored fit_profile")

        #expect(try p.get(id: "no-such-pattern-xyz") == nil)
        #expect(try p.get(id: "   ") == nil)
    }
}
