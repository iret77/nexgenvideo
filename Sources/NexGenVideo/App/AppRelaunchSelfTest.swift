import AppKit
import Darwin

@MainActor
enum AppRelaunchSelfTest {
    private static let startArgument = "--ngv-relaunch-selftest-start"
    private static let completionArgument = "--ngv-relaunch-selftest-complete"

    private struct StartConfiguration {
        let stateURL: URL
        let expectedBundle: String
        let packID: String
        let oldVersion: String
        let newVersion: String
    }

    private struct CompletionConfiguration {
        let stateURL: URL
        let expectedBundle: String
        let packID: String
        let newVersion: String
    }

    static var isRequested: Bool {
        startConfiguration != nil || completionConfiguration != nil
    }

    static func reopenArguments(_ requested: [String]) -> [String] {
        guard requested.isEmpty, let config = startConfiguration else { return requested }
        return [
            "--args",
            completionArgument,
            config.stateURL.path,
            config.expectedBundle,
            config.packID,
            config.newVersion,
        ]
    }

    static func recordBootIfRequested() {
        guard let config = startConfiguration else { return }
        Darwin.signal(SIGABRT, SIG_DFL)
        write("booted \(ProcessInfo.processInfo.processIdentifier)", to: config.stateURL)
    }

    static func checkpoint(_ name: String) {
        guard let config = startConfiguration else { return }
        write(
            "checkpoint:\(name) \(ProcessInfo.processInfo.processIdentifier)",
            to: config.stateURL
        )
    }

    static func runIfRequested() async {
        if let config = completionConfiguration {
            await complete(config)
        } else if let config = startConfiguration {
            await start(config)
        }
    }

    private static func start(_ config: StartConfiguration) async {
        validateBundle(config.expectedBundle, stateURL: config.stateURL)
        write("launched \(ProcessInfo.processInfo.processIdentifier)", to: config.stateURL)

        let ready = await waitUntil(timeout: .seconds(30)) {
            HomeWindowController.shared.window?.isVisible == true
                && NSApp.modalWindow == nil
                && PluginLoader.liveBinding(id: config.packID)?.version == config.oldVersion
                && PluginUpdateCenter.shared.restartTarget(for: config.packID)?.version
                    == config.newVersion
        }
        guard ready else {
            fail("the real two-pack restart state never became actionable", stateURL: config.stateURL)
        }

        write("pressing \(ProcessInfo.processInfo.processIdentifier)", to: config.stateURL)
        guard pressAccessibilityElement(
            identifier: "home.restart-format-packs",
            in: HomeWindowController.shared.window
        ) else {
            fail("the visible restart button rejected its accessibility press", stateURL: config.stateURL)
        }
    }

    private static func complete(_ config: CompletionConfiguration) async {
        validateBundle(config.expectedBundle, stateURL: config.stateURL)
        guard (try? String(contentsOf: config.stateURL, encoding: .utf8))?.hasPrefix("pressing ")
                == true else {
            fail("the new process opened before the production button was pressed", stateURL: config.stateURL)
        }

        let ready = await waitUntil(timeout: .seconds(30)) {
            HomeWindowController.shared.window?.isVisible == true
                && NSApp.modalWindow == nil
                && PluginLoader.liveBinding(id: config.packID)?.version == config.newVersion
                && PluginUpdateCenter.shared.restartTarget(for: config.packID) == nil
        }
        guard ready else {
            fail("the requested pack did not become live in an interactive Home", stateURL: config.stateURL)
        }
        guard pressAccessibilityElement(
            identifier: "home.settings",
            in: HomeWindowController.shared.window
        ) else {
            fail("Home rejected a control press after relaunch", stateURL: config.stateURL)
        }
        guard await waitUntil(timeout: .seconds(5), {
            SettingsWindowController.shared.window?.isVisible == true
        }) else {
            fail("the Settings control did not open its window after relaunch", stateURL: config.stateURL)
        }

        write("reopened \(ProcessInfo.processInfo.processIdentifier)", to: config.stateURL)
        FileHandle.standardOutput.write(Data("SELFTEST_RELAUNCH_OK\n".utf8))
        exit(0)
    }

    private static var startConfiguration: StartConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: startArgument),
              arguments.indices.contains(marker + 5) else { return nil }
        return StartConfiguration(
            stateURL: URL(fileURLWithPath: arguments[marker + 1]),
            expectedBundle: arguments[marker + 2],
            packID: arguments[marker + 3],
            oldVersion: arguments[marker + 4],
            newVersion: arguments[marker + 5]
        )
    }

    private static var completionConfiguration: CompletionConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: completionArgument),
              arguments.indices.contains(marker + 4) else { return nil }
        return CompletionConfiguration(
            stateURL: URL(fileURLWithPath: arguments[marker + 1]),
            expectedBundle: arguments[marker + 2],
            packID: arguments[marker + 3],
            newVersion: arguments[marker + 4]
        )
    }

    private static func validateBundle(_ expected: String, stateURL: URL) {
        let expectedBundle = URL(fileURLWithPath: expected, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let actualBundle = Bundle.main.bundleURL
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard actualBundle == expectedBundle else {
            fail("opened \(actualBundle) instead of \(expectedBundle)", stateURL: stateURL)
        }
    }

    private static func waitUntil(
        timeout: Duration,
        _ predicate: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return predicate()
    }

    private static func pressAccessibilityElement(
        identifier: String,
        in window: NSWindow?
    ) -> Bool {
        guard let root = window?.contentView,
              let element = findAccessibilityElement(
                  in: root,
                  identifier: identifier,
                  depth: 0
              ) else { return false }
        return element.accessibilityPerformPress()
    }

    private static func findAccessibilityElement(
        in element: Any,
        identifier: String,
        depth: Int
    ) -> (any NSAccessibilityProtocol)? {
        guard depth < 32,
              let accessible = element as? any NSAccessibilityProtocol else { return nil }
        if accessible.accessibilityIdentifier() == identifier { return accessible }
        for child in accessible.accessibilityChildren() ?? [] {
            if let match = findAccessibilityElement(
                in: child,
                identifier: identifier,
                depth: depth + 1
            ) {
                return match
            }
        }
        return nil
    }

    private static func write(_ value: String, to url: URL) {
        do {
            try Data(value.utf8).write(to: url, options: .atomic)
        } catch {
            fail("could not write state: \(error.localizedDescription)", stateURL: url)
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
