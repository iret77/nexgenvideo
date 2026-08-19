import Foundation
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

    @Test("a project-open continuation survives one relaunch and is consumed once")
    func projectContinuationRoundTripsOnce() throws {
        let suite = "app-relaunch-project-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let intent = AppRelaunchIntent.openProject(
            URL(fileURLWithPath: "/tmp/Claude Mouse.ngv")
        )

        AppRelaunchIntentStore.save(intent, defaults: defaults)

        #expect(AppRelaunchIntentStore.take(defaults: defaults) == intent)
        #expect(AppRelaunchIntentStore.take(defaults: defaults) == nil)
    }

    @Test("a new-project continuation preserves the selected format")
    func newProjectContinuationRoundTrips() throws {
        let suite = "app-relaunch-new-project-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let intent = AppRelaunchIntent.createProject(format: "musicvideo")

        AppRelaunchIntentStore.save(intent, defaults: defaults)

        #expect(AppRelaunchIntentStore.take(defaults: defaults) == intent)
    }

    @Test("an invalid continuation is discarded instead of looping")
    func invalidContinuationIsConsumed() throws {
        let suite = "app-relaunch-invalid-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["kind": "unknown", "value": "/tmp/project.ngv"],
            forKey: "NGVAppRelaunchIntent"
        )

        #expect(AppRelaunchIntentStore.take(defaults: defaults) == nil)
        #expect(AppRelaunchIntentStore.take(defaults: defaults) == nil)
    }

    @Test("a self-test launch consumes and discards a pending continuation")
    func selfTestDiscardsContinuationOnce() throws {
        let suite = "app-relaunch-self-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let intent = AppRelaunchIntent.createProject(format: "musicvideo")
        AppRelaunchIntentStore.save(intent, defaults: defaults)

        #expect(AppRelaunchIntentStore.consumeForLaunch(
            isSelfTest: true,
            defaults: defaults
        ) == nil)
        #expect(AppRelaunchIntentStore.consumeForLaunch(
            isSelfTest: false,
            defaults: defaults
        ) == nil)
    }

    @Test("a normal launch returns a pending continuation exactly once")
    func normalLaunchConsumesContinuationOnce() throws {
        let suite = "app-relaunch-normal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let intent = AppRelaunchIntent.openProject(
            URL(fileURLWithPath: "/tmp/Resume Once.ngv")
        )
        AppRelaunchIntentStore.save(intent, defaults: defaults)

        #expect(AppRelaunchIntentStore.consumeForLaunch(
            isSelfTest: false,
            defaults: defaults
        ) == intent)
        #expect(AppRelaunchIntentStore.consumeForLaunch(
            isSelfTest: false,
            defaults: defaults
        ) == nil)
    }
}
