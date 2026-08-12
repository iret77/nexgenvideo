import Foundation
import NexGenEngine

/// Resolves canonical song form from the strongest measured evidence available at runtime.
public enum Consolidator {
    static let resolutionVersion = "adaptive-structure/v4"
    static let systemSource = "apple_music_understanding"
    public static let toleranceS = 2.0
    public static let downbeatSnapS = 0.5
    static let minimumConsensusBars = 8
    static let minimumTerminalBars = 2
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
        case reviewRequired = "review_required"
        case needsReview = "needs_review"
    }

    enum BoundaryEvidenceKind: String, Codable, Sendable {
        case systemHierarchy = "system_hierarchy"
        case detectorConsensus = "detector_consensus"
        case lyricsSupportedAcoustic = "lyrics_supported_acoustic"
        case lyricsAlignedVocal = "lyrics_aligned_vocal"
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

    private struct BoundaryGroup {
        let time: Double
        let times: [Double]
        let sources: Set<String>
    }

    private struct SelectedBoundary {
        let group: BoundaryGroup
        let kind: BoundaryEvidenceKind
        let lyricMarker: String?
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
                durationS: durationS
              ) else {
            return consolidateNativeDetailed(
                candidateSeries: candidateSeries,
                alignment: alignment,
                alignmentReport: alignmentReport,
                downbeats: downbeats,
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

    private static func consolidateNativeDetailed(
        candidateSeries: [CandidateSeries],
        alignment: [AlignmentLine]?,
        alignmentReport: LyricsAlignment.Result?,
        downbeats: [Double],
        durationS: Double
    ) -> DetailedResult {
        let grid = downbeats
            .filter { $0 >= 0 && $0 <= durationS }
            .sorted()
        let measuredBarDuration = medianPositiveDifference(grid)
        let barDuration = measuredBarDuration ?? max(1.0, toleranceS)
        let markerTolerance = max(toleranceS, barDuration)
        let minimumConsensusSpan = barDuration * Double(minimumConsensusBars)
        let minimumTerminalSpan = barDuration * Double(minimumTerminalBars)

        var detectorBoundaries: [(t: Double, source: String)] = []
        var detectorSources: Set<String> = []
        for candidate in candidateSeries where !candidate.sections.isEmpty {
            detectorSources.insert(candidate.source)
            for section in candidate.sections
                where section.start > 0.01 && section.start < durationS - 0.01 {
                detectorBoundaries.append((round1000(section.start), candidate.source))
            }
        }

        var deduplicated: [(t: Double, source: String)] = []
        var seen: Set<String> = []
        for boundary in detectorBoundaries.sorted(by: boundaryOrder) {
            let key = "\(boundary.source)\u{1f}\(round1000(boundary.t))"
            if seen.insert(key).inserted { deduplicated.append(boundary) }
        }

        let rawGroups = groupedBoundaryRecords(deduplicated, tolerance: toleranceS).map { matching in
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
                    sources: matching.reduce(into: Set<String>()) {
                        $0.formUnion($1.sources)
                    }
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
        for group in consensusGroups {
            guard let minimum = group.times.min(),
                  let maximum = group.times.max(),
                  maximum - minimum > downbeatSnapS else { continue }
            let spread = String(format: "%.3f", maximum - minimum)
            anomalies.append(
                Anomaly(
                    kind: "boundary_divergence",
                    time: group.time,
                    detail: "Detector spread \(spread)s converged on this downbeat."
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
                        if $0.sources.count != $1.sources.count {
                            return $0.sources.count > $1.sources.count
                        }
                        return $0.time < $1.time
                    }
                let measuredBoundary: BoundaryGroup
                let evidenceKind: BoundaryEvidenceKind
                if let match = matches.first {
                    measuredBoundary = match
                    evidenceKind = .lyricsSupportedAcoustic
                } else {
                    measuredBoundary = BoundaryGroup(
                        time: target,
                        times: [],
                        sources: ["whisper_alignment"]
                    )
                    evidenceKind = .lyricsAlignedVocal
                }
                guard measuredBoundary.time > 0.01,
                      measuredBoundary.time < durationS - 0.01 else {
                    anomalies.append(
                        Anomaly(
                            kind: "out_of_range_lyric_marker",
                            time: measuredBoundary.time,
                            detail: "The aligned lyric marker does not resolve to an internal measured boundary."
                        )
                    )
                    continue
                }
                guard markerBoundaries.insert(measuredBoundary.time).inserted else {
                    anomalies.append(
                        Anomaly(
                            kind: "colliding_lyric_markers",
                            time: measuredBoundary.time,
                            detail: "Multiple lyric section markers resolve to the same measured bar boundary."
                        )
                    )
                    continue
                }
                selected[measuredBoundary.time] = SelectedBoundary(
                    group: measuredBoundary,
                    kind: evidenceKind,
                    lyricMarker: marker.sectionMarker
                )
                labels[measuredBoundary.time] = marker.sectionMarker
                resolvedMarkers += 1
            }
        }

        let allMarkersResolved = alignmentIsReliable
            && !markers.isEmpty
            && resolvedMarkers == markers.count
        let consensusByStrength = consensusGroups.sorted {
            if $0.sources.count != $1.sources.count { return $0.sources.count > $1.sources.count }
            return $0.time < $1.time
        }
        if allMarkersResolved {
            let lastMarker = markerBoundaries.max() ?? 0
            if let terminal = consensusGroups.reversed().first(where: {
                $0.time - lastMarker >= minimumConsensusSpan
                    && durationS - $0.time >= minimumTerminalSpan
            }) {
                selected[terminal.time] = SelectedBoundary(
                    group: terminal,
                    kind: .detectorConsensus,
                    lyricMarker: nil
                )
            }
        } else {
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
        let status: ResolutionStatus
        if measuredBarDuration == nil || detectorSources.isEmpty {
            status = .needsReview
        } else if allMarkersResolved || hasAcceptedConsensus || homogeneousConsensus {
            status = .resolved
        } else {
            status = .reviewRequired
            for group in groups.sorted(by: {
                if $0.sources.count != $1.sources.count { return $0.sources.count > $1.sources.count }
                return $0.time < $1.time
            }) {
                guard group.time > 0.01,
                      group.time < durationS - 0.01,
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

        let method: String
        switch status {
        case .needsReview:
            method = "unresolved"
        case .reviewRequired:
            method = "phrase_filtered_acoustic"
        case .resolved where homogeneousConsensus:
            method = "homogeneous_consensus"
        case .resolved:
            method = "per_boundary_evidence"
        }
        let detail: String
        switch status {
        case .resolved where homogeneousConsensus:
            detail = "Independent acoustic detectors found no internal structural boundary."
        case .resolved:
            detail = "Every canonical boundary has measured acoustic or reliable lyric-alignment evidence on the bar grid."
        case .reviewRequired:
            detail = "The bar-aligned structure contains single-detector evidence; review every section before approval."
        case .needsReview where measuredBarDuration == nil:
            detail = "No complete measured bar grid is available for canonical structure resolution."
        case .needsReview:
            detail = "No acoustic structure candidates are available for canonical structure resolution."
        }

        let accepted: [Double: SelectedBoundary] = status == .needsReview ? [:] : selected
        let times = endpoints.union(accepted.keys).sorted()
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
            } else if let boundary = accepted[pair.0] {
                switch boundary.kind {
                case .lyricsSupportedAcoustic:
                    source = "measured_alignment_fusion"
                    confidence = 0.9
                case .lyricsAlignedVocal:
                    source = "measured_vocal_alignment"
                    confidence = 0.85
                case .detectorConsensus:
                    source = "measured_consensus"
                    confidence = 0.8
                case .singleDetector:
                    source = "measured_phrase_filtered"
                    confidence = 0.6
                case .systemHierarchy:
                    source = "measured_system_hierarchy"
                    confidence = 0.95
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
                    index: 0,
                    start: 0,
                    end: round1000(durationS),
                    cluster: 0,
                    source: "unresolved_structure",
                    confidence: 0.3
                ),
            ]
        }

        let evidence = accepted.values.map {
            BoundaryEvidence(
                time: $0.group.time,
                kind: $0.kind,
                detectorSources: $0.group.sources.sorted(),
                lyricMarker: $0.lyricMarker
            )
        }.sorted { $0.time < $1.time }
        let acceptedCandidateCount = accepted.values.reduce(0) { $0 + $1.group.times.count }
        return DetailedResult(
            sections: sections,
            anomalies: anomalies,
            resolution: StructureResolution(
                version: resolutionVersion,
                status: status,
                method: method,
                detectorSources: detectorSources.sorted(),
                minimumSectionBars: minimumConsensusBars,
                candidateBoundaryCount: deduplicated.count,
                consensusBoundaryCount: consensusGroups.count,
                alignmentMarkerCount: alignmentReport?.markerCount ?? markers.count,
                resolvedAlignmentMarkerCount: resolvedMarkers,
                acceptedBoundaryCount: accepted.count,
                discardedBoundaryCount: max(0, deduplicated.count - acceptedCandidateCount),
                boundaryEvidence: evidence,
                hierarchy: nil,
                detail: detail
            )
        )
    }

    private static func normalizedHierarchy(
        _ measurement: MusicUnderstandingMeasurement,
        durationS: Double
    ) -> StructureHierarchy? {
        guard durationS > 0,
              durationS.isFinite,
              !measurement.bars.isEmpty,
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
                  measurement.bars.contains { abs($0 - section.start) <= downbeatSnapS }
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
