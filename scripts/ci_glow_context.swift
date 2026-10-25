import CoreImage
import CryptoKit
import Foundation
import Metal

enum ProbeError: Error { case unavailable(String) }

func required<T>(_ value: T?, _ name: String) throws -> T {
    guard let value else { throw ProbeError.unavailable(name) }
    return value
}

func required(_ condition: Bool, _ name: String) throws {
    guard condition else { throw ProbeError.unavailable(name) }
}

func record(_ value: [String: Any], to file: FileHandle) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    bytes.append(10)
    try file.write(contentsOf: bytes)
    try file.synchronize()
}

enum ProductionContext {
    // @production-context-initializer
}

final class MeasuredContext {
    let context: CIContext
    let round: Int
    let lane: Int
    let file: FileHandle
    let ready: DispatchSemaphore
    let go: DispatchSemaphore

    init(context: CIContext, round: Int, lane: Int, file: FileHandle,
         ready: DispatchSemaphore, go: DispatchSemaphore) {
        self.context = context
        self.round = round
        self.lane = lane
        self.file = file
        self.ready = ready
        self.go = go
    }

    func startTask(toRender image: CIImage, from rect: CGRect, to destination: CIRenderDestination,
                   at point: CGPoint) throws -> CIRenderTask {
        try record(["event": "ready", "round": round, "lane": lane, "pid": getpid()], to: file)
        ready.signal()
        guard go.wait(timeout: .now() + 30) == .success else { throw ProbeError.unavailable("barrier") }
        let begin = DispatchTime.now().uptimeNanoseconds
        let task = try context.startTask(toRender: image, from: rect, to: destination, at: point)
        let end = DispatchTime.now().uptimeNanoseconds
        try record(["event": "interval", "round": round, "lane": lane, "pid": getpid(),
                    "begin": begin, "end": end], to: file)
        return task
    }
}

struct GlowProbe {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let ctx: MeasuredContext
    private let n = 48

    init(arm: String, round: Int, lane: Int, file: FileHandle,
         ready: DispatchSemaphore, go: DispatchSemaphore) throws {
        let device = try required(MTLCreateSystemDefaultDevice(), "Metal device")
        let queue = try required(device.makeCommandQueue(), "command queue")
        self.device = device
        self.queue = queue
        let context = arm == "separate"
            ? CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            : ProductionContext.ciContext
        ctx = MeasuredContext(context: context, round: round, lane: lane, file: file, ready: ready, go: go)
    }

    func measure(lane: Int) throws -> (Double, Double, Double) {
        try pixel(glow(1, warmth: 0), n / 2 + (lane == 0 ? 5 : 8), n / 2)
    }

    // @production-fixture-functions
}

func render(arm: String, round: Int, lane: Int, folder: String,
            ready: DispatchSemaphore, go: DispatchSemaphore) throws {
    let file = try FileHandle(forWritingTo: URL(fileURLWithPath: folder).appendingPathComponent("lane-\(lane).jsonl"))
    defer { try? file.close() }
    try file.seekToEnd()
    let probe = try GlowProbe(arm: arm, round: round, lane: lane, file: file, ready: ready, go: go)
    let rgb = try probe.measure(lane: lane)
    guard rgb.0.isFinite, rgb.1.isFinite, rgb.2.isFinite, rgb.0 > 0, rgb.0 <= 1 else {
        throw ProbeError.unavailable("Actual Glow GPU readback")
    }
    try record(["event": "completed", "round": round, "lane": lane, "pid": getpid(),
                "red": rgb.0, "green": rgb.1, "blue": rgb.2], to: file)
}

guard [4, 5].contains(CommandLine.arguments.count), CommandLine.arguments[3] == "normal" else { exit(2) }
let folder = CommandLine.arguments[1]
let calibration = CommandLine.arguments[2] == "calibration"
guard calibration || CommandLine.arguments[2] == "measured" else { exit(2) }
let arm = CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : "separate"
guard ["separate", "shared"].contains(arm), !calibration || arm == "separate" else { exit(2) }
let environment = ProcessInfo.processInfo.environment
guard !environment.keys.contains(where: {
    $0.hasPrefix("MTL_") || $0.hasPrefix("Malloc") || $0.hasPrefix("NSZombie") ||
    $0.hasPrefix("OBJC_DEBUG_") || $0.hasPrefix("DYLD_") ||
    $0 == "NSDeallocateZombies" || $0 == "METAL_DEVICE_WRAPPER_TYPE"
}), environment["SWIFT_BACKTRACE"] == "enable=yes,interactive=no,demangle=yes,cache=no" else { exit(2) }
do {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let expected = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    guard Bundle.main.resourceURL?.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path else { exit(2) }
    let library = try Data(contentsOf: expected.appendingPathComponent("Glow.metallib"))
    let checksum = SHA256.hash(data: library).map { String(format: "%02x", $0) }.joined()
    let proof = try JSONSerialization.data(withJSONObject: ["metallibSHA256": checksum, "bytes": library.count])
    try proof.write(to: URL(fileURLWithPath: folder).appendingPathComponent("resources.json"))
} catch { exit(2) }
let start = DispatchTime.now().uptimeNanoseconds
var round = 0
repeat {
    let ready = DispatchSemaphore(value: 0)
    let go = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    let current = round
    for lane in 0..<2 {
        finished.enter()
        Thread.detachNewThread { [folder, current, lane, ready, go, finished, arm] in
            defer { finished.leave() }
            do {
                try autoreleasepool {
                    try render(arm: arm, round: current, lane: lane, folder: folder, ready: ready, go: go)
                }
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(2)
            }
        }
    }
    guard ready.wait(timeout: .now() + 30) == .success,
          ready.wait(timeout: .now() + 30) == .success else { exit(2) }
    go.signal(); go.signal()
    finished.wait()
    round += 1
} while calibration ? (round < 10000 && DispatchTime.now().uptimeNanoseconds - start < 30_000_000_000) : round < 4
print("completed \(round) rounds")
