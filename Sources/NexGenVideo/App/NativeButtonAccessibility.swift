import ApplicationServices
import Darwin
import Foundation

enum NativeButtonAccessibility {
    struct Frame: Sendable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
        }

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        var valid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
        var known: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width >= 0 && height >= 0 }
        var values: [Double] { [x, y, width, height] }
        var evidence: [Any] { values.map { $0.isFinite ? $0 as Any : String(describing: $0) } }

        func matches(_ other: Frame) -> Bool {
            valid && other.valid && zip(values, other.values).allSatisfy { abs($0.0 - $0.1) <= 0.5 }
        }
    }

    struct Request: Sendable {
        let pid: pid_t
        let windowNumber: Int
        let windowFrame: Frame
    }

    struct Node: Sendable {
        let parent: Int?
        let pid: pid_t
        let role: String?
        let title: String?
        let label: String?
        let enabled: Bool?
        let frame: Frame?
        let statuses: [String: Int32]
        let childTypes: [UInt]

        var evidence: [String: Any] {
            ["parent": parent as Any? ?? NSNull(), "pid": pid, "role": role as Any? ?? NSNull(),
             "title": title as Any? ?? NSNull(), "label": label as Any? ?? NSNull(),
             "enabled": enabled as Any? ?? NSNull(), "publicScreenFrame": frame?.evidence as Any? ?? NSNull(),
             "statuses": statuses, "rawChildTypes": childTypes]
        }
    }

    struct CGWindow: Sendable {
        let pid: pid_t?
        let number: Int?
        let frame: Frame?
        let onscreen: Bool?

        var evidence: [String: Any] {
            ["pid": pid as Any? ?? NSNull(), "number": number as Any? ?? NSNull(),
             "frame": frame?.evidence as Any? ?? NSNull(), "onscreen": onscreen as Any? ?? NSNull()]
        }
    }

    struct Snapshot: Sendable {
        let request: Request
        var nodes: [Node] = []
        var windows: [Node] = []
        var cgWindows: [CGWindow] = []
        var reportedWindowCount = 0
        var applicationStatuses: [String: Int32] = [:]
        var windowCandidates: Int = 0
        var complete = false
        var failure: String?
        var started = ProcessInfo.processInfo.systemUptime
        var finished = ProcessInfo.processInfo.systemUptime
        var readOnMainThread = Thread.isMainThread

        var evidence: [String: Any] {
            ["plane": "public-AX", "pid": request.pid, "window": request.windowNumber,
             "expectedWindowFrame": request.windowFrame.evidence, "windowCandidates": windowCandidates,
             "visited": nodes.count, "truncated": !complete, "failure": failure as Any? ?? NSNull(),
             "startedUptime": started, "finishedUptime": finished, "readOnMainThread": readOnMainThread,
             "coordinateSystem": "global top-left points", "nodes": nodes.map(\.evidence),
             "applicationStatuses": applicationStatuses, "windows": windows.map(\.evidence),
             "reportedWindows": reportedWindowCount, "CGWindows": cgWindows.map(\.evidence)]
        }
    }

    static func read(_ request: Request, nodeLimit: Int = 2048, seconds: Double = 1) async -> Snapshot {
        if Task.isCancelled {
            var result = Snapshot(request: request)
            result.failure = "cancelled"
            return result
        }
        let task = Task.detached(priority: .userInitiated) {
            capture(request, nodeLimit: nodeLimit, seconds: seconds)
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    static func buttons(_ snapshot: Snapshot, title: String, inside probe: Frame) -> [Node] {
        guard snapshot.complete, snapshot.failure == nil, snapshot.windowCandidates == 1,
              snapshot.request.pid == getpid(), snapshot.request.windowNumber > 0,
              snapshot.request.windowFrame.valid, probe.valid, !title.isEmpty,
              uniqueCGWindow(snapshot.cgWindows, request: snapshot.request),
              snapshot.reportedWindowCount == snapshot.windows.count,
              snapshot.windows.allSatisfy({ knownWindow($0, pid: snapshot.request.pid) }),
              snapshot.windows.filter({ $0.frame?.matches(snapshot.request.windowFrame) == true }).count == 1,
              snapshot.nodes.allSatisfy({ knownDiscoveryNode($0, pid: snapshot.request.pid) }) else { return [] }
        return snapshot.nodes.filter { node in
            guard node.pid == snapshot.request.pid, node.role == kAXButtonRole, node.enabled == true,
                  [node.title, node.label].contains(title), let frame = node.frame, frame.valid,
                  ["pid", kAXRoleAttribute, kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute]
                    .allSatisfy({ node.statuses[$0] == AXError.success.rawValue }) else { return false }
            return snapshot.request.windowFrame.rect.contains(frame.rect)
                && probe.rect.insetBy(dx: -1, dy: -1).contains(frame.rect)
                && probe.rect.contains(CGPoint(x: frame.rect.midX, y: frame.rect.midY))
        }
    }

    static func uniqueCGWindow(_ windows: [CGWindow], request: Request) -> Bool {
        guard !windows.isEmpty, windows.allSatisfy({
            $0.pid == request.pid && ($0.number ?? 0) > 0 && $0.onscreen == true && $0.frame?.known == true
        }) else { return false }
        let matches = windows.filter { $0.frame?.matches(request.windowFrame) == true }
        return matches.count == 1 && matches.first?.number == request.windowNumber
    }

    static func ownCGWindows(_ entries: [[String: Any]], pid: pid_t) -> [CGWindow] {
        entries.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t else {
                return CGWindow(pid: nil, number: nil, frame: nil, onscreen: nil)
            }
            guard owner == pid else { return nil }
            var frame: Frame?
            if let bounds = entry[kCGWindowBounds as String] as? [String: Double],
               let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] {
                frame = Frame(CGRect(x: x, y: y, width: width, height: height))
            }
            return CGWindow(pid: owner, number: entry[kCGWindowNumber as String] as? Int,
                frame: frame, onscreen: entry[kCGWindowIsOnscreen as String] as? Bool)
        }
    }

    private static func knownWindow(_ node: Node, pid: pid_t) -> Bool {
        node.pid == pid && node.role == kAXWindowRole && node.frame?.known == true
            && ["pid", kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute]
                .allSatisfy { node.statuses[$0] == AXError.success.rawValue }
    }

    private static func knownDiscoveryNode(_ node: Node, pid: pid_t) -> Bool {
        guard node.pid == pid, node.role != nil, node.statuses["pid"] == AXError.success.rawValue,
              node.statuses[kAXRoleAttribute] == AXError.success.rawValue else { return false }
        guard node.role == kAXButtonRole else { return true }
        let absent = [AXError.attributeUnsupported.rawValue, AXError.noValue.rawValue]
        let namesKnown = [(kAXTitleAttribute, node.title), (kAXDescriptionAttribute, node.label)].allSatisfy { pair in
            let (attribute, value) = pair
            if node.statuses[attribute] == AXError.success.rawValue { return value != nil }
            return absent.contains(node.statuses[attribute] ?? AXError.failure.rawValue)
        }
        return namesKnown && node.enabled != nil && node.frame?.known == true
            && [kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute]
                .allSatisfy { node.statuses[$0] == AXError.success.rawValue }
    }

    private final class Reader {
        let deadline: Double
        var failure: String?

        init(seconds: Double) { deadline = ProcessInfo.processInfo.systemUptime + seconds }

        func available() -> Bool {
            if Task.isCancelled { failure = "cancelled"; return false }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = "query-deadline"; return false }
            return failure == nil
        }

        func prepare(_ element: AXUIElement, attribute: String, statuses: inout [String: Int32]) -> Bool {
            guard available() else { return false }
            let timeout = Float(min(0.15, deadline - ProcessInfo.processInfo.systemUptime))
            guard timeout > 0 else { failure = "query-deadline"; return false }
            let status = AXUIElementSetMessagingTimeout(element, timeout)
            statuses["timeout:" + attribute] = status.rawValue
            guard status == .success else { failure = "AX-timeout-configuration"; return false }
            return available()
        }

        func value(_ element: AXUIElement, _ attribute: String, statuses: inout [String: Int32]) -> CFTypeRef? {
            guard prepare(element, attribute: attribute, statuses: &statuses) else { return nil }
            var result: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
            statuses[attribute] = status.rawValue
            if status != .success && status != .attributeUnsupported && status != .noValue {
                failure = "AX-read-" + attribute + ":" + String(status.rawValue)
            }
            guard available() else { return nil }
            if status == .success && result == nil { failure = "AX-missing-value-" + attribute }
            return status == .success ? result : nil
        }

        func string(_ element: AXUIElement, _ attribute: String, statuses: inout [String: Int32]) -> String? {
            guard let raw = value(element, attribute, statuses: &statuses) else { return nil }
            guard let string = raw as? String else { failure = "AX-invalid-string-" + attribute; return nil }
            return string
        }

        func frame(_ element: AXUIElement, statuses: inout [String: Int32]) -> Frame? {
            guard let position = value(element, kAXPositionAttribute, statuses: &statuses),
                  let size = value(element, kAXSizeAttribute, statuses: &statuses) else { return nil }
            guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
                failure = "AX-invalid-frame-type"; return nil
            }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { failure = "AX-invalid-frame-value"; return nil }
            return Frame(CGRect(origin: point, size: dimensions))
        }

        func pid(_ element: AXUIElement, statuses: inout [String: Int32]) -> pid_t? {
            guard prepare(element, attribute: "pid", statuses: &statuses) else { return nil }
            var pid: pid_t = 0
            let status = AXUIElementGetPid(element, &pid)
            statuses["pid"] = status.rawValue
            if status != .success { failure = "AX-unreadable-pid" }
            guard available() else { return nil }
            return status == .success ? pid : nil
        }
    }

    private static func capture(_ request: Request, nodeLimit: Int, seconds: Double) -> Snapshot {
        var result = inspect(request, nodeLimit: nodeLimit, seconds: seconds)
        result.finished = ProcessInfo.processInfo.systemUptime
        return result
    }

    private static func inspect(_ request: Request, nodeLimit: Int, seconds: Double) -> Snapshot {
        var result = Snapshot(request: request)
        guard request.pid == getpid(), (1...Int(CGWindowID.max)).contains(request.windowNumber), request.windowFrame.valid,
              (1...2048).contains(nodeLimit), seconds.isFinite, seconds > 0, seconds <= 2 else {
            result.failure = "invalid-owned-window-request"
            return result
        }
        let reader = Reader(seconds: seconds)
        guard reader.available() else {
            result.failure = reader.failure
            return result
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]]
        guard reader.available() else { result.failure = reader.failure; return result }
        guard let windows, windows.count <= 4096 else {
            result.failure = "CG-window-inventory-unavailable"
            return result
        }
        result.cgWindows = ownCGWindows(windows, pid: request.pid)
        guard uniqueCGWindow(result.cgWindows, request: request) else {
            result.failure = "owned-CG-window-mismatch"
            return result
        }
        let app = AXUIElementCreateApplication(request.pid)
        var applicationStatuses: [String: Int32] = [:]
        let raw = reader.value(app, kAXWindowsAttribute, statuses: &applicationStatuses)
        result.applicationStatuses = applicationStatuses
        guard let raw,
              let entries = raw as? [AXUIElement], entries.count <= 128 else {
            result.failure = reader.failure ?? "AX-windows-unavailable"
            return result
        }
        result.reportedWindowCount = entries.count
        var candidates: [AXUIElement] = []
        for entry in entries {
            guard reader.available() else { break }
            var statuses: [String: Int32] = [:]
            let pid = reader.pid(entry, statuses: &statuses)
            let role = reader.string(entry, kAXRoleAttribute, statuses: &statuses)
            let frame = reader.frame(entry, statuses: &statuses)
            result.windows.append(Node(parent: nil, pid: pid ?? 0, role: role, title: nil, label: nil,
                enabled: nil, frame: frame, statuses: statuses, childTypes: []))
            guard let observed = result.windows.last, knownWindow(observed, pid: request.pid), reader.available() else {
                result.failure = reader.failure ?? "unreadable-AX-window"
                return result
            }
            if pid == request.pid, role == kAXWindowRole, let frame, frame.matches(request.windowFrame) {
                candidates.append(entry)
                result.windowCandidates = candidates.count
            }
        }
        result.windowCandidates = candidates.count
        guard reader.failure == nil, candidates.count == 1, let root = candidates.first else {
            result.failure = reader.failure ?? "non-unique-AX-window"
            return result
        }
        var pending: [(AXUIElement, Int?)] = [(root, nil)], visited: [AXUIElement] = []
        let leafRoles: Set<String> = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
            kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole, kAXImageRole,
            kAXSliderRole, kAXProgressIndicatorRole, kAXScrollBarRole, kAXPopUpButtonRole]
        while !pending.isEmpty {
            guard reader.available(), visited.count < nodeLimit else {
                result.failure = reader.failure ?? "AX-node-budget"
                return result
            }
            let (element, parent) = pending.removeLast()
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            var statuses: [String: Int32] = [:]
            let pid = reader.pid(element, statuses: &statuses) ?? 0
            let role = reader.string(element, kAXRoleAttribute, statuses: &statuses)
            let title = reader.string(element, kAXTitleAttribute, statuses: &statuses)
            let label = reader.string(element, kAXDescriptionAttribute, statuses: &statuses)
            let rawEnabled = reader.value(element, kAXEnabledAttribute, statuses: &statuses)
            let enabled = rawEnabled.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0 as? Bool : nil }
            if rawEnabled != nil && enabled == nil { reader.failure = "AX-invalid-enabled-value" }
            let frame = reader.frame(element, statuses: &statuses)
            let children = reader.value(element, kAXChildrenAttribute, statuses: &statuses)
            var types: [UInt] = [], descendants: [AXUIElement] = []
            if let children {
                if let values = children as? [AnyObject], values.count <= 2048 {
                    for value in values {
                        let type = CFGetTypeID(value)
                        types.append(type)
                        if type == AXUIElementGetTypeID() { descendants.append(value as! AXUIElement) }
                        else { reader.failure = "unsupported-AX-child" }
                    }
                } else { reader.failure = "invalid-AX-children" }
            } else if !leafRoles.contains(role ?? "") || ![AXError.attributeUnsupported.rawValue, AXError.noValue.rawValue]
                .contains(statuses[kAXChildrenAttribute] ?? AXError.failure.rawValue) {
                reader.failure = reader.failure ?? "incomplete-AX-children"
            }
            let index = result.nodes.count
            result.nodes.append(Node(parent: parent, pid: pid, role: role, title: title, label: label,
                enabled: enabled, frame: frame, statuses: statuses, childTypes: types))
            guard reader.available(), let observed = result.nodes.last, knownDiscoveryNode(observed, pid: request.pid) else {
                result.failure = reader.failure ?? "unreadable-potential-button"
                return result
            }
            guard pending.count + descendants.count <= 4096 else {
                result.failure = "AX-pending-budget"
                return result
            }
            pending += descendants.map { ($0, index) }
        }
        _ = reader.available()
        result.failure = reader.failure
        result.complete = result.failure == nil
        return result
    }
}
