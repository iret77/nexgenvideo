import Foundation
import Testing
@testable import NexGenEngine

/// Coverage derived from `nexgen_pack_musicvideo/analysis/structure/consolidator.py`'s
/// logic (no dedicated Python test file exists for this module — the task's
/// consolidation rules are ported and exercised directly): boundary
/// clustering, downbeat snapping, alignment-marker voting, and the two
/// anomaly flags.
@Suite("Musicvideo Consolidator")
struct ConsolidatorTests {
    // MARK: - clusterBoundaries

    @Test("clusterBoundaries groups chained-tolerance boundaries and keeps the mean")
    func clusterBoundariesGroupsChained() {
        // 10.0 -> 11.5 (within 2s) -> 13.0 (within 2s of 11.5, NOT of 10.0):
        // chained tolerance means all three land in one group.
        let boundaries: [(t: Double, source: String)] = [
            (10.0, "a"), (11.5, "b"), (13.0, "c"),
        ]
        let clusters = Consolidator.clusterBoundaries(boundaries, tolerance: 2.0)
        #expect(clusters.count == 1)
        #expect(abs(clusters[0].t - (10.0 + 11.5 + 13.0) / 3) < 1e-9)
        #expect(Set(clusters[0].sources) == ["a", "b", "c"])
    }

    @Test("clusterBoundaries splits boundaries beyond tolerance into separate groups")
    func clusterBoundariesSplitsFarApart() {
        let boundaries: [(t: Double, source: String)] = [(0.0, "a"), (5.0, "b")]
        let clusters = Consolidator.clusterBoundaries(boundaries, tolerance: 2.0)
        #expect(clusters.count == 2)
    }

    @Test("clusterBoundaries is empty for empty input")
    func clusterBoundariesEmptyInput() {
        #expect(Consolidator.clusterBoundaries([], tolerance: 2.0).isEmpty)
    }

    // MARK: - snap

    @Test("snap moves a boundary to a downbeat within tolerance")
    func snapMovesWithinTolerance() {
        #expect(Consolidator.snap(10.3, downbeats: [10.0, 12.0]) == 10.0)
    }

    @Test("snap leaves a boundary untouched beyond tolerance")
    func snapLeavesUntouchedBeyondTolerance() {
        #expect(Consolidator.snap(10.6, downbeats: [10.0, 12.0]) == 10.6)
    }

    @Test("snap is a no-op with no downbeats")
    func snapNoOpWithoutDownbeats() {
        #expect(Consolidator.snap(10.3, downbeats: []) == 10.3)
    }

    // MARK: - consolidate: Path A (alignment markers)

    @Test("consolidate uses alignment markers as the section truth")
    func consolidateUsesAlignmentMarkers() {
        let alignment = [
            AlignmentLine(start: 0.0, end: 10.0, text: "l1", sectionMarker: "intro"),
            AlignmentLine(start: 20.0, end: 30.0, text: "l2", sectionMarker: "verse1"),
            AlignmentLine(start: 45.0, end: 55.0, text: "l3", sectionMarker: "chorus1"),
        ]
        let result = Consolidator.consolidate(candidates: [], alignment: alignment, downbeats: [], durationS: 120.0)
        #expect(result.sections.count == 3)
        #expect(result.sections.map(\.label) == ["intro", "verse1", "chorus1"])
        #expect(result.sections.map(\.source) == ["alignment", "alignment", "alignment"])
        #expect(result.sections[2].end == 120.0)
        #expect(result.sections.allSatisfy { $0.confidence == 0.9 })
    }

    @Test("consolidate inserts a synthetic intro when the first marker starts late")
    func consolidateInsertsSyntheticIntro() {
        let alignment = [
            AlignmentLine(start: 5.0, end: 10.0, text: "l1", sectionMarker: "verse1"),
        ]
        let result = Consolidator.consolidate(candidates: [], alignment: alignment, downbeats: [], durationS: 60.0)
        #expect(result.sections.count == 2)
        #expect(result.sections[0].label == "intro")
        #expect(result.sections[0].start == 0.0)
        #expect(result.sections[0].end == 5.0)
        #expect(result.sections[0].index == 0)
        #expect(result.sections[1].index == 1)
        #expect(result.sections[1].label == "verse1")
    }

    @Test("consolidate skips the synthetic intro when the first marker starts near zero")
    func consolidateSkipsSyntheticIntroNearZero() {
        let alignment = [
            AlignmentLine(start: 0.3, end: 10.0, text: "l1", sectionMarker: "verse1"),
        ]
        let result = Consolidator.consolidate(candidates: [], alignment: alignment, downbeats: [], durationS: 60.0)
        #expect(result.sections.count == 1)
        #expect(result.sections[0].label == "verse1")
    }

    @Test("consolidate snaps alignment marker boundaries to downbeats")
    func consolidateSnapsAlignmentBoundaries() {
        let alignment = [
            AlignmentLine(start: 10.2, end: 20.0, text: "l1", sectionMarker: "verse1"),
        ]
        let result = Consolidator.consolidate(
            candidates: [], alignment: alignment, downbeats: [10.0], durationS: 60.0
        )
        // First marker starts near 0? No -> 10.2 snapped to 10.0, which is > 0.5, so
        // a synthetic intro [0, 10.0] precedes it.
        #expect(result.sections.count == 2)
        #expect(result.sections[1].start == 10.0)
    }

    @Test("consolidate ignores alignment with no section markers, falling to path B")
    func consolidateIgnoresAlignmentWithoutMarkers() {
        let alignment = [AlignmentLine(start: 0.0, end: 10.0, text: "l1", sectionMarker: nil)]
        let candidates = [[AnalysisSection(index: 0, start: 0.0, end: 60.0, cluster: 0, source: "librosa")]]
        let result = Consolidator.consolidate(
            candidates: candidates, alignment: alignment, downbeats: [], durationS: 60.0
        )
        #expect(result.sections.allSatisfy { $0.source == "consolidated" })
    }

    // MARK: - consolidate: Path B (detector voting)

    @Test("consolidate averages converging boundaries from multiple detectors")
    func consolidateAveragesConvergingBoundaries() {
        let candidates: [[AnalysisSection]] = [
            [AnalysisSection(index: 0, start: 0.0, end: 30.0, cluster: 0, source: "essentia")],
            [AnalysisSection(index: 0, start: 0.0, end: 31.0, cluster: 0, source: "librosa")],
        ]
        let result = Consolidator.consolidate(candidates: candidates, alignment: nil, downbeats: [], durationS: 60.0)
        // Boundaries: 0,0 (start) and 30,31 (end) -> two clusters -> times [0, ~30.5, 60].
        let starts = result.sections.map(\.start)
        #expect(starts.contains(0.0))
        #expect(starts.contains { abs($0 - 30.5) < 0.01 })
    }

    @Test("consolidate flags a single-source boundary as an anomaly")
    func consolidateFlagsSingleSourceBoundary() {
        let candidates: [[AnalysisSection]] = [
            [AnalysisSection(index: 0, start: 0.0, end: 30.0, cluster: 0, source: "librosa")]
        ]
        let result = Consolidator.consolidate(candidates: candidates, alignment: nil, downbeats: [], durationS: 60.0)
        #expect(result.anomalies.contains { $0.kind == "single_source_boundary" && $0.detail == "librosa" })
    }

    @Test("consolidate flags boundary divergence beyond tolerance")
    func consolidateFlagsBoundaryDivergence() {
        // Two "start" boundaries exactly 2.0s apart: still within the 2.0s cluster
        // tolerance (<=) so they group into one cluster, but the spread (2.0) is
        // greater than `tolerance - 0.01` (1.99), which trips the divergence flag.
        let candidates: [[AnalysisSection]] = [
            [AnalysisSection(index: 0, start: 0.0, end: 30.0, cluster: 0, source: "a")],
            [AnalysisSection(index: 0, start: 2.0, end: 30.0, cluster: 0, source: "b")],
        ]
        let result = Consolidator.consolidate(candidates: candidates, alignment: nil, downbeats: [], durationS: 60.0)
        #expect(result.anomalies.contains { $0.kind == "boundary_divergence" })
    }

    @Test("consolidate always starts at 0 and ends at duration")
    func consolidateAlwaysCoversFullDuration() {
        let candidates: [[AnalysisSection]] = [
            [AnalysisSection(index: 0, start: 10.0, end: 50.0, cluster: 0, source: "essentia")]
        ]
        let result = Consolidator.consolidate(candidates: candidates, alignment: nil, downbeats: [], durationS: 60.0)
        #expect(result.sections.first?.start == 0.0)
        #expect(result.sections.last?.end == 60.0)
    }

    @Test("consolidate with no candidates and no alignment still spans the full duration")
    func consolidateEmptyInputsStillSpansDuration() {
        let result = Consolidator.consolidate(candidates: [], alignment: nil, downbeats: [], durationS: 42.0)
        #expect(result.sections.count == 1)
        #expect(result.sections[0].start == 0.0)
        #expect(result.sections[0].end == 42.0)
        #expect(result.sections[0].source == "consolidated")
        #expect(result.sections[0].confidence == 0.6)
    }
}
