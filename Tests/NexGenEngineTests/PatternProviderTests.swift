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

    @Test("recommend fails closed while the library is not fully authored")
    func recommendFailsClosed() throws {
        // Only the pilot ships a fit_profile today, so the whole feature is gated: the seam returns a
        // structured `available:false` envelope, never a partial ranking.
        let briefJSON = try JSONEncoder().encode(brief())
        let optionsJSON = Data("{\"perceived_bpm\": 92.0}".utf8)
        let data = try provider().recommend(briefJSON: briefJSON, optionsJSON: optionsJSON)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["available"] as? Bool == false)
        let missing = try #require(object["missing_profiles"] as? [String])
        #expect(missing.count == 22, "22 of 23 patterns still lack a fit_profile")
        #expect(!missing.contains("wong-kar-wai-doyle-neon-dream"), "the pilot must not be listed as missing")
        #expect(object["results"] == nil, "no partial ranking is emitted")
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
