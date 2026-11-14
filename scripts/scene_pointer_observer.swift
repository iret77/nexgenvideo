import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

nonisolated(unsafe) private var stopping = false

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
    var queried: [AXUIElement] = []

    init(output: URL, deadline: Double, pid: Int32) {
        self.output = output; self.deadline = deadline; self.pid = pid
    }

    func checkDeadline() throws {
        try require(!stopping && ProcessInfo.processInfo.systemUptime < deadline, "AX observation deadline reached")
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
                if AXValueGetValue(item, .cgPoint, &point) {
                    guard point.x.isFinite, point.y.isFinite else { return ["invalidPoint": [String(describing: point.x), String(describing: point.y)]] }
                    return [Double(point.x), Double(point.y)]
                }
            }
            if AXValueGetType(item) == .cgSize {
                var size = CGSize.zero
                if AXValueGetValue(item, .cgSize, &size) {
                    guard size.width.isFinite, size.height.isFinite else { return ["invalidSize": [String(describing: size.width), String(describing: size.height)]] }
                    return [Double(size.width), Double(size.height)]
                }
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
            queried.append(element)
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
            try require(status == .success || status == .attributeUnsupported || status == .noValue,
                "AX child enumeration failed")
            if status != .success {
                let leaves: Set<String> = ["AXButton", "AXStaticText", "AXImage", "AXTextField", "AXTextArea",
                    "AXCheckBox", "AXRadioButton", "AXSlider", "AXScrollBar", "AXProgressIndicator", "AXValueIndicator", "AXSplitter"]
                try require(raw == nil && leaves.contains(values[kAXRoleAttribute] as? String ?? ""),
                    "Unreadable children of a possible AX container")
            }
            var children: [AXUIElement] = [], childTypes: [CFTypeID] = []
            if status == .success {
                try require(raw != nil && CFGetTypeID(raw!) == CFArrayGetTypeID(), "AXChildren did not return an array")
                let items = raw as! [CFTypeRef]
                try require(items.count <= 2048, "AX child array budget reached")
                for item in items {
                    childTypes.append(CFGetTypeID(item))
                    try require(CFGetTypeID(item) == AXUIElementGetTypeID(), "Unsupported AX child")
                    children.append(item as! AXUIElement)
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

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func finiteRect(_ value: Any?) throws -> CGRect {
    guard let a = value as? [Double], a.count == 4,
          a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0 else {
        throw ObservationError(message: "Missing finite positive rectangle")
    }
    return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
}

private func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5
        && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
}

private func boundedData(_ url: URL, under root: URL, maximum: Int = 8 * 1024 * 1024) throws -> Data {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    try require(resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
        && resolved == url.standardizedFileURL, "Unexpected evidence symlink or escape")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    try require(attributes[.type] as? FileAttributeType == .typeRegular
        && ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= maximum, "Evidence file bound exceeded")
    return try Data(contentsOf: url)
}

private func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ObservationError(message: "Expected an evidence object")
    }
    return value
}

private func canonical(_ expected: [String: Any], output: URL) throws -> [String: Any] {
    guard let scene = expected["sceneID"] as? String, UUID(uuidString: scene) != nil,
          let revision = expected["revision"] as? String, UUID(uuidString: revision) != nil,
          let manifestHash = expected["manifestSHA256"] as? String else {
        throw ObservationError(message: "Invalid canonical observation")
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let recovery = support.appendingPathComponent("NexGenVideo/Recovery", isDirectory: true).resolvingSymlinksInPath()
    let projects = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
    try require(projects.count <= 128, "Recovery discovery bound exceeded")
    var matches: [[String: Any]] = []
    for project in projects {
        let root = project.appendingPathComponent("pipeline/production_design/spatial", isDirectory: true)
        let indexURL = root.appendingPathComponent("index.v1.json")
        if !FileManager.default.fileExists(atPath: indexURL.path) { continue }
        let indexData = try boundedData(indexURL, under: recovery)
        let index = try object(indexData)
        try require(index["schema"] as? String == "spatial-scene-index/v1", "Unknown scene index")
        guard let scenes = index["scenes"] as? [[String: Any]] else { continue }
        for head in scenes where head["id"] as? String == scene {
            try require(head["name"] as? String == "Pale room 100" && head["revision"] as? String == revision
                && head["manifestSHA256"] as? String == manifestHash, "Canonical scene advanced before intervention")
            let directory = root.appendingPathComponent("scenes/" + scene + "/revisions/" + revision)
            let manifestData = try boundedData(directory.appendingPathComponent("manifest.v1.json"), under: recovery)
            let manifest = try object(manifestData)
            try require(manifest["schema"] as? String == "spatial-scene-manifest/v1"
                && digest(manifestData) == manifestHash && manifest["sceneID"] as? String == scene
                && manifest["revision"] as? String == revision, "Canonical manifest identity differs")
            guard let parent = manifest["parentRevision"] as? String, UUID(uuidString: parent) != nil else {
                throw ObservationError(message: "Missing prior scene revision")
            }
            let parentDirectory = root.appendingPathComponent("scenes/" + scene + "/revisions/" + parent)
            let parentManifestData = try boundedData(parentDirectory.appendingPathComponent("manifest.v1.json"), under: recovery)
            let parentManifest = try object(parentManifestData)
            let snapshotData = try boundedData(directory.appendingPathComponent("snapshot.v1.json"), under: recovery)
            let priorData = try boundedData(parentDirectory.appendingPathComponent("snapshot.v1.json"), under: recovery)
            let sceneData = try boundedData(directory.appendingPathComponent("scene.blend"), under: recovery, maximum: 64 * 1024 * 1024)
            let priorSceneData = try boundedData(parentDirectory.appendingPathComponent("scene.blend"), under: recovery, maximum: 64 * 1024 * 1024)
            try require(manifest["snapshotSHA256"] as? String == digest(snapshotData)
                && parentManifest["snapshotSHA256"] as? String == digest(priorData)
                && manifest["sceneSHA256"] as? String == digest(sceneData)
                && parentManifest["sceneSHA256"] as? String == digest(priorSceneData)
                && parentManifest["sceneID"] as? String == scene && parentManifest["revision"] as? String == parent,
                "Canonical snapshot lineage differs")
            let snapshot = try object(snapshotData), prior = try object(priorData)
            guard let objects = snapshot["objects"] as? [[String: Any]], objects.count == 1,
                  let oldObjects = prior["objects"] as? [[String: Any]], oldObjects.count == 1,
                  let matrix = objects[0]["matrixWorld"] as? [Double], matrix.count == 16,
                  let oldMatrix = oldObjects[0]["matrixWorld"] as? [Double], oldMatrix.count == 16 else {
                throw ObservationError(message: "Expected one transformed cube and its prior matrix")
            }
            try require(objects[0]["id"] as? String == oldObjects[0]["id"] as? String
                && objects[0]["name"] as? String == "Cube" && abs(matrix[3] - 0.5) < 0.000001
                && abs(oldMatrix[3]) < 0.000001 && matrix.allSatisfy(\.isFinite) && oldMatrix.allSatisfy(\.isFinite),
                "Original scene transformation differs")
            let evidence = output.appendingPathComponent("canonical-before", isDirectory: true)
            try require(!FileManager.default.fileExists(atPath: evidence.path), "Ambiguous canonical evidence root")
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
            for (name, data) in [("index.json", indexData), ("manifest.json", manifestData),
                                 ("snapshot.json", snapshotData), ("scene.blend", sceneData),
                                 ("prior-manifest.json", parentManifestData), ("prior-snapshot.json", priorData),
                                 ("prior-scene.blend", priorSceneData)] {
                try data.write(to: evidence.appendingPathComponent(name), options: .atomic)
            }
            matches.append(["root": root.path, "head": head, "indexSHA256": digest(indexData),
                "manifest": manifest, "manifestSHA256": digest(manifestData), "snapshot": snapshot,
                "snapshotSHA256": digest(snapshotData), "priorManifest": parentManifest,
                "priorManifestSHA256": digest(parentManifestData), "priorSnapshot": prior,
                "priorSnapshotSHA256": digest(priorData)])
        }
    }
    try require(matches.count == 1, "Canonical scene root is missing or ambiguous")
    return matches[0]
}

private func screenGeometry(_ frame: CGRect) -> [String: Any] {
    ["screenFrame": [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)],
     "screenPoint": [Double(frame.midX), Double(frame.midY)]]
}

private func geometryPair(_ value: Any?) -> [Double]? {
    guard let values = value as? [Double], values.count == 2, values.allSatisfy(\.isFinite) else { return nil }
    return values
}

private func geometrySelfCheck(output: URL, source: String, executableHash: String, nonce: String) throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    try require(digest(Data(contentsOf: executable)) == executableHash, "Selfcheck executable differs")
    let observer = Observer(output: output.deletingLastPathComponent(), deadline: ProcessInfo.processInfo.systemUptime + 5, pid: getpid())
    var point = CGPoint(x: -12.5, y: 25.25), size = CGSize(width: 960, height: 640)
    guard let rawPoint = AXValueCreate(.cgPoint, &point), let rawSize = AXValueCreate(.cgSize, &size) else {
        throw ObservationError(message: "Native AX geometry fixture unavailable")
    }
    let position = observer.scalar(rawPoint), extent = observer.scalar(rawSize)
    try require(geometryPair(position) == [-12.5, 25.25] && geometryPair(extent) == [960, 640], "Window geometry consumer failed")
    let node: [String: Any] = [kAXPositionAttribute: position, kAXSizeAttribute: extent]
    try require(geometryPair(node[kAXPositionAttribute]) == [-12.5, 25.25]
        && geometryPair(node[kAXSizeAttribute]) == [960, 640], "Button geometry consumer failed")
    let screen = screenGeometry(CGRect(x: -12.5, y: 25.25, width: 50, height: 28))
    try require(geometryPair(screen["screenPoint"]) == [12.5, 39.25]
        && sameRect(try finiteRect(screen["screenFrame"]), CGRect(x: -12.5, y: 25.25, width: 50, height: 28)), "Screen geometry consumer failed")
    var badPoint = CGPoint(x: CGFloat.nan, y: 1), badSize = CGSize(width: 1, height: CGFloat.infinity)
    guard let rawBadPoint = AXValueCreate(.cgPoint, &badPoint), let rawBadSize = AXValueCreate(.cgSize, &badSize) else {
        throw ObservationError(message: "Native invalid geometry fixture unavailable")
    }
    let invalid = [observer.scalar(rawBadPoint), observer.scalar(rawBadSize), observer.scalar("wrong" as CFString), observer.scalar(nil)]
    try require(invalid.allSatisfy { geometryPair($0) == nil }
        && geometryPair([1.0]) == nil && geometryPair([1.0, 2.0, 3.0]) == nil
        && geometryPair([Double.nan, 1.0]) == nil, "Invalid geometry accepted")
    let oldPoint: Any = [point.x, point.y]
    try observer.write(["schema": "nexgenvideo/observer-geometry-selfcheck/1", "sourceSHA256": source,
        "executableSHA256": executableHash, "nonce": nonce, "pid": getpid(), "passed": true,
        "windowConsumer": true, "buttonConsumer": true, "screenConsumers": true, "invalidRejected": true,
        "oldCGFloatArrayCastsToDouble": oldPoint is [Double], "invalidValues": invalid,
        "position": position, "size": extent, "screen": screen], to: output)
}

private func snapshot(pid: Int32, window: Int, frame: CGRect, output: URL) throws -> [String: Any] {
    let observer = Observer(output: output, deadline: ProcessInfo.processInfo.systemUptime + 8, pid: pid)
    let application = AXUIElementCreateApplication(pid)
    try require(AXUIElementSetMessagingTimeout(application, 0.2) == .success, "Cannot bound AX application query")
    let (status, raw) = try observer.copy(application, kAXWindowsAttribute)
    let journal = output.appendingPathComponent("window-geometry-" + UUID().uuidString + ".json")
    var inventory: [String: Any] = ["pid": pid, "window": window, "AXWindowsStatus": status.rawValue,
        "AXWindowsCFType": raw.map { CFGetTypeID($0) } as Any? ?? NSNull(), "windows": []]
    try observer.write(inventory, to: journal)
    guard status == .success, let windows = raw as? [AXUIElement], windows.count <= 32 else {
        throw ObservationError(message: "Complete AX window inventory unavailable")
    }
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let cg = all.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        && ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window }
    inventory["CGTarget"] = cg
    try observer.write(inventory, to: journal)
    guard cg.count == 1, let bounds = cg[0][kCGWindowBounds as String] as? [String: Any],
          let fullFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
        throw ObservationError(message: "Original CG window unavailable")
    }
    try require(abs(fullFrame.width - 960) < 0.5 && fullFrame.height >= 640 && fullFrame.height <= 740,
        "Compact viewport geometry changed")
    let expected = frame.offsetBy(dx: fullFrame.minX, dy: fullFrame.maxY - 640)
    var trees: [[String: Any]] = [], buttons: [[String: Any]] = []
    var geometry: [[String: Any]] = []
    for candidate in windows {
        let (positionStatus, positionValue) = try observer.copy(candidate, kAXPositionAttribute)
        let (sizeStatus, sizeValue) = try observer.copy(candidate, kAXSizeAttribute)
        func record(_ status: AXError, _ raw: CFTypeRef?) -> [String: Any] {
            var value: [String: Any] = ["status": status.rawValue, "value": observer.scalar(raw),
                "doubleArray": observer.scalar(raw) is [Double]]
            if let raw {
                value["CFType"] = CFGetTypeID(raw)
                if CFGetTypeID(raw) == AXValueGetTypeID() { value["AXValueType"] = AXValueGetType(raw as! AXValue).rawValue }
            }
            return value
        }
        var candidatePID: Int32 = 0
        let pidStatus = AXUIElementGetPid(candidate, &candidatePID)
        geometry.append(["identity": CFHash(candidate), "pid": candidatePID, "pidStatus": pidStatus.rawValue,
            "position": record(positionStatus, positionValue), "size": record(sizeStatus, sizeValue)])
        inventory["windows"] = geometry
        try observer.write(inventory, to: journal)
        guard positionStatus == .success, sizeStatus == .success,
              let position = geometryPair(observer.scalar(positionValue)),
              let size = geometryPair(observer.scalar(sizeValue)) else {
            throw ObservationError(message: "Incomplete AX window geometry inventory")
        }
        let actual = CGRect(x: position[0], y: position[1], width: size[0], height: size[1])
        if !sameRect(actual, fullFrame) { continue }
        let tree = try observer.tree(candidate)
        guard let nodes = tree["nodes"] as? [[String: Any]] else { throw ObservationError(message: "Missing AX nodes") }
        try require(tree["truncated"] as? Bool == false, "AX tree incomplete")
        trees.append(tree)
        let (mainStatus, mainValue) = try observer.copy(application, kAXMainWindowAttribute)
        let (focusedStatus, focusedValue) = try observer.copy(application, kAXFocusedWindowAttribute)
        try require(mainStatus == .success && mainValue != nil && CFEqual(mainValue!, candidate)
            && focusedStatus == .success && focusedValue != nil && CFEqual(focusedValue!, candidate), "Original window lost focus")
        for node in nodes {
            guard let statuses = node["statuses"] as? [String: Int32] else { throw ObservationError(message: "Missing AX query statuses") }
            try require(statuses[kAXRoleAttribute] == 0, "Unclassified AX node")
            guard let a = node["attributes"] as? [String: Any], a[kAXRoleAttribute] as? String == kAXButtonRole,
                  a[kAXDescriptionAttribute] as? String == "Undo" || a[kAXTitleAttribute] as? String == "Undo",
                  a[kAXEnabledAttribute] as? Bool == true,
                  let p = geometryPair(a[kAXPositionAttribute]),
                  let s = geometryPair(a[kAXSizeAttribute]) else { continue }
            try require([kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute].allSatisfy { statuses[$0] == 0 },
                "Undo query failed")
            let button = CGRect(x: p[0], y: p[1], width: s[0], height: s[1])
            if sameRect(button, expected) { buttons.append(node) }
        }
    }
    try require(trees.count == 1 && buttons.count == 1, "No unique enabled actual Undo at original target")
    let candidates = observer.queried.filter { NSNumber(value: CFHash($0)) == buttons[0]["identity"] as? NSNumber }
    try require(candidates.count == 1, "Ambiguous retained AX button reference")
    let system = AXUIElementCreateSystemWide()
    try require(AXUIElementSetMessagingTimeout(system, 0.2) == .success, "Cannot bound system hit test")
    var hit: AXUIElement?
    try observer.checkDeadline()
    let hitStatus = AXUIElementCopyElementAtPosition(system, Float(expected.midX), Float(expected.midY), &hit)
    try require(hitStatus == .success && hit != nil, "No public system target at pointer position")
    var hitPath: [[String: Any]] = [], matched = false
    for _ in 0..<16 {
        guard let element = hit else { break }
        var hitPID: Int32 = 0
        try require(AXUIElementGetPid(element, &hitPID) == .success && hitPID == pid,
            "System pointer target belongs to another process")
        hitPath.append(["identity": CFHash(element), "pid": hitPID])
        if CFEqual(element, candidates[0]) { matched = true; break }
        try require(AXUIElementSetMessagingTimeout(element, 0.2) == .success, "Cannot bound target ancestor query")
        let (parentStatus, parent) = try observer.copy(element, kAXParentAttribute)
        try require(parentStatus == .success && parent != nil && CFGetTypeID(parent!) == AXUIElementGetTypeID(),
            "System hit target has no verified Undo ancestor")
        hit = (parent as! AXUIElement)
    }
    try require(matched, "Original Undo is occluded or no longer the system pointer target")
    let cgIdentity = Dictionary(uniqueKeysWithValues: [kCGWindowOwnerPID, kCGWindowNumber, kCGWindowBounds,
        kCGWindowLayer, kCGWindowIsOnscreen].map { ($0 as String, cg[0][$0 as String] ?? NSNull()) })
    var result: [String: Any] = ["window": window, "pid": pid, "CGWindow": cgIdentity, "AXTree": trees[0], "button": buttons[0],
        "systemHitStatus": hitStatus.rawValue, "systemHitPath": hitPath,
        "observedUptime": ProcessInfo.processInfo.systemUptime]
    result.merge(screenGeometry(expected)) { _, new in new }
    return result
}

private func exclusive(_ value: [String: Any], at url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    try require(fd >= 0, "One-shot marker already exists or cannot be created")
    defer { close(fd) }
    let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    try require(count == data.count && fsync(fd) == 0, "One-shot marker was not durably written")
    let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
    try require(directory >= 0, "Cannot open one-shot marker directory")
    defer { close(directory) }
    try require(fsync(directory) == 0, "One-shot marker directory was not durably written")
}

private func sameTarget(_ before: [String: Any], _ after: [String: Any]) throws {
    for key in ["window", "pid", "CGWindow", "screenFrame", "screenPoint"] {
        try require(NSDictionary(dictionary: [key: before[key] ?? NSNull()])
            .isEqual(to: [key: after[key] ?? NSNull()]), "Pointer target moved or changed")
    }
    for (key, identityKey) in [("AXTree", "windowIdentity"), ("button", "identity")] {
        try require((before[key] as? [String: Any])?[identityKey] as? NSNumber
            == (after[key] as? [String: Any])?[identityKey] as? NSNumber, "AX target identity changed")
    }
}

private func capture(window: Int, at url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l", String(window), url.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline && !stopping {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    try require(process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path),
        "Bounded native screenshot failed")
}

private func restored(_ before: [String: Any], head: [String: Any], output: URL) throws -> [String: Any] {
    guard let path = before["root"] as? String,
          let old = before["manifest"] as? [String: Any],
          let prior = before["priorManifest"] as? [String: Any],
          let scene = head["sceneID"] as? String, UUID(uuidString: scene) != nil,
          let revision = head["revision"] as? String, UUID(uuidString: revision) != nil else {
        throw ObservationError(message: "Restoration identity unavailable")
    }
    let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let directory = root.appendingPathComponent("scenes/" + scene + "/revisions/" + revision)
    let manifestData = try boundedData(directory.appendingPathComponent("manifest.v1.json"), under: root)
    let manifest = try object(manifestData)
    let snapshotData = try boundedData(directory.appendingPathComponent("snapshot.v1.json"), under: root)
    let sceneData = try boundedData(directory.appendingPathComponent("scene.blend"), under: root, maximum: 64 * 1024 * 1024)
    try require(scene == old["sceneID"] as? String && revision != old["revision"] as? String
        && manifest["revision"] as? String == revision && manifest["sceneID"] as? String == scene
        && manifest["parentRevision"] as? String == old["revision"] as? String
        && manifest["restoredFromRevision"] as? String == prior["revision"] as? String
        && digest(manifestData) == head["manifestSHA256"] as? String
        && digest(snapshotData) == prior["snapshotSHA256"] as? String
        && digest(sceneData) == prior["sceneSHA256"] as? String
        && manifest["snapshotSHA256"] as? String == digest(snapshotData)
        && manifest["sceneSHA256"] as? String == digest(sceneData),
        "The observed transition is not exactly the expected single Undo")
    let evidence = output.appendingPathComponent("canonical-after", isDirectory: true)
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
    for (name, data) in [("manifest.json", manifestData), ("snapshot.json", snapshotData), ("scene.blend", sceneData)] {
        try data.write(to: evidence.appendingPathComponent(name), options: .atomic)
    }
    return ["head": head, "manifest": manifest, "manifestSHA256": digest(manifestData),
        "snapshot": try object(snapshotData), "snapshotSHA256": digest(snapshotData),
        "sceneSHA256": digest(sceneData), "observedUptime": ProcessInfo.processInfo.systemUptime]
}

@main
private enum ScenePointerObserver {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            Darwin.exit(1)
        }
    }

    static func run() throws {
        if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--self-check-geometry" {
            try geometrySelfCheck(output: URL(fileURLWithPath: CommandLine.arguments[2]),
                source: CommandLine.arguments[3], executableHash: CommandLine.arguments[4], nonce: CommandLine.arguments[5])
            return
        }
        try require(CommandLine.arguments.count == 7, "Expected native/App/source/hash/output/done arguments")
        let native = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let executable = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        let source = CommandLine.arguments[3], executableHash = CommandLine.arguments[4]
        let output = URL(fileURLWithPath: CommandLine.arguments[5]).resolvingSymlinksInPath()
        let done = URL(fileURLWithPath: CommandLine.arguments[6])
        try require(AXIsProcessTrusted() && CGPreflightPostEventAccess(), "Native observation/input access unavailable")
        try require(digest(Data(contentsOf: executable)) == executableHash, "Observed executable bytes differ")
        signal(SIGTERM) { _ in stopping = true }; signal(SIGINT) { _ in stopping = true }
        let deadline = ProcessInfo.processInfo.systemUptime + 920
        let ready: [String: Any] = ["schema": "nexgenvideo/scene-pointer-observer-ready/1", "observerPID": getpid(),
            "sourceSHA": source, "executable": executable.path, "executableSHA256": executableHash,
            "AXTrusted": true, "postEventAccess": true]
        try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
            .write(to: output.appendingPathComponent("ready.json"), options: .atomic)
        let processFile = native.appendingPathComponent("process.json")
        while !FileManager.default.fileExists(atPath: processFile.path) {
            try require(!stopping && ProcessInfo.processInfo.systemUptime < deadline
                && !FileManager.default.fileExists(atPath: done.path), "App did not become observable")
            Thread.sleep(forTimeInterval: 0.1)
        }
        let process = try json(processFile)
        guard let pid = (process["pid"] as? NSNumber)?.int32Value, let original = identity(pid) else {
            throw ObservationError(message: "Owned App identity unavailable")
        }
        try require(process["sourceSHA"] as? String == source && process["mode"] as? String == "runtime"
            && original["executable"] as? String == executable.path, "Owned App attachment differs")
        let writer = Observer(output: output, deadline: deadline, pid: pid)
        try writer.write(["processIdentity": original, "sourceSHA": source, "executableSHA256": executableHash,
            "observerPID": getpid()], to: output.appendingPathComponent("attachment.json"))
        let progressFile = native.appendingPathComponent("spatial-scene-100.json")
        var progress: [String: Any] = [:]
        while true {
            try require(!stopping && ProcessInfo.processInfo.systemUptime < deadline, "Observation deadline reached")
            guard let current = identity(pid), sameIdentity(original, current) else {
                throw ObservationError(message: "App ended before the compact Undo observation")
            }
            if FileManager.default.fileExists(atPath: progressFile.path) {
                progress = try object(boundedData(progressFile, under: native))
                if progress["stage"] as? String == "native scene revision committed after undo" { break }
            }
            try require(!FileManager.default.fileExists(atPath: done.path), "Original supervision ended before target")
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let interactions = progress["interactions"] as? [[String: Any]] else {
            throw ObservationError(message: "Original pointer evidence missing")
        }
        let pointers = interactions.filter { $0["kind"] as? String == "pointer" && $0["id"] as? String == "spatial.undo" }
        let transforms = interactions.filter { ($0["evidence"] as? [String: Any])?["action"] as? String == "apply transform" }
        guard pointers.count == 1, transforms.count == 1,
              let window = pointers[0]["window"] as? Int,
              let expected = (transforms[0]["evidence"] as? [String: Any])?["canonical"] as? [String: Any] else {
            throw ObservationError(message: "Original Undo setup ambiguous")
        }
        try require(pointers[0]["localMonitorDownObserved"] as? Bool == true
            && pointers[0]["localMonitorUpObserved"] as? Bool == true, "Original synthetic event delivery missing")
        let frame = try finiteRect(pointers[0]["frame"])
        let before = try canonical(expected, output: output)
        let first = try snapshot(pid: pid, window: window, frame: frame, output: output)
        try writer.write(["progress": progress, "canonical": before, "AX": first,
            "historyTraceIsLive": false], to: output.appendingPathComponent("before.json"))
        try capture(window: window, at: output.appendingPathComponent("before.png"))
        let stableSince = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - stableSince < 5 {
            try check(original: original, before: before, progress: progressFile, native: native, done: done, deadline: deadline)
            Thread.sleep(forTimeInterval: 0.1)
        }
        let finalAX = try snapshot(pid: pid, window: window, frame: frame, output: output)
        try sameTarget(first, finalAX)
        try check(original: original, before: before, progress: progressFile, native: native, done: done, deadline: deadline)
        guard let point = geometryPair(finalAX["screenPoint"]) else {
            throw ObservationError(message: "Missing final pointer location")
        }
        try require(!CGEventSource.buttonState(.combinedSessionState, button: .left), "Mouse button already held")
        let position = CGPoint(x: point[0], y: point[1])
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: position, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left) else {
            throw ObservationError(message: "Could not create the complete mouse event sequence")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        try exclusive(["processIdentity": original, "canonical": before, "AX": finalAX,
            "stableSeconds": ProcessInfo.processInfo.systemUptime - stableSince, "oneShot": true,
            "diagnosticOnly": true], at: output.appendingPathComponent("INTERVENTION-STARTED.json"))
        var downPosted = false, upPosted = false
        defer { if downPosted && !upPosted { up.post(tap: .cghidEventTap) } }
        let moveAt = ProcessInfo.processInfo.systemUptime
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        let afterMove = try snapshot(pid: pid, window: window, frame: frame, output: output)
        try sameTarget(finalAX, afterMove)
        try check(original: original, before: before, progress: progressFile, native: native, done: done, deadline: deadline)
        let downAt = ProcessInfo.processInfo.systemUptime
        down.post(tap: .cghidEventTap); downPosted = true
        Thread.sleep(forTimeInterval: 0.03)
        let upAt = ProcessInfo.processInfo.systemUptime
        up.post(tap: .cghidEventTap); upPosted = true
        try writer.write(["point": point, "movePostedAt": moveAt, "downPostedAt": downAt, "upPostedAt": upAt,
            "afterMoveAX": afterMove,
            "eventDeliveryAcknowledged": false, "diagnosticOnly": true,
            "causality": "Combined elapsed-time, pointer-motion, hover and HID intervention only"],
            to: output.appendingPathComponent("posting.json"))
        while !FileManager.default.fileExists(atPath: done.path) {
            try require(!stopping && ProcessInfo.processInfo.systemUptime < deadline, "Post-intervention deadline reached")
            guard let current = identity(pid) else {
                try writer.write(["processIdentity": original, "observedUptime": ProcessInfo.processInfo.systemUptime,
                    "restorationObserved": false], to: output.appendingPathComponent("app-ended-before-restoration.json"))
                break
            }
            try require(sameIdentity(original, current), "Owned App identity changed after intervention")
            if FileManager.default.fileExists(atPath: progressFile.path) {
                let now = try object(boundedData(progressFile, under: native))
                let records = (now["interactions"] as? [[String: Any]] ?? []).compactMap { $0["evidence"] as? [String: Any] }
                let undos = records.filter { $0["action"] as? String == "undo" && $0["waitCompleted"] as? Bool == true }
                if undos.count == 1, let head = undos[0]["canonical"] as? [String: Any] {
                    let result = try restored(before, head: head, output: output)
                    try writer.write(["progress": now, "observedUptime": ProcessInfo.processInfo.systemUptime,
                        "restoration": result, "diagnosticOnly": true], to: output.appendingPathComponent("first-progress-after.json"))
                    try capture(window: window, at: output.appendingPathComponent("after.png"))
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try writer.write(["processIdentity": original, "finishedUptime": ProcessInfo.processInfo.systemUptime,
            "interventionPosted": true, "runtimeAccepted": false], to: output.appendingPathComponent("completion.json"))
    }

    static func check(original: [String: Any], before: [String: Any], progress: URL, native: URL, done: URL, deadline: Double) throws {
        guard let pid = (original["pid"] as? NSNumber)?.int32Value, let current = identity(pid) else {
            throw ObservationError(message: "Owned App disappeared")
        }
        try require(!stopping && ProcessInfo.processInfo.systemUptime < deadline
            && !FileManager.default.fileExists(atPath: done.path)
            && sameIdentity(original, current), "Owned App identity or active observation changed")
        let actual = try object(boundedData(progress, under: native))
        try require(actual["stage"] as? String == "native scene revision committed after undo",
            "Original scene progressed; do not intervene")
        guard let rootPath = before["root"] as? String, let expected = before["head"] as? [String: Any] else {
            throw ObservationError(message: "Missing canonical root")
        }
        let root = URL(fileURLWithPath: rootPath)
        let index = try object(boundedData(root.appendingPathComponent("index.v1.json"), under: root))
        let heads = (index["scenes"] as? [[String: Any]] ?? []).filter { $0["id"] as? String == expected["id"] as? String }
        try require(heads.count == 1 && NSDictionary(dictionary: heads[0]).isEqual(to: expected),
            "Canonical scene progressed; do not intervene")
    }
}

