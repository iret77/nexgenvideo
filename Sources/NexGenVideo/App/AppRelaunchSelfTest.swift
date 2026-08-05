import AppKit

@MainActor
enum AppRelaunchSelfTest {
    private static let environmentKey = "NGV_SELFTEST_RELAUNCH"
    private static let completionArgument = "--ngv-relaunch-selftest-complete"

    static var isRequested: Bool {
        guard let path = ProcessInfo.processInfo.environment[environmentKey] else { return false }
        return !path.isEmpty
    }

    static func completeIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: completionArgument),
              arguments.indices.contains(marker + 2) else { return }
        let stateURL = URL(fileURLWithPath: arguments[marker + 1])
        let expectedBundle = URL(fileURLWithPath: arguments[marker + 2], isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let actualBundle = Bundle.main.bundleURL
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard actualBundle == expectedBundle else {
            fail("reopened \(actualBundle) instead of \(expectedBundle)", stateURL: stateURL)
        }
        guard (try? String(contentsOf: stateURL, encoding: .utf8)) == "armed" else {
            fail("reopened before the restart action completed", stateURL: stateURL)
        }
        write("reopened", to: stateURL)
        FileHandle.standardOutput.write(Data("SELFTEST_RELAUNCH_OK\n".utf8))
        exit(0)
    }

    static func startIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment[environmentKey],
              !path.isEmpty else { return false }
        let stateURL = URL(fileURLWithPath: path)
        write("launched", to: stateURL)
        guard NSApp.windows.contains(where: \.isVisible), NSApp.modalWindow == nil else {
            fail("Home was not visible and interactive before restart", stateURL: stateURL)
        }
        AppRelaunch.now(
            reopenArguments: [
                "--args",
                completionArgument,
                path,
                Bundle.main.bundlePath,
            ]
        ) {
            write("armed", to: stateURL)
        }
        return true
    }

    private static func write(_ value: String, to url: URL) {
        do {
            try Data(value.utf8).write(to: url, options: .atomic)
        } catch {
            fail("could not write state: \(error.localizedDescription)")
        }
    }

    private static func fail(_ reason: String, stateURL: URL? = nil) -> Never {
        if let stateURL {
            try? Data("failed: \(reason)".utf8).write(to: stateURL, options: .atomic)
        }
        FileHandle.standardError.write(Data("SELFTEST_RELAUNCH_FAIL \(reason)\n".utf8))
        exit(1)
    }
}
