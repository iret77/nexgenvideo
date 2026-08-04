import Testing

@testable import NexGenVideo

@Suite("App relaunch")
struct AppRelaunchTests {
    @Test("cancelling a document review fully disarms the restart request")
    func cancelledReviewDisarmsRequest() {
        var state = AppRelaunchRequestState()

        #expect(state.begin())
        #expect(!state.begin())
        #expect(state.complete(approved: false) == .cancelled)
        #expect(!state.isPending)
        #expect(state.begin())
        #expect(state.complete(approved: true) == .proceed)
        #expect(state.complete(approved: true) == .ignored)
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
