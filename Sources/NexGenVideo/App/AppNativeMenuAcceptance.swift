import AppKit
import ApplicationServices
import NexGenEngine

@MainActor
enum AppNativeMenuAcceptance {
    static func choose(_ path: [String], in window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        guard path.count >= 2, window.isKeyWindow, let main = NSApp.mainMenu,
              let entry = main.items.first(where: { $0.submenu?.title == path[0] }), let root = entry.submenu else {
            throw GateBlocked("The actual application menu is unavailable: " + path.joined(separator: " / "))
        }
        @MainActor final class Tracking {
            var expected: NSMenu?
            var observed: [[String]] = []
            var error: String?
            var ended = false
        }
        let tracking = Tracking(); tracking.expected = root
        let begin = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            let menuID = ObjectIdentifier(menu)
            MainActor.assumeIsolated {
                guard let menu = tracking.expected, ObjectIdentifier(menu) == menuID else { return }
                let depth = tracking.observed.count + 1
                guard depth < path.count else { return }
                menu.update()
                let choices = menu.items.filter { !$0.isHidden && !$0.isSeparatorItem && $0.isEnabled }
                tracking.observed.append(choices.map(\.title))
                guard let index = choices.firstIndex(where: { $0.title == path[depth] }) else {
                    tracking.error = "The enabled native menu item is missing: " + path[depth]
                    menu.cancelTracking(); return
                }
                do {
                    try driver.pressKey(115, characters: "\u{f729}", in: window)
                    for _ in 0..<index { try driver.pressKey(125, characters: "\u{f701}", in: window) }
                    if depth + 1 < path.count {
                        guard let submenu = choices[index].submenu else { throw GateBlocked("The requested native submenu is missing.") }
                        tracking.expected = submenu
                        try driver.pressKey(124, characters: "\u{f703}", in: window)
                    } else { try driver.pressKey(36, characters: "\r", in: window) }
                } catch { tracking.error = error.localizedDescription; menu.cancelTracking() }
            }
        }
        let end = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: root, queue: .main) { _ in
            MainActor.assumeIsolated { tracking.ended = true }
        }
        defer { NotificationCenter.default.removeObserver(begin); NotificationCenter.default.removeObserver(end) }
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 1)
        guard let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let items = attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
              let item = items.first(where: { attribute($0, kAXTitleAttribute) as? String == path[0] }),
              let position = attribute(item, kAXPositionAttribute), let size = attribute(item, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw GateBlocked("The application's menu-bar item has no actual accessibility frame.")
        }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { throw GateBlocked("The menu-bar item has an empty frame.") }
        let point = CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                throw GateBlocked("The native menu-bar pointer event could not be created.")
            }
            event.post(tap: .cghidEventTap)
        }
        try await driver.wait("actual application menu " + path.joined(separator: " / ")) { tracking.ended || tracking.error != nil }
        if let error = tracking.error { throw GateBlocked(error) }
        guard tracking.observed.count == path.count - 1 else { throw GateBlocked("The complete native menu path was not exercised.") }
        try driver.record("application-menu", fields: ["path": path, "menus": tracking.observed,
            "screenPoint": [point.x, point.y], "window": window.windowNumber, "closed": tracking.ended])
    }

    static func modalMenu(_ path: [String], in parent: NSWindow, driver: ProductionVisualSourcesDriver,
                          action: @escaping @MainActor (NSWindow) throws -> Void) async throws {
        @MainActor final class State { var window: NSWindow?; var error: (any Error)? }
        let state = State()
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            let modal: NSWindow? = MainActor.assumeIsolated {
                guard state.window == nil, let modal = NSApp.modalWindow, modal !== parent, modal.isVisible, modal.isKeyWindow else { return nil }
                state.window = modal
                return modal
            }
            guard let modal else { return }
            timer.invalidate()
            MainActor.assumeIsolated {
                do { try action(modal) }
                catch { state.error = error; try? driver.pressKey(53, characters: "\u{1b}", in: modal) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        try await choose(path, in: parent, driver: driver)
        if let error = state.error { throw error }
        try await driver.wait("native modal decision " + path.joined(separator: " / ")) {
            state.window.map { !$0.isVisible } == true && parent.isKeyWindow
        }
        if let error = state.error { throw error }
    }

    static func pointer(_ point: NSPoint, in view: NSView, window: NSWindow,
                        driver: ProductionVisualSourcesDriver, label: String, right: Bool = false) throws {
        guard window.isKeyWindow, view.window === window, !view.isHiddenOrHasHiddenAncestor,
              view.visibleRect.contains(point), let root = window.contentView?.superview ?? window.contentView,
              root.hitTest(view.convert(point, to: root.superview)) != nil else { throw GateBlocked("The actual pointer target is clipped: " + label) }
        for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { throw GateBlocked("Native pointer event unavailable.") }
            NSApp.postEvent(event, atStart: false)
        }
        try driver.record("native-pointer", fields: ["target": label, "point": [point.x, point.y], "window": window.windowNumber])
    }

    static func drag(from: NSPoint, to: NSPoint, in view: NSView, window: NSWindow,
                     driver: ProductionVisualSourcesDriver, label: String) async throws {
        guard window.isKeyWindow, view.window === window, !view.isHiddenOrHasHiddenAncestor,
              view.visibleRect.contains(from), view.visibleRect.contains(to) else { throw GateBlocked("Native drag endpoints are clipped: " + label) }
        for step in 0...9 {
            let f = CGFloat(min(step, 8)) / 8
            let point = NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)
            let type: NSEvent.EventType = step == 0 ? .leftMouseDown : step == 9 ? .leftMouseUp : .leftMouseDragged
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: step, clickCount: 1, pressure: step == 9 ? 0 : 1) else { throw GateBlocked("Native drag event unavailable.") }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(30))
        }
        try driver.record("native-drag", fields: ["target": label, "from": [from.x, from.y], "to": [to.x, to.y], "window": window.windowNumber])
    }

    static func close(_ window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        guard let button = window.standardWindowButton(.closeButton), button.isEnabled,
              !button.isHiddenOrHasHiddenAncestor else { throw GateBlocked("The real window Close control is unavailable.") }
        try pointer(NSPoint(x: button.bounds.midX, y: button.bounds.midY), in: button,
                    window: window, driver: driver, label: "window.close")
        try await driver.wait("native window close") { !window.isVisible }
    }

    static func accessibilityClick(_ title: String, in window: NSWindow, driver: ProductionVisualSourcesDriver) throws {
        guard let root = window.contentView else { throw GateBlocked("The actual window content is missing.") }
        var pending: [any NSAccessibilityProtocol] = [root], visited = Set<ObjectIdentifier>(), frames: [NSRect] = []
        while let element = pending.popLast(), visited.count < 2048 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let frame = element.accessibilityFrame()
            if element.accessibilityRole() == .button, element.isAccessibilityEnabled(),
               [element.accessibilityTitle(), element.accessibilityLabel()].contains(title),
               frame.width > 0, frame.height > 0, window.frame.contains(frame), !frames.contains(frame) { frames.append(frame) }
            pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        guard frames.count == 1, let frame = frames.first else { throw GateBlocked("The native button has no unique visible accessibility target: " + title) }
        let point = root.convert(window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)), from: nil)
        try pointer(point, in: root, window: window, driver: driver, label: "button." + title)
    }

    static func requireFinderSelection(_ url: URL, driver: ProductionVisualSourcesDriver) async throws {
        let expected = url.standardizedFileURL.resolvingSymlinksInPath().path
        try await driver.wait("Finder selected actual project", seconds: 15) {
            guard let finder = NSWorkspace.shared.frontmostApplication, finder.bundleIdentifier == "com.apple.finder" else { return false }
            let app = AXUIElementCreateApplication(finder.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.1)
            let pollDeadline = ProcessInfo.processInfo.systemUptime + 1
            var pending: [(AXUIElement, Bool)] = [(app, false)], visited: [(AXUIElement, Bool)] = []
            while let (element, inheritedSelection) = pending.popLast(), visited.count < 4096,
                  ProcessInfo.processInfo.systemUptime < pollDeadline {
                guard !visited.contains(where: { CFEqual($0.0, element) && $0.1 == inheritedSelection }) else { continue }
                visited.append((element, inheritedSelection))
                let selected = inheritedSelection || attribute(element, kAXSelectedAttribute) as? Bool == true
                if selected, let raw = attribute(element, kAXURLAttribute) {
                    let target = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
                    if target?.standardizedFileURL.resolvingSymlinksInPath().path == expected { return true }
                }
                for child in attribute(element, kAXSelectedChildrenAttribute) as? [AXUIElement] ?? [] { pending.append((child, true)) }
                for child in attribute(element, kAXSelectedRowsAttribute) as? [AXUIElement] ?? [] { pending.append((child, true)) }
                for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { pending.append((child, selected)) }
            }
            return false
        }
        try driver.record("finder-project-selection", fields: ["filename": url.lastPathComponent, "exactSelectedURL": true])
        try await returnFromFinder(driver: driver)
    }

    static func requireFinderDirectory(_ url: URL, driver: ProductionVisualSourcesDriver) async throws {
        let expected = url.standardizedFileURL.resolvingSymlinksInPath().path
        try await driver.wait("Finder opened actual diagnostics folder", seconds: 15) {
            guard let finder = NSWorkspace.shared.frontmostApplication, finder.bundleIdentifier == "com.apple.finder" else { return false }
            let app = AXUIElementCreateApplication(finder.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.5)
            return (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains { window in
                guard let raw = attribute(window, kAXDocumentAttribute) as? String, let document = URL(string: raw) else { return false }
                return document.standardizedFileURL.resolvingSymlinksInPath().path == expected
            }
        }
        try driver.record("finder-diagnostic-directory", fields: ["exactDirectory": true])
        try await returnFromFinder(driver: driver)
    }

    static func buttons(in window: NSWindow) -> [(title: String, enabled: Bool, frame: NSRect)] {
        guard let root = window.contentView else { return [] }
        var pending: [any NSAccessibilityProtocol] = [root], visited = Set<ObjectIdentifier>()
        var result: [(title: String, enabled: Bool, frame: NSRect)] = []
        while let element = pending.popLast(), visited.count < 2048 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let frame = element.accessibilityFrame()
            if element.accessibilityRole() == .button, frame.width > 0, frame.height > 0, window.frame.contains(frame),
               let title = element.accessibilityTitle() ?? element.accessibilityLabel(), !title.isEmpty,
               !result.contains(where: { $0.title == title && $0.frame == frame }) {
                result.append((title, element.isAccessibilityEnabled(), frame))
            }
            pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        return result
    }

    private static func returnFromFinder(driver: ProductionVisualSourcesDriver) async throws {
        for (code, down, flags) in [(CGKeyCode(55), true, CGEventFlags.maskCommand),
            (48, true, .maskCommand), (48, false, .maskCommand), (55, false, CGEventFlags())] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw GateBlocked("The native application-switch key is unavailable.") }
            event.flags = flags; event.post(tap: .cghidEventTap)
        }
        try await driver.wait("native application-switch returned to NexGenVideo") { NSRunningApplication.current.isActive }
    }

    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
