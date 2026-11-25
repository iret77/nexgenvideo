import AppKit
import ApplicationServices
import NexGenEngine

@MainActor
enum ProductionNativeDisclosureAcceptance {
    struct Lookup {
        var matches: [NSRect] = []
        var nearby: [[String: Any]] = []
        var visited = 0
        var failure: String?

        func evidence(id: String, label: NSRect) -> [String: Any] {
            ["id": id, "plane": "in-process accessibility", "labelScreenFrame": ProductionNativeDisclosureAcceptance.frame(label),
             "matches": matches.map(ProductionNativeDisclosureAcceptance.frame), "nearby": nearby, "visited": visited, "failure": failure as Any? ?? NSNull()]
        }
    }

    static func toggle(_ id: String, content: String, expanded: Bool,
                       driver: ProductionVisualSourcesDriver, in window: NSWindow) async throws {
        try await driver.reveal(id, in: window)
        try driver.visible([id], in: window)
        guard (driver.state(content, in: window) != nil) != expanded, let root = window.contentView,
              let label = WorkspaceUIAcceptance.probeFrame(identifier: id, in: window) else {
            throw GateBlocked("The disclosure has an unexpected initial state: " + id)
        }
        let labelScreen = window.convertToScreen(root.convert(label, to: nil))
        var lookup = Lookup()
        do {
            try await driver.wait("actual disclosure control " + id) {
                lookup = triangles(beside: labelScreen, in: window)
                return lookup.matches.count == 1 || lookup.failure != nil
            }
        } catch {
            try? driver.record("native disclosure lookup", fields: lookup.evidence(id: id, label: labelScreen))
            throw error
        }
        guard lookup.failure == nil, lookup.matches.count == 1, let control = lookup.matches.first else {
            try driver.record("native disclosure lookup", fields: lookup.evidence(id: id, label: labelScreen))
            throw GateBlocked(lookup.failure ?? "The native disclosure triangle is unavailable: " + id)
        }
        let point = window.convertPoint(fromScreen: NSPoint(x: control.midX, y: control.midY))
        let controlLocal = root.convert(window.convertFromScreen(control), from: nil)
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
        try driver.record("native disclosure pointer", fields: lookup.evidence(id: id, label: labelScreen).merging([
            "content": content, "expanded": expanded, "role": kAXDisclosureTriangleRole, "input": "nativePointer",
            "controlFrame": frame(control)]) { _, new in new })
    }

    // Reads this window's accessibility objects directly: a main-thread AXUIElement query of our own process waits on the thread that answers it.
    static func triangles(beside label: NSRect, in window: NSWindow) -> Lookup {
        var result = Lookup()
        guard let root = window.contentView else { result.failure = "The disclosure window has no content."; return result }
        let band = label.insetBy(dx: -2 * label.height, dy: -label.height)
        var pending: [AnyObject] = [root], visited = Set<ObjectIdentifier>()
        while let element = pending.popLast() {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            guard visited.count <= 4096 else { result.failure = "The disclosure search reached its element cap."; break }
            let readFrame: (@MainActor () -> NSRect)? = element.accessibilityFrame
            let readRole: (@MainActor () -> NSAccessibility.Role?)? = element.accessibilityRole
            let readEnabled: (@MainActor () -> Bool)? = element.isAccessibilityEnabled
            let readChildren: (@MainActor () -> [Any]?)? = element.accessibilityChildren
            let frame = readFrame?()
            if let frame, !frame.isEmpty, !frame.intersects(band) { continue }
            let role = readRole?(), enabled = readEnabled?() ?? false
            if let frame, !frame.isEmpty, let role, role != .group {
                result.nearby.append(["role": role.rawValue, "enabled": enabled, "frame": Self.frame(frame)])
            }
            if role == .disclosureTriangle, let frame, accepts(frame, enabled: enabled, beside: label) {
                result.matches.append(frame)
            }
            pending += (readChildren?() ?? []).map { $0 as AnyObject }
        }
        result.visited = visited.count
        return result
    }

    static func accepts(_ frame: NSRect, enabled: Bool, beside label: NSRect) -> Bool {
        enabled && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
            && abs(frame.midY - label.midY) <= max(frame.height, label.height) / 2
            && frame.minX >= label.minX - 2 * label.height && frame.maxX <= label.maxX
            && frame.height <= label.height * 2
    }

    nonisolated fileprivate static func frame(_ value: NSRect) -> [Double] {
        [value.minX, value.minY, value.width, value.height].map(Double.init)
    }
}
