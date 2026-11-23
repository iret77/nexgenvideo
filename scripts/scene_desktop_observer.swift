import AppKit
import ApplicationServices
import Darwin
import Foundation

func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func frameOf(_ button: AXUIElement, read: (AXUIElement, String) -> CFTypeRef?) -> CGRect? {
    guard let origin = read(button, kAXPositionAttribute), let extent = read(button, kAXSizeAttribute),
          CFGetTypeID(origin) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(origin as! AXValue, .cgPoint, &point),
          AXValueGetValue(extent as! AXValue, .cgSize, &size),
          point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}

@MainActor
func undoHit(_ pid: pid_t, keyWindow: Int, windows: [[String: Any]]) -> [String: Any] {
    var errors: [String: Int32] = [:]
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if status == .success { return value }
        if status != .attributeUnsupported && status != .noValue { errors[name] = status.rawValue }
        return nil
    }
    func coordinates(_ frame: CGRect) -> [CGFloat] { [frame.minX, frame.minY, frame.width, frame.height] }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.15)
    guard let window = element(attribute(app, kAXFocusedWindowAttribute)) else { return ["status": "no-focused-window"] }
    guard let focusedFrame = frameOf(window, read: attribute) else { return ["status": "missing-focused-frame", "errors": errors] }
    let matching = windows.filter { row in
        guard (row["pid"] as? NSNumber)?.int32Value == pid,
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return zip(coordinates(frame), coordinates(focusedFrame)).allSatisfy { abs($0.0 - $0.1) <= 0.5 }
    }
    let numbers = matching.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
    guard numbers == [keyWindow] else {
        return ["status": "focused-window-not-uniquely-bound", "matchingWindows": numbers,
                "nativeKeyWindow": keyWindow, "focusedFrame": coordinates(focusedFrame)]
    }
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
        guard let role = attribute(node, kAXRoleAttribute) as? String else {
            return ["status": "unclassified-node", "errors": errors]
        }
        if role == kAXButtonRole,
           (attribute(node, kAXTitleAttribute) as? String == "Undo" || attribute(node, kAXDescriptionAttribute) as? String == "Undo"),
           (attribute(node, kAXEnabledAttribute) as? NSNumber)?.boolValue == true {
            buttons.append(node)
        }
        if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
            guard children.count + pending.count <= 512 else { return ["status": "too-many-children"] }
            pending.append(contentsOf: children)
        }
    }
    guard errors.isEmpty else { return ["status": "incomplete-ax-read", "errors": errors] }
    guard buttons.count == 1, let button = buttons.first, let frame = frameOf(button, read: attribute) else {
        return ["status": "no-unique-enabled-undo", "matches": buttons.count]
    }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    var hit: AXUIElement?
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.15)
    let status = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
    let appKit = NSPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).maxY - point.y)
    var record: [String: Any] = ["status": "sampled", "publicUndoCenterQuartz": [point.x, point.y],
        "nativeKeyWindow": keyWindow, "focusedFrame": coordinates(focusedFrame), "publicUndoFrame": coordinates(frame),
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
    record["attributeErrors"] = errors
    return record
}

@MainActor
func desktop(_ phase: String, pid: pid_t? = nil, keyWindow: Int? = nil) throws {
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
    if let keyWindow, let pid { row["undoHit"] = undoHit(pid, keyWindow: keyWindow, windows: windows) }
    row["finishedUptime"] = ProcessInfo.processInfo.systemUptime
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
    FileHandle.standardOutput.write(Data([10]))
    if phase == "before-app", inventory == nil || !AXIsProcessTrusted() { exit(3) }
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
        var keyWindow: Int?
        if let receipt = try? Data(contentsOf: progress),
           let fields = try? JSONSerialization.jsonObject(with: receipt) as? [String: Any],
           let stage = fields["stage"] as? String {
            phase = String(stage.prefix(120))
            if phase == "settled local button Undo", let diagnostic = fields["diagnostic"] as? String,
               diagnostic.hasPrefix("key="), let first = diagnostic.split(separator: ",").first {
                keyWindow = Int(first.dropFirst(4))
            }
        }
        try desktop(phase, pid: pid, keyWindow: keyWindow)
    }
    Thread.sleep(forTimeInterval: 0.5)
}
