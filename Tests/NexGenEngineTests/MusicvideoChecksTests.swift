import Foundation
import Testing
@testable import NexGenEngine

/// Port of `plugins/musicvideo/tests/test_checks.py`.
@Suite("Musicvideo Checks", .serialized)
struct MusicvideoChecksTests {
    static func song(bpm: Double = 128.0, tempoMultiplier: Double = 1.0) throws -> Song {
        try Song(
            title: "t", audioPath: "audio/song.wav", analysisPath: "analysis/song.json", bpm: bpm,
            tempoMultiplier: tempoMultiplier, durationS: 180.0
        )
    }

    static func shot(
        _ idx: Int, duration: Double, visualPrompt: String = "a calm wide vista", motion: String? = nil,
        notes: String? = nil
    ) throws -> Shot {
        let start = Double(idx) * 100.0
        return try Shot(
            id: String(format: "s%03d", idx), section: "verse", timeStart: start, timeEnd: start + duration,
            durationS: duration, type: .performance, description: "d", visualPrompt: visualPrompt, motion: motion,
            mood: "m", notes: notes
        )
    }

    static func shotlist(_ shots: [Shot], song: Song? = nil, mode: Mode = .beat) throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: mode, project: "proj", song: try song ?? Self.song(),
            generated: "2026-01-01", generator: "test", shots: shots
        )
    }

    static func ctx(_ shotlist: Shotlist, extra: [String: String]? = nil) -> AuditContext {
        AuditContext(shotlist: shotlist, extra: extra)
    }

    // MARK: - tempo

    @Test("tempo flags shots over hard cap at uptempo")
    func tempoFlagsShotsOverHardCapAtUptempo() throws {
        // uptempo_dance hard_cap = 4.0s; two shots at 8s blow past it.
        let shots = try [Self.shot(1, duration: 8.0), Self.shot(2, duration: 8.0)]
        let findings = try MusicvideoChecks.tempoCheck(Self.ctx(Self.shotlist(shots, song: Self.song(bpm: 128.0))))
        let codes = Set(findings.map(\.code))
        #expect(codes.contains("SHOT_OVER_TEMPO_CAP"))
        // 2/2 shots over cap => too_many_breakers
        #expect(codes.contains("PACING_TOO_MANY_BREAKERS"))
        let overCap = findings.filter { $0.code == "SHOT_OVER_TEMPO_CAP" }
        #expect(Set(overCap.map(\.shotId)) == Set(["s001", "s002"] as [String?]))
        #expect(findings.allSatisfy { $0.level == .warn })
    }

    @Test("tempo is clean when durations match the band")
    func tempoCleanWhenDurationsMatchBand() throws {
        let shots = try [Self.shot(1, duration: 1.5), Self.shot(2, duration: 2.0), Self.shot(3, duration: 1.5)]
        let findings = try MusicvideoChecks.tempoCheck(Self.ctx(Self.shotlist(shots, song: Self.song(bpm: 128.0))))
        #expect(findings.isEmpty)
    }

    @Test("tempo returns empty when BPM is unavailable")
    func tempoReturnsEmptyWhenBPMUnavailable() throws {
        let shots = try [Self.shot(1, duration: 8.0), Self.shot(2, duration: 8.0)]
        var sl = try Self.shotlist(shots, song: Self.song(bpm: 128.0))
        sl.song = try Song(
            title: "t", audioPath: "audio/song.wav", analysisPath: "analysis/song.json", bpm: 1.0,
            tempoMultiplier: 0.0, durationS: 180.0
        )
        let findings = try MusicvideoChecks.tempoCheck(Self.ctx(sl))
        #expect(findings.isEmpty)
    }

    @Test("tempo skips multicam")
    func tempoSkipsMulticam() throws {
        // Multicam shots span the whole song; build a valid multicam shotlist.
        let song = try Self.song(bpm: 128.0)
        let shot = try Shot(
            id: "s001", timeStart: 0.0, timeEnd: song.durationS, durationS: song.durationS, type: .performance,
            description: "d", visualPrompt: "performance", mood: "m", cameraId: "cam01"
        )
        let sl = try Self.shotlist([shot], song: song, mode: .multicam)
        #expect(try MusicvideoChecks.tempoCheck(Self.ctx(sl)).isEmpty)
    }

    @Test("tempo reads BPM from ctx.extra when the song has none")
    func tempoBPMFromExtraAnalysisWhenSongHasNone() throws {
        let shots = try [Self.shot(1, duration: 8.0), Self.shot(2, duration: 8.0)]
        var sl = try Self.shotlist(shots, song: Self.song(bpm: 128.0))
        sl.song = try Song(
            title: "t", audioPath: "audio/song.wav", analysisPath: "analysis/song.json", bpm: 1.0,
            tempoMultiplier: 0.0, durationS: 180.0
        )
        let findings = try MusicvideoChecks.tempoCheck(Self.ctx(sl, extra: ["analysis.perceived_bpm": "128.0"]))
        #expect(findings.contains { $0.code == "SHOT_OVER_TEMPO_CAP" })
    }

    // MARK: - pacing

    @Test("pacing flags slow-motion risk")
    func pacingFlagsSlowMotionRisk() throws {
        // 1 action beat ("sits") over a 12s clip => 12s/beat > 4.0 threshold.
        let shots = try [Self.shot(1, duration: 12.0, visualPrompt: "sits at the desk, papers in front")]
        let findings = try MusicvideoChecks.pacingCheck(Self.ctx(Self.shotlist(shots)))
        #expect(findings.count == 1)
        #expect(findings[0].code == "SHOT_PACING_IMPLAUSIBLE")
        #expect(findings[0].shotId == "s001")
        #expect(findings[0].level == .warn)
    }

    @Test("pacing is clean when density matches duration")
    func pacingCleanWhenDensityMatchesDuration() throws {
        // 3 beats over 12s => 4.0s/beat exactly (not > 4.0) and 0.25 b/s => clean.
        let shots = try [
            Self.shot(1, duration: 12.0, visualPrompt: "she stands, then turns, then walks toward the door")
        ]
        let findings = try MusicvideoChecks.pacingCheck(Self.ctx(Self.shotlist(shots)))
        #expect(findings.isEmpty)
    }

    @Test("pacing is silenced by the pacing_ok marker")
    func pacingSilencedByMarker() throws {
        let shots = try [
            Self.shot(
                1, duration: 12.0, visualPrompt: "sits at the desk",
                notes: "pacing_ok: intentional contemplative still life"
            )
        ]
        #expect(try MusicvideoChecks.pacingCheck(Self.ctx(Self.shotlist(shots))).isEmpty)
    }

    // MARK: - count_action_beats boundary cases

    @Test("count_action_beats dedupes verb lemmas")
    func countActionBeatsDedupesLemmas() {
        // "reach" and "reaches" both lemmatize to "reach" -> counted once.
        #expect(countActionBeats(visualPrompt: "he reaches, then she reach", motion: nil, blockingText: nil) == 2)
    }

    @Test("count_action_beats returns 0 for empty text")
    func countActionBeatsEmptyText() {
        #expect(countActionBeats(visualPrompt: nil, motion: nil, blockingText: nil) == 0)
        #expect(countActionBeats(visualPrompt: "   ", motion: nil, blockingText: nil) == 0)
    }

    @Test("count_action_beats counts sequence connectors as extra beats")
    func countActionBeatsCountsSequenceConnectors() {
        // "stands" (1 verb) + "then" (1 connector) = 2.
        #expect(countActionBeats(visualPrompt: "she stands, then waits", motion: nil, blockingText: nil) == 2)
    }
}
