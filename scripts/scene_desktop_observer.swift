import AppKit
import ApplicationServices
import Darwin
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func buttonFrame(_ button: AXUIElement) -> CGRect? {
    guard let origin = attribute(button, kAXPositionAttribute), let extent = attribute(button, kAXSizeAttribute),
          CFGetTypeID(origin) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(origin as! AXValue, .cgPoint, &point),
          AXValueGetValue(extent as! AXValue, .cgSize, &size),
          point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}

func undoHit(_ pid: pid_t) -> [String: Any] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.15)
    guard let window = element(attribute(app, kAXFocusedWindowAttribute)) else { return ["status": "no-focused-window"] }
    let deadline = ProcessInfo.processInfo.systemUptime + 0.6
    var pending = [window]
    var seen: [AXUIElement] = []
    var buttons: [AXUIElement] = []
    while let node = pending.popLast() {
        guard !seen.contains(where: { CFEqual(node, $0) }) else { continue }
        seen.append(node)
        guard seen.count <= 512, ProcessInfo.processInfo.systemUptime < deadline else {
            return ["status": "incomplete", "visited": seen.count]
        }
        if attribute(node, kAXRoleAttribute) as? String == kAXButtonRole,
           (attribute(node, kAXTitleAttribute) as? String == "Undo" || attribute(node, kAXDescriptionAttribute) as? String == "Undo"),
           (attribute(node, kAXEnabledAttribute) as? NSNumber)?.boolValue == true {
            buttons.append(node)
        }
        if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
            guard children.count + pending.count <= 512 else { return ["status": "too-many-children"] }
            pending.append(contentsOf: children)
        }
    }
    guard buttons.count == 1, let button = buttons.first, let frame = buttonFrame(button) else {
        return ["status": "no-unique-enabled-undo", "matches": buttons.count]
    }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    var hit: AXUIElement?
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.15)
    let status = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
    let appKit = NSPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).maxY - point.y)
    var record: [String: Any] = ["status": "sampled", "publicUndoCenterQuartz": [point.x, point.y],
        "appKitWindowAtPoint": NSWindow.windowNumber(at: appKit, belowWindowWithWindowNumber: 0),
        "hitStatus": status.rawValue, "focusedWindowIdentity": CFHash(window), "undoIdentity": CFHash(button)]
    var ancestors: [[String: Any]] = []
    var chain: [AXUIElement] = []
    while let node = hit, chain.count < 12, !chain.contains(where: { CFEqual(node, $0) }) {
        chain.append(node)
        var owner: pid_t = 0
        let ownerStatus = AXUIElementGetPid(node, &owner)
        var item: [String: Any] = ["pid": owner, "pidStatus": ownerStatus.rawValue, "identity": CFHash(node),
                                   "matchesUndo": CFEqual(node, button), "matchesFocusedWindow": CFEqual(node, window)]
        item["role"] = attribute(node, kAXRoleAttribute) as? String
        ancestors.append(item)
        hit = element(attribute(node, kAXParentAttribute))
    }
    record["hitAncestors"] = ancestors
    return record
}

func desktop(_ phase: String, pid: pid_t? = nil, inspectUndo: Bool = false) throws {
    let now = ProcessInfo.processInfo.systemUptime
    let inventory = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    let windows: [[String: Any]] = (inventory ?? []).compactMap {
        guard let owner = ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
        let bundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier ?? ""
        guard bundle == "com.apple.notificationcenterui" || owner == pid else { return nil }
        var row: [String: Any] = ["pid": owner, "bundle": bundle]
        for key in [kCGWindowNumber, kCGWindowBounds, kCGWindowLayer, kCGWindowAlpha] { row[key as String] = $0[key as String] }
        return row
    }
    var row: [String: Any] = ["phase": phase, "uptime": now, "windowListAvailable": inventory != nil,
                              "windows": windows, "axTrusted": AXIsProcessTrusted()]
    row["frontmostPID"] = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if inspectUndo, let pid { row["undoHit"] = undoHit(pid) }
    row["finishedUptime"] = ProcessInfo.processInfo.systemUptime
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
    FileHandle.standardOutput.write(Data([10]))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else { exit(2) }
let root = URL(fileURLWithPath: arguments[0], isDirectory: true)
let progress = root.appendingPathComponent("evidence/scene/spatial-history-admission.json")
let processFile = root.appendingPathComponent("scene-observed-app.json")
try desktop("before-app")
try Data().write(to: root.appendingPathComponent("scene-desktop-ready"))
let deadline = ProcessInfo.processInfo.systemUptime + 350
while ProcessInfo.processInfo.systemUptime < deadline && !FileManager.default.fileExists(atPath: root.appendingPathComponent("scene-desktop-done").path) {
    if let data = try? Data(contentsOf: processFile),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let pid = (object["pid"] as? NSNumber)?.int32Value,
       let path = object["executable"] as? String, let app = NSRunningApplication(processIdentifier: pid),
       app.executableURL?.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path {
        var phase = "app-started"
        if let receipt = try? Data(contentsOf: progress),
           let fields = try? JSONSerialization.jsonObject(with: receipt) as? [String: Any],
           let stage = fields["stage"] as? String { phase = String(stage.prefix(120)) }
        try desktop(phase, pid: pid, inspectUndo: phase == "settled local button Undo")
    }
    Thread.sleep(forTimeInterval: 0.5)
}
