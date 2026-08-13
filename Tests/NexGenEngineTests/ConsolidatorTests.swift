import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

@Suite("Musicvideo structure resolution", .serialized)
struct ConsolidatorTests {
    private static func sections(
        boundaries: [Double], duration: Double, source: String
    ) -> [AnalysisSection] {
        let times = ([0.0] + boundaries.filter { $0 > 0 && $0 < duration } + [duration])
            .sorted()
        return zip(times, times.dropFirst()).enumerated().map { item in
            AnalysisSection(
                index: item.offset,
                start: item.element.0,
                end: item.element.1,
                cluster: item.offset,
                source: source
            )
        }
    }

    private static func measurement(
        sections: [(Double, Double)] = [(0, 16), (16, 40), (40, 64)],
        segments: [(Double, Double)] = [(0, 8), (8, 16), (16, 28), (28, 40), (40, 52), (52, 64)],
        phrases: [(Double, Double)] = stride(from: 0.0, to: 64.0, by: 4.0).map { ($0, $0 + 4) }
    ) -> MusicUnderstandingMeasurement {
        MusicUnderstandingMeasurement(
            beats: stride(from: 0.0, through: 64.0, by: 0.5).map { $0 },
            bars: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            bpm: 120,
            sections: sections.map { MeasuredMusicRange(start: $0.0, end: $0.1) },
            segments: segments.map { MeasuredMusicRange(start: $0.0, end: $0.1) },
            phrases: phrases.map { MeasuredMusicRange(start: $0.0, end: $0.1) }
        )
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

    @Test("one downbeat cannot establish a canonical bar grid")
    func singleDownbeatNeedsReview() {
        let result = Consolidator.consolidateDetailed(
            candidates: [
                Self.sections(boundaries: [16], duration: 32, source: "librosa"),
                Self.sections(boundaries: [16.4], duration: 32, source: "essentia"),
            ],
            alignment: nil,
            alignmentReport: nil,
            downbeats: [0],
            durationS: 32
        )

        #expect(result.resolution.status == .needsReview)
        #expect(result.resolution.acceptedBoundaryCount == 0)
        #expect(result.resolution.boundaryEvidence.isEmpty)
        #expect(result.sections.count == 1)
    }

    @Test("independent native candidates resolve bar-aligned song form")
    func nativeCandidatesResolveSongForm() {
        let candidates = [
            Self.sections(boundaries: [16, 40], duration: 64, source: "librosa"),
            Self.sections(boundaries: [16.5, 40.5], duration: 64, source: "essentia"),
        ]
        let result = Consolidator.consolidateDetailed(
            candidates: candidates,
            alignment: nil,
            alignmentReport: nil,
            downbeats: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            durationS: 64
        )

        #expect(result.resolution.status == .resolved)
        #expect(result.resolution.method == "per_boundary_evidence")
        #expect(result.resolution.candidateBoundaryCount == 4)
        #expect(result.resolution.acceptedBoundaryCount == 2)
        #expect(result.sections.map(\.start) == [0, 16, 40])
        #expect(result.sections.dropFirst().allSatisfy {
            $0.source == "measured_consensus"
        })
    }

    @Test("complete system hierarchy resolves canonical sections")
    func systemHierarchyResolvesSections() {
        let candidates = [
            Self.sections(boundaries: [8, 16, 24, 32, 40, 48], duration: 64, source: "librosa"),
            Self.sections(boundaries: [8.5, 16.5, 24.5, 32.5, 40.5, 48.5], duration: 64, source: "essentia"),
        ]
        let result = Consolidator.consolidateDetailed(
            candidates: candidates,
            alignment: nil,
            alignmentReport: nil,
            downbeats: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            durationS: 64,
            musicUnderstanding: Self.measurement()
        )

        #expect(result.resolution.status == .resolved)
        #expect(result.resolution.version == "adaptive-structure/v5")
        #expect(result.resolution.method == "music_understanding_hierarchy")
        #expect(result.resolution.detectorSources == ["apple_music_understanding"])
        #expect(result.resolution.candidateBoundaryCount == 12)
        #expect(result.resolution.discardedBoundaryCount == 12)
        #expect(result.sections.map(\.start) == [0, 16, 40])
        #expect(result.sections.allSatisfy { $0.source == "measured_system_hierarchy" })
        #expect(result.resolution.hierarchy?.segments.count == 6)
        #expect(result.resolution.hierarchy?.phrases.count == 16)
        #expect(result.resolution.boundaryEvidence.allSatisfy {
            $0.kind == .systemHierarchy
                && $0.detectorSources == ["apple_music_understanding"]
        })
    }

    @Test("system sections must align to the measured bar grid")
    func rejectsOffGridSystemSection() {
        let result = Consolidator.consolidateDetailed(
            candidates: [],
            alignment: nil,
            alignmentReport: nil,
            downbeats: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            durationS: 64,
            musicUnderstanding: Self.measurement(
                sections: [(0, 15.4), (15.4, 40), (40, 64)]
            )
        )

        #expect(result.resolution.status == .needsReview)
        #expect(result.resolution.hierarchy == nil)
    }

    @Test("system hierarchy must be complete and nested")
    func rejectsIncompleteHierarchy() {
        let result = Consolidator.consolidateDetailed(
            candidates: [],
            alignment: nil,
            alignmentReport: nil,
            downbeats: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            durationS: 64,
            musicUnderstanding: Self.measurement(
                segments: [(0, 20), (20, 64)],
                phrases: [(0, 4), (4, 8), (8, 12), (12, 16), (16, 20), (20, 64)]
            )
        )

        #expect(result.resolution.status == .needsReview)
        #expect(result.sections.count == 1)
    }

    @Test("system hierarchy cannot repair a source coverage gap")
    func rejectsHierarchyCoverageGap() {
        let result = Consolidator.consolidateDetailed(
            candidates: [],
            alignment: nil,
            alignmentReport: nil,
            downbeats: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            durationS: 64,
            musicUnderstanding: Self.measurement(
                sections: [(0, 15.9), (16, 40), (40, 64)]
            )
        )

        #expect(result.resolution.status == .needsReview)
    }

    @Test("system hierarchy preserves measured ranges and permits phrase gaps")
    func preservesMeasuredHierarchyWithPhraseGaps() {
        let measuredSections = [(0.0, 16.2), (16.2, 40.0), (40.0, 64.0)]
        let result = Consolidator.consolidateDetailed(
            candidates: [],
            alignment: nil,
            alignmentReport: nil,
            downbeats: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            durationS: 64,
            musicUnderstanding: Self.measurement(
                sections: measuredSections,
                segments: measuredSections,
                phrases: [(1, 4), (17, 20), (41, 44)]
            )
        )

        #expect(result.resolution.status == .resolved)
        #expect(result.sections.map(\.start) == [0, 16.2, 40])
        #expect(result.resolution.hierarchy?.sections == measuredSections.map {
            MeasuredMusicRange(start: $0.0, end: $0.1)
        })
        #expect(result.resolution.hierarchy?.phrases.count == 3)
    }

    @Test("reliable lyrics label nearby system boundaries without changing timing")
    func lyricsLabelSystemHierarchy() {
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Intro]\nopen words\n[Verse]\nverse words\n[Chorus]\nwide open",
            transcript: [
                .init(text: "open", start: 0.1, end: 0.3),
                .init(text: "words", start: 0.3, end: 0.5),
                .init(text: "verse", start: 16.1, end: 16.3),
                .init(text: "words", start: 16.3, end: 16.5),
                .init(text: "wide", start: 40.1, end: 40.3),
                .init(text: "open", start: 40.3, end: 40.5),
            ]
        )
        let result = Consolidator.consolidateDetailed(
            candidates: [],
            alignment: report.lines,
            alignmentReport: report,
            downbeats: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            durationS: 64,
            musicUnderstanding: Self.measurement()
        )

        #expect(result.sections.map(\.start) == [0, 16, 40])
        #expect(result.sections.map(\.label) == ["intro", "verse", "chorus"])
        #expect(result.resolution.resolvedAlignmentMarkerCount == 3)
    }

    @Test("reliable lyrics preserve a measured instrumental outro")
    func lyricsAndConsensusResolveOutro() {
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nopen words\n[Chorus]\nwide open",
            transcript: [
                .init(text: "open", start: 16.1, end: 16.3),
                .init(text: "words", start: 16.3, end: 16.5),
                .init(text: "wide", start: 40.1, end: 40.3),
                .init(text: "open", start: 40.3, end: 40.5),
            ]
        )
        let candidates = [
            Self.sections(boundaries: [16, 40, 58], duration: 64, source: "librosa"),
            Self.sections(boundaries: [16.4, 40.4, 58.4], duration: 64, source: "essentia"),
        ]
        let result = Consolidator.consolidateDetailed(
            candidates: candidates,
            alignment: report.lines,
            alignmentReport: report,
            downbeats: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            durationS: 64
        )

        #expect(result.resolution.status == .resolved)
        #expect(result.sections.map(\.start) == [0, 16, 40, 58])
        #expect(result.sections.map(\.label) == [nil, "verse", "chorus", nil])
        #expect(result.resolution.boundaryEvidence.last?.kind == .detectorConsensus)
    }

    @Test("the earliest strongest terminal consensus wins over a later instrumental tag")
    func terminalConsensusPrefersOutroStart() {
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nopen words\n[Chorus]\nwide open",
            transcript: [
                .init(text: "open", start: 16.1, end: 16.3),
                .init(text: "words", start: 16.3, end: 16.5),
                .init(text: "wide", start: 40.1, end: 40.3),
                .init(text: "open", start: 40.3, end: 40.5),
            ]
        )
        let candidates = [
            Self.sections(boundaries: [16, 40, 58, 62], duration: 68, source: "librosa"),
            Self.sections(boundaries: [16.4, 40.4, 58.4, 62.4], duration: 68, source: "essentia"),
        ]
        let result = Consolidator.consolidateDetailed(
            candidates: candidates,
            alignment: report.lines,
            alignmentReport: report,
            downbeats: stride(from: 0.0, through: 68.0, by: 2.0).map { $0 },
            durationS: 68
        )

        #expect(result.resolution.status == .resolved)
        #expect(result.sections.map(\.start) == [0, 16, 40, 58])
        #expect(result.resolution.boundaryEvidence.last?.time == 58)
        #expect(result.resolution.boundaryEvidence.last?.kind == .detectorConsensus)
    }

    @Test("speech recognition cannot create a structural boundary")
    func speechRecognitionDoesNotCreateBoundary() {
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nopen words\n[Bridge]\nwide open",
            transcript: [
                .init(text: "open", start: 16.1, end: 16.3),
                .init(text: "words", start: 16.3, end: 16.5),
                .init(text: "wide", start: 40.1, end: 40.3),
                .init(text: "open", start: 40.3, end: 40.5),
            ]
        )
        let result = Consolidator.consolidateDetailed(
            candidates: [
                Self.sections(boundaries: [58], duration: 76, source: "librosa"),
                Self.sections(boundaries: [58.4], duration: 76, source: "essentia"),
            ],
            alignment: report.lines,
            alignmentReport: report,
            downbeats: stride(from: 0.0, through: 76.0, by: 2.0).map { $0 },
            durationS: 76
        )

        #expect(result.resolution.status == .resolved)
        #expect(result.sections.map(\.start) == [0, 58])
        #expect(result.resolution.resolvedAlignmentMarkerCount == 0)
        #expect(result.resolution.boundaryEvidence.map(\.kind) == [.detectorConsensus])
        #expect(result.anomalies.filter { $0.kind == "unmeasured_lyric_marker" }.count == 2)
    }

    @Test("known-text lyric timing remains distinguishable from generic recognition")
    func forcedAlignmentEvidenceIsPersisted() {
        let report = LyricsAlignment.alignKnownTextDetailed(
            lyrics: "[Verse]\nopen words\n[Bridge]\nwide open",
            measurement: KnownTextAlignmentMeasurement(
                words: [
                    .init(text: "open", start: 16.1, end: 16.3),
                    .init(text: "words", start: 16.3, end: 16.5),
                    .init(text: "wide", start: 40.1, end: 40.3),
                    .init(text: "open", start: 40.3, end: 40.5),
                ],
                timingMethod: .attentionDTW
            )
        )
        let result = Consolidator.consolidateDetailed(
            candidates: [
                Self.sections(boundaries: [58], duration: 64, source: "librosa"),
                Self.sections(boundaries: [58.4], duration: 64, source: "essentia"),
            ],
            alignment: report.lines,
            alignmentReport: report,
            downbeats: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            durationS: 64
        )

        #expect(result.sections.map(\.source) == [
            "measured_track_extent",
            "measured_known_text_alignment",
            "measured_known_text_alignment",
            "measured_consensus",
        ])
        #expect(result.sections.map(\.confidence) == [1, 0.75, 0.75, 0.8])
        #expect(result.resolution.boundaryEvidence.filter {
            $0.kind == .lyricsKnownTextAlignment
        }.count == 2)
    }

    @Test("late lyric marker uses nearby internal acoustic evidence")
    func lateLyricMarkerUsesInternalEvidence() {
        let report = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nopen words\n[Outro]\nfinal words",
            transcript: [
                .init(text: "open", start: 0.1, end: 0.3),
                .init(text: "words", start: 0.3, end: 0.5),
                .init(text: "final", start: 63.5, end: 63.7),
                .init(text: "words", start: 63.7, end: 63.9),
            ]
        )
        let result = Consolidator.consolidateDetailed(
            candidates: [
                Self.sections(boundaries: [62], duration: 64, source: "librosa"),
                Self.sections(boundaries: [62.4], duration: 64, source: "essentia"),
            ],
            alignment: report.lines,
            alignmentReport: report,
            downbeats: stride(from: 0.0, through: 64.0, by: 2.0).map { $0 },
            durationS: 64
        )

        #expect(result.resolution.status == .resolved)
        #expect(result.sections.map(\.start) == [0, 62])
        #expect(result.sections[1].label == "outro")
        #expect(result.resolution.boundaryEvidence[0].kind == .lyricsSupportedAcoustic)
    }
}
