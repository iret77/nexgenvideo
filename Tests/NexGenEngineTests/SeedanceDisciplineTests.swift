import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// seedance_camera discipline — faithful port of the reference codes/severities.
@Suite("seedance_camera")
struct SeedanceDisciplineTests {
    static func shot(_ id: String, prompt: String, dur: Double = 5) throws -> Shot {
        try Shot(id: id, section: "verse", timeStart: 0, timeEnd: dur, durationS: dur, type: .performance,
                 description: "d", visualPrompt: prompt, mood: "m", sceneVideoProvider: .fal)
    }
    static func shotlist(_ shots: [Shot]) throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "p",
            song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "t", generator: "g", shots: shots)
    }

    static func run(_ prompt: String, dur: Double = 5) throws -> Set<String> {
        let findings = try MusicvideoChecks.seedanceDisciplineCheck(
            AuditContext(shotlist: try shotlist([shot("s001", prompt: prompt, dur: dur)])))
        return Set(findings.map(\.code))
    }

    @Test("a clean prompt in-band produces no findings")
    func clean() throws {
        let codes = try Self.run("a woman walks slowly through warm golden hour, long soft shadows on the floor")
        #expect(codes.isEmpty)
    }

    @Test("jitter token 'fast'")
    func hardBlock() throws {
        #expect(try Self.run("she runs fast across the lit rooftop").contains("PROMPT_HARD_BLOCK_TOKEN"))
    }

    @Test("slop adjectives in the subject")
    func qualityKiller() throws {
        let codes = try Self.run("a stunning cinematic portrait of the singer")
        #expect(codes.contains("PROMPT_QUALITY_KILLER"))
    }

    @Test("technical lens/exposure lingo")
    func technicalLingo() throws {
        #expect(try Self.run("portrait on a 50mm lens with soft light").contains("PROMPT_TECHNICAL_LINGO"))
    }

    @Test("duration band follows Seedance 2.5 catalog data")
    func durationBand() throws {
        #expect(try Self.run("a calm wide view in soft daylight", dur: 30).contains("SHOT_OVER_SEEDANCE_CAP") == false)
        #expect(try Self.run("a calm wide view in soft daylight", dur: 31).contains("SHOT_OVER_SEEDANCE_CAP"))
        #expect(try Self.run("a calm wide view in soft daylight", dur: 3).contains("SHOT_UNDER_SEEDANCE_MIN"))
    }

    @Test("capability catalog resolves fal endpoint families and Higgsfield id")
    func providerAliases() throws {
        #expect(ModelCapabilities.catalogIsValid)
        for id in [
            "bytedance/seedance-2.5/text-to-video",
            "bytedance/seedance-2.5/image-to-video",
            "bytedance/seedance-2.5/reference-to-video",
            "seedance_2_5",
            "higgsfield/seedance_2_5",
        ] {
            let capability = try #require(ModelCapabilities.capability(id))
            #expect(capability.maxDurationS == 30)
            #expect(capability.maxReferenceImages == 30)
        }
    }
}
