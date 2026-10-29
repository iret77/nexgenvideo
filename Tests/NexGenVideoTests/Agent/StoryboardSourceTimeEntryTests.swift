import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Storyboard source media time entry")
struct StoryboardSourceTimeEntryTests {
    @Test func sourceClockIsIndependentOfStoryboardFrameRate() throws {
        let clock = SourceMediaTimebaseV1(ticksPerSecond: 24_000)
        #expect(try StoryboardSourceTimeEntry.tick("0.041708333333", clock: clock, durationTicks: 24_000) == 1_001)
        #expect(try StoryboardSourceTimeEntry.tick("0,5", clock: clock, durationTicks: 24_000) == 12_000)
        #expect(try StoryboardSourceTimeEntry.tick("0", clock: clock, durationTicks: 24_000) == 0)
    }

    @Test(arguments: ["1", "-0.1", "NaN", "1.2.3", "9999999999999999999999999999999999999999999999999999"])
    func rejectsEndOrInvalidPosition(_ text: String) {
        #expect(throws: (any Error).self) { _ = try StoryboardSourceTimeEntry.tick(text, clock: .init(ticksPerSecond: 24_000), durationTicks: 24_000) }
    }
}
