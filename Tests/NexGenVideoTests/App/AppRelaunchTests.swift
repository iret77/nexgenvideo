import Testing

@testable import NexGenVideo

@Suite("App relaunch")
struct AppRelaunchTests {
    @Test("cancelling a document review fully disarms the restart request")
    func cancelledReviewDisarmsRequest() {
        var state = AppRelaunchRequestState()

        let firstBegin = state.begin()
        let duplicateBegin = state.begin()
        let cancellation = state.complete(approved: false)

        #expect(firstBegin)
        #expect(!duplicateBegin)
        #expect(cancellation == .cancelled)
        #expect(!state.isPending)

        let retryBegin = state.begin()
        let approval = state.complete(approved: true)
        let duplicateCompletion = state.complete(approved: true)

        #expect(retryBegin)
        #expect(approval == .proceed)
        #expect(duplicateCompletion == .ignored)
    }

    @Test("reopener waits for the exact process exit and passes the bundle path as data")
    func reopenerCommandIsRaceFree() {
        let bundlePath = "/Applications/NexGenVideo Test.app"
        let arguments = AppRelaunch.reopenerArguments(
            parentPID: 1234,
            bundlePath: bundlePath
        )

        #expect(arguments[0] == "-c")
        #expect(arguments[1].contains("kill -0 \"$1\""))
        #expect(arguments[1].contains("\"$attempts\" -lt 300"))
        #expect(arguments[1].contains("exec /usr/bin/open \"$2\""))
        #expect(!arguments[1].contains(bundlePath))
        #expect(arguments[3] == "1234")
        #expect(arguments[4] == bundlePath)
    }
}
