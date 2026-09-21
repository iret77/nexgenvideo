import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// PATTERN_DRIFT — the mechanism half of the pattern regression fix (#185). Also proves the pattern
/// library actually LOADS from the bundle (the ported data had zero live callers before).
@Suite("PATTERN_DRIFT")
struct PatternDriftTests {
    static func brief(pattern: String?, notes: String? = nil) throws -> Brief {
        try Brief(
            project: "proj", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "beat", conceptType: .abstract,
            visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored,
            directorPattern: pattern, notes: notes)
    }

    static func shot(_ i: Int, framing: Framing) throws -> Shot {
        let start = Double(i) * 10
        return try Shot(
            id: String(format: "s%03d", i), section: "verse", timeStart: start, timeEnd: start + 4,
            durationS: 4, type: .performance, description: "d", visualPrompt: "v", mood: "m", framing: framing)
    }

    static func shot(_ i: Int, framing: Framing, duration: Double) throws -> Shot {
        let start = Double(i) * 20
        return try Shot(
            id: String(format: "s%03d", i), section: "verse", timeStart: start, timeEnd: start + duration,
            durationS: duration, type: .performance, description: "d", visualPrompt: "v", mood: "m",
            framing: framing
        )
    }

    static func shotlist(_ shots: [Shot]) throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "proj",
            song: try Song(title: "t", audioPath: "audio/song.wav", analysisPath: "analysis/song.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "2026-01-01", generator: "test", shots: shots)
    }

    /// The framing the pattern uses least — 100% of it guarantees a > tolerance drift.
    static func rarestFraming(_ pattern: Pattern) throws -> Framing {
        try #require(pattern.framingMix.byFraming().min(by: { $0.value < $1.value })?.key)
    }

    @Test("the pattern library loads AND drift is measured against the chosen pattern")
    func driftMeasured() throws {
        let library = try Patterns.loadAllPatterns()
        #expect(!library.isEmpty)  // the regression: ported data with no way to load it
        let pattern = try #require(library.first)
        let shots = try (1...6).map { try Self.shot($0, framing: Self.rarestFraming(pattern)) }
        let ctx = AuditContext(shotlist: try Self.shotlist(shots), brief: try Self.brief(pattern: pattern.id))
        let findings = try MusicvideoChecks.patternDriftCheck(ctx)
        #expect(findings.contains { $0.code == "PATTERN_DRIFT" && $0.level == .warn })
    }

    @Test("`pattern_override:` in brief.notes is the escape hatch")
    func escapeMarker() throws {
        let pattern = try #require(try Patterns.loadAllPatterns().first)
        let shots = try (1...6).map { try Self.shot($0, framing: Self.rarestFraming(pattern)) }
        let ctx = AuditContext(
            shotlist: try Self.shotlist(shots),
            brief: try Self.brief(pattern: pattern.id, notes: "pattern_override: intentional look"))
        #expect(try MusicvideoChecks.patternDriftCheck(ctx).isEmpty)
    }

    @Test("no chosen pattern → no drift")
    func noPattern() throws {
        let shots = try (1...6).map { try Self.shot($0, framing: .wide) }
        let ctx = AuditContext(shotlist: try Self.shotlist(shots), brief: try Self.brief(pattern: nil))
        #expect(try MusicvideoChecks.patternDriftCheck(ctx).isEmpty)
    }

    @Test("ASL outside the sourced range is included in the drift report")
    func aslDriftMeasured() throws {
        let pattern = try #require(try Patterns.loadAllPatterns().first)
        let framing = try #require(pattern.framingMix.byFraming().max(by: { $0.value < $1.value })?.key)
        let duration = pattern.aslRange.maxS + 10
        let shots = try (1...6).map { try Self.shot($0, framing: framing, duration: duration) }
        let ctx = AuditContext(shotlist: try Self.shotlist(shots), brief: try Self.brief(pattern: pattern.id))
        let findings = try MusicvideoChecks.patternDriftCheck(ctx)
        #expect(findings.contains { $0.code == "PATTERN_DRIFT" && $0.message.contains("average shot length") })
    }

    @Test("below the minimum shot count → no drift (quantization-noise guard)")
    func tooFewShots() throws {
        let pattern = try #require(try Patterns.loadAllPatterns().first)
        let shots = try (1...3).map { try Self.shot($0, framing: Self.rarestFraming(pattern)) }
        let ctx = AuditContext(shotlist: try Self.shotlist(shots), brief: try Self.brief(pattern: pattern.id))
        #expect(try MusicvideoChecks.patternDriftCheck(ctx).isEmpty)
    }

    @Test("multicam mode is exempt")
    func multicamExempt() throws {
        let pattern = try #require(try Patterns.loadAllPatterns().first)
        let shots = try (1...6).map { try Self.shot($0, framing: Self.rarestFraming(pattern)) }
        var sl = try Self.shotlist(shots)
        sl.mode = .multicam
        let ctx = AuditContext(shotlist: sl, brief: try Self.brief(pattern: pattern.id))
        #expect(try MusicvideoChecks.patternDriftCheck(ctx).isEmpty)
    }
}
