import AppKit
import ApplicationServices
import CoreFoundation
import Darwin
import Foundation
import MachO
import SwiftUI
import Testing

private typealias Query = NativeButtonAccessibility

// NGV_DIAGNOSTIC_FIXTURE

private func availabilityRequest(_ request: Query.Request) -> [String: Any] {
    ["PID": request.pid, "windowNumber": request.windowNumber,
        "windowFrame": request.windowFrame.evidence, "contentFrame": request.contentFrame.evidence]
}

private enum AvailabilityJSONPath: Codable, Equatable, Sendable {
    case key(String)
    case index(Int)
    case dictionaryEntry(Int)
}

private struct AvailabilityJSONFailure: Error, Codable, Sendable {
    let path: [AvailabilityJSONPath]
    let runtimeType: String
    let reason: String
}

private struct AvailabilityJSONErrorRecord: Codable, Sendable {
    let schema: String
    let stage: String
    let context: String
    let sourceSHA: String
    let PID: Int32
    let expectedProbe: Bool
    let failure: AvailabilityJSONFailure
}

@MainActor
private enum AvailabilityJSON {
    static func failure(_ value: Any) -> AvailabilityJSONFailure? {
        var ancestors: Set<ObjectIdentifier> = []
        var remaining = 2_000_000
        func visit(_ value: Any, path: [AvailabilityJSONPath], depth: Int) -> AvailabilityJSONFailure? {
            func fail(_ reason: String) -> AvailabilityJSONFailure {
                AvailabilityJSONFailure(path: path, runtimeType: String(reflecting: type(of: value)), reason: reason)
            }
            remaining -= 1
            guard remaining >= 0, depth <= 64 else { return fail("validation-budget") }
            if value is NSNull || value is String { return nil }
            if let number = value as? NSNumber {
                return number.doubleValue.isFinite ? nil : fail("nonfinite-number")
            }
            if let dictionary = value as? NSDictionary {
                let identity = ObjectIdentifier(dictionary)
                guard ancestors.insert(identity).inserted else { return fail("container-cycle") }
                defer { ancestors.remove(identity) }
                guard dictionary.count <= remaining else { return fail("validation-budget") }
                for (index, key) in dictionary.allKeys.enumerated() {
                    guard let name = key as? String else {
                        return AvailabilityJSONFailure(path: path + [.dictionaryEntry(index)],
                            runtimeType: String(reflecting: type(of: key)), reason: "non-string-key")
                    }
                    guard let item = dictionary.object(forKey: key) else { return fail("missing-dictionary-value") }
                    if let issue = visit(item, path: path + [.key(name)], depth: depth + 1) { return issue }
                }
                return nil
            }
            if let array = value as? NSArray {
                let identity = ObjectIdentifier(array)
                guard ancestors.insert(identity).inserted else { return fail("container-cycle") }
                defer { ancestors.remove(identity) }
                guard array.count <= remaining else { return fail("validation-budget") }
                for index in 0..<array.count {
                    if let issue = visit(array.object(at: index), path: path + [.index(index)], depth: depth + 1) { return issue }
                }
                return nil
            }
            return fail("unsupported-value")
        }
        return visit(value, path: [], depth: 0)
    }

    static func write(_ value: [String: Any], to file: URL, stage: String, expectedProbe: Bool = false) throws {
        let invalid = failure(value) ?? (JSONSerialization.isValidJSONObject(value) ? nil :
            AvailabilityJSONFailure(path: [], runtimeType: String(reflecting: type(of: value)), reason: "foundation-invalid-object"))
        if let invalid {
            let environment = ProcessInfo.processInfo.environment
            let record = AvailabilityJSONErrorRecord(schema: "nexgenvideo/availability-json-error/1", stage: stage,
                context: environment["NGV_AVAILABILITY_CONTEXT"] ?? "", sourceSHA: environment["GITHUB_SHA"] ?? "",
                PID: getpid(), expectedProbe: expectedProbe, failure: invalid)
            let data = try JSONEncoder().encode(record)
            try data.write(to: file.deletingLastPathComponent().appendingPathComponent(stage + ".serialization-error.json"),
                options: .withoutOverwriting)
            throw invalid
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: file, options: .withoutOverwriting)
    }
}

private func availabilityMode(_ mode: CFRunLoopMode?) -> Any {
    mode.map { String(describing: $0.rawValue) as Any } ?? NSNull()
}

@MainActor
private func persistAvailability(_ report: [String: Any], in folder: URL) throws {
    try AvailabilityJSON.write(report, to: folder.appendingPathComponent("observation.json"), stage: "final-report")
}

@MainActor
private func availabilityStage(_ name: String, report: [String: Any], folder: URL) throws {
    let stages = folder.appendingPathComponent("stages", isDirectory: true)
    try FileManager.default.createDirectory(at: stages, withIntermediateDirectories: true)
    let value: [String: Any] = ["schema": "nexgenvideo/availability-stage/1", "stage": name,
        "sourceSHA": ProcessInfo.processInfo.environment["GITHUB_SHA"]!, "PID": getpid(),
        "context": ProcessInfo.processInfo.environment["NGV_AVAILABILITY_CONTEXT"]!, "facts": report]
    try AvailabilityJSON.write(value, to: stages.appendingPathComponent(name + ".json"), stage: name)
}

private struct AvailabilityUnsupportedProbe { let value: Int }

@MainActor
private func availabilitySerializationProbes(folder: URL) throws {
    let probes = folder.appendingPathComponent("serialization-probes", isDirectory: true)
    try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: false)
    let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain())
    let valid: [String: Any] = ["mode": availabilityMode(mode), "absentMode": availabilityMode(nil)]
    let validFile = probes.appendingPathComponent("valid.json")
    try AvailabilityJSON.write(valid, to: validFile, stage: "valid", expectedProbe: true)
    let roundTrip = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: validFile)) as? [String: Any])
    #expect(roundTrip["absentMode"] is NSNull)
    if let mode { #expect(roundTrip["mode"] as? String == String(describing: mode.rawValue)) }
    else { #expect(roundTrip["mode"] is NSNull) }
    let unsupported = AvailabilityUnsupportedProbe(value: 1)
    let rejected: [String: Any] = ["nested": [["value": unsupported]]]
    let rejectedFile = probes.appendingPathComponent("rejected.json")
    do {
        try AvailabilityJSON.write(rejected, to: rejectedFile, stage: "rejected", expectedProbe: true)
        Issue.record("Unsupported value reached JSON writing")
    } catch let issue as AvailabilityJSONFailure {
        #expect(issue.path == [.key("nested"), .index(0), .key("value")])
        #expect(issue.reason == "unsupported-value")
        #expect(issue.runtimeType == String(reflecting: type(of: unsupported)))
        #expect(!FileManager.default.fileExists(atPath: rejectedFile.path))
        let record = try JSONDecoder().decode(AvailabilityJSONErrorRecord.self,
            from: Data(contentsOf: probes.appendingPathComponent("rejected.serialization-error.json")))
        #expect(record.expectedProbe && record.failure.path == issue.path && record.failure.runtimeType == issue.runtimeType)
    }
    let cycle = NSMutableArray()
    cycle.add(cycle)
    var deep: Any = "leaf"
    for _ in 0..<70 { deep = [deep] }
    let cases: [(String, Any, String)] = [("nonfinite", Double.infinity, "nonfinite-number"),
        ("non-string-key", NSDictionary(object: "value", forKey: NSNumber(value: 1)), "non-string-key"),
        ("cycle", cycle, "container-cycle"), ("depth", deep, "validation-budget")]
    for (name, value, reason) in cases {
        let destination = probes.appendingPathComponent(name + ".json")
        do {
            try AvailabilityJSON.write(["value": value], to: destination, stage: name, expectedProbe: true)
            Issue.record("Invalid JSON value reached writing: \(name)")
        } catch let issue as AvailabilityJSONFailure {
            #expect(issue.reason == reason && !issue.path.isEmpty && !issue.runtimeType.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let record = try JSONDecoder().decode(AvailabilityJSONErrorRecord.self,
                from: Data(contentsOf: probes.appendingPathComponent(name + ".serialization-error.json")))
            #expect(record.expectedProbe && record.failure.reason == reason && record.failure.path == issue.path)
        }
    }
}

private final class AvailabilityTraceState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    private var timeline: [[String: Any]] = []
    private var truncated = false

    func tick(_ name: String, activity: UInt = 0) {
        lock.lock()
        defer { lock.unlock() }
        values[name + "Count", default: 0] += 1
        values[name + "Last"] = ProcessInfo.processInfo.systemUptime
        values[name + "Main"] = Thread.isMainThread ? 1 : 0
        values["activity"] = Double(activity)
        if timeline.count < 12000 {
            timeline.append(["kind": name, "activity": activity,
                "at": ProcessInfo.processInfo.systemUptime, "mainThread": Thread.isMainThread,
                "mode": CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()).map { String(describing: $0.rawValue) } ?? ""])
        } else { truncated = true }
    }

    func snapshot() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return values.merging(["at": ProcessInfo.processInfo.systemUptime]) { _, new in new }
    }

    func evidence() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["timeline": timeline, "truncated": truncated]
    }
}

private func availabilityPause(milliseconds: Int = 5) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { continuation.resume() }
    }
}

@MainActor
private func availabilityCG(_ fixture: Fixture) async -> [String: Any] {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var samples: [[String: Any]] = []
    var previous: Query.Request?
    while ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
        let request = fixture.request
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = Query.ownCGWindows(entries, pid: getpid())
        let qualified = Query.uniqueCGWindow(windows, request: request)
        samples.append(["at": ProcessInfo.processInfo.systemUptime, "request": availabilityRequest(request),
            "windows": windows.map(\.evidence), "qualified": qualified])
        if qualified, previous == request { return ["qualified": true, "samples": samples] }
        previous = qualified ? request : nil
        await availabilityPause(milliseconds: 50)
    }
    return ["qualified": false, "samples": samples]
}

@MainActor
private final class AvailabilityTrace {
    let state: AvailabilityTraceState
    private let installedAt = ProcessInfo.processInfo.systemUptime
    private let observer: CFRunLoopObserver
    private let timer: any DispatchSourceTimer

    init() {
        let state = AvailabilityTraceState()
        self.state = state
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, activity in
            state.tick("runLoop", activity: activity.rawValue)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { state.tick("dispatch") }
        timer.resume()
    }

    func stop() {
        timer.cancel()
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }

    func evidence() -> [String: Any] {
        var value = state.evidence()
        value["installedAt"] = installedAt
        value["recordedAt"] = ProcessInfo.processInfo.systemUptime
        value["observerValid"] = CFRunLoopObserverIsValid(observer)
        value["observerOnMainCommonModes"] = CFRunLoopContainsObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        return value
    }
}

@MainActor
private func availabilityRaw(_ context: String, seconds: String, fixture: Fixture,
                             trace: AvailabilityTrace, folder: URL) async throws -> [String: Any] {
    let environment = ProcessInfo.processInfo.environment
    let process = Process()
    process.executableURL = URL(fileURLWithPath: environment["NGV_AVAILABILITY_RAW_CLIENT"]!)
    let request = fixture.request
    process.arguments = [String(getpid()), context, seconds, String(request.windowNumber),
        String(request.windowFrame.x), String(request.windowFrame.y),
        String(request.windowFrame.width), String(request.windowFrame.height)]
    process.standardInput = FileHandle.nullDevice
    let stem = context + "-" + seconds
    let stdout = folder.appendingPathComponent(stem + ".stdout")
    let stderr = folder.appendingPathComponent(stem + ".stderr")
    guard FileManager.default.createFile(atPath: stdout.path, contents: nil),
          FileManager.default.createFile(atPath: stderr.path, contents: nil) else {
        throw NSError(domain: "AvailabilityOutput", code: 1)
    }
    let output = try FileHandle(forWritingTo: stdout), errors = try FileHandle(forWritingTo: stderr)
    defer { try? output.close(); try? errors.close() }
    process.standardOutput = output
    process.standardError = errors
    let before = trace.state.snapshot()
    try process.run()
    let pid = process.processIdentifier
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
        await availabilityPause()
    }
    let cancelled = Task.isCancelled
    let timedOut = process.isRunning && !cancelled
    if process.isRunning { process.terminate() }
    let terminateDeadline = ProcessInfo.processInfo.systemUptime + 0.5
    while process.isRunning, ProcessInfo.processInfo.systemUptime < terminateDeadline {
        await availabilityPause()
    }
    if process.isRunning { Darwin.kill(pid, SIGKILL) }
    let reapDeadline = ProcessInfo.processInfo.systemUptime + 2
    while process.isRunning, ProcessInfo.processInfo.systemUptime < reapDeadline {
        await availabilityPause()
    }
    if !process.isRunning { process.waitUntilExit() }
    let result: [String: Any] = ["kind": "raw-after-peer", "primedContext": true, "context": context, "seconds": seconds,
        "PID": pid, "timedOut": timedOut, "reaped": !process.isRunning,
        "cancelled": cancelled,
        "exitStatus": process.isRunning ? NSNull() : process.terminationStatus as Any,
        "before": before, "after": trace.state.snapshot(), "target": availabilityRequest(fixture.request),
        "stdout": stdout.lastPathComponent, "stderr": stderr.lastPathComponent]
    if process.isRunning {
        withExtendedLifetime(fixture) { () -> Never in
            try? AvailabilityJSON.write(result, to: folder.appendingPathComponent(stem + ".process.json"), stage: stem)
            Darwin._exit(EXIT_FAILURE)
        }
    }
    try output.synchronize()
    try errors.synchronize()
    try AvailabilityJSON.write(result, to: folder.appendingPathComponent(stem + ".process.json"), stage: stem)
    guard !timedOut, !cancelled, process.terminationStatus == 0 else {
        throw NSError(domain: "AvailabilityRawLifetime", code: 1)
    }
    return result
}

@Test("Collect isolated test-host AX availability; no App acceptance")
@MainActor
func collectPeerAvailability() async throws {
    let environment = ProcessInfo.processInfo.environment
    let folder = URL(fileURLWithPath: environment["NGV_AVAILABILITY_OUTPUT"]!, isDirectory: true)
    let context = environment["NGV_AVAILABILITY_CONTEXT"]!
    try availabilitySerializationProbes(folder: folder)
    let trace = AvailabilityTrace()
    var report: [String: Any] = ["schema": "nexgenvideo/peer-availability-observation/1",
        "context": context, "PID": getpid(), "appAcceptance": false,
        "parentPID": getppid(), "startedWall": Date().timeIntervalSince1970,
        "originalFullAppImage": false, "diagnosticFunctionExecutions": 1]
    defer { trace.stop() }
    let initialPolicy = NSApp.activationPolicy().rawValue
    if context == "regular" { report["setRegularSucceeded"] = NSApp.setActivationPolicy(.regular) }
    report["launch"] = ["class": NSStringFromClass(type(of: NSApp!)),
        "initialPolicy": initialPolicy, "actualPolicy": NSApp.activationPolicy().rawValue,
        "isRunning": NSApp.isRunning, "isFinishedLaunching": NSRunningApplication.current.isFinishedLaunching,
        "bundleIdentifier": Bundle.main.bundleIdentifier.map { $0 as Any } ?? NSNull(),
        "bundleURL": Bundle.main.bundleURL.path,
        "runLoopMode": availabilityMode(CFRunLoopCopyCurrentMode(CFRunLoopGetMain()))]
    let fixture = Fixture()
    defer { fixture.close() }
    report["initialRequest"] = availabilityRequest(fixture.request)
    let image = try NativeAXPeer.Image.current()
    let owner = try NativeAXPeer.Identity.read(getpid())
    report["owner"] = ["PID": owner.pid, "start": owner.start, "executable": owner.executable]
    guard let header = _dyld_get_image_header(0) else { throw NSError(domain: "AvailabilityHostImage", code: 1) }
    let hostImage = try NativeAXPeer.Image.current(address: UnsafeRawPointer(header))
    guard hostImage.path == owner.executable else { throw NSError(domain: "AvailabilityHostImage", code: 2) }
    report["hostImage"] = ["path": hostImage.path, "uuid": hostImage.uuid, "SHA256": hostImage.SHA256]
    report["image"] = ["path": image.path, "uuid": image.uuid, "SHA256": image.SHA256]
    try availabilityStage("launch-owner", report: report, folder: folder)
    do {
        let cg = await availabilityCG(fixture)
        report["preAXCGStability"] = cg
        try availabilityStage("cg", report: report, folder: folder)
        guard cg["qualified"] as? Bool == true else { throw NSError(domain: "AvailabilityCGWindow", code: 1) }
        report["requestBefore"] = availabilityRequest(fixture.request)
        let before = trace.state.snapshot()
        let session: NativeAXPeer.Session
        do { session = try await NativeAXPeer.Session.prepare() }
        catch {
            withExtendedLifetime(fixture) { () -> Never in
                report["collectionCompleted"] = false
                report["collectionError"] = "Peer startup: " + String(describing: error)
                report["heartbeat"] = trace.evidence()
                report["finishedWall"] = Date().timeIntervalSince1970
                try? persistAvailability(report, in: folder)
                Darwin._exit(EXIT_FAILURE)
            }
        }
        let snapshot = await Query.read(fixture.request, using: session)
        let lifecycle = await session.close()
        report["firstPeer"] = ["before": before, "after": trace.state.snapshot(),
            "snapshot": snapshot.evidence, "lifecycle": lifecycle.evidence]
        report["peerHeartbeatScope"] = "Capture interval includes CG binding and does not isolate the AXWindows CF call."
        if !lifecycle.reaped {
            withExtendedLifetime(fixture) { () -> Never in
                report["collectionCompleted"] = false
                report["heartbeat"] = trace.evidence()
                report["finishedWall"] = Date().timeIntervalSince1970
                try? persistAvailability(report, in: folder)
                Darwin._exit(EXIT_FAILURE)
            }
        }
        try availabilityStage("first-peer", report: report, folder: folder)
        guard lifecycle.clean else { throw NSError(domain: "AvailabilityPeerLifetime", code: 1) }
        report["requestAfterPeer"] = availabilityRequest(fixture.request)
        var raw: [[String: Any]] = []
        for (thread, seconds) in [("background", "0.15"), ("main", "0.15"), ("background", "1")] {
            raw.append(try await availabilityRaw(thread, seconds: seconds, fixture: fixture, trace: trace, folder: folder))
            report["rawAfterPeer"] = raw
            try availabilityStage("raw-" + thread + "-" + seconds, report: report, folder: folder)
        }
        report["rawAfterPeer"] = raw
        report["collectionCompleted"] = true
        report["heartbeat"] = trace.evidence()
        report["finishedWall"] = Date().timeIntervalSince1970
        try persistAvailability(report, in: folder)
    } catch {
        report["collectionCompleted"] = false
        report["collectionError"] = String(describing: error)
        report["heartbeat"] = trace.evidence()
        report["finishedWall"] = Date().timeIntervalSince1970
        try? persistAvailability(report, in: folder)
        throw error
    }
}
