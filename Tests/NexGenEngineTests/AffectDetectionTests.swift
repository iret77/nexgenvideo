import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// #214 — affect comes from the agent's read of audio + lyrics (recorded as `AffectProfile`), not the
/// brief tone-tag lookup. These pin the assembler's source precedence and the override semantics.
@Suite("affect detection (#214)")
struct AffectDetectionTests {
    static func brief(tone: [ToneTag]) throws -> Brief {
        try Brief(project: "p", generated: "t", mission: .demo, targetPlatform: "web",
                  aspectRatio: .landscape16x9, projectMode: "beat", conceptType: .abstract,
                  visualMedium: .liveActionRealistic, tone: tone, figures: .none,
                  lyricsIntegration: .ignored)
    }

    static func affects(_ p: ProjectFitProfile) -> [AffectTag] {
        (p.creative.affects?.value ?? []).map(\.value)
    }

    @Test("a recorded detection replaces the brief tone-tag map as the affect source")
    func detectionOutranksToneMap() throws {
        // Brief tone would map to .melancholic; the detection says something else entirely.
        let brief = try Self.brief(tone: [.melancholic])
        let profile = AffectProfile(detected: [WeightedAffect(value: .euphoric, weight: 1)],
                                    rationale: "major key, 128 BPM, rising energy")
        let assembled = ProjectProfileAssembler.assemble(brief: brief, affectProfile: profile)
        #expect(Self.affects(assembled) == [.euphoric])
        #expect(assembled.creative.affects?.source == .agentInference)
        #expect(assembled.creative.affects?.userConfirmed == false)
    }

    @Test("an override outranks the detection and is marked user-confirmed at full confidence")
    func overrideOutranksDetection() throws {
        let brief = try Self.brief(tone: [.euphoric])
        // Happy song, deliberately dark video — the map could never express this.
        let profile = AffectProfile(
            detected: [WeightedAffect(value: .euphoric, weight: 1)],
            override: [WeightedAffect(value: .dark, weight: 1)],
            rationale: "upbeat track, contrary treatment")
        let assembled = ProjectProfileAssembler.assemble(brief: brief, affectProfile: profile)
        #expect(Self.affects(assembled) == [.dark])
        #expect(assembled.creative.affects?.source == .user)
        #expect(assembled.creative.affects?.userConfirmed == true)
        #expect(assembled.creative.affects?.confidence == 1.0)
    }

    @Test("with no detection recorded, the brief tone-tag map is the fallback")
    func fallsBackToToneMapWhenNoDetection() throws {
        let brief = try Self.brief(tone: [.dark, .poetic])
        let assembled = ProjectProfileAssembler.assemble(brief: brief, affectProfile: nil)
        #expect(Set(Self.affects(assembled)) == Set([.dark, .poetic]))
        #expect(assembled.creative.affects?.source == .brief)
    }

    @Test("an empty detection does not shadow the tone-tag fallback")
    func emptyDetectionYieldsToFallback() throws {
        let brief = try Self.brief(tone: [.melancholic])
        let profile = AffectProfile(detected: [])
        let assembled = ProjectProfileAssembler.assemble(brief: brief, affectProfile: profile)
        #expect(Self.affects(assembled) == [.melancholic])
        #expect(assembled.creative.affects?.source == .brief)
    }

    @Test("an empty override is not a correction — the detection stands, not the tone fallback")
    func emptyOverrideDoesNotDiscardDetection() throws {
        let brief = try Self.brief(tone: [.melancholic])
        let profile = AffectProfile(detected: [WeightedAffect(value: .euphoric, weight: 1)], override: [])
        #expect(profile.isOverridden == false)
        #expect(profile.effective.map(\.value) == [.euphoric])
        let assembled = ProjectProfileAssembler.assemble(brief: brief, affectProfile: profile)
        #expect(Self.affects(assembled) == [.euphoric])
        #expect(assembled.creative.affects?.source == .agentInference)
    }

    @Test("a zero-weight detection carries no signal and yields to the tone fallback, not a dead axis")
    func zeroWeightDetectionYieldsToFallback() throws {
        let brief = try Self.brief(tone: [.dark])
        let profile = AffectProfile(detected: [WeightedAffect(value: .euphoric, weight: 0)])
        #expect(profile.effective.isEmpty)
        let assembled = ProjectProfileAssembler.assemble(brief: brief, affectProfile: profile)
        #expect(Self.affects(assembled) == [.dark])
        #expect(assembled.creative.affects?.source == .brief)
    }

    @Test("effective is override when set, else detection; isOverridden reflects it")
    func effectiveAndOverrideFlag() {
        let plain = AffectProfile(detected: [WeightedAffect(value: .warm, weight: 1)])
        #expect(plain.effective.map(\.value) == [.warm])
        #expect(plain.isOverridden == false)
        let overridden = AffectProfile(detected: [WeightedAffect(value: .warm, weight: 1)],
                                       override: [WeightedAffect(value: .tense, weight: 1)])
        #expect(overridden.effective.map(\.value) == [.tense])
        #expect(overridden.isOverridden == true)
    }

    @Test("AffectProfile round-trips through its JSON store on disk")
    func roundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("affect-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AffectProfile(
            detected: [WeightedAffect(value: .melancholic, weight: 0.7), WeightedAffect(value: .fragile, weight: 0.3)],
            override: [WeightedAffect(value: .dark, weight: 1)],
            rationale: "minor key, sparse arrangement", basis: .measured)
        try profile.save(dataRoot: root)
        let loaded = try #require(AffectProfile.load(dataRoot: root))
        #expect(loaded == profile)
    }

    @Test("a manifest written before affect fields decodes as an empty, non-overridden detection")
    func tolerantDecode() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AffectProfile.self, from: json)
        #expect(decoded.detected.isEmpty)
        #expect(decoded.isOverridden == false)
        #expect(decoded.basis == .inferred)
    }
}
