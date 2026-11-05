import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

@_silgen_name("proc_pid_rusage")
private func processUsage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

@_silgen_name("proc_pidpath")
private func processPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

private struct ObservationError: Error { let message: String }

private func require(_ value: Bool, _ message: String) throws {
    if !value { throw ObservationError(message: message) }
}

private func json(_ url: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw ObservationError(message: "Expected a JSON object")
    }
    return object
}

private func identity(_ pid: Int32) -> [String: Any]? {
    let data = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 8)
    defer { data.deallocate() }
    data.initializeMemory(as: UInt8.self, repeating: 0, count: 1024)
    guard processUsage(pid, 4, data) == 0 else { return nil }
    let start = data.load(fromByteOffset: 80, as: UInt64.self)
    var path = [UInt8](repeating: 0, count: 4096)
    guard start > 0, processPath(pid, &path, UInt32(path.count)) > 0,
          let zero = path.firstIndex(of: 0), let name = String(bytes: path[..<zero], encoding: .utf8) else { return nil }
    return ["pid": pid, "startAbsoluteTime": start, "executable": URL(fileURLWithPath: name).resolvingSymlinksInPath().path]
}

private func sameIdentity(_ left: [String: Any], _ right: [String: Any]) -> Bool {
    (left["pid"] as? NSNumber) == (right["pid"] as? NSNumber)
        && (left["startAbsoluteTime"] as? NSNumber) == (right["startAbsoluteTime"] as? NSNumber)
        && left["executable"] as? String == right["executable"] as? String
}

private final class Observer {
    let output: URL
    let deadline: Double
    let pid: Int32
    var bytes = 0
    var trees = Set<String>()

    init(output: URL, deadline: Double, pid: Int32) {
        self.output = output; self.deadline = deadline; self.pid = pid
    }

    func checkDeadline() throws {
        try require(ProcessInfo.processInfo.systemUptime < deadline, "AX observation deadline reached")
    }

    func write(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        bytes += data.count
        try require(bytes <= 64 * 1024 * 1024, "AX evidence byte budget reached")
        try data.write(to: url, options: .atomic)
    }

    func copy(_ element: AXUIElement, _ attribute: String) throws -> (AXError, CFTypeRef?) {
        try checkDeadline()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (status, value)
    }

    func scalar(_ value: CFTypeRef?) -> Any {
        guard let value else { return NSNull() }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as! NSNumber).boolValue }
        if let string = value as? String { return String(string.prefix(1024)) }
        if let number = value as? NSNumber {
            return number.doubleValue.isFinite ? number as Any : String(describing: number)
        }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return ["AXIdentity": CFHash(value)] }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let item = value as! AXValue
            if AXValueGetType(item) == .cgPoint {
                var point = CGPoint.zero
                if AXValueGetValue(item, .cgPoint, &point), point.x.isFinite, point.y.isFinite { return [point.x, point.y] }
            }
            if AXValueGetType(item) == .cgSize {
                var size = CGSize.zero
                if AXValueGetValue(item, .cgSize, &size), size.width.isFinite, size.height.isFinite { return [size.width, size.height] }
            }
        }
        return ["unsupportedCFTypeID": CFGetTypeID(value)]
    }

    func tree(_ window: AXUIElement) throws -> [String: Any] {
        var pending = [window], seen: [AXUIElement] = [], rows: [[String: Any]] = []
        while !pending.isEmpty && seen.count < 2048 {
            try checkDeadline()
            guard let element = pending.popLast() else { break }
            if seen.contains(where: { CFEqual($0, element) }) { continue }
            seen.append(element)
            var actualPID: Int32 = 0
            let pidStatus = AXUIElementGetPid(element, &actualPID)
            try require(pidStatus == .success && actualPID == pid, "Foreign or unavailable AX process identity")
            let timeoutStatus = AXUIElementSetMessagingTimeout(element, 0.2)
            try require(timeoutStatus == .success, "AX messaging timeout could not be bounded")
            var row: [String: Any] = ["identity": CFHash(element), "pid": actualPID, "pidStatus": pidStatus.rawValue]
            var values: [String: Any] = [:], statuses: [String: Int32] = [:]
            for attribute in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                              kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute] {
                let (status, value) = try copy(element, attribute)
                statuses[attribute] = status.rawValue; values[attribute] = scalar(value)
            }
            let (status, raw) = try copy(element, kAXChildrenAttribute)
            statuses[kAXChildrenAttribute] = status.rawValue
            var children: [AXUIElement] = [], childTypes: [CFTypeID] = []
            if status == .success {
                try require(raw != nil && CFGetTypeID(raw!) == CFArrayGetTypeID(), "AXChildren did not return an array")
                let items = raw as! [CFTypeRef]
                try require(items.count <= 2048, "AX child array budget reached")
                for item in items {
                    childTypes.append(CFGetTypeID(item))
                    if CFGetTypeID(item) == AXUIElementGetTypeID() { children.append(item as! AXUIElement) }
                }
            }
            row["attributes"] = values; row["statuses"] = statuses
            row["rawChildTypes"] = childTypes; row["rawChildrenCount"] = childTypes.count
            row["unsupportedChildrenCount"] = childTypes.count - children.count
            row["children"] = children.map { CFHash($0) }
            rows.append(row); pending += children
        }
        return ["windowIdentity": CFHash(window), "nodes": rows, "visited": seen.count,
                "budget": 2048, "truncated": !pending.isEmpty, "localSwiftObjectTypesObserved": false]
    }

    func sample(_ application: AXUIElement, initialIdentity: [String: Any], index: Int) throws -> [String: Any] {
        try checkDeadline()
        guard let current = identity(pid) else { return ["sample": index, "processAlive": false] }
        try require(sameIdentity(initialIdentity, current), "The App PID was reused or its executable changed")
        let started = ProcessInfo.processInfo.systemUptime
        let (windowStatus, raw) = try copy(application, kAXWindowsAttribute)
        var windows: [[String: Any]] = []
        if windowStatus == .success {
            try require(raw != nil && CFGetTypeID(raw!) == CFArrayGetTypeID(), "AXWindows did not return an array")
            let items = raw as! [CFTypeRef]
            try require(items.count <= 32, "AX window budget reached")
            for item in items {
                try require(CFGetTypeID(item) == AXUIElementGetTypeID(), "Unsupported AX window object")
                let value = try tree(item as! AXUIElement)
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if trees.insert(digest).inserted {
                    try require(trees.count <= 128, "Distinct AX tree budget reached")
                    try write(value, to: output.appendingPathComponent("ax-tree-" + digest + ".json"))
                }
                windows.append(["treeSHA256": digest, "windowIdentity": CFHash(item)])
            }
        }
        let cg = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
            .map { record -> [String: Any] in
                var retained: [String: Any] = [:]
                for key in [kCGWindowOwnerPID, kCGWindowNumber, kCGWindowBounds, kCGWindowLayer, kCGWindowIsOnscreen] {
                    retained[key as String] = record[key as String] ?? NSNull()
                }
                return retained
            }
        return ["sample": index, "startedUptime": started, "completedUptime": ProcessInfo.processInfo.systemUptime,
                "processAlive": true, "processIdentity": current, "AXWindowsStatus": windowStatus.rawValue,
                "windows": windows, "CGWindows": cg]
    }
}

@main
private enum SceneHistoryAXObserver {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            Darwin.exit(1)
        }
    }

    static func run() throws {
        let args = CommandLine.arguments
        try require(args.count == 6, "Expected process receipt, executable, source, output and completion paths")
        let receipt = URL(fileURLWithPath: args[1]), binary = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath().path
        let source = args[3], output = URL(fileURLWithPath: args[4]), done = URL(fileURLWithPath: args[5])
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + 180
        var process: [String: Any]?
        while process == nil && ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: done.path) { throw ObservationError(message: "The App completed before AX attachment") }
            if let candidate = try? json(receipt) { process = candidate }
            if process == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        guard let process, let number = process["pid"] as? NSNumber, number.int32Value > 1,
              process["sourceSHA"] as? String == source, process["mode"] as? String == "runtime",
              let actual = identity(number.int32Value), actual["executable"] as? String == binary else {
            throw ObservationError(message: "The supervisor App PID/source/path/start binding is missing")
        }
        let trusted = AXIsProcessTrusted()
        try require(trusted, "Read-only AX observation permission is unavailable")
        let application = AXUIElementCreateApplication(number.int32Value)
        try require(AXUIElementSetMessagingTimeout(application, 0.2) == .success, "Cannot bound application AX queries")
        let observer = Observer(output: output, deadline: deadline, pid: number.int32Value)
        try observer.write(["schema": "nexgenvideo/scene-history-ax-attachment/1", "sourceSHA": source,
            "processIdentity": actual, "observerPID": getpid(), "observerParentPID": getppid(), "AXTrusted": trusted,
            "startedUptime": started, "firstQueryUptime": ProcessInfo.processInfo.systemUptime,
            "coordinateSystem": "AX and CG global top-left screen coordinates; no backing-pixel conversion",
            "geometryTolerance": 0.5, "externalQueriesMayInitializeAccessibility": true,
            "localSwiftObjectTypesObserved": false], to: output.appendingPathComponent("attachment.json"))
        var count = 0
        while !FileManager.default.fileExists(atPath: done.path) {
            try observer.checkDeadline()
            try require(count < 720, "AX sample budget reached")
            let sample = try observer.sample(application, initialIdentity: actual, index: count)
            try observer.write(sample, to: output.appendingPathComponent(String(format: "ax-sample-%04d.json", count)))
            count += 1
            Thread.sleep(forTimeInterval: 0.15)
        }
        let completion = try json(done)
        try require(completion["sourceSHA"] as? String == source && (completion["pid"] as? NSNumber) == number,
                    "App completion source/PID differs")
        try observer.write(["schema": "nexgenvideo/scene-history-ax-completion/1", "sourceSHA": source,
            "processIdentity": actual, "samples": count, "distinctTrees": observer.trees.count,
            "evidenceBytes": observer.bytes, "completedUptime": ProcessInfo.processInfo.systemUptime,
            "boundedQueries": true, "readOnly": true], to: output.appendingPathComponent("observer-completion.json"))
    }
}
