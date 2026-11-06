import AppKit
import ApplicationServices
import Foundation
import SwiftUI

private typealias Query = NativeButtonAccessibility

@MainActor
private final class QueryFixture {
    let window: NSWindow
    let leaf: SlowLeaf?

    init(mode: String) {
        let slow = mode.hasPrefix("slow-")
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 200),
            styleMask: slow ? [.borderless] : [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if slow {
            let root = LastChildRoot(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
            let child = SlowLeaf(frame: NSRect(x: 20, y: 20, width: 100, height: 40))
            child.setAccessibilityLabel("Bounded child")
            root.addSubview(child)
            let button = NSButton(title: "Undo", target: nil, action: nil)
            button.frame = NSRect(x: 180, y: 20, width: 100, height: 30)
            root.addSubview(button)
            window.setAccessibilityElement(true)
            window.setAccessibilityTitle("Native bounded AX query")
            window.contentView = root
            leaf = child
        } else {
            window.contentView = NSHostingView(rootView: HStack {
                Button("Undo") {}.disabled(mode == "disabled")
                if mode == "duplicate" { Button("Undo") {} }
                Button("Redo") {}.disabled(true)
            }.buttonStyle(.capsule()))
            leaf = nil
        }
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    var request: Query.Request {
        let frame = window.frame
        return Query.Request(pid: getpid(), windowNumber: window.windowNumber,
            windowFrame: .init(CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
                width: frame.width, height: frame.height)))
    }

    func geometry() -> [String: Any] {
        let current = request
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = Query.ownCGWindows(entries, pid: getpid())
        return ["uptime": ProcessInfo.processInfo.systemUptime, "window": current.windowNumber,
            "frame": current.windowFrame.evidence, "visible": window.isVisible,
            "CGWindows": windows.map(\.evidence), "uniqueMatch": Query.uniqueCGWindow(windows, request: current)]
    }

    func settledGeometry() async throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var samples: [[String: Any]] = []
        var previous: Query.Request?
        var consecutive = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            let current = request
            let sample = geometry()
            samples.append(sample)
            if sample["uniqueMatch"] as? Bool == true, previous?.windowNumber == current.windowNumber,
               previous?.windowFrame.matches(current.windowFrame) == true {
                consecutive += 1
            } else {
                consecutive = 0
            }
            if consecutive >= 2 { return ["stable": true, "samples": samples] }
            previous = current
            try await Task.sleep(for: .milliseconds(50))
        }
        return ["stable": false, "samples": samples]
    }
}

@MainActor
private final class LastChildRoot: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? { subviews }
}

@MainActor
private final class SlowLeaf: NSView {
    let entered = DispatchSemaphore(value: 0)
    var armed = false
    var enteredAt: Double = 0
    var returnedAt: Double = 0
    var enteredOnMainThread = false

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? {
        if armed {
            enteredAt = ProcessInfo.processInfo.systemUptime
            enteredOnMainThread = Thread.isMainThread
            entered.signal()
            Thread.sleep(forTimeInterval: 0.35)
            returnedAt = ProcessInfo.processInfo.systemUptime
        }
        return []
    }
}

private enum RawAttributes {
    private final class Reader {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let pid: pid_t
        var errors: [String] = []
        let leaves: Set<String> = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXStaticTextRole,
            kAXTextFieldRole, kAXTextAreaRole, kAXImageRole, kAXSliderRole, kAXProgressIndicatorRole,
            kAXScrollBarRole, kAXPopUpButtonRole]

        init(pid: pid_t) { self.pid = pid }

        func available() -> Bool {
            if Task.isCancelled { errors.append("cancelled"); return false }
            if ProcessInfo.processInfo.systemUptime >= deadline { errors.append("deadline"); return false }
            return true
        }

        func prepare(_ element: AXUIElement, _ name: String, _ statuses: inout [String: Int32]) -> Bool {
            guard available() else { return false }
            let seconds = Float(min(0.15, deadline - ProcessInfo.processInfo.systemUptime))
            guard seconds > 0 else { errors.append("deadline"); return false }
            let status = AXUIElementSetMessagingTimeout(element, seconds)
            statuses["timeout:" + name] = status.rawValue
            guard status == .success else { errors.append("timeout-configuration:" + name); return false }
            return available()
        }

        func owned(_ element: AXUIElement, _ statuses: inout [String: Int32]) -> pid_t? {
            guard prepare(element, "pid", &statuses) else { return nil }
            var observed: pid_t = 0
            let status = AXUIElementGetPid(element, &observed)
            statuses["pid"] = status.rawValue
            guard available(), status == .success, observed == pid else {
                errors.append("unowned-or-unreadable-element"); return nil
            }
            return observed
        }

        func value(_ element: AXUIElement, _ name: String, _ statuses: inout [String: Int32]) -> CFTypeRef? {
            guard prepare(element, name, &statuses) else { return nil }
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
            statuses[name] = status.rawValue
            if status != .success && status != .attributeUnsupported && status != .noValue {
                errors.append("attribute:" + name + ":" + String(status.rawValue))
            }
            guard available() else { return nil }
            if status == .success && raw == nil { errors.append("missing-value:" + name) }
            return status == .success ? raw : nil
        }

        func node(_ element: AXUIElement, parent: Int?, readChildren: Bool) -> ([String: Any], [AXUIElement]) {
            var statuses: [String: Int32] = [:]
            var node: [String: Any] = ["parent": parent as Any? ?? NSNull()]
            guard let owner = owned(element, &statuses) else {
                node["statuses"] = statuses; return (node, [])
            }
            node["pid"] = owner
            var names: CFArray?
            if prepare(element, "attributeNames", &statuses) {
                let status = AXUIElementCopyAttributeNames(element, &names)
                statuses["attributeNames"] = status.rawValue
                if status != .success { errors.append("attribute-names:" + String(status.rawValue)) }
                _ = available()
            }
            let strings = names as? [String]
            node["attributeNames"] = strings as Any? ?? NSNull()
            node["attributeNamesType"] = names.map { CFGetTypeID($0) } as Any? ?? NSNull()
            if strings == nil || (strings?.count ?? 0) > 256 || Set(strings ?? []).count != strings?.count {
                errors.append("invalid-attribute-names")
            }
            for name in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXEnabledAttribute] {
                let raw = value(element, name, &statuses)
                node[name] = raw.map { String(describing: $0) } as Any? ?? NSNull()
                node["type:" + name] = raw.map { CFGetTypeID($0) } as Any? ?? NSNull()
                if name == kAXRoleAttribute && (raw == nil || raw.flatMap({ $0 as? String }) == nil) {
                    errors.append("unreadable-role")
                }
            }
            for (name, kind) in [(kAXPositionAttribute, AXValueType.cgPoint), (kAXSizeAttribute, AXValueType.cgSize)] {
                if let raw = value(element, name, &statuses) {
                    guard CFGetTypeID(raw) == AXValueGetTypeID() else { errors.append("invalid-frame-type"); continue }
                    if kind == .cgPoint {
                        var point = CGPoint.zero
                        if AXValueGetValue(raw as! AXValue, kind, &point) { node[name] = [Double(point.x), Double(point.y)] }
                        else { errors.append("invalid-position-value") }
                    } else {
                        var size = CGSize.zero
                        if AXValueGetValue(raw as! AXValue, kind, &size) { node[name] = [Double(size.width), Double(size.height)] }
                        else { errors.append("invalid-size-value") }
                    }
                }
            }
            var children: [AXUIElement] = []
            if readChildren {
                let raw = value(element, kAXChildrenAttribute, &statuses)
                node["type:AXChildren"] = raw.map { CFGetTypeID($0) } as Any? ?? NSNull()
                node["advertised:AXChildren"] = strings.map { $0.contains(kAXChildrenAttribute) } as Any? ?? NSNull()
                if let raw {
                    if let values = raw as? [AnyObject], values.count <= 64 {
                        let types = values.map { CFGetTypeID($0) }
                        node["childTypes:AXChildren"] = types
                        node["count:AXChildren"] = values.count
                        if types.allSatisfy({ $0 == AXUIElementGetTypeID() }) {
                            children = values.map { $0 as! AXUIElement }
                        } else { errors.append("unsupported-child-type") }
                    } else { errors.append("invalid-or-over-budget-children") }
                } else {
                    node["count:AXChildren"] = NSNull()
                    let status = statuses[kAXChildrenAttribute]
                    if !leaves.contains(node[kAXRoleAttribute] as? String ?? "")
                        || ![AXError.attributeUnsupported.rawValue, AXError.noValue.rawValue].contains(status ?? AXError.failure.rawValue) {
                        errors.append("unreadable-child-branch")
                    }
                }
            }
            node["statuses"] = statuses
            _ = available()
            return (node, children)
        }

        func windows(_ app: AXUIElement, statuses: inout [String: Int32]) -> [(AXUIElement, [String: Any])] {
            guard owned(app, &statuses) != nil, let raw = value(app, kAXWindowsAttribute, &statuses),
                  let values = raw as? [AnyObject], values.count <= 128,
                  values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
                errors.append("incomplete-window-inventory"); return []
            }
            return values.map { item in
                let element = item as! AXUIElement
                return (element, node(element, parent: nil, readChildren: false).0)
            }
        }
    }

    private static func frame(_ node: [String: Any]) -> Query.Frame? {
        guard let point = node[kAXPositionAttribute] as? [Double], let size = node[kAXSizeAttribute] as? [Double],
              point.count == 2, size.count == 2 else { return nil }
        return Query.Frame(CGRect(x: point[0], y: point[1], width: size[0], height: size[1]))
    }

    static func capture(_ request: Query.Request) throws -> Data {
        let reader = Reader(pid: request.pid)
        let app = AXUIElementCreateApplication(request.pid)
        var appStatuses: [String: Int32] = [:]
        let windows = reader.windows(app, statuses: &appStatuses)
        func windowKnown(_ node: [String: Any]) -> Bool {
            let statuses = node["statuses"] as? [String: Int32] ?? [:]
            return node["pid"] as? pid_t == request.pid && node[kAXRoleAttribute] as? String == kAXWindowRole
                && frame(node)?.known == true
                && ["pid", kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute].allSatisfy { statuses[$0] == 0 }
        }
        let candidates = windows.filter { frame($0.1)?.matches(request.windowFrame) == true }
        if !windows.allSatisfy({ windowKnown($0.1) }) || candidates.count != 1 { reader.errors.append("non-unique-owned-window") }
        let target = candidates.count == 1 ? candidates.first?.0 : nil
        var pending: [(AXUIElement, Int?)] = target.map { [($0, nil)] } ?? []
        var nodes: [[String: Any]] = [], visited: [AXUIElement] = []
        while !pending.isEmpty, reader.available() {
            if visited.count >= 64 { reader.errors.append("node-budget"); break }
            let (element, parent) = pending.removeLast()
            if visited.contains(where: { CFEqual($0, element) }) { reader.errors.append("duplicate-or-cyclic-child"); continue }
            visited.append(element)
            let (node, children) = reader.node(element, parent: parent, readChildren: true)
            let index = nodes.count
            nodes.append(node)
            if pending.count + children.count > 64 { reader.errors.append("pending-budget"); break }
            pending += children.map { ($0, index) }
        }
        var afterStatuses: [String: Int32] = [:]
        let after = reader.windows(app, statuses: &afterStatuses)
        let matchesAfter = after.filter { frame($0.1)?.matches(request.windowFrame) == true }
        let stillPresent = target.map { selected in matchesAfter.count == 1 && CFEqual(selected, matchesAfter[0].0) } ?? false
        if !after.allSatisfy({ windowKnown($0.1) }) || !stillPresent { reader.errors.append("window-changed-during-enumeration") }
        if nodes.first.flatMap({ frame($0) })?.matches(request.windowFrame) != true { reader.errors.append("root-frame-mismatch") }
        _ = reader.available()
        return try JSONSerialization.data(withJSONObject: ["pid": request.pid, "window": request.windowNumber,
            "requestFrame": request.windowFrame.evidence, "applicationStatuses": appStatuses,
            "CFArrayTypeID": CFArrayGetTypeID(), "AXUIElementTypeID": AXUIElementGetTypeID(),
            "applicationStatusesAfter": afterStatuses, "windows": windows.map { $0.1 }, "windowsAfter": after.map { $0.1 },
            "targetStillPresentByCFEqual": stillPresent, "hierarchyEnumerationEnded": pending.isEmpty,
            "hierarchyComplete": reader.errors.isEmpty && pending.isEmpty && stillPresent,
            "errors": reader.errors, "readOnMainThread": Thread.isMainThread, "nodes": nodes], options: [.sortedKeys])
    }
}

@MainActor
private final class ProbeApplication: NSObject, NSApplicationDelegate {
    let mode: String
    let destination: URL
    var failure = false

    init(mode: String, destination: URL) { self.mode = mode; self.destination = destination }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await observe() }
    }

    func observe() async {
        do {
            let fixture = QueryFixture(mode: mode)
            defer { fixture.window.contentView = nil; fixture.window.close() }
            let before = fixture.geometry()
            let first = await Query.read(fixture.request)
            let after = fixture.geometry()
            let stability = try await fixture.settledGeometry()
            let beforeWarm = fixture.geometry()
            let warm = await Query.read(fixture.request)
            let afterWarm = fixture.geometry()
            var slow: [String: Any] = ["status": "not-requested"]
            if let leaf = fixture.leaf {
                let buttons = Query.buttons(warm, title: "Undo", inside: fixture.request.windowFrame)
                if warm.complete, buttons.count == 1 {
                    leaf.armed = true
                    NSAccessibility.post(element: leaf, notification: .layoutChanged)
                    let request = fixture.request
                    let result: Query.Snapshot
                    var observed = false
                    var cancelledAt: Double = 0
                    if mode == "slow-cancel" {
                        let entered = leaf.entered
                        let query = Task.detached { await Query.read(request) }
                        let detection: (Bool, Double) = await withCheckedContinuation { continuation in
                            DispatchQueue.global(qos: .userInitiated).async {
                                let found = entered.wait(timeout: .now() + 2) == .success
                                let instant = found ? ProcessInfo.processInfo.systemUptime : 0
                                if found { query.cancel() }
                                continuation.resume(returning: (found, instant))
                            }
                        }
                        observed = detection.0
                        cancelledAt = detection.1
                        result = await query.value
                    } else {
                        result = await Query.read(request, seconds: 0.2)
                        observed = leaf.enteredAt > 0
                    }
                    slow = ["status": observed ? "observed-after-complete-warmup" : "not-reached-getter-entry",
                        "getterEntered": observed, "enabledUndoCount": buttons.count, "cancelRequestedAt": cancelledAt,
                        "requestedSeconds": mode == "slow-timeout" ? 0.2 : 1,
                        "enteredAt": leaf.enteredAt, "returnedAt": leaf.returnedAt,
                        "enteredOnMainThread": leaf.enteredOnMainThread, "query": result.evidence]
                    leaf.armed = false
                } else {
                    slow = ["status": "not-reached-warmup-unqualified", "warmup": warm.evidence,
                        "enabledUndoCount": buttons.count]
                }
            }
            let rawRequest = fixture.request
            let beforeRaw = fixture.geometry()
            let raw = try await Task.detached { try RawAttributes.capture(rawRequest) }.value
            let afterRaw = fixture.geometry()
            let beforeLast = fixture.geometry()
            let last = await Query.read(fixture.request)
            let report: [String: Any] = ["schema": "nexgenvideo/button-query-framework-control/1",
                "mode": mode, "pid": getpid(), "parentPID": getppid(), "mainLoopRunning": NSApp.isRunning,
                "mainThread": Thread.isMainThread, "activationPolicy": NSApp.activationPolicy().rawValue,
                "appearance": NSApp.effectiveAppearance.name.rawValue, "styleMask": fixture.window.styleMask.rawValue,
                "sourceSubsetFrameworkFixture": true, "parallelAppTestHost": false,
                "appAcceptance": false, "originalQueryBeforeAdditionalAX": true,
                "beforeFirstQuery": before, "originalFirstQuery": first.evidence, "afterFirstQuery": after,
                "CGStability": stability, "originalQueryAfterCGStability": warm.evidence,
                "beforeWarmQuery": beforeWarm, "afterWarmQuery": afterWarm,
                "beforeRawAttributes": beforeRaw, "afterRawAttributes": afterRaw, "beforeLastQuery": beforeLast,
                "slowObservation": slow, "rawAttributesAfterOriginalQueries": try JSONSerialization.jsonObject(with: raw),
                "queryAfterAdditionalAX": last.evidence, "finalGeometry": fixture.geometry()]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .withoutOverwriting)
        } catch {
            failure = true
            FileHandle.standardError.write(Data("Framework control failed: \(error)\n".utf8))
        }
        NSApp.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: true)
        }
    }
}

@main
private enum ButtonQueryProbe {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let delegate = ProbeApplication(mode: CommandLine.arguments[1], destination: URL(fileURLWithPath: CommandLine.arguments[2]))
        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
        exit(delegate.failure ? 1 : 0)
    }
}
