import Foundation
import Testing
@testable import NexGenEngine

/// Beat-snapping math for beat-synced assembly. Uses a synthetic 120 BPM grid at
/// 30 fps: beats every 0.5 s (15 frames), downbeats every 4 beats (2.0 s).
@Suite("Beat assembly planner")
struct BeatAssemblyTests {

    // 120 BPM at 30 fps → a beat every 0.5 s = 15 frames.
    static let beats: [Double] = stride(from: 0.0, through: 4.0, by: 0.5).map { ($0 * 1000).rounded() / 1000 }
    static let downbeats: [Double] = [0.0, 2.0, 4.0]
    static let fps = 30

    private func shot(
        _ id: String, _ start: Double, _ end: Double, startsSection: Bool = false, endsSection: Bool = false
    ) -> BeatAssembly.ShotInput {
        BeatAssembly.ShotInput(id: id, timeStart: start, timeEnd: end, startsSection: startsSection, endsSection: endsSection)
    }

    // MARK: - seconds → frames

    @Test("frame(seconds:) rounds to the nearest frame, not truncates")
    func frameRounds() {
        #expect(BeatAssembly.frame(seconds: 0.5, fps: 30) == 15)
        #expect(BeatAssembly.frame(seconds: 0.517, fps: 30) == 16)  // 15.51 → 16
        #expect(BeatAssembly.frame(seconds: 0.51, fps: 30) == 15)   // 15.3 → 15
        #expect(BeatAssembly.frame(seconds: 2.0, fps: 30) == 60)
    }

    // MARK: - nearest-beat snap

    @Test("a near-beat cut snaps to the nearest regular beat and lands on a beat frame")
    func nearestBeatSnap() throws {
        // 0.52 s is nearest beat 0.5 (frame 15); 1.48 s is nearest beat 1.5 (frame 45).
        let placements = BeatAssembly.plan(
            beats: Self.beats, downbeats: Self.downbeats, fps: Self.fps,
            shots: [shot("s001", 0.52, 1.48)]
        )
        let p = try #require(placements.first)
        #expect(p.startFrame == 15)
        #expect(p.durationFrames == 30)  // 45 − 15
        #expect(p.onDownbeat == false)
        // Every start lands exactly on a beat (15-frame grid).
        #expect(p.startFrame % 15 == 0)
    }

    // MARK: - downbeat at a section boundary

    @Test("a section-start cut prefers the nearest downbeat; the same time otherwise takes a beat")
    func downbeatPreferenceAtSectionBoundary() throws {
        // 1.6 s: nearest beat is 1.5 (frame 45); nearest downbeat is 2.0 (frame 60).
        let atBoundary = BeatAssembly.plan(
            beats: Self.beats, downbeats: Self.downbeats, fps: Self.fps,
            shots: [shot("s001", 1.6, 4.0, startsSection: true)]
        )
        let boundary = try #require(atBoundary.first)
        #expect(boundary.startFrame == 60)  // snapped up to the downbeat at 2.0 s
        #expect(boundary.onDownbeat == true)
        #expect(boundary.atSectionBoundary == true)

        // The identical time, NOT a section start, snaps to the nearer regular beat instead.
        let midSection = BeatAssembly.plan(
            beats: Self.beats, downbeats: Self.downbeats, fps: Self.fps,
            shots: [shot("s001", 1.6, 4.0, startsSection: false)]
        )
        let mid = try #require(midSection.first)
        #expect(mid.startFrame == 45)  // nearest beat at 1.5 s
        #expect(mid.onDownbeat == false)
    }

    // MARK: - contiguity (no sub-beat gap or overlap)

    @Test("consecutive shots sharing a boundary snap to the same frame — no gap or overlap")
    func contiguousShotsShareTheCut() {
        let placements = BeatAssembly.plan(
            beats: Self.beats, downbeats: Self.downbeats, fps: Self.fps,
            shots: [
                shot("s001", 0.0, 1.0, startsSection: true, endsSection: false),
                shot("s002", 1.0, 2.0, startsSection: false, endsSection: true),
            ]
        )
        #expect(placements.count == 2)
        let a = placements[0]
        let b = placements[1]
        #expect(a.startFrame == 0)
        #expect(a.startFrame + a.durationFrames == b.startFrame)  // shot 1 ends exactly where shot 2 starts
        #expect(b.startFrame % 15 == 0)
    }

    // MARK: - determinism (re-run yields the same plan)

    @Test("planning is deterministic — re-running produces the identical placements")
    func planIsDeterministic() {
        let shots = [
            shot("s001", 0.0, 1.0, startsSection: true),
            shot("s002", 1.0, 3.0, startsSection: false, endsSection: true),
        ]
        let first = BeatAssembly.plan(beats: Self.beats, downbeats: Self.downbeats, fps: Self.fps, shots: shots)
        let second = BeatAssembly.plan(beats: Self.beats, downbeats: Self.downbeats, fps: Self.fps, shots: shots)
        #expect(first == second)
    }

    // MARK: - degenerate inputs

    @Test("no beats → no placements (assembly can't be beat-synced)")
    func noBeatsNoPlacements() {
        let placements = BeatAssembly.plan(beats: [], downbeats: [], fps: Self.fps, shots: [shot("s001", 0.0, 1.0)])
        #expect(placements.isEmpty)
    }

    @Test("a sub-beat shot never collapses to a zero-length placement")
    func subBeatShotGetsAtLeastOneBeat() throws {
        // 0.1 s → 0.2 s both snap to beat 0; the shot is widened to the next beat.
        let placements = BeatAssembly.plan(
            beats: Self.beats, downbeats: Self.downbeats, fps: Self.fps,
            shots: [shot("s001", 0.1, 0.2)]
        )
        let p = try #require(placements.first)
        #expect(p.durationFrames >= 1)
        #expect(p.startFrame == 0)
    }

    @Test("nearSectionBoundary flags times within tolerance of a section start")
    func nearSectionBoundaryTolerance() {
        let starts = [0.0, 2.0]
        #expect(BeatAssembly.nearSectionBoundary(1.9, sectionStarts: starts, tolerance: 0.25))
        #expect(BeatAssembly.nearSectionBoundary(1.0, sectionStarts: starts, tolerance: 0.25) == false)
    }
}
