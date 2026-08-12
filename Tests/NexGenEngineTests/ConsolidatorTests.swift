import Foundation
import Testing
@testable import MusicvideoPlugin

@Suite("Musicvideo structure fusion", .serialized)
struct ConsolidatorTests {
    private static func sections(
        boundaries: [Double], duration: Double, source: String
    ) -> [AnalysisSection] {
        let times = ([0.0] + boundaries.filter { $0 > 0 && $0 < duration } + [duration])
            .sorted()
        return zip(times, times.dropFirst()).enumerated().map { item in
            let index = item.offset
            let pair = item.element
            return AnalysisSection(
                index: index, start: pair.0, end: pair.1, cluster: index, source: source
            )
        }
    }

    @Test("boundary clustering uses a fixed span instead of transitive chaining")
    func clusterBoundariesDoesNotChain() {
        let boundaries: [(t: Double, source: String)] = [
            (10.0, "a"), (11.5, "b"), (13.0, "c"),
        ]
        let clusters = Consolidator.clusterBoundaries(boundaries, tolerance: 2.0)
        #expect(clusters.count == 2)
        #expect(abs(clusters[0].t - 10.75) < 0.001)
        #expect(clusters[1].t == 13.0)
    }

    @Test("snap retains the compatibility tolerance contract")
    func snapCompatibility() {
        #expect(Consolidator.snap(10.3, downbeats: [10.0, 12.0]) == 10.0)
        #expect(Consolidator.snap(10.6, downbeats: [10.0, 12.0]) == 10.6)
        #expect(Consolidator.snap(10.3, downbeats: []) == 10.3)
    }

    @Test("lyrics cannot create a section boundary without acoustic evidence")
    func lyricsCannotCreateTiming() {
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nhello world\n[Chorus]\nwide open",
            transcript: [
                .init(text: "hello", start: 0.1, end: 0.3),
                .init(text: "world", start: 0.3, end: 0.5),
                .init(text: "wide", start: 20.0, end: 20.2),
                .init(text: "open", start: 20.2, end: 20.4),
            ]
        )
        let result = Consolidator.consolidateDetailed(
            candidates: [], alignment: report.lines, alignmentReport: report,
            downbeats: [0, 10, 20, 30], durationS: 30
        )
        #expect(result.resolution.status == .needsReview)
        #expect(result.resolution.resolvedAlignmentMarkerCount == 1)
        #expect(result.sections.count == 1)
        #expect(result.sections[0].source == "unresolved_structure")
    }

    @Test("reliably aligned lyrics select and label nearby measured candidates")
    func lyricsSelectMeasuredCandidates() {
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nhello world\n[Chorus]\nwide open",
            transcript: [
                .init(text: "hello", start: 0.1, end: 0.3),
                .init(text: "world", start: 0.3, end: 0.5),
                .init(text: "wide", start: 20.0, end: 20.2),
                .init(text: "open", start: 20.2, end: 20.4),
            ]
        )
        let candidates = [Self.sections(boundaries: [19.6], duration: 40, source: "librosa")]
        let result = Consolidator.consolidateDetailed(
            candidates: candidates, alignment: report.lines, alignmentReport: report,
            downbeats: [0, 10, 20, 30, 40], durationS: 40
        )
        #expect(result.resolution.status == .resolved)
        #expect(result.resolution.method == "per_boundary_evidence")
        #expect(result.sections.map(\.start) == [0, 20])
        #expect(result.sections.map(\.label) == ["verse", "chorus"])
        #expect(result.sections.map(\.source) == ["measured_track_extent", "measured_alignment_fusion"])
        #expect(result.resolution.boundaryEvidence.first?.kind == .lyricsSupportedAcoustic)
    }

    @Test("a snapped track endpoint cannot become an internal lyric boundary")
    func lyricMarkerRejectsSnappedEndpoint() {
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nhello world\n[Outro]\nfinal words",
            transcript: [
                .init(text: "hello", start: 0.1, end: 0.3),
                .init(text: "world", start: 0.3, end: 0.5),
                .init(text: "final", start: 39.5, end: 39.7),
                .init(text: "words", start: 39.7, end: 39.9),
            ]
        )
        let candidates = [Self.sections(boundaries: [39.6], duration: 40, source: "librosa")]
        let result = Consolidator.consolidateDetailed(
            candidates: candidates, alignment: report.lines, alignmentReport: report,
            downbeats: [0, 20, 40], durationS: 40
        )
        #expect(result.resolution.status == .reviewRequired)
        #expect(result.resolution.resolvedAlignmentMarkerCount == 1)
        #expect(result.resolution.acceptedBoundaryCount == 0)
        #expect(result.sections.map(\.start) == [0])
        #expect(result.anomalies.contains { $0.kind == "unresolved_lyric_marker" })
    }

    @Test("independent detector agreement creates a canonical boundary")
    func detectorConsensus() {
        let candidates = [
            Self.sections(boundaries: [24.2], duration: 64, source: "librosa"),
            Self.sections(boundaries: [23.7], duration: 64, source: "essentia"),
        ]
        let grid = stride(from: 0.0, through: 64.0, by: 2.0).map { $0 }
        let result = Consolidator.consolidateDetailed(
            candidates: candidates, alignment: nil, alignmentReport: nil,
            downbeats: grid, durationS: 64
        )
        #expect(result.resolution.status == .resolved)
        #expect(result.resolution.method == "per_boundary_evidence")
        #expect(result.sections.map(\.start) == [0, 24])
        #expect(result.sections.map(\.source) == ["measured_track_extent", "measured_consensus"])
    }

    @Test("detectors may differ by one downbeat before their consensus is snapped")
    func consensusClustersBeforeGridSnap() {
        let candidates = [
            Self.sections(boundaries: [23.3], duration: 64, source: "librosa"),
            Self.sections(boundaries: [25.1], duration: 64, source: "essentia"),
        ]
        let grid = stride(from: 0.0, through: 64.0, by: 2.0).map { $0 }
        let result = Consolidator.consolidateDetailed(
            candidates: candidates, alignment: nil, alignmentReport: nil,
            downbeats: grid, durationS: 64
        )
        #expect(result.resolution.status == .resolved)
        #expect(result.sections.map(\.start) == [0, 24])
        #expect(result.resolution.boundaryEvidence.first?.detectorSources == ["essentia", "librosa"])
    }

    @Test("single-source micro-boundaries become a compact review-required structure")
    func phraseFiltersSingleSourceMicroBoundaries() {
        let candidates = [
            Self.sections(boundaries: [8, 16, 24, 32, 40], duration: 48, source: "librosa"),
            Self.sections(boundaries: [12, 20, 28, 36], duration: 48, source: "essentia"),
        ]
        let grid = stride(from: 0.0, through: 48.0, by: 2.0).map { $0 }
        let result = Consolidator.consolidateDetailed(
            candidates: candidates, alignment: nil, alignmentReport: nil,
            downbeats: grid, durationS: 48
        )
        #expect(result.resolution.status == .reviewRequired)
        #expect(result.resolution.method == "phrase_filtered_acoustic")
        #expect(result.sections.map(\.start) == [0, 16, 32])
        #expect(result.sections.dropFirst().allSatisfy { $0.source == "measured_phrase_filtered" })
        #expect(result.resolution.candidateBoundaryCount == 9)
        #expect(result.anomalies.contains { $0.kind == "single_detector_boundary_evidence" })
    }

    @Test("two homogeneous detectors resolve one full-track section")
    func homogeneousConsensus() {
        let candidates = [
            Self.sections(boundaries: [], duration: 32, source: "librosa"),
            Self.sections(boundaries: [], duration: 32, source: "essentia"),
        ]
        let result = Consolidator.consolidateDetailed(
            candidates: candidates, alignment: nil, alignmentReport: nil,
            downbeats: [0, 2, 4, 6, 8], durationS: 32
        )
        #expect(result.resolution.status == .resolved)
        #expect(result.resolution.method == "homogeneous_consensus")
        #expect(result.sections.count == 1)
        #expect(result.sections[0].start == 0 && result.sections[0].end == 32)
    }

    @Test("the recurrent 199-second over-segmentation collapses to supported song parts")
    func denseCandidateRegression() {
        let duration = 199.0
        let grid = stride(from: 0.0, through: 198.4, by: 1.6).map { ($0 * 1000).rounded() / 1000 }
        let markerIndexes = [20, 36, 53, 68, 87, 101, 121]
        var sourceA = Set(markerIndexes)
        for index in stride(from: 6, through: 118, by: 6) where sourceA.count < 20 {
            sourceA.insert(index)
        }
        var sourceB: Set<Int> = []
        for index in stride(from: 3, through: 123, by: 6) where sourceB.count < 20 {
            if !sourceA.contains(index) { sourceB.insert(index) }
        }
        let candidates = [
            Self.sections(boundaries: sourceA.map { grid[$0] }, duration: duration, source: "librosa"),
            Self.sections(boundaries: sourceB.map { grid[$0] }, duration: duration, source: "essentia"),
        ]
        let names = ["Intro", "Verse 1", "Chorus 1", "Verse 2", "Chorus 2", "Bridge", "Chorus 3", "Outro"]
        let starts = [0.1] + markerIndexes.map { grid[$0] }
        let lyrics = zip(names, 0..<names.count).map { "[\($0.0)]\nword\($0.1) anchor\($0.1)" }.joined(separator: "\n")
        var transcript: [TranscriptToken] = []
        for (index, start) in starts.enumerated() {
            transcript.append(.init(text: "word\(index)", start: start, end: start + 0.2))
            transcript.append(.init(text: "anchor\(index)", start: start + 0.2, end: start + 0.4))
        }
        let report = LyricsAlignment.alignDetailed(lyrics: lyrics, transcript: transcript)
        let first = Consolidator.consolidateDetailed(
            candidates: candidates, alignment: report.lines, alignmentReport: report,
            downbeats: grid, durationS: duration
        )
        let second = Consolidator.consolidateDetailed(
            candidates: candidates, alignment: report.lines, alignmentReport: report,
            downbeats: grid, durationS: duration
        )
        #expect(first == second)
        #expect(first.resolution.status == .resolved)
        #expect(first.resolution.candidateBoundaryCount == 40)
        #expect(first.resolution.acceptedBoundaryCount == 7)
        #expect(first.sections.count == 8)
        #expect(first.sections.map(\.label) == names.map(LyricsAlignment.normalizeMarker))
        #expect(first.sections.allSatisfy { section in
            section.start == 0 || grid.contains(section.start)
        })

        let withoutLyrics = Consolidator.consolidateDetailed(
            candidates: candidates, alignment: nil, alignmentReport: nil,
            downbeats: grid, durationS: duration
        )
        #expect(withoutLyrics.resolution.status == .resolved)
        #expect(withoutLyrics.resolution.candidateBoundaryCount == 40)
        #expect(withoutLyrics.sections.count == 3)
        #expect(withoutLyrics.sections.dropFirst().allSatisfy {
            $0.source == "measured_consensus"
        })
    }
}
