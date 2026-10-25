import CoreImage
import Foundation
import Metal

enum ProbeError: Error { case unavailable(String) }

func required<T>(_ value: T?, _ name: String) throws -> T {
    guard let value else { throw ProbeError.unavailable(name) }
    return value
}

func record(_ value: [String: Any], to file: FileHandle) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    bytes.append(10)
    try file.write(contentsOf: bytes)
    try file.synchronize()
}

func render(round: Int, lane: Int, folder: String, ready: DispatchSemaphore,
            go: DispatchSemaphore) throws {
    let n = 48
    let url = URL(fileURLWithPath: folder).appendingPathComponent("lane-\(lane).jsonl")
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.seekToEnd()
    let device = try required(MTLCreateSystemDefaultDevice(), "Metal device")
    let queue = try required(device.makeCommandQueue(), "command queue")
    let context = CIContext(mtlDevice: device,
        options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    var pixels = [UInt8](repeating: 0, count: n * n * 4)
    for y in (n / 2 - 3)..<(n / 2 + 3) {
        for x in (n / 2 - 3)..<(n / 2 + 3) {
            let i = (y * n + x) * 4
            pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255; pixels[i + 3] = 255
        }
    }
    let bitmap = try required(CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
        bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "bitmap")
    let storage = try required(bitmap.data, "bitmap storage")
    try pixels.withUnsafeBytes { bytes in
        storage.copyMemory(from: try required(bytes.baseAddress, "pixels"), byteCount: bytes.count)
    }
    let original = CIImage(cgImage: try required(bitmap.makeImage(), "spot"), options: [.colorSpace: NSNull()])
    let intermediate = original.applyingFilter("CIColorMatrix", parameters: [
        "inputGVector": CIVector(x: 0, y: 0.9, z: 0, w: 0)])
    let blurred = intermediate.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6])
        .cropped(to: original.extent)
    let image = blurred.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: original])
    let bytesPerRow = n * 4 * MemoryLayout<Float>.stride
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
        width: n, height: n, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let texture = try required(device.makeTexture(descriptor: descriptor), "texture")
    let readback = try required(device.makeBuffer(length: bytesPerRow * n, options: .storageModeShared), "readback")
    let command = try required(queue.makeCommandBuffer(), "command buffer")
    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
    destination.colorSpace = nil
    destination.blendKernel = nil
    destination.alphaMode = .premultiplied
    destination.isFlipped = false
    destination.isClamped = false
    destination.isDithered = false
    try record(["event": "ready", "round": round, "lane": lane, "pid": getpid()], to: file)
    ready.signal()
    guard go.wait(timeout: .now() + 30) == .success else { throw ProbeError.unavailable("barrier") }
    let begin = DispatchTime.now().uptimeNanoseconds
    let task = try context.startTask(toRender: image,
        from: CGRect(x: 0, y: 0, width: n, height: n), to: destination, at: .zero)
    let end = DispatchTime.now().uptimeNanoseconds
    try record(["event": "interval", "round": round, "lane": lane, "pid": getpid(),
                "begin": begin, "end": end], to: file)
    let blit = try required(command.makeBlitCommandEncoder(), "blit")
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: n, height: n, depth: 1), to: readback, destinationOffset: 0,
        destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: 0)
    blit.endEncoding()
    try withExtendedLifetime((device, queue, context, image, texture, readback, command, destination, task)) {
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw ProbeError.unavailable("command completion") }
        _ = try task.waitUntilCompleted()
        let values = readback.contents().bindMemory(to: Float.self, capacity: n * n * 4)
        let red = values[(n / 2 * n + n / 2 + 5) * 4]
        guard red.isFinite, red > 0 else { throw ProbeError.unavailable("blur readback") }
        try record(["event": "completed", "round": round, "lane": lane, "pid": getpid(), "red": red], to: file)
    }
}

guard [4, 5].contains(CommandLine.arguments.count) else { exit(2) }
let folder = CommandLine.arguments[1]
let calibration = CommandLine.arguments[2] == "calibration"
guard calibration || CommandLine.arguments[2] == "measured" else { exit(2) }
let scribble = CommandLine.arguments[3] == "scribble"
guard scribble || CommandLine.arguments[3] == "normal" else { exit(2) }
let environment = ProcessInfo.processInfo.environment
guard !environment.keys.contains(where: {
    $0.hasPrefix("MTL_") || ($0.hasPrefix("Malloc") && !(scribble && ["MallocScribble", "MallocDebugReport"].contains($0))) || $0.hasPrefix("NSZombie") ||
    $0.hasPrefix("OBJC_DEBUG_") || $0.hasPrefix("DYLD_") ||
    $0 == "NSDeallocateZombies" || $0 == "METAL_DEVICE_WRAPPER_TYPE"
}), environment["SWIFT_BACKTRACE"] == "enable=yes,interactive=no,demangle=yes,cache=no" else { exit(2) }
guard !scribble || (environment["MallocScribble"] == "1" && environment["MallocDebugReport"] == "stderr") else { exit(2) }
let arm = CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : "cold"
guard ["cold", "warm"].contains(arm), arm != "warm" || (!calibration && !scribble) else { exit(2) }
if arm == "warm" {
    let warmFolder = URL(fileURLWithPath: folder).appendingPathComponent("warmup")
    do {
        try FileManager.default.createDirectory(at: warmFolder, withIntermediateDirectories: false)
        guard FileManager.default.createFile(atPath: warmFolder.appendingPathComponent("lane-0.jsonl").path,
                                             contents: Data()) else { exit(2) }
    } catch { exit(2) }
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        do {
            try autoreleasepool {
                let go = DispatchSemaphore(value: 0)
                go.signal()
                try render(round: -1, lane: 0, folder: warmFolder.path,
                           ready: DispatchSemaphore(value: 0), go: go)
            }
        } catch {
            FileHandle.standardError.write(Data("warmup failed: \(error)\n".utf8))
            exit(2)
        }
        finished.signal()
    }
    guard finished.wait(timeout: .now() + 30) == .success else { exit(2) }
}
let start = DispatchTime.now().uptimeNanoseconds
var round = 0
repeat {
    let ready = DispatchSemaphore(value: 0)
    let go = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    let current = round
    for lane in 0..<2 {
        finished.enter()
        Thread.detachNewThread { [folder, current, lane, ready, go, finished] in
            defer { finished.leave() }
            do {
                try autoreleasepool { try render(round: current, lane: lane, folder: folder, ready: ready, go: go) }
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
