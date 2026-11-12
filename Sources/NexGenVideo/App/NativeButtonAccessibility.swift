import ApplicationServices
import Darwin
import Foundation

enum NativeButtonAccessibility {
    struct Frame: Sendable, Equatable, Codable {
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

    struct Request: Sendable, Equatable, Codable {
        let pid: pid_t
        let windowNumber: Int
        let windowFrame: Frame
        let contentFrame: Frame

        init(pid: pid_t, windowNumber: Int, windowFrame: Frame, contentFrame: Frame? = nil) {
            self.pid = pid; self.windowNumber = windowNumber; self.windowFrame = windowFrame
            self.contentFrame = contentFrame ?? windowFrame
        }
    }

    struct Node: Sendable, Equatable, Codable {
        let parent: Int?
        let pid: pid_t
        let role: String?
        let title: String?
        let label: String?
        let enabled: Bool?
        let frame: Frame?
        let statuses: [String: Int32]
        let childTypes: [UInt]
        var scopeExclusion: String?

        var evidence: [String: Any] {
            ["parent": parent as Any? ?? NSNull(), "pid": pid, "role": role as Any? ?? NSNull(),
             "title": title as Any? ?? NSNull(), "label": label as Any? ?? NSNull(),
             "enabled": enabled as Any? ?? NSNull(), "publicScreenFrame": frame?.evidence as Any? ?? NSNull(),
             "statuses": statuses, "rawChildTypes": childTypes,
             "scopeExclusion": scopeExclusion as Any? ?? NSNull()]
        }
    }

    struct CGWindow: Sendable, Equatable, Codable {
        let pid: pid_t?
        let number: Int?
        let frame: Frame?
        let onscreen: Bool?

        var evidence: [String: Any] {
            ["pid": pid as Any? ?? NSNull(), "number": number as Any? ?? NSNull(),
             "frame": frame?.evidence as Any? ?? NSNull(), "onscreen": onscreen as Any? ?? NSNull()]
        }
    }

    struct Snapshot: Sendable, Codable {
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
        var contentRoots: [Node] = []
        var contentCandidates = 0
        var rootRivals: [Node] = []
        var reportedRootCount = 0
        var rootInventoryComplete = false
        var chromeExclusions: [String: Node] = [:]
        var readerEvidence: NativeAXPeer.Evidence?
        var windowAttributes: [String] = []
        var windowAttributeStatuses: [String: Int32] = [:]

        var evidence: [String: Any] {
            ["plane": "public-AX", "pid": request.pid, "window": request.windowNumber,
             "expectedWindowFrame": request.windowFrame.evidence, "windowCandidates": windowCandidates,
             "visited": nodes.count, "truncated": !complete, "failure": failure as Any? ?? NSNull(),
             "startedUptime": started, "finishedUptime": finished, "readOnMainThread": readOnMainThread,
             "coordinateSystem": "global top-left points", "nodes": nodes.map(\.evidence),
             "applicationStatuses": applicationStatuses, "windows": windows.map(\.evidence),
             "reportedWindows": reportedWindowCount, "CGWindows": cgWindows.map(\.evidence),
             "scope": "whole-content-root", "contentFrame": request.contentFrame.evidence,
             "contentCandidates": contentCandidates, "contentRoots": contentRoots.map(\.evidence),
             "reportedRootCount": reportedRootCount, "rootInventoryComplete": rootInventoryComplete,
             "rootRivals": rootRivals.map(\.evidence), "chromeExclusions": chromeExclusions.mapValues(\.evidence),
             "windowAttributes": windowAttributes, "windowAttributeStatuses": windowAttributeStatuses,
             "reader": readerEvidence?.evidence as Any? ?? NSNull()]
        }
    }

    private static let chromeAttributes = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute,
        kAXZoomButtonAttribute, kAXFullScreenButtonAttribute, kAXToolbarButtonAttribute,
        kAXGrowAreaAttribute, kAXTitleUIElementAttribute]

    static func validatedWindowAttributes(_ value: Any) -> [String]? {
        guard let names = value as? [String], !names.isEmpty, names.count <= 256,
              Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { return nil }
        return names
    }

    static func supportedChromeAttributes(_ names: [String]) -> [String] {
        let available = Set(names)
        return chromeAttributes.filter { available.contains($0) }
    }

    private static func knownWindowAttributes(_ snapshot: Snapshot) -> Bool {
        guard validatedWindowAttributes(snapshot.windowAttributes) != nil,
              snapshot.windowAttributeStatuses["AXAttributeNames"] == AXError.success.rawValue,
              snapshot.windowAttributeStatuses["timeout:AXAttributeNames"] == AXError.success.rawValue,
              Set([kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute])
                .isSubset(of: Set(snapshot.windowAttributes)) else { return false }
        let supported = Set(supportedChromeAttributes(snapshot.windowAttributes))
        let queried = Set(snapshot.windowAttributeStatuses.keys.filter { !$0.hasPrefix("timeout:") && $0 != "AXAttributeNames" })
        let allowed = Set(["AXAttributeNames", "timeout:AXAttributeNames"] + supported.flatMap { [$0, "timeout:" + $0] })
        return Set(snapshot.windowAttributeStatuses.keys).isSubset(of: allowed)
            && Set(snapshot.chromeExclusions.keys).isSubset(of: queried)
            && supported.allSatisfy { attribute in
                let status = snapshot.windowAttributeStatuses[attribute]
                let timeout = snapshot.windowAttributeStatuses["timeout:" + attribute]
                if status == nil && timeout == nil { return snapshot.chromeExclusions[attribute] == nil }
                guard timeout == AXError.success.rawValue else { return false }
                if status == AXError.success.rawValue {
                    return snapshot.chromeExclusions[attribute].map { knownChrome($0, slot: attribute, request: snapshot.request) } == true
                }
                return [AXError.attributeUnsupported.rawValue, AXError.noValue.rawValue]
                    .contains(status ?? AXError.failure.rawValue) && snapshot.chromeExclusions[attribute] == nil
            }
    }

    static func read(_ request: Request, using session: NativeAXPeer.Session? = nil,
                     nodeLimit: Int = 2048, seconds: Double = 2) async -> Snapshot {
        if Task.isCancelled {
            var result = Snapshot(request: request)
            result.failure = "cancelled"
            return result
        }
        guard request.pid == getpid(), request.windowNumber > 0, request.windowFrame.valid,
              request.contentFrame.valid, (1...2048).contains(nodeLimit), seconds.isFinite,
              seconds > 0, seconds <= 2 else {
            var result = Snapshot(request: request); result.failure = "invalid-owned-window-request"; return result
        }
        guard let session else {
            var result = Snapshot(request: request); result.failure = "reader-session-required"; return result
        }
        return await session.read(request, nodeLimit: nodeLimit, seconds: seconds)
    }

    static func buttons(_ snapshot: Snapshot, title: String, inside probe: Frame) -> [Node] {
        guard snapshot.complete, snapshot.failure == nil, snapshot.windowCandidates == 1,
              snapshot.request.pid == getpid(), snapshot.request.windowNumber > 0,
              snapshot.request.windowFrame.valid, probe.valid, !title.isEmpty,
              snapshot.request.contentFrame.valid, knownWindowAttributes(snapshot), snapshot.contentCandidates == 1,
              snapshot.contentRoots.count == 1,
              knownContent(snapshot.contentRoots[0], request: snapshot.request),
              snapshot.rootRivals.filter({ knownContent($0, request: snapshot.request) }) == snapshot.contentRoots,
              snapshot.rootInventoryComplete, snapshot.reportedRootCount == snapshot.rootRivals.count,
              !snapshot.rootRivals.isEmpty,
              snapshot.rootRivals.allSatisfy({ node in
                  node.pid == snapshot.request.pid && node.role != nil && node.frame?.known == true
                      && ["pid", kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute]
                          .allSatisfy({ node.statuses[$0] == AXError.success.rawValue })
              }),
              snapshot.rootRivals.allSatisfy({ node in
                  if knownContent(node, request: snapshot.request) { return true }
                  guard let frame = node.frame else { return false }
                  if !frame.rect.intersects(snapshot.request.contentFrame.rect) { return true }
                  guard let slot = node.scopeExclusion, let declared = snapshot.chromeExclusions[slot] else { return false }
                  return declared.pid == node.pid && declared.role == node.role && declared.frame == node.frame
                      && knownChrome(declared, slot: slot, request: snapshot.request)
              }),
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
        guard namesKnown, let frame = node.frame, frame.known,
              [kAXPositionAttribute, kAXSizeAttribute]
                .allSatisfy({ node.statuses[$0] == AXError.success.rawValue }) else { return false }
        if node.enabled != nil && node.statuses[kAXEnabledAttribute] == AXError.success.rawValue { return true }
        // AppKit exposes zero-area scroller buttons without an enabled attribute.
        return (frame.width == 0 || frame.height == 0) && node.enabled == nil
            && absent.contains(node.statuses[kAXEnabledAttribute] ?? AXError.failure.rawValue)
    }

    private final class Reader {
        let deadline: Double
        let cancelled: () -> Bool
        var failure: String?

        init(deadline: Double, cancelled: @escaping () -> Bool) {
            self.deadline = deadline; self.cancelled = cancelled
        }

        func available() -> Bool {
            if Task.isCancelled || cancelled() { failure = "cancelled"; return false }
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

        func values(_ element: AXUIElement, _ attributes: [String], statuses: inout [String: Int32]) -> [String: CFTypeRef] {
            guard prepare(element, attribute: "AXAttributes", statuses: &statuses) else { return [:] }
            var raw: CFArray?
            let status = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
            guard available() else { return [:] }
            guard status == .success, let raw, CFArrayGetCount(raw) == attributes.count else {
                for attribute in attributes { statuses[attribute] = status == .success ? AXError.failure.rawValue : status.rawValue }
                failure = "AX-batch-read:" + String(status.rawValue)
                return [:]
            }
            let decoded = NativeButtonAccessibility.decodeAttributes(raw as [AnyObject], attributes: attributes)
            statuses.merge(decoded.statuses) { _, current in current }
            if let error = decoded.failure { failure = error }
            return available() ? decoded.values : [:]
        }

        func windowAttributes(_ element: AXUIElement, statuses: inout [String: Int32]) -> [String]? {
            guard prepare(element, attribute: "AXAttributeNames", statuses: &statuses) else { return nil }
            var raw: CFArray?
            let status = AXUIElementCopyAttributeNames(element, &raw)
            statuses["AXAttributeNames"] = status.rawValue
            guard available() else { return nil }
            guard status == .success else { failure = "AX-window-attributes:" + String(status.rawValue); return nil }
            guard let raw, CFGetTypeID(raw) == CFArrayGetTypeID(),
                  let names = validatedWindowAttributes(raw) else {
                failure = "AX-invalid-window-attributes"; return nil
            }
            return names
        }

        func string(_ element: AXUIElement, _ attribute: String, statuses: inout [String: Int32]) -> String? {
            guard let raw = value(element, attribute, statuses: &statuses) else { return nil }
            return string(raw, attribute: attribute)
        }

        func string(_ raw: CFTypeRef?, attribute: String) -> String? {
            guard let raw else { return nil }
            guard let string = raw as? String else { failure = "AX-invalid-string-" + attribute; return nil }
            return string
        }

        func frame(_ element: AXUIElement, statuses: inout [String: Int32]) -> Frame? {
            guard let position = value(element, kAXPositionAttribute, statuses: &statuses),
                  let size = value(element, kAXSizeAttribute, statuses: &statuses) else { return nil }
            return frame(position: position, size: size)
        }

        func frame(position: CFTypeRef?, size: CFTypeRef?) -> Frame? {
            guard let position, let size else { return nil }
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

    static func decodeAttributes(_ raw: [AnyObject], attributes: [String])
        -> (values: [String: CFTypeRef], statuses: [String: Int32], failure: String?) {
        guard !attributes.isEmpty, raw.count == attributes.count, Set(attributes).count == attributes.count else {
            return ([:], [:], "AX-invalid-batch-inventory")
        }
        var values: [String: CFTypeRef] = [:], statuses: [String: Int32] = [:]
        var failure: String?
        for (attribute, value) in zip(attributes, raw) {
            var error = AXError.success
            if CFGetTypeID(value) == CFNullGetTypeID() {
                error = .noValue
            } else if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                guard AXValueGetValue(value as! AXValue, .axError, &error), error != .success else {
                    statuses[attribute] = AXError.failure.rawValue
                    failure = "AX-invalid-attribute-error-" + attribute
                    return ([:], statuses, failure)
                }
            }
            statuses[attribute] = error.rawValue
            if error == .success { values[attribute] = value }
            else if error != .attributeUnsupported && error != .noValue {
                failure = "AX-read-" + attribute + ":" + String(error.rawValue)
            }
        }
        return (failure == nil ? values : [:], statuses, failure)
    }

    static func captureForParent(_ request: Request, nodeLimit: Int, deadline: Double,
                                 cancelled: @escaping () -> Bool) -> Snapshot {
        var result = inspect(request, nodeLimit: nodeLimit, deadline: deadline, cancelled: cancelled)
        result.finished = ProcessInfo.processInfo.systemUptime
        return result
    }

    private static func knownContent(_ node: Node, request: Request) -> Bool {
        node.pid == request.pid && [kAXGroupRole, kAXSplitGroupRole, kAXScrollAreaRole].contains(node.role ?? "")
            && node.frame?.matches(request.contentFrame) == true
            && ["pid", kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute]
                .allSatisfy { node.statuses[$0] == AXError.success.rawValue }
    }

    private static func chromeRole(_ slot: String) -> String? {
        let roles = [kAXCloseButtonAttribute: kAXButtonRole, kAXMinimizeButtonAttribute: kAXButtonRole,
            kAXZoomButtonAttribute: kAXButtonRole, kAXFullScreenButtonAttribute: kAXButtonRole,
            kAXToolbarButtonAttribute: kAXButtonRole, kAXGrowAreaAttribute: kAXGrowAreaRole,
            kAXTitleUIElementAttribute: kAXStaticTextRole]
        return roles[slot]
    }

    private static func knownChrome(_ node: Node, slot: String, request: Request) -> Bool {
        guard let expected = chromeRole(slot), node.pid == request.pid, node.role == expected,
              let frame = node.frame, frame.known, request.windowFrame.rect.contains(frame.rect) else { return false }
        return [slot, "pid", kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute]
            .allSatisfy { node.statuses[$0] == AXError.success.rawValue }
    }

    private static func inspect(_ request: Request, nodeLimit: Int, deadline: Double,
                                cancelled: @escaping () -> Bool) -> Snapshot {
        var result = Snapshot(request: request)
        let remaining = deadline - result.started
        guard CommandLine.arguments.dropFirst().first == NativeAXPeer.flag, request.pid == getppid(),
              request.pid > 1, (1...Int(CGWindowID.max)).contains(request.windowNumber),
              request.windowFrame.valid, request.contentFrame.valid,
              request.windowFrame.rect.insetBy(dx: -0.5, dy: -0.5).contains(request.contentFrame.rect),
              (1...2048).contains(nodeLimit), deadline.isFinite, remaining > 0, remaining <= 2 else {
            result.failure = "invalid-owned-window-request"
            return result
        }
        let reader = Reader(deadline: deadline, cancelled: cancelled)
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
        var rootStatuses: [String: Int32] = [:]
        guard let rawChildren = reader.value(root, kAXChildrenAttribute, statuses: &rootStatuses),
              CFGetTypeID(rawChildren) == CFArrayGetTypeID(), let childValues = rawChildren as? [AnyObject],
              !childValues.isEmpty, childValues.count <= 256,
              childValues.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
            result.failure = reader.failure ?? "content-root-inventory-unavailable"
            return result
        }
        let children = childValues.map { $0 as! AXUIElement }
        guard let attributes = reader.windowAttributes(root, statuses: &result.windowAttributeStatuses) else {
            result.failure = reader.failure ?? "window-attributes-unavailable"; return result
        }
        result.windowAttributes = attributes
        guard Set([kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute])
            .isSubset(of: Set(attributes)) else {
            result.failure = "incomplete-window-attribute-inventory"; return result
        }
        var roots: [AXUIElement] = [], seenRoots: [AXUIElement] = []
        result.reportedRootCount = children.count
        for element in children {
            guard !seenRoots.contains(where: { CFEqual($0, element) }) else {
                result.failure = "duplicate-content-root-reference"; return result
            }
            seenRoots.append(element)
            var statuses: [String: Int32] = [:]
            let pid = reader.pid(element, statuses: &statuses)
            let role = reader.string(element, kAXRoleAttribute, statuses: &statuses)
            let frame = reader.frame(element, statuses: &statuses)
            let observed = Node(parent: nil, pid: pid ?? 0, role: role, title: nil, label: nil,
                enabled: nil, frame: frame, statuses: statuses, childTypes: [])
            result.rootRivals.append(observed)
            guard reader.available(), pid == request.pid, role != nil, frame?.known == true else {
                result.failure = reader.failure ?? "unreadable-content-root-rival"; return result
            }
            if knownContent(observed, request: request) {
                roots.append(element); result.contentRoots.append(observed)
            }
        }
        var chrome: [String: AXUIElement] = [:]
        for index in result.rootRivals.indices {
            let observed = result.rootRivals[index]
            guard !knownContent(observed, request: request),
                  observed.frame?.rect.intersects(request.contentFrame.rect) == true else { continue }
            let element = children[index]
            for slot in supportedChromeAttributes(attributes) where chromeRole(slot) == observed.role {
                if result.windowAttributeStatuses[slot] == nil {
                    var statuses: [String: Int32] = [:]
                    let value = reader.value(root, slot, statuses: &statuses)
                    result.windowAttributeStatuses[slot] = statuses[slot]
                    result.windowAttributeStatuses["timeout:" + slot] = statuses["timeout:" + slot]
                    guard reader.available() else { result.failure = reader.failure; return result }
                    if let value {
                        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                            result.failure = "invalid-window-chrome-type"; return result
                        }
                        let candidate = value as! AXUIElement
                        let pid = reader.pid(candidate, statuses: &statuses)
                        let role = reader.string(candidate, kAXRoleAttribute, statuses: &statuses)
                        let frame = reader.frame(candidate, statuses: &statuses)
                        let declared = Node(parent: nil, pid: pid ?? 0, role: role, title: nil,
                            label: nil, enabled: nil, frame: frame, statuses: statuses, childTypes: [])
                        guard reader.available(), knownChrome(declared, slot: slot, request: request) else {
                            result.failure = reader.failure ?? "unknown-window-chrome-identity"; return result
                        }
                        chrome[slot] = candidate
                        result.chromeExclusions[slot] = declared
                    } else if ![AXError.attributeUnsupported.rawValue, AXError.noValue.rawValue]
                        .contains(statuses[slot] ?? AXError.failure.rawValue) {
                        result.failure = "unknown-window-chrome"; return result
                    }
                }
            }
            let matches = chrome.keys.filter { slot in
                chrome[slot].map { CFEqual($0, element) } == true
                    && result.chromeExclusions[slot]?.pid == observed.pid
                    && result.chromeExclusions[slot]?.role == observed.role
                    && result.chromeExclusions[slot]?.frame == observed.frame
            }
            guard matches.count == 1, let slot = matches.first else {
                result.failure = "intersecting-unclassified-content-root-rival"; return result
            }
            result.rootRivals[index].scopeExclusion = slot
        }
        result.contentCandidates = roots.count
        result.rootInventoryComplete = true
        guard roots.count == 1, let content = roots.first else {
            result.failure = "non-unique-content-root"; return result
        }
        var pending: [(AXUIElement, Int?)] = [(content, nil)], visited: [AXUIElement] = []
        let leafRoles: Set<String> = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
            kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole, kAXImageRole,
            kAXSliderRole, kAXProgressIndicatorRole, kAXScrollBarRole, kAXPopUpButtonRole, kAXSplitterRole]
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
            let values = reader.values(element, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute], statuses: &statuses)
            let role = reader.string(values[kAXRoleAttribute], attribute: kAXRoleAttribute)
            let title = reader.string(values[kAXTitleAttribute], attribute: kAXTitleAttribute)
            let label = reader.string(values[kAXDescriptionAttribute], attribute: kAXDescriptionAttribute)
            let rawEnabled = values[kAXEnabledAttribute]
            let enabled = rawEnabled.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0 as? Bool : nil }
            if rawEnabled != nil && enabled == nil { reader.failure = "AX-invalid-enabled-value" }
            let frame = reader.frame(position: values[kAXPositionAttribute], size: values[kAXSizeAttribute])
            let children = values[kAXChildrenAttribute]
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
