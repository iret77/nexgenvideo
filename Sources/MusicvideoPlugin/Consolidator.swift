import Foundation
import NexGenEngine

/// Fuses acoustic candidates and reliable lyric evidence into one bar-aligned timeline.
public enum Consolidator {
    public static let toleranceS = 2.0
    public static let downbeatSnapS = 0.5
    static let minimumConsensusBars = 8

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
        case reviewRequired = "review_required"
        case needsReview = "needs_review"
    }

    enum BoundaryEvidenceKind: String, Codable, Sendable {
        case detectorConsensus = "detector_consensus"
        case lyricsSupportedAcoustic = "lyrics_supported_acoustic"
        case singleDetector = "single_detector"
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
        let detail: String

        enum CodingKeys: String, CodingKey {
            case version, status, method, detail
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

    private struct BoundaryGroup {
        let time: Double
        let times: [Double]
        let sources: Set<String>
    }

    struct CandidateSeries: Sendable {
        let source: String
        let sections: [AnalysisSection]
    }

    private struct SelectedBoundary {
        let group: BoundaryGroup
        let kind: BoundaryEvidenceKind
        let lyricMarker: String?
    }

    /// Fixed-span clustering prevents transitive micro-boundary chains.
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
        durationS: Double
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
            durationS: durationS
        )
    }

    static func consolidateDetailed(
        candidateSeries: [CandidateSeries],
        alignment: [AlignmentLine]?,
        alignmentReport: LyricsAlignment.Result?,
        downbeats: [Double],
        durationS: Double
    ) -> DetailedResult {
        let grid = downbeats
            .filter { $0 >= 0 && $0 <= durationS }
            .sorted()
        let barDuration = medianPositiveDifference(grid) ?? max(1.0, toleranceS)
        let agreementTolerance = toleranceS
        let markerTolerance = max(agreementTolerance, barDuration)
        let minimumConsensusSpan = barDuration * Double(minimumConsensusBars)

        var detectorBoundaries: [(t: Double, source: String)] = []
        var detectorSources: Set<String> = []
        for candidate in candidateSeries where !candidate.sections.isEmpty {
            detectorSources.insert(candidate.source)
            for section in candidate.sections {
                guard section.start > 0.01, section.start < durationS - 0.01 else { continue }
                detectorBoundaries.append((round1000(section.start), candidate.source))
            }
        }

        var deduplicated: [(t: Double, source: String)] = []
        var seen: Set<String> = []
        for boundary in detectorBoundaries.sorted(by: boundaryOrder) {
            let key = "\(boundary.source)\u{1f}\(round1000(boundary.t))"
            if seen.insert(key).inserted { deduplicated.append(boundary) }
        }

        let rawGroups: [BoundaryGroup] = groupedBoundaryRecords(
            deduplicated, tolerance: agreementTolerance
        ).map { matching in
            let mean = matching.reduce(0.0) { $0 + $1.t } / Double(matching.count)
            return BoundaryGroup(
                time: round1000(nearestGridPoint(mean, grid: grid)),
                times: matching.map(\.t),
                sources: Set(matching.map(\.source))
            )
        }
        let groups = Dictionary(grouping: rawGroups, by: \.time)
            .map { time, matching in
                BoundaryGroup(
                    time: time,
                    times: matching.flatMap(\.times),
                    sources: matching.reduce(into: Set<String>()) { $0.formUnion($1.sources) }
                )
            }
            .sorted { $0.time < $1.time }
        let consensusGroups = groups.filter { $0.sources.count >= 2 }

        var anomalies: [Anomaly] = []
        let singleSourceCount = groups.filter { $0.sources.count == 1 }.count
        if singleSourceCount > 0 {
            anomalies.append(
                Anomaly(
                    kind: "single_detector_boundary_evidence",
                    time: 0,
                    detail: "Found \(singleSourceCount) acoustic boundary groups without independent detector agreement."
                )
            )
        }
        for group in groups {
            guard group.sources.count >= 2,
                  let minimum = group.times.min(), let maximum = group.times.max(),
                  maximum - minimum > downbeatSnapS else { continue }
            anomalies.append(
                Anomaly(
                    kind: "boundary_divergence",
                    time: group.time,
                    detail: "Detector spread \(String(format: "%.3f", maximum - minimum))s converged on this downbeat."
                )
            )
        }

        let endpoints: Set<Double> = [0, round1000(durationS)]
        var selected: [Double: SelectedBoundary] = [:]
        var labels: [Double: String] = [:]
        var markerBoundaries: Set<Double> = []
        var resolvedMarkers = 0
        let markers = (alignment ?? [])
            .filter { $0.sectionMarker != nil }
            .sorted { $0.start < $1.start }
        let alignmentIsReliable = alignmentReport?.hasReliableStructureEvidence == true
        if alignmentIsReliable {
            for marker in markers {
                let target = round1000(nearestGridPoint(marker.start, grid: grid))
                if target <= markerTolerance {
                    guard markerBoundaries.insert(0).inserted else {
                        anomalies.append(
                            Anomaly(
                                kind: "colliding_lyric_markers",
                                time: 0,
                                detail: "Multiple lyric section markers resolve to the opening boundary."
                            )
                        )
                        continue
                    }
                    labels[0] = marker.sectionMarker
                    resolvedMarkers += 1
                    continue
                }
                let matches = groups
                    .filter {
                        $0.time > 0.01
                            && $0.time < durationS - 0.01
                            && abs($0.time - target) <= markerTolerance
                    }
                    .sorted {
                        let leftDistance = abs($0.time - target)
                        let rightDistance = abs($1.time - target)
                        if leftDistance != rightDistance { return leftDistance < rightDistance }
                        if $0.sources.count != $1.sources.count { return $0.sources.count > $1.sources.count }
                        return $0.time < $1.time
                    }
                guard let match = matches.first else {
                    anomalies.append(
                        Anomaly(
                            kind: "unresolved_lyric_marker",
                            time: target,
                            detail: "No acoustic boundary supports \(marker.sectionMarker ?? "section") near this bar."
                        )
                    )
                    continue
                }
                guard markerBoundaries.insert(match.time).inserted else {
                    anomalies.append(
                        Anomaly(
                            kind: "colliding_lyric_markers",
                            time: match.time,
                            detail: "Multiple lyric section markers resolve to the same acoustic boundary."
                        )
                    )
                    continue
                }
                selected[match.time] = SelectedBoundary(
                    group: match,
                    kind: .lyricsSupportedAcoustic,
                    lyricMarker: marker.sectionMarker
                )
                labels[match.time] = marker.sectionMarker
                resolvedMarkers += 1
            }
        }

        let allMarkersResolved = alignmentIsReliable
            && !markers.isEmpty
            && resolvedMarkers == markers.count
        if !allMarkersResolved {
            let consensusByStrength = consensusGroups.sorted {
                if $0.sources.count != $1.sources.count { return $0.sources.count > $1.sources.count }
                return $0.time < $1.time
            }
            for group in consensusByStrength {
                guard group.time > 0.01, group.time < durationS - 0.01 else { continue }
                let occupied = endpoints.union(selected.keys)
                if occupied.allSatisfy({ abs($0 - group.time) >= minimumConsensusSpan }) {
                    selected[group.time] = SelectedBoundary(
                        group: group,
                        kind: .detectorConsensus,
                        lyricMarker: nil
                    )
                }
            }
        }

        let homogeneousConsensus = deduplicated.isEmpty && detectorSources.count >= 2
        let hasAcceptedConsensus = selected.values.contains { $0.kind == .detectorConsensus }
        var status: ResolutionStatus
        if grid.isEmpty || detectorSources.isEmpty {
            status = .needsReview
        } else if allMarkersResolved || hasAcceptedConsensus || homogeneousConsensus {
            status = .resolved
        } else {
            status = .reviewRequired
            let fallbackByStrength = groups.sorted {
                if $0.sources.count != $1.sources.count { return $0.sources.count > $1.sources.count }
                return $0.time < $1.time
            }
            for group in fallbackByStrength {
                guard group.time > 0.01, group.time < durationS - 0.01,
                      selected[group.time] == nil else { continue }
                let occupied = endpoints.union(selected.keys)
                if occupied.allSatisfy({ abs($0 - group.time) >= minimumConsensusSpan }) {
                    selected[group.time] = SelectedBoundary(
                        group: group,
                        kind: .singleDetector,
                        lyricMarker: nil
                    )
                }
            }
        }

        let times = endpoints.union(selected.keys).sorted()
        let acceptedInternal = selected.count
        let method: String
        if status == .needsReview {
            method = "unresolved"
        } else if homogeneousConsensus {
            method = "homogeneous_consensus"
        } else if status == .reviewRequired {
            method = "phrase_filtered_acoustic"
        } else {
            method = "per_boundary_evidence"
        }

        let detail: String
        switch status {
        case .resolved where homogeneousConsensus:
            detail = "Independent acoustic detectors found no internal structural boundary."
        case .resolved:
            detail = "Every canonical boundary has corroborated acoustic or lyric-alignment evidence on the downbeat grid."
        case .reviewRequired:
            detail = "The phrase-filtered downbeat structure contains single-detector evidence; review every section before approval."
        case .needsReview where grid.isEmpty:
            detail = "No downbeat grid is available for a canonical bar-aligned structure."
        case .needsReview:
            detail = "No acoustic structure candidate is available for a canonical section timeline."
        }

        var sections: [AnalysisSection] = []
        for (index, pair) in zip(times, times.dropFirst()).enumerated() {
            let source: String
            let confidence: Double
            if status == .needsReview {
                source = "unresolved_structure"
                confidence = 0.3
            } else if pair.0 <= 0.01 {
                source = "measured_track_extent"
                confidence = 1.0
            } else if let evidence = selected[pair.0] {
                switch evidence.kind {
                case .lyricsSupportedAcoustic:
                    source = "measured_alignment_fusion"
                    confidence = 0.9
                case .detectorConsensus:
                    source = "measured_consensus"
                    confidence = 0.8
                case .singleDetector:
                    source = "measured_phrase_filtered"
                    confidence = 0.6
                }
            } else {
                source = "measured_track_extent"
                confidence = 1.0
            }
            sections.append(
                AnalysisSection(
                    index: index,
                    start: round1000(pair.0),
                    end: round1000(pair.1),
                    cluster: index,
                    label: labels[pair.0],
                    source: source,
                    confidence: confidence
                )
            )
        }
        if sections.isEmpty, durationS > 0 {
            sections = [
                AnalysisSection(
                    index: 0, start: 0, end: round1000(durationS), cluster: 0,
                    source: "unresolved_structure", confidence: 0.3
                )
            ]
        }

        let evidence = selected.values
            .map { selected in
                BoundaryEvidence(
                    time: selected.group.time,
                    kind: selected.kind,
                    detectorSources: selected.group.sources.sorted(),
                    lyricMarker: selected.lyricMarker
                )
            }
            .sorted { $0.time < $1.time }
        let acceptedCandidateCount = selected.values.reduce(0) { $0 + $1.group.times.count }
        let resolution = StructureResolution(
            version: "bar-consensus/v1",
            status: status,
            method: method,
            detectorSources: detectorSources.sorted(),
            minimumSectionBars: minimumConsensusBars,
            candidateBoundaryCount: deduplicated.count,
            consensusBoundaryCount: consensusGroups.count,
            alignmentMarkerCount: alignmentReport?.markerCount ?? markers.count,
            resolvedAlignmentMarkerCount: resolvedMarkers,
            acceptedBoundaryCount: acceptedInternal,
            discardedBoundaryCount: max(0, deduplicated.count - acceptedCandidateCount),
            boundaryEvidence: evidence,
            detail: detail
        )
        return DetailedResult(sections: sections, anomalies: anomalies, resolution: resolution)
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

    private static func nearestGridPoint(_ time: Double, grid: [Double]) -> Double {
        guard let closest = grid.min(by: { abs($0 - time) < abs($1 - time) }) else {
            return time
        }
        return closest
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
