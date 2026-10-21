import AppKit
import CoreFoundation
import Dispatch
import Darwin
import Foundation
import Testing

@Test("AppKit host continues after a default-mode CFRunLoop stop")
@MainActor
func appKitHostContinuesAfterDefaultModeStop() async throws {
    try #require(NSApplication.shared.isRunning)
    let resumedOnMain = await withCheckedContinuation {
        (continuation: CheckedContinuation<Bool, Never>) in
        CFRunLoopPerformBlock(CFRunLoopGetMain(), RunLoop.Mode.default.rawValue as CFString) {
            CFRunLoopStop(CFRunLoopGetMain())
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
                continuation.resume(returning: Thread.isMainThread)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    #expect(resumedOnMain)
    #expect(NSApplication.shared.isRunning)
}

@Test("AppKit host captures the original native exception and rejects occupied evidence",
      arguments: ["fresh", "existing", "symlink"])
@MainActor
func appKitHostCapturesNativeException(_ evidenceKind: String) async throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    try #require(executable.lastPathComponent == "NexGenVideoAppKitTestHost")
    let environment = ProcessInfo.processInfo.environment
    let base = environment["NGV_SWIFT_TEST_PROCESS_EVIDENCE"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory
    let folder = base.appendingPathComponent("appkit-exception-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let evidence = folder.appendingPathComponent("exception.jsonl")
    let target = folder.appendingPathComponent("symlink-target.jsonl")
    let sentinel = Data("occupied evidence\n".utf8)
    if evidenceKind == "existing" {
        try sentinel.write(to: evidence)
    } else if evidenceKind == "symlink" {
        try FileManager.default.createSymbolicLink(at: evidence, withDestinationURL: target)
    }
    let console = folder.appendingPathComponent("console.log")
    try Data().write(to: console)
    let output = try FileHandle(forWritingTo: console)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--ngv-exception-probe"]
    process.environment = environment.merging([
        "NGV_APPKIT_EXCEPTION_EVIDENCE": evidence.path,
        "NGV_APPKIT_TEST_BUNDLE": "/does-not-exist/probe-must-not-load-a-test-bundle",
        "NGV_APPKIT_TEST_EVENTS": folder.appendingPathComponent("events.jsonl").path,
        "NGV_APPKIT_TEST_RECEIPT": folder.appendingPathComponent("host-receipt.json").path
    ]) { _, probe in probe }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    try process.run()
    defer {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(60))
    while process.isRunning && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(!process.isRunning, "The owned native exception probe did not terminate")
    process.waitUntilExit()
    #expect(process.terminationStatus != 0)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("events.jsonl").path))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("host-receipt.json").path))
    if evidenceKind == "fresh" {
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: evidence)) as? [String: Any])
        #expect(record["name"] as? String == "NGVHostDiagnosticProbe")
        #expect(record["reason"] as? String == "Native AppKit exception capture probe")
        #expect(record["pid"] as? Int32 == process.processIdentifier)
        #expect(record["parentPID"] as? Int32 == getpid())
        #expect(record["sourceSHA"] as? String == (environment["GITHUB_SHA"] ?? ""))
        let symbols = try #require(record["throwStackSymbols"] as? [String])
        let addresses = try #require(record["throwStackReturnAddresses"] as? [NSNumber])
        #expect(symbols.contains { $0.contains("ngv_raiseProbeException") })
        #expect(!addresses.isEmpty)
        #expect(addresses.allSatisfy { $0.uint64Value > 0 })
    } else {
        #expect(try String(contentsOf: console, encoding: .utf8).contains("Cannot create the diagnostic AppKit application"))
        if evidenceKind == "existing" {
            #expect(try Data(contentsOf: evidence) == sentinel)
        } else {
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: evidence.path) == target.path)
        }
    }
}
