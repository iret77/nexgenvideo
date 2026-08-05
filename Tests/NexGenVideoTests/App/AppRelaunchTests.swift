import Testing

@testable import NexGenVideo

@Suite("App relaunch")
struct AppRelaunchTests {
    @Test("home restart bypasses document review when no unsaved document exists")
    func cleanHomeRestartIsImmediate() {
        #expect(!AppRelaunchDocumentPolicy.requiresReview(editStates: []))
        #expect(!AppRelaunchDocumentPolicy.requiresReview(editStates: [false, false]))
        #expect(AppRelaunchDocumentPolicy.requiresReview(editStates: [false, true]))
    }

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
        #expect(arguments[1].contains("kill -0 \"$parent\""))
        #expect(!arguments[1].contains("exit 1"))
        #expect(arguments[1].contains("exec /usr/bin/open \"$bundle\" \"$@\""))
        #expect(!arguments[1].contains(bundlePath))
        #expect(arguments[3] == "1234")
        #expect(arguments[4] == bundlePath)
    }

    @Test("reopener passes self-test launch arguments as data")
    func reopenerArgumentsRemainSeparated() {
        let arguments = AppRelaunch.reopenerArguments(
            parentPID: 1234,
            bundlePath: "/Applications/NexGenVideo.app",
            openArguments: ["--args", "--self-test", "/tmp/state file"]
        )

        #expect(Array(arguments.suffix(3)) == ["--args", "--self-test", "/tmp/state file"])
    }
}
