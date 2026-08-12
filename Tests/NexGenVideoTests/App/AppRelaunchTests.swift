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

    @Test("reopener bounds termination and launches one exact new app instance")
    func reopenerCommandIsRaceFree() {
        let bundlePath = "/Applications/NexGenVideo Test.app"
        let executablePath = bundlePath + "/Contents/MacOS/NexGenVideo"
        let arguments = AppRelaunch.reopenerArguments(
            parentPID: 1234,
            executablePath: executablePath,
            bundlePath: bundlePath
        )

        #expect(arguments[0] == "-c")
        #expect(arguments[1].contains("-p \"$$\" -o ppid="))
        #expect(arguments[1].contains("/bin/ps -ww -p \"$parent\" -o command="))
        #expect(arguments[1].contains("[ \"$attempts\" -lt 50 ]"))
        #expect(arguments[1].contains("/bin/kill -TERM \"$parent\""))
        #expect(arguments[1].contains("/bin/kill -KILL \"$parent\""))
        #expect(arguments[1].contains("exec /usr/bin/open -n -a \"$bundle\" \"$@\""))
        #expect(!arguments[1].contains("open -n \"$bundle\""))
        #expect(!arguments[1].contains(bundlePath))
        #expect(arguments[3] == "1234")
        #expect(arguments[4] == executablePath)
        #expect(arguments[5] == bundlePath)
    }

    @Test("reopener passes self-test launch arguments as data")
    func reopenerArgumentsRemainSeparated() {
        let arguments = AppRelaunch.reopenerArguments(
            parentPID: 1234,
            executablePath: "/Applications/NexGenVideo.app/Contents/MacOS/NexGenVideo",
            bundlePath: "/Applications/NexGenVideo.app",
            openArguments: ["--self-test", "/tmp/state file"]
        )

        #expect(Array(arguments.suffix(3)) == ["--args", "--self-test", "/tmp/state file"])

        let prefixed = AppRelaunch.reopenerArguments(
            parentPID: 1234,
            executablePath: "/Applications/NexGenVideo.app/Contents/MacOS/NexGenVideo",
            bundlePath: "/Applications/NexGenVideo.app",
            openArguments: ["--args", "--self-test", "/tmp/state file"]
        )
        #expect(Array(prefixed.suffix(3)) == ["--args", "--self-test", "/tmp/state file"])
        #expect(prefixed.filter { $0 == "--args" }.count == 1)
    }

    @Test("self-test reopener can bypass LaunchServices without changing production arguments")
    func directExecutableRelaunchRemainsExplicit() {
        let executablePath = "/Applications/NexGenVideo.app/Contents/MacOS/NexGenVideo"
        let arguments = AppRelaunch.reopenerArguments(
            parentPID: 1234,
            executablePath: executablePath,
            bundlePath: "/Applications/NexGenVideo.app",
            openArguments: ["--self-test", "/tmp/state file"],
            launchMode: .executable
        )

        #expect(arguments[1].contains("exec \"$expected\" \"$@\""))
        #expect(!arguments[1].contains("exec /usr/bin/open"))
        #expect(Array(arguments.suffix(2)) == ["--self-test", "/tmp/state file"])
        #expect(!arguments.contains("--args"))
    }
}
