import Foundation
import NexGenEngine

/// Resolves a canonical song-form hierarchy from measured system analysis.
public enum Consolidator {
    static let resolutionVersion = "system-structure/v3"
    static let systemSource = "apple_music_understanding"
    public static let toleranceS = 2.0
    public static let downbeatSnapS = 0.5
    private static let sourceCoverageToleranceS = 0.05
    private static let rangeContinuityToleranceS = 0.001

    public struct Anomaly: Sendable, Equatable {
        public let kind: String
        public let time: Double
        public let detail: String
    }

    public struct ConsolidationResult: Sendable, Equatable {
        public let sections: [AnalysisSection]
        public let anomalies: [Anomaly]
    }

    enum ResolutionStatus: String, Codable, Sendable {
        case resolved
        case needsReview = "needs_review"
    }

    enum BoundaryEvidenceKind: String, Codable, Sendable {
        case systemHierarchy = "system_hierarchy"
    }

    struct BoundaryEvidence: Codable, Sendable, Equatable {
        let time: Double
        let kind: BoundaryEvidenceKind
        let detectorSources: [String]
        let lyricMarker: String?

        enum CodingKeys: String, CodingKey {
            case time, kind
            case detectorSources = "detector_sources"
            case lyricMarker = "lyric_marker"
        }
    }

    struct StructureHierarchy: Codable, Sendable, Equatable {
        let source: String
        let sections: [MeasuredMusicRange]
        let segments: [MeasuredMusicRange]
        let phrases: [MeasuredMusicRange]
    }

    struct StructureResolution: Codable, Sendable, Equatable {
        let version: String
        let status: ResolutionStatus
        let method: String
        let detectorSources: [String]
        let minimumSectionBars: Int
        let candidateBoundaryCount: Int
        let consensusBoundaryCount: Int
        let alignmentMarkerCount: Int
        let resolvedAlignmentMarkerCount: Int
        let acceptedBoundaryCount: Int
        let discardedBoundaryCount: Int
        let boundaryEvidence: [BoundaryEvidence]
        let hierarchy: StructureHierarchy?
        let detail: String

        enum CodingKeys: String, CodingKey {
            case version, status, method, hierarchy, detail
            case detectorSources = "detector_sources"
            case minimumSectionBars = "minimum_section_bars"
            case candidateBoundaryCount = "candidate_boundary_count"
            case consensusBoundaryCount = "consensus_boundary_count"
            case alignmentMarkerCount = "alignment_marker_count"
            case resolvedAlignmentMarkerCount = "resolved_alignment_marker_count"
            case acceptedBoundaryCount = "accepted_boundary_count"
            case discardedBoundaryCount = "discarded_boundary_count"
            case boundaryEvidence = "boundary_evidence"
        }
    }

    struct DetailedResult: Sendable, Equatable {
        let sections: [AnalysisSection]
        let anomalies: [Anomaly]
        let resolution: StructureResolution
    }

    struct CandidateSeries: Sendable {
        let source: String
        let sections: [AnalysisSection]
    }

    static func clusterBoundaries(
        _ boundaries: [(t: Double, source: String)], tolerance: Double
    ) -> [(t: Double, sources: [String])] {
        groupedBoundaryRecords(boundaries, tolerance: tolerance).map { group in
            let mean = group.reduce(0.0) { $0 + $1.t } / Double(group.count)
            return (mean, group.map(\.source))
        }
    }

    static func snap(_ time: Double, downbeats: [Double]) -> Double {
        guard let closest = downbeats.min(by: { abs($0 - time) < abs($1 - time) }) else {
            return time
        }
        return abs(closest - time) <= downbeatSnapS ? closest : time
    }

    public static func consolidate(
        candidates: [[AnalysisSection]], alignment: [AlignmentLine]?, downbeats: [Double], durationS: Double
    ) -> ConsolidationResult {
        let detailed = consolidateDetailed(
            candidates: candidates,
            alignment: alignment,
            alignmentReport: nil,
            downbeats: downbeats,
            durationS: durationS
        )
        return ConsolidationResult(sections: detailed.sections, anomalies: detailed.anomalies)
    }

    static func consolidateDetailed(
        candidates: [[AnalysisSection]],
        alignment: [AlignmentLine]?,
        alignmentReport: LyricsAlignment.Result?,
        downbeats: [Double],
        durationS: Double,
        musicUnderstanding: MusicUnderstandingMeasurement? = nil
    ) -> DetailedResult {
        let series = candidates.map { sections in
            CandidateSeries(
                source: sections.compactMap(\.source).first ?? "unknown",
                sections: sections
            )
        }
        return consolidateDetailed(
            candidateSeries: series,
            alignment: alignment,
            alignmentReport: alignmentReport,
            downbeats: downbeats,
            durationS: durationS,
            musicUnderstanding: musicUnderstanding
        )
    }

    static func consolidateDetailed(
        candidateSeries: [CandidateSeries],
        alignment: [AlignmentLine]?,
        alignmentReport: LyricsAlignment.Result?,
        downbeats: [Double],
        durationS: Double,
        musicUnderstanding: MusicUnderstandingMeasurement? = nil
    ) -> DetailedResult {
        let native = nativeBoundarySummary(candidateSeries, durationS: durationS)
        guard let measurement = musicUnderstanding,
              let hierarchy = normalizedHierarchy(
                measurement,
                downbeats: downbeats,
                durationS: durationS
              ) else {
            return unresolvedResult(
                nativeCandidateCount: native.count,
                nativeSources: native.sources,
                markerCount: alignmentReport?.markerCount
                    ?? (alignment ?? []).filter { $0.sectionMarker != nil }.count,
                durationS: durationS
            )
        }

        var anomalies: [Anomaly] = []
        var labels: [Double: String] = [:]
        var resolvedMarkers = 0
        let markerLines = (alignment ?? [])
            .filter { $0.sectionMarker != nil }
            .sorted { $0.start < $1.start }
        if alignmentReport?.hasReliableStructureEvidence == true {
            let starts = hierarchy.sections.map(\.start)
            let medianBar = medianPositiveDifference(downbeats) ?? toleranceS
            let markerTolerance = max(toleranceS, medianBar)
            for marker in markerLines {
                guard let name = marker.sectionMarker,
                      let closest = starts.min(by: {
                          abs($0 - marker.start) < abs($1 - marker.start)
                      }),
                      abs(closest - marker.start) <= markerTolerance,
                      labels[closest] == nil else {
                    anomalies.append(
                        Anomaly(
                            kind: "unresolved_lyric_marker",
                            time: round1000(marker.start),
                            detail: "No unique system section boundary supports this lyric marker."
                        )
                    )
                    continue
                }
                labels[closest] = name
                resolvedMarkers += 1
            }
        }

        let sectionStarts = hierarchy.sections.map(\.start)
        let internalStarts = hierarchy.sections.dropFirst().map(\.start)
        let evidence = sectionStarts.map { time in
            BoundaryEvidence(
                time: time,
                kind: .systemHierarchy,
                detectorSources: [systemSource],
                lyricMarker: labels[time]
            )
        }
        let sections = hierarchy.sections.enumerated().map { index, range in
            AnalysisSection(
                index: index,
                start: range.start,
                end: range.end,
                cluster: index,
                label: labels[range.start],
                source: "measured_system_hierarchy",
                confidence: 0.95
            )
        }
        let resolution = StructureResolution(
            version: resolutionVersion,
            status: .resolved,
            method: "music_understanding_hierarchy",
            detectorSources: [systemSource],
            minimumSectionBars: 0,
            candidateBoundaryCount: native.count,
            consensusBoundaryCount: 0,
            alignmentMarkerCount: alignmentReport?.markerCount ?? markerLines.count,
            resolvedAlignmentMarkerCount: resolvedMarkers,
            acceptedBoundaryCount: internalStarts.count,
            discardedBoundaryCount: native.count,
            boundaryEvidence: evidence,
            hierarchy: hierarchy,
            detail: "Apple Music Understanding measured a complete section, segment, and phrase hierarchy; native local-change candidates were retained only as diagnostics."
        )
        return DetailedResult(sections: sections, anomalies: anomalies, resolution: resolution)
    }

    private static func unresolvedResult(
        nativeCandidateCount: Int,
        nativeSources: Set<String>,
        markerCount: Int,
        durationS: Double
    ) -> DetailedResult {
        let sections = durationS > 0
            ? [
                AnalysisSection(
                    index: 0,
                    start: 0,
                    end: round1000(durationS),
                    cluster: 0,
                    source: "unresolved_structure",
                    confidence: 0.0
                ),
            ]
            : []
        let detail = "No complete system section/segment/phrase hierarchy is available. Native MFCC/Mel change points are diagnostic phrase candidates, not reliable song-form boundaries."
        return DetailedResult(
            sections: sections,
            anomalies: [
                Anomaly(
                    kind: "system_structure_unavailable",
                    time: 0,
                    detail: detail
                ),
            ],
            resolution: StructureResolution(
                version: resolutionVersion,
                status: .needsReview,
                method: "unresolved",
                detectorSources: nativeSources.sorted(),
                minimumSectionBars: 0,
                candidateBoundaryCount: nativeCandidateCount,
                consensusBoundaryCount: 0,
                alignmentMarkerCount: markerCount,
                resolvedAlignmentMarkerCount: 0,
                acceptedBoundaryCount: 0,
                discardedBoundaryCount: nativeCandidateCount,
                boundaryEvidence: [],
                hierarchy: nil,
                detail: detail
            )
        )
    }

    private static func normalizedHierarchy(
        _ measurement: MusicUnderstandingMeasurement,
        downbeats: [Double],
        durationS: Double
    ) -> StructureHierarchy? {
        guard durationS > 0,
              !measurement.beats.isEmpty,
              !downbeats.isEmpty,
              let sections = validatedRanges(
                measurement.sections,
                durationS: durationS,
                requireFullCoverage: true,
                requireContiguous: true
              ),
              let segments = validatedRanges(
                measurement.segments,
                durationS: durationS,
                requireFullCoverage: false,
                requireContiguous: false
              ),
              let phrases = validatedRanges(
                measurement.phrases,
                durationS: durationS,
                requireFullCoverage: false,
                requireContiguous: false
              ),
              sections.dropFirst().allSatisfy({ section in
                  downbeats.contains { abs($0 - section.start) <= downbeatSnapS }
              }),
              nested(segments, inside: sections),
              nested(phrases, inside: segments),
              everyParentHasChild(sections, children: segments),
              everyParentHasChild(segments, children: phrases) else {
            return nil
        }
        return StructureHierarchy(
            source: systemSource,
            sections: sections,
            segments: segments,
            phrases: phrases
        )
    }

    private static func validatedRanges(
        _ input: [MeasuredMusicRange],
        durationS: Double,
        requireFullCoverage: Bool,
        requireContiguous: Bool
    ) -> [MeasuredMusicRange]? {
        guard !input.isEmpty,
              input.allSatisfy({
                  $0.start.isFinite && $0.end.isFinite
                      && $0.start >= 0 && $0.end > $0.start
                      && $0.start < durationS + sourceCoverageToleranceS
                      && $0.end <= durationS + sourceCoverageToleranceS
              }) else { return nil }
        for pair in zip(input, input.dropFirst()) {
            guard pair.1.start > pair.0.start,
                  pair.1.start >= pair.0.end - rangeContinuityToleranceS else {
                return nil
            }
            if requireContiguous,
               abs(pair.0.end - pair.1.start) > rangeContinuityToleranceS {
                return nil
            }
        }
        if requireFullCoverage {
            guard input[0].start <= sourceCoverageToleranceS,
                  input[input.count - 1].end >= durationS - sourceCoverageToleranceS else {
                return nil
            }
        }
        return input
    }

    private static func nested(
        _ children: [MeasuredMusicRange],
        inside parents: [MeasuredMusicRange]
    ) -> Bool {
        children.allSatisfy { child in
            parents.contains { parent in
                child.start >= parent.start - rangeContinuityToleranceS
                    && child.end <= parent.end + rangeContinuityToleranceS
            }
        }
    }

    private static func everyParentHasChild(
        _ parents: [MeasuredMusicRange],
        children: [MeasuredMusicRange]
    ) -> Bool {
        parents.allSatisfy { parent in
            children.contains { child in
                child.start >= parent.start - rangeContinuityToleranceS
                    && child.end <= parent.end + rangeContinuityToleranceS
            }
        }
    }

    private static func nativeBoundarySummary(
        _ candidates: [CandidateSeries],
        durationS: Double
    ) -> (count: Int, sources: Set<String>) {
        var keys: Set<String> = []
        var sources: Set<String> = []
        for candidate in candidates where !candidate.sections.isEmpty {
            sources.insert(candidate.source)
            for section in candidate.sections
                where section.start > 0.01 && section.start < durationS - 0.01 {
                keys.insert("\(candidate.source)\u{1f}\(round1000(section.start))")
            }
        }
        return (keys.count, sources)
    }

    private static func boundaryOrder(
        _ lhs: (t: Double, source: String), _ rhs: (t: Double, source: String)
    ) -> Bool {
        lhs.t == rhs.t ? lhs.source < rhs.source : lhs.t < rhs.t
    }

    private static func groupedBoundaryRecords(
        _ boundaries: [(t: Double, source: String)], tolerance: Double
    ) -> [[(t: Double, source: String)]] {
        guard !boundaries.isEmpty else { return [] }
        let sorted = boundaries.sorted(by: boundaryOrder)
        var groups = [[sorted[0]]]
        for entry in sorted.dropFirst() {
            if entry.t - groups[groups.count - 1][0].t <= tolerance {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups
    }

    private static func medianPositiveDifference(_ values: [Double]) -> Double? {
        let differences = zip(values, values.dropFirst())
            .map { $0.1 - $0.0 }
            .filter { $0 > 0.01 }
            .sorted()
        guard !differences.isEmpty else { return nil }
        return differences[differences.count / 2]
    }

    private static func round1000(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}
