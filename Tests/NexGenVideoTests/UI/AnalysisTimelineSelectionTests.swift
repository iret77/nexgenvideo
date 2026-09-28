import Testing
@testable import NexGenVideo

@Suite("Analysis timeline selection")
@MainActor
struct AnalysisTimelineSelectionTests {
    private let sections = [
        AnalysisSurfaceData.Section(index: 0, start: 0, end: 30, label: "Intro", source: nil),
        AnalysisSurfaceData.Section(index: 1, start: 30, end: 120, label: "Verse", source: nil),
    ]

    @Test func boundariesBelongToTheFollowingSectionAndTheFinalEndpointRemainsSelectable() {
        #expect(BeatTimeline.section(atFraction: 0, duration: 120, sections: sections)?.label == "Intro")
        #expect(BeatTimeline.section(atFraction: 0.25, duration: 120, sections: sections)?.label == "Verse")
        #expect(BeatTimeline.section(atFraction: 1, duration: 120, sections: sections)?.label == "Verse")
    }

    @Test func missingOrInvalidTimeNeverSelectsAnInventedSection() {
        #expect(BeatTimeline.section(atFraction: .nan, duration: 120, sections: sections) == nil)
        #expect(BeatTimeline.section(atFraction: 0.5, duration: 0, sections: sections) == nil)
        #expect(BeatTimeline.section(atFraction: 1.1, duration: 120, sections: sections) == nil)
        #expect(BeatTimeline.section(atFraction: 0.5, duration: 120, sections: []) == nil)
    }
}
