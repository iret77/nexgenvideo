import Testing
@testable import NexGenVideo

@Suite("Spatial scene activity")
struct SpatialSceneActivityTests {
    private func reading(_ activity: inout SpatialSceneActivity) {
        #expect(activity.admitsRead)
        activity.operating = true
        activity.reading = true
    }

    @Test func aNewSessionReadsItsLocationsBeforeAnyControlActs() {
        var activity = SpatialSceneActivity()
        #expect(activity.busy && activity.working && activity.readingLocations)
        #expect(!activity.cancellable && !activity.offersReload)
        reading(&activity)
        #expect(!activity.admitsRead && !activity.cancellable && !activity.offersReload)
        activity.finishRead(succeeded: true)
        #expect(!activity.busy && !activity.working && !activity.readingLocations && !activity.offersReload)
    }

    @Test func aFailedFirstReadStaysLockedAndOffersReload() {
        var activity = SpatialSceneActivity()
        reading(&activity)
        activity.finishRead(succeeded: false)
        #expect(activity.busy)
        #expect(!activity.working && !activity.readingLocations && !activity.cancellable)
        #expect(activity.offersReload && activity.admitsRead)
        reading(&activity)
        #expect(!activity.offersReload)
        activity.finishRead(succeeded: true)
        #expect(!activity.busy && !activity.offersReload)
    }

    @Test func onlyOperationsAfterTheFirstReadCanBeCancelled() {
        var activity = SpatialSceneActivity()
        reading(&activity)
        activity.finishRead(succeeded: true)
        activity.operating = true
        #expect(activity.busy && activity.working && activity.cancellable && !activity.readingLocations)
        activity.finishRead(succeeded: false)
        #expect(!activity.busy && activity.offersReload)
        activity.operating = false
        #expect(!activity.busy)
    }
}
