import Foundation

/// Consolidator: multiple structure-candidate lists + optional alignment ->
/// one final `sections` list with prioritized confidence. Port of
/// `nexgen_pack_musicvideo/analysis/structure/consolidator.py`.
///
/// Rule (agreed with the user):
/// 1. If forced alignment with `[AnalysisSection]` markers is available: markers are
///    the truth for section starts. Other detectors are a secondary hint.
/// 2. Otherwise: for every boundary group that converges across detectors
///    (cluster within a 2s tolerance), take the mean.
/// 3. On > 2s divergence between detectors: flag `anomaly`, take the more
///    conservative (earlier) boundary — overlap-render covers the gap.
/// 4. Snap all boundaries to the nearest downbeat at the end (+/- 0.5s).
public enum Consolidator {
    public static let toleranceS = 2.0
    public static let downbeatSnapS = 0.5

    /// One flagged anomaly during consolidation. Port of the ad hoc
    /// `{kind, time, detail}` dicts `consolidate` appends to `anomalies`.
    public struct Anomaly: Sendable, Equatable {
        public let kind: String
        public let time: Double
        public let detail: String
    }

    public struct ConsolidationResult: Sendable, Equatable {
        public let sections: [AnalysisSection]
        public let anomalies: [Anomaly]
    }

    /// Group boundaries from different sources that lie within `tolerance` of
    /// each other. A group extends as long as each next boundary is within
    /// `tolerance` of the PREVIOUS boundary already in the group (chained
    /// tolerance, not distance-from-group-start). Returns
    /// `(representative_time, contributing_sources)` pairs. Port of
    /// `consolidator.py::_cluster_boundaries`.
    static func clusterBoundaries(_ boundaries: [(t: Double, source: String)], tolerance: Double) -> [(t: Double, sources: [String])] {
        guard !boundaries.isEmpty else { return [] }
        let sorted = boundaries.sorted { $0.t < $1.t }
        var groups: [[(t: Double, source: String)]] = [[sorted[0]]]
        for entry in sorted.dropFirst() {
            if entry.t - groups[groups.count - 1].last!.t <= tolerance {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups.map { g in
            let mean = g.reduce(0.0) { $0 + $1.t } / Double(g.count)
            return (mean, g.map(\.source))
        }
    }

    /// Snaps `t` to the nearest downbeat if within `downbeatSnapS`, else
    /// returns `t` unchanged. Port of `consolidator.py::_snap`.
    static func snap(_ t: Double, downbeats: [Double]) -> Double {
        guard let closest = downbeats.min(by: { abs($0 - t) < abs($1 - t) }) else { return t }
        return abs(closest - t) <= downbeatSnapS ? closest : t
    }

    /// Port of `consolidator.py::consolidate`.
    public static func consolidate(
        candidates: [[AnalysisSection]], alignment: [AlignmentLine]?, downbeats: [Double], durationS: Double
    ) -> ConsolidationResult {
        var anomalies: [Anomaly] = []

        // Path A: alignment with [AnalysisSection] markers.
        if let alignment {
            let markerLines = alignment.filter { $0.sectionMarker != nil }
            if !markerLines.isEmpty {
                var sections: [AnalysisSection] = []
                let sortedMarkers = markerLines.sorted { $0.start < $1.start }
                for (i, line) in sortedMarkers.enumerated() {
                    let end = i + 1 < sortedMarkers.count ? sortedMarkers[i + 1].start : durationS
                    sections.append(
                        AnalysisSection(
                            index: i,
                            start: round1000(snap(line.start, downbeats: downbeats)),
                            end: round1000(snap(end, downbeats: downbeats)),
                            cluster: i,
                            label: line.sectionMarker,
                            source: "alignment",
                            confidence: 0.9
                        )
                    )
                }
                // Ensure the first section starts at 0.
                if let first = sections.first, first.start > 0.5 {
                    sections.insert(
                        AnalysisSection(index: 0, start: 0.0, end: first.start, cluster: -1, label: "intro", source: "alignment", confidence: 0.8),
                        at: 0
                    )
                    for i in sections.indices { sections[i].index = i }
                }
                return ConsolidationResult(sections: sections, anomalies: anomalies)
            }
        }

        // Path B: majority/mean consolidation across detectors.
        var boundaries: [(t: Double, source: String)] = []
        for cand in candidates {
            for sec in cand {
                boundaries.append((Double(sec.start), sec.source ?? "unknown"))
            }
            if let last = cand.last {
                // Also pick up the final end marker.
                boundaries.append((Double(last.end), last.source ?? "unknown"))
            }
        }

        let clusters = clusterBoundaries(boundaries, tolerance: toleranceS)
        // Dedupe to meaningful boundaries.
        var times: [Double] = []
        for (t, srcs) in clusters {
            let snapped = snap(t, downbeats: downbeats)
            if times.isEmpty || snapped - times[times.count - 1] > 2.0 {
                times.append(round1000(snapped))
            }
            // Single-source boundary without convergence: info.
            if Set(srcs).count == 1 {
                anomalies.append(Anomaly(kind: "single_source_boundary", time: round1000(snapped), detail: srcs[0]))
            }
        }

        // Divergence flag: within a cluster, if the spread exceeds tolerance.
        for (t, srcs) in clusters {
            let clusterTimes = boundaries.filter { abs($0.t - t) <= toleranceS }.map(\.t)
            if let maxT = clusterTimes.max(), let minT = clusterTimes.min(), maxT - minT > toleranceS - 0.01 {
                anomalies.append(
                    Anomaly(
                        kind: "boundary_divergence",
                        time: round1000(t),
                        detail: "spread=\(String(format: "%.2f", maxT - minT))s, sources=\(pythonListRepr(srcs))"
                    )
                )
            }
        }

        if times.isEmpty || times[0] > 0.5 {
            times.insert(0.0, at: 0)
        }
        if let last = times.last, last < durationS - 0.5 {
            times.append(durationS)
        }

        var sections: [AnalysisSection] = []
        for (i, pair) in zip(times, times.dropFirst()).enumerated() {
            sections.append(AnalysisSection(index: i, start: pair.0, end: pair.1, cluster: i, source: "consolidated", confidence: 0.6))
        }
        return ConsolidationResult(sections: sections, anomalies: anomalies)
    }

    private static func round1000(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    /// Mirrors Python's `str(list_of_str)` (`['a', 'b']`) so the
    /// `boundary_divergence` detail string matches byte-for-byte.
    private static func pythonListRepr(_ items: [String]) -> String {
        "[" + items.map { "'\($0)'" }.joined(separator: ", ") + "]"
    }
}
