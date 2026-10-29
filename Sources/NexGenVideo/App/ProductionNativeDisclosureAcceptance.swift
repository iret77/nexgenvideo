import AppKit
import ApplicationServices
import NexGenEngine

@MainActor
enum ProductionNativeDisclosureAcceptance {
    static func toggle(_ id: String, content: String, expanded: Bool,
                       driver: ProductionVisualSourcesDriver, in window: NSWindow) async throws {
        try await driver.reveal(id, in: window)
        try driver.visible([id], in: window)
        guard (driver.state(content, in: window) != nil) != expanded,
              let label = WorkspaceUIAcceptance.probeFrame(identifier: id, in: window),
              let root = window.contentView, let screen = NSScreen.screens.first else {
            throw GateBlocked("The disclosure has an unexpected initial state: " + id)
        }
        let global = window.convertToScreen(root.convert(label, to: nil))
        let labelAX = CGRect(x: global.minX, y: screen.frame.height - global.maxY, width: global.width, height: global.height)
        let parent = window.sheetParent ?? window
        let parentAX = CGRect(x: parent.frame.minX, y: screen.frame.height - parent.frame.maxY,
            width: parent.frame.width, height: parent.frame.height)
        var control: CGRect?, lookupFailure: Error?
        try await driver.wait("actual disclosure control " + id) {
            do { control = try triangle(near: labelAX, windowFrame: parentAX) }
            catch { lookupFailure = error }
            return control != nil || lookupFailure != nil
        }
        if let lookupFailure { throw lookupFailure }
        guard let control else { throw GateBlocked("The native disclosure triangle is unavailable: " + id) }
        let point = window.convertPoint(fromScreen: .init(x: control.midX, y: screen.frame.height - control.midY))
        let controlScreen = NSRect(x: control.minX, y: screen.frame.height - control.maxY, width: control.width, height: control.height)
        let controlLocal = root.convert(window.convertFromScreen(controlScreen), from: nil)
        guard root.bounds.contains(controlLocal) else {
            throw GateBlocked("The native disclosure triangle is clipped: " + id)
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw GateBlocked("The disclosure pointer event could not be created.")
            }
            NSApp.postEvent(event, atStart: false)
        }
        try await driver.wait("native disclosure changed " + id) { (driver.state(content, in: window) != nil) == expanded }
        try driver.record("native disclosure pointer", fields: ["id": id, "content": content, "expanded": expanded,
            "role": kAXDisclosureTriangleRole, "input": "nativePointer",
            "controlFrame": [control.minX, control.minY, control.width, control.height]])
    }

    private static func triangle(near label: CGRect, windowFrame: CGRect) throws -> CGRect? {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 1)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let matchesWindow = windows.filter { element in
            guard let frame = frame(element) else { return false }
            return abs(frame.minX - windowFrame.minX) < 2 && abs(frame.minY - windowFrame.minY) < 2
                && abs(frame.width - windowFrame.width) < 2 && abs(frame.height - windowFrame.height) < 2
        }
        guard matchesWindow.count == 1, let target = matchesWindow.first else { return nil }
        let band = label.insetBy(dx: -2 * label.height, dy: -label.height)
        var queue = [target], visited: [AXUIElement] = [], matches: [CGRect] = []
        while let element = queue.popLast() {
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            guard visited.count < 1024 else { throw GateBlocked("The target window disclosure search reached its element cap.") }
            visited.append(element)
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == kAXMenuBarRole { continue }
            let actualFrame = frame(element)
            if let actualFrame, !actualFrame.isEmpty, !actualFrame.intersects(band) { continue }
            if role == kAXDisclosureTriangleRole, attribute(element, kAXEnabledAttribute) as? Bool == true,
               let frame = actualFrame, frame.width > 0, frame.height > 0,
               abs(frame.midY - label.midY) <= max(frame.height, label.height) / 2,
               frame.minX >= label.minX - 2 * label.height, frame.minX <= label.maxX,
               frame.maxX <= label.maxX, frame.height <= label.height * 2 { matches.append(frame) }
            queue += attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
