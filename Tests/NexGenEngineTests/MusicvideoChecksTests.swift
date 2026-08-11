import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// Port of `plugins/musicvideo/tests/test_checks.py`.
@Suite("Musicvideo Checks", .serialized)
struct MusicvideoChecksTests {
    static let goodPrompt =
        "A performer stands center frame in warm side light, holding a measured opening pose."

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

    @Test("tempo flags shots over the uptempo hard cap")
    func tempoFlagsHardCap() throws {
        let shots = try [
            Self.shot(1, duration: 8),
            Self.shot(2, duration: 8),
        ]
        let findings = try MusicvideoChecks.tempoCheck(
            Self.ctx(Self.shotlist(shots, song: Self.song(bpm: 128)))
        )
        let codes = Set(findings.map(\.code))
        #expect(codes.contains("SHOT_OVER_TEMPO_CAP"))
        #expect(codes.contains("PACING_TOO_MANY_BREAKERS"))
    }

    @Test("tempo accepts durations inside the active band")
    func tempoAcceptsBand() throws {
        let shots = try [
            Self.shot(1, duration: 1.5),
            Self.shot(2, duration: 2),
            Self.shot(3, duration: 1.5),
        ]
        #expect(try MusicvideoChecks.tempoCheck(
            Self.ctx(Self.shotlist(shots, song: Self.song(bpm: 128)))
        ).isEmpty)
    }

    @Test("pacing flags a stretched single action")
    func pacingFlagsSlowMotionRisk() throws {
        let shots = try [
            Self.shot(1, duration: 12, visualPrompt: "The performer sits at the desk."),
        ]
        let findings = try MusicvideoChecks.pacingCheck(
            Self.ctx(Self.shotlist(shots))
        )
        #expect(findings.map(\.code) == ["SHOT_PACING_IMPLAUSIBLE"])
    }

    @Test("pacing accepts an explicit deliberate-stillness marker")
    func pacingAcceptsMarker() throws {
        let shots = try [
            Self.shot(
                1,
                duration: 12,
                visualPrompt: "The performer sits at the desk.",
                notes: "pacing_ok: deliberate held tableau"
            ),
        ]
        #expect(try MusicvideoChecks.pacingCheck(
            Self.ctx(Self.shotlist(shots))
        ).isEmpty)
    }

    @Test("action beat counting deduplicates verb lemmas")
    func actionBeatCounting() {
        #expect(countActionBeats(
            visualPrompt: "He reaches, then she reaches.",
            motion: nil,
            blockingText: nil
        ) == 2)
    }

    @Test("a chained shot uses its predecessor frame as the bible anchor")
    func keyframeAnchorAcceptsChainedContinuity() throws {
        let first = try Shot(
            id: "s001",
            section: "verse",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .performance,
            description: "Opening.",
            visualPrompt: Self.goodPrompt,
            mood: "restrained",
            locationRef: "yard",
            keyframeStrategy: .start
        )
        let chained = try Shot(
            id: "s002",
            section: "verse",
            timeStart: 4,
            timeEnd: 8,
            durationS: 4,
            type: .performance,
            description: "Continue.",
            visualPrompt: Self.goodPrompt,
            mood: "restrained",
            locationRef: "yard",
            keyframeStrategy: .none,
            seedanceInputMode: .keyframe,
            chainWithPreviousEnd: true
        )
        let findings = try MusicvideoChecks.keyframeAnchorCheck(
            Self.ctx(Self.shotlist([first, chained]))
        )

        #expect(
            !findings.contains {
                $0.code == "MISSING_BIBLE_ANCHOR_FOR_T2V"
                    && $0.shotId == "s002"
            }
        )
    }
}
