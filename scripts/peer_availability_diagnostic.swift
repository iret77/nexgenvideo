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

private func persistAvailability(_ report: [String: Any], in folder: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try data.write(to: folder.appendingPathComponent("observation.json"), options: .withoutOverwriting)
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
                "mode": CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()).map { String(describing: $0) } ?? ""])
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
            if let receipt = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                try? receipt.write(to: folder.appendingPathComponent(stem + ".process.json"), options: .withoutOverwriting)
            }
            Darwin._exit(EXIT_FAILURE)
        }
    }
    try output.synchronize()
    try errors.synchronize()
    let receipt = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    try receipt.write(to: folder.appendingPathComponent(stem + ".process.json"), options: .withoutOverwriting)
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
        "bundleIdentifier": Bundle.main.bundleIdentifier as Any? ?? NSNull(),
        "bundleURL": Bundle.main.bundleURL.path,
        "runLoopMode": CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) as Any? ?? NSNull()]
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
    do {
        let cg = await availabilityCG(fixture)
        report["preAXCGStability"] = cg
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
        guard lifecycle.clean else { throw NSError(domain: "AvailabilityPeerLifetime", code: 1) }
        report["requestAfterPeer"] = availabilityRequest(fixture.request)
        var raw: [[String: Any]] = []
        for (thread, seconds) in [("background", "0.15"), ("main", "0.15"), ("background", "1")] {
            raw.append(try await availabilityRaw(thread, seconds: seconds, fixture: fixture, trace: trace, folder: folder))
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
