import Testing
@testable import NexGenVideo

@Suite("Spatial scene activity")
struct SpatialSceneActivityTests {
    @Test func aNewSessionReadsItsLocationsBeforeAnyControlActs() {
        var activity = SpatialSceneActivity()
        #expect(activity.busy)
        #expect(activity.readingLocations)
        #expect(activity.admitsRead)
        activity.operating = true
        activity.reading = true
        #expect(!activity.admitsRead)
        activity.finishRead()
        #expect(!activity.busy)
        #expect(!activity.readingLocations)
    }

    @Test func laterOperationsAloneDecideBusy() {
        var activity = SpatialSceneActivity()
        activity.finishRead()
        activity.operating = true
        #expect(activity.busy)
        #expect(!activity.readingLocations)
        activity.operating = false
        #expect(!activity.busy)
    }
}
