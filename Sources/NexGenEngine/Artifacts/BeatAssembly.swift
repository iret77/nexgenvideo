import Foundation

/// Beat-synced assembly planner: maps ordered, rendered shots onto timeline
/// frames cut to the music. Pure and host-agnostic — it takes the beat grid
/// (from the analysis artifact) plus each shot's planned span and section role,
/// and returns frame placements. The host (the app's `assemble_timeline` tool)
/// resolves each shot's rendered file and lays the returned placements onto a
/// video track.
///
/// Snapping model: every cut lands on a beat. A cut that begins a section
/// (`startsSection`) prefers the nearest downbeat; any other cut snaps to the
/// nearest regular beat. Because consecutive shots share a boundary time and the
/// same section flag on that shared edge, adjacent shots snap to the SAME beat —
/// no sub-beat gap or overlap. Shot durations are already BPM-derived, so
/// snapping both edges yields a whole number of beats per shot.
public enum BeatAssembly {

    /// One shot to place, in shotlist order. `startsSection`/`endsSection`
    /// come from the shotlist section mapping (and, optionally, the analysis
    /// section boundaries) — they drive the downbeat preference on each edge.
    public struct ShotInput: Sendable, Equatable {
        public let id: String
        public let timeStart: Double
        public let timeEnd: Double
        public let startsSection: Bool
        public let endsSection: Bool

        public init(id: String, timeStart: Double, timeEnd: Double, startsSection: Bool, endsSection: Bool) {
            self.id = id
            self.timeStart = timeStart
            self.timeEnd = timeEnd
            self.startsSection = startsSection
            self.endsSection = endsSection
        }
    }

    /// A frame placement for one shot. `startFrame`/`durationFrames` are timeline
    /// frames at the project fps; `cutSeconds` is the beat time the start snapped
    /// to; `onDownbeat`/`atSectionBoundary` explain the cut.
    public struct Placement: Sendable, Equatable {
        public let shotId: String
        public let startFrame: Int
        public let durationFrames: Int
        public let cutSeconds: Double
        public let onDownbeat: Bool
        public let atSectionBoundary: Bool
    }

    /// The beat grid an analysis artifact carries — the assembly input the host
    /// reads back from `analysis/<song>.json`.
    public struct BeatGrid: Sendable, Equatable {
        public let beats: [Double]
        public let downbeats: [Double]
        public let sectionStarts: [Double]
        public let bpm: Double
        public let durationS: Double

        public init(beats: [Double], downbeats: [Double], sectionStarts: [Double], bpm: Double, durationS: Double) {
            self.beats = beats
            self.downbeats = downbeats
            self.sectionStarts = sectionStarts
            self.bpm = bpm
            self.durationS = durationS
        }
    }

    private static let epsilon = 1e-6

    /// Seconds → timeline frame at `fps`, rounded (not truncated) so a cut lands
    /// on the frame nearest its beat time. One conversion used for every edge
    /// keeps starts and ends consistent.
    public static func frame(seconds: Double, fps: Int) -> Int {
        Int((seconds * Double(max(fps, 1))).rounded())
    }

    /// Whether `t` sits within `tolerance` seconds of any section boundary — the
    /// analysis-derived signal the host ORs with the shotlist section change.
    public static func nearSectionBoundary(_ t: Double, sectionStarts: [Double], tolerance: Double) -> Bool {
        sectionStarts.contains { abs($0 - t) <= tolerance }
    }

    /// Plan frame placements for `shots` (already filtered to those with a
    /// rendered output), in the given order, against the beat grid.
    public static func plan(beats: [Double], downbeats: [Double], fps: Int, shots: [ShotInput]) -> [Placement] {
        guard !beats.isEmpty else { return [] }
        var out: [Placement] = []
        out.reserveCapacity(shots.count)
        for shot in shots {
            let startIndex = snapBeatIndex(shot.timeStart, beats: beats, downbeats: downbeats, preferDownbeat: shot.startsSection)
            var endIndex = snapBeatIndex(shot.timeEnd, beats: beats, downbeats: downbeats, preferDownbeat: shot.endsSection)
            // Never collapse to a zero-length shot: give it at least one beat.
            if endIndex <= startIndex { endIndex = min(startIndex + 1, beats.count - 1) }

            let startFrame = frame(seconds: beats[startIndex], fps: fps)
            let endFrame: Int
            if endIndex > startIndex {
                endFrame = frame(seconds: beats[endIndex], fps: fps)
            } else {
                // startIndex is the last beat — the shot runs to its planned end.
                endFrame = max(startFrame + 1, frame(seconds: shot.timeEnd, fps: fps))
            }

            let startBeat = beats[startIndex]
            let onDownbeat = downbeats.contains { abs($0 - startBeat) <= epsilon }
            out.append(Placement(
                shotId: shot.id,
                startFrame: startFrame,
                durationFrames: max(1, endFrame - startFrame),
                cutSeconds: startBeat,
                onDownbeat: onDownbeat,
                atSectionBoundary: shot.startsSection
            ))
        }
        return out
    }

    /// Beat index a time snaps to. A section edge prefers the nearest downbeat
    /// (resolved back to its beat index); any other edge takes the nearest beat.
    private static func snapBeatIndex(_ t: Double, beats: [Double], downbeats: [Double], preferDownbeat: Bool) -> Int {
        if preferDownbeat, let downbeat = nearestValue(t, in: downbeats) {
            return nearestIndex(downbeat, in: beats)
        }
        return nearestIndex(t, in: beats)
    }

    private static func nearestIndex(_ t: Double, in grid: [Double]) -> Int {
        var best = 0
        var bestDelta = Double.infinity
        for (i, v) in grid.enumerated() {
            let delta = abs(v - t)
            if delta < bestDelta { bestDelta = delta; best = i }
        }
        return best
    }

    private static func nearestValue(_ t: Double, in grid: [Double]) -> Double? {
        grid.min { abs($0 - t) < abs($1 - t) }
    }

    // MARK: - Artifact read-back

    /// Load the beat grid from a project's analysis artifact
    /// (`analysis/<song>.json`), tolerant of the canonical `Analysis` shape and
    /// the DSP-subset shape (both snake_case). Returns nil when the artifact is
    /// absent, unreadable, or carries no beats.
    public static func loadBeatGrid(dataRoot: URL) -> BeatGrid? {
        guard let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(RawAnalysis.self, from: data)
        else { return nil }
        let beats = raw.beats ?? []
        guard !beats.isEmpty else { return nil }
        return BeatGrid(
            beats: beats,
            downbeats: raw.downbeats ?? [],
            sectionStarts: (raw.sections ?? []).compactMap(\.start),
            bpm: raw.bpm ?? 0,
            durationS: raw.durationS ?? 0
        )
    }

    /// Lenient view of the analysis JSON — only the fields assembly needs, all
    /// optional so a partial or older artifact still reads.
    private struct RawAnalysis: Decodable {
        let beats: [Double]?
        let downbeats: [Double]?
        let bpm: Double?
        let durationS: Double?
        let sections: [RawSection]?

        enum CodingKeys: String, CodingKey {
            case beats, downbeats, bpm
            case durationS = "duration_s"
            case sections
        }

        struct RawSection: Decodable { let start: Double? }
    }
}
