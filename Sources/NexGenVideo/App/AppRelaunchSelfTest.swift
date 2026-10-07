import AppKit
import Darwin
import SwiftUI

struct AppRelaunchClickProbe: NSViewRepresentable {
    let identifier: String
    var acceptanceState: Bool?
    var acceptanceValue: Double?
    var acceptanceText: String?

    init(identifier: String, acceptanceState: Bool? = nil, acceptanceValue: Double? = nil, acceptanceText: String? = nil) {
        self.identifier = identifier
        self.acceptanceState = acceptanceState
        self.acceptanceValue = acceptanceValue
        self.acceptanceText = acceptanceText
    }

    func makeNSView(context: Context) -> AppRelaunchClickProbeView {
        let view = AppRelaunchClickProbeView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.acceptanceState = acceptanceState
        view.acceptanceValue = acceptanceValue
        view.acceptanceText = acceptanceText
        return view
    }

    func updateNSView(_ nsView: AppRelaunchClickProbeView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(identifier)
        nsView.acceptanceState = acceptanceState
        nsView.acceptanceValue = acceptanceValue
        nsView.acceptanceText = acceptanceText
    }
}

final class AppRelaunchClickProbeView: NSView {
    var acceptanceState: Bool?
    var acceptanceValue: Double?
    var acceptanceText: String?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum AppRelaunchSelfTest {
    private static let startArgument = "--ngv-relaunch-selftest-start"
    private static let completionArgument = "--ngv-relaunch-selftest-complete"
    private static let directExecutableArgument = "--ngv-relaunch-direct-executable"
    private static let stateArgument = "--ngv-relaunch-state="
    private static let bundleArgument = "--ngv-relaunch-bundle="
    private static let packArgument = "--ngv-relaunch-pack="
    private static let oldVersionArgument = "--ngv-relaunch-old-version="
    private static let newVersionArgument = "--ngv-relaunch-new-version="

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

    static var reopenLaunchMode: AppRelaunch.LaunchMode {
        startConfiguration != nil
            && ProcessInfo.processInfo.arguments.contains(directExecutableArgument)
            ? .executable
            : .launchServices
    }

    static func reopenArguments(_ requested: [String]) -> [String] {
        guard requested.isEmpty, let config = startConfiguration else { return requested }
        var arguments = [
            completionArgument,
            stateArgument + config.stateURL.path,
            bundleArgument + config.expectedBundle,
            packArgument + config.packID,
            newVersionArgument + config.newVersion,
        ]
        if reopenLaunchMode == .executable {
            arguments.insert(directExecutableArgument, at: 1)
        }
        return arguments
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

    static func failUnexpectedOpenFiles(_ filenames: [String]) -> Never {
        let names = filenames.map { URL(fileURLWithPath: $0).lastPathComponent }
            .joined(separator: ", ")
        let stateURL = startConfiguration?.stateURL ?? completionConfiguration?.stateURL
        fail("received an unexpected Open Files event for: \(names)", stateURL: stateURL)
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

        let whatsNewReady = await waitUntil(timeout: .seconds(30)) {
            HomeWindowController.shared.window?.isVisible == true
                && HomeWindowController.shared.window?.isKeyWindow == true
                && NSApp.modalWindow == nil
                && ChangelogStore.shared.pending != nil
                && isClickProbeReady(
                    identifier: "home.whats-new.continue",
                    in: HomeWindowController.shared.window
                )
        }
        guard whatsNewReady else {
            let diagnostics = homeDiagnostics(
                probe: "home.whats-new.continue",
                ["pending \(ChangelogStore.shared.pending?.version ?? "none")"]
            )
            fail("What's New never became actionable (\(diagnostics))", stateURL: config.stateURL)
        }
        if let failure = postMouseClick(
            identifier: "home.whats-new.continue",
            in: HomeWindowController.shared.window
        ) {
            fail("the visible What's New Continue button was not clickable: \(failure)", stateURL: config.stateURL)
        }
        guard await waitUntil(timeout: .seconds(5), {
            ChangelogStore.shared.pending == nil
        }) else {
            fail("What's New did not dismiss", stateURL: config.stateURL)
        }
        try? await Task.sleep(for: .milliseconds(100))
        guard isClickProbeAbsent(
            identifier: "home.whats-new.continue",
            in: HomeWindowController.shared.window
        ) else {
            fail("What's New did not leave the Home input hierarchy", stateURL: config.stateURL)
        }

        let ready = await waitUntil(timeout: .seconds(30)) {
            HomeWindowController.shared.window?.isVisible == true
                && HomeWindowController.shared.window?.isKeyWindow == true
                && NSApp.modalWindow == nil
                && PluginLoader.liveBinding(id: config.packID)?.version == config.oldVersion
                && PluginUpdateCenter.shared.restartTarget(for: config.packID)?.version
                    == config.newVersion
                && isClickProbeReady(
                    identifier: "home.restart-format-packs",
                    in: HomeWindowController.shared.window
                )
        }
        guard ready else {
            let diagnostics = homeDiagnostics(probe: "home.restart-format-packs", [
                "live \(PluginLoader.liveBinding(id: config.packID)?.version ?? "none")",
                "restart target \(PluginUpdateCenter.shared.restartTarget(for: config.packID)?.version ?? "none")",
            ])
            fail("the real two-pack restart state never became actionable (\(diagnostics))", stateURL: config.stateURL)
        }

        write("pressing \(ProcessInfo.processInfo.processIdentifier)", to: config.stateURL)
        if let failure = postMouseClick(
            identifier: "home.restart-format-packs",
            in: HomeWindowController.shared.window
        ) {
            fail("the visible restart button was not clickable: \(failure)", stateURL: config.stateURL)
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
                && HomeWindowController.shared.window?.isKeyWindow == true
                && NSApp.modalWindow == nil
                && PluginLoader.liveBinding(id: config.packID)?.version == config.newVersion
                && PluginUpdateCenter.shared.restartTarget(for: config.packID) == nil
                && isClickProbeReady(
                    identifier: "home.settings",
                    in: HomeWindowController.shared.window
                )
        }
        guard ready else {
            let diagnostics = homeDiagnostics(probe: "home.settings", [
                "live \(PluginLoader.liveBinding(id: config.packID)?.version ?? "none")",
                "restart target \(PluginUpdateCenter.shared.restartTarget(for: config.packID)?.version ?? "none")",
            ])
            fail("the requested pack did not become live in an interactive Home (\(diagnostics))", stateURL: config.stateURL)
        }
        guard SettingsWindowController.shared.window?.isVisible != true else {
            fail("Settings was already visible before the Home control click", stateURL: config.stateURL)
        }
        if let failure = postMouseClick(
            identifier: "home.settings",
            in: HomeWindowController.shared.window
        ) {
            fail("Home Settings was not clickable after relaunch: \(failure)", stateURL: config.stateURL)
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
        guard arguments.contains(startArgument),
              let statePath = value(for: stateArgument, in: arguments),
              let expectedBundle = value(for: bundleArgument, in: arguments),
              let packID = value(for: packArgument, in: arguments),
              let oldVersion = value(for: oldVersionArgument, in: arguments),
              let newVersion = value(for: newVersionArgument, in: arguments) else { return nil }
        return StartConfiguration(
            stateURL: URL(fileURLWithPath: statePath),
            expectedBundle: expectedBundle,
            packID: packID,
            oldVersion: oldVersion,
            newVersion: newVersion
        )
    }

    private static var completionConfiguration: CompletionConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(completionArgument),
              let statePath = value(for: stateArgument, in: arguments),
              let expectedBundle = value(for: bundleArgument, in: arguments),
              let packID = value(for: packArgument, in: arguments),
              let newVersion = value(for: newVersionArgument, in: arguments) else { return nil }
        return CompletionConfiguration(
            stateURL: URL(fileURLWithPath: statePath),
            expectedBundle: expectedBundle,
            packID: packID,
            newVersion: newVersion
        )
    }

    private static func value(for prefix: String, in arguments: [String]) -> String? {
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = argument.dropFirst(prefix.count)
        return value.isEmpty ? nil : String(value)
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

    static func postMouseClick(identifier: String, in window: NSWindow?) -> String? {
        guard let window else { return "the Home window was unavailable" }
        guard window.isVisible else { return "the Home window was not visible" }
        guard window.isKeyWindow else { return "the Home window was not key" }
        guard !window.ignoresMouseEvents else { return "the Home window ignored mouse events" }
        guard let root = window.contentView,
              let probe = findClickProbe(in: root, identifier: identifier) else {
            return "the control geometry probe was absent"
        }
        let location: NSPoint
        switch clickLocation(for: probe, in: root, window: window) {
        case .ready(let point):
            location = point
        case .blocked(let reason):
            return "the control was not clickable: \(reason)"
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else {
            return "AppKit could not create mouse events"
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return nil
    }

    static func scrollClickProbeToVisible(identifier: String, in window: NSWindow?) -> String? {
        guard let window else { return "the window was unavailable" }
        guard let root = window.contentView,
              let probe = findClickProbe(in: root, identifier: identifier) else {
            return "the control geometry probe was absent"
        }
        guard probe.window === window else { return "the control probe belonged to another window" }
        guard !probe.isHiddenOrHasHiddenAncestor else { return "the control probe was hidden" }
        for clipView in clipViews(enclosing: probe) {
            let frame = probe.convert(probe.bounds, to: clipView)
            let visible = clipView.bounds
            guard !visible.contains(frame) else { continue }
            let document = clipView.documentRect
            var origin = visible.origin
            if frame.minX < visible.minX || frame.width > visible.width {
                origin.x = frame.minX
            } else if frame.maxX > visible.maxX {
                origin.x = frame.maxX - visible.width
            }
            if frame.minY < visible.minY || frame.height > visible.height {
                origin.y = frame.minY
            } else if frame.maxY > visible.maxY {
                origin.y = frame.maxY - visible.height
            }
            origin.x = min(max(origin.x, document.minX), max(document.minX, document.maxX - visible.width))
            origin.y = min(max(origin.y, document.minY), max(document.minY, document.maxY - visible.height))
            clipView.scroll(to: origin)
            clipView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }
        window.displayIfNeeded()
        return nil
    }

    // Partly clipped is enough: the click guard requires full containment in every clip view.
    static func scrollClickProbeOutOfVisibleArea(
        identifier: String,
        in window: NSWindow?
    ) -> String? {
        guard let window else { return "the window was unavailable" }
        guard let root = window.contentView,
              let probe = findClickProbe(in: root, identifier: identifier) else {
            return "the control geometry probe was absent"
        }
        guard probe.window === window else { return "the control probe belonged to another window" }
        let enclosingClipViews = clipViews(enclosing: probe)
        var geometry: [String] = []
        for clipView in enclosingClipViews {
            let documentRect = clipView.documentRect
            let maximumX = max(documentRect.minX, documentRect.maxX - clipView.bounds.width)
            let maximumY = max(documentRect.minY, documentRect.maxY - clipView.bounds.height)
            let origins = [
                NSPoint(x: documentRect.minX, y: documentRect.minY),
                NSPoint(x: maximumX, y: maximumY),
            ]
            for origin in origins {
                clipView.scroll(to: origin)
                clipView.enclosingScrollView?.reflectScrolledClipView(clipView)
                window.displayIfNeeded()
                let frameInClipView = probe.convert(probe.bounds, to: clipView)
                if !clipView.bounds.contains(frameInClipView) { return nil }
                geometry.append(
                    "document \(describe(documentRect)) visible \(describe(clipView.bounds)) probe \(describe(frameInClipView))"
                )
            }
        }
        return "the control probe could not be scrolled even partly outside its \(enclosingClipViews.count) clip views "
            + "(\(geometry.joined(separator: "; ")))"
    }

    private static func clipViews(enclosing view: NSView) -> [NSClipView] {
        var result: [NSClipView] = []
        var ancestor = view.superview
        while let current = ancestor {
            if let clipView = current as? NSClipView { result.append(clipView) }
            ancestor = current.superview
        }
        return result
    }

    private enum ClickTarget {
        case ready(NSPoint)
        case blocked(String)
    }

    private static func homeDiagnostics(probe identifier: String, _ details: [String]) -> String {
        let home = HomeWindowController.shared.window
        let windows = NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)):\($0.title)" }
        var parts: [String] = [
            "home visible \(home?.isVisible == true)",
            "home key \(home?.isKeyWindow == true)",
            "key window \(NSApp.keyWindow.map { "\(type(of: $0)):\($0.title)" } ?? "none")",
            "modal \(NSApp.modalWindow.map { "\(type(of: $0)):\($0.title)" } ?? "none")",
        ]
        parts += details
        parts.append("probe \(clickProbeFailure(identifier: identifier, in: home) ?? "ready")")
        parts.append("content \(describe(home?.contentView?.bounds))")
        parts.append("screen \(describe(home?.screen?.visibleFrame))")
        parts.append("visible windows \(windows)")
        return parts.joined(separator: ", ")
    }

    static func isClickProbeReady(identifier: String, in window: NSWindow?) -> Bool {
        clickProbeFailure(identifier: identifier, in: window) == nil
    }

    static func clickProbeFailure(identifier: String, in window: NSWindow?) -> String? {
        guard let window else { return "no window" }
        guard window.isVisible else { return "window hidden" }
        guard window.isKeyWindow else { return "window not key" }
        guard !window.ignoresMouseEvents else { return "window ignores mouse events" }
        guard let root = window.contentView else { return "no content view" }
        let probes = findClickProbes(in: root, identifier: identifier)
        guard probes.count == 1, let probe = probes.first else { return "\(probes.count) geometry probes" }
        guard probe.window === window else { return "probe in another window" }
        guard !probe.isHiddenOrHasHiddenAncestor else { return "probe hidden" }
        switch clickLocation(for: probe, in: root, window: window) {
        case .ready:
            return nil
        case .blocked(let reason):
            return reason
        }
    }

    private static func clickLocation(for probe: NSView, in root: NSView, window: NSWindow) -> ClickTarget {
        let frame = probe.bounds
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return .blocked("probe bounds \(describe(frame))") }
        let frameInRoot = probe.convert(frame, to: root)
        guard root.bounds.contains(frameInRoot) else {
            return .blocked("probe \(describe(frameInRoot)) outside root \(describe(root.bounds))")
        }
        var ancestor = probe.superview
        while let current = ancestor {
            if current is NSClipView {
                let frameInClipView = probe.convert(frame, to: current)
                guard current.bounds.contains(frameInClipView) else {
                    return .blocked("probe \(describe(frameInClipView)) clipped by \(describe(current.bounds))")
                }
            }
            ancestor = current.superview
        }
        let location = probe.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        let rootPoint = root.convert(location, from: nil)
        let hitTestPoint = root.superview?.convert(location, from: nil) ?? rootPoint
        guard root.bounds.contains(rootPoint) else { return .blocked("probe center outside root") }
        guard let hitTarget = root.hitTest(hitTestPoint) else { return .blocked("no native hit target") }
        guard hitTarget.window === window, !hitTarget.isHiddenOrHasHiddenAncestor else {
            return .blocked("native hit \(type(of: hitTarget)) was hidden or in another window")
        }
        return .ready(location)
    }

    private static func describe(_ rect: NSRect?) -> String {
        guard let rect else { return "none" }
        return String(format: "%.0f,%.0f %.0fx%.0f", rect.minX, rect.minY, rect.width, rect.height)
    }

    private static func isClickProbeAbsent(identifier: String, in window: NSWindow?) -> Bool {
        guard let root = window?.contentView else { return false }
        return findClickProbes(in: root, identifier: identifier).isEmpty
    }

    private static func findClickProbe(in view: NSView, identifier: String) -> NSView? {
        let matches = findClickProbes(in: view, identifier: identifier)
        return matches.count == 1 ? matches[0] : nil
    }

    private static func findClickProbes(in view: NSView, identifier: String) -> [NSView] {
        var matches: [NSView] = []
        if view is AppRelaunchClickProbeView,
           view.identifier?.rawValue == identifier {
            matches.append(view)
        }
        for child in view.subviews {
            matches.append(contentsOf: findClickProbes(in: child, identifier: identifier))
        }
        return matches
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
