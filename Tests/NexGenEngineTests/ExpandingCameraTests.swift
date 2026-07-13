import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// expanding_camera (C2) — the blocker cited in the initial port ("no CostsConfig / capabilities") is
/// resolved, so this ports faithfully.
@Suite("expanding_camera")
struct ExpandingCameraTests {
    @Test("isExpandingMove classifies moves like the reference")
    func classify() {
        #expect(CameraMoves.isExpandingMove("slow pan across the room"))
        #expect(CameraMoves.isExpandingMove("orbit around her"))
        #expect(CameraMoves.isExpandingMove("slow pull out to reveal the city"))
        #expect(CameraMoves.isExpandingMove("zoom out to wide"))
        #expect(!CameraMoves.isExpandingMove("slow zoom in on the face"))       // zoom-in is a push, not expanding
        #expect(!CameraMoves.isExpandingMove("locked-off wide shot, static"))
        #expect(!CameraMoves.isExpandingMove("push-in on the subject"))
        #expect(!CameraMoves.isExpandingMove(""))
    }

    static func shot(_ id: String, prompt: String, strategy: KeyframeStrategy, notes: String? = nil) throws -> Shot {
        try Shot(id: id, section: "verse", timeStart: 0, timeEnd: 4, durationS: 4, type: .performance,
                 description: "d", visualPrompt: prompt, mood: "m", keyframeStrategy: strategy, notes: notes)
    }

    static func shotlist(_ shots: [Shot]) throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "p",
            song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "t", generator: "g", shots: shots)
    }

    @Test("an expanding move without an end frame is flagged")
    func expandingFlags() throws {
        let shots = try [Self.shot("s001", prompt: "slow pan across the neon street", strategy: .start)]
        let findings = try MusicvideoChecks.expandingCameraCheck(AuditContext(shotlist: try Self.shotlist(shots)))
        #expect(findings.contains {
            $0.code == "EXPANDING_CAMERA_NEEDS_END_FRAME" || $0.code == "EXPANDING_CAMERA_NO_END_KEYFRAME_SUPPORT"
        })
    }

    @Test("keyframe_end_skip_ok suppresses; a static shot is clean")
    func escapeAndStatic() throws {
        let escaped = try Self.shot("s001", prompt: "slow pan", strategy: .start, notes: "keyframe_end_skip_ok: pure sky")
        let staticShot = try Self.shot("s002", prompt: "locked-off wide, static", strategy: .start)
        let findings = try MusicvideoChecks.expandingCameraCheck(
            AuditContext(shotlist: try Self.shotlist([escaped, staticShot])))
        #expect(!findings.contains { $0.code.hasPrefix("EXPANDING_CAMERA") })
    }

    @Test("start_end without a frame_pair_strategy marker is flagged")
    func framePairUndocumented() throws {
        let shots = try [Self.shot("s001", prompt: "slow pan", strategy: .startEnd)]
        let findings = try MusicvideoChecks.expandingCameraCheck(AuditContext(shotlist: try Self.shotlist(shots)))
        #expect(findings.contains { $0.code == "FRAME_PAIR_NO_STRATEGY_DOCUMENTED" })
    }
}
