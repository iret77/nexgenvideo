import AppKit
import AVFoundation
import ImageIO
import NexGenEngine
import UniformTypeIdentifiers

@MainActor
enum PostproductionRenderedEvidence {
    struct CompositionSnapshot: Codable, Equatable {
        let width: Int
        let height: Int
        let fps: Int
        let layers: [Clip]
    }

    struct Raster {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        var composition: CompositionSnapshot? = nil
    }

    static func sources(directory: URL) throws -> [URL] {
        var urls: [URL] = []
        for foreground in [true, false] {
            var bytes: [UInt8] = []
            for y in 0..<180 {
                for x in 0..<320 {
                    let rgb: [UInt8]
                    if !foreground { rgb = [0, 0, 255] }
                    else if x < 80 { rgb = [0, 255, 0] }
                    else if x < 160 { rgb = [255, 0, 0] }
                    else {
                        let noise = (x * 31 + y * 17) % 29 - 14
                        let value = 0.12 + 0.80 * Double(y) / 179
                        let color = NSColor(calibratedHue: CGFloat(x - 160) / 160, saturation: 0.7, brightness: CGFloat(value), alpha: 1).usingColorSpace(.sRGB)!
                        rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { UInt8(max(0, min(255, Int($0 * 255) + noise))) }
                    }
                    bytes += rgb + [255]
                }
            }
            let label = foreground ? "Foreground" : "Background"
            let raster = Raster(width: 320, height: 180, pixels: bytes)
            let file = directory.appendingPathComponent(label + ".png")
            try png(raster).write(to: file)
            try Data(bytes).write(to: directory.appendingPathComponent(label + ".rgba"))
            urls.append(file)
        }
        return urls
    }

    static func capture(editor: EditorViewModel, baseline: Raster? = nil, matching: Raster? = nil) async throws -> Raster {
        let expectedTimeline = editor.timeline
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var reason = "The current player composition has not produced the expected pixels."
        while ProcessInfo.processInfo.systemUptime < deadline {
            do {
                guard editor.timeline == expectedTimeline, editor.currentFrame == 0, editor.activePreviewTab == .timeline,
                      let item = editor.videoEngine?.player.currentItem, let composition = item.videoComposition else { throw failed("The actual timeline player is not ready.") }
                let snapshot = try compositionSnapshot(composition, timeline: expectedTimeline)
                let generator = AVAssetImageGenerator(asset: item.asset)
                generator.videoComposition = composition
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                let result = try await generator.image(at: .zero)
                let image = result.image
                guard result.actualTime == .zero, image.width == 320, image.height == 180,
                      editor.timeline == expectedTimeline, editor.currentFrame == 0,
                      editor.videoEngine?.player.currentItem === item, let currentComposition = item.videoComposition,
                      try compositionSnapshot(currentComposition, timeline: expectedTimeline) == snapshot else {
                    throw failed("The actual rendered frame or composition changed during capture.")
                }
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { storage in
                    guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: storage.baseAddress,
                        width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                        throw failed("The actual composition cannot be decoded as RGBA.")
                    }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                let raster = Raster(width: image.width, height: image.height, pixels: pixels, composition: snapshot)
                if let baseline, PostproductionControlsAcceptance.difference(baseline.pixels, pixels) <= 0.1 {
                    reason = "The native effect left the actual player composition unchanged."
                } else if let matching, PostproductionControlsAcceptance.difference(matching.pixels, pixels) >= 0.01 {
                    reason = "Undo did not restore the actual player composition."
                } else { return raster }
            } catch { reason = error.localizedDescription }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw failed(reason)
    }

    static func retain(_ raster: Raster, timeline: Timeline, label: String, directory: URL) throws -> [String: String] {
        guard let composition = raster.composition else { throw failed("The actual composition snapshot is missing.") }
        let files = [label + ".rgba": Data(raster.pixels), label + ".png": try png(raster), label + ".json": try PlanningWriterIO.json(timeline),
            label + ".composition.json": try PlanningWriterIO.json(composition)]
        for (name, bytes) in files { try bytes.write(to: directory.appendingPathComponent(name), options: .atomic) }
        return files.mapValues { FileDigest.sha256(of: $0) }
    }

    private static func compositionSnapshot(_ composition: AVVideoComposition, timeline: Timeline) throws -> CompositionSnapshot {
        guard timeline.tracks.count == 2, timeline.tracks.allSatisfy({ !$0.hidden && $0.clips.count == 1 && $0.clips[0].mediaType == .image }),
              composition.renderSize == CGSize(width: timeline.width, height: timeline.height),
              composition.frameDuration == CMTime(value: 1, timescale: CMTimeScale(timeline.fps)),
              composition.instructions.count == 1, let instruction = composition.instructions.first as? CompositorInstruction,
              instruction.timeRange.start == .zero, instruction.timeRange.duration > .zero,
              instruction.renderSize == composition.renderSize, instruction.fps == timeline.fps else {
            throw failed("The player does not contain the actual two-image fixture composition.")
        }
        let clips = timeline.tracks.reversed().flatMap(\.clips)
        guard instruction.layers.map(\.clip) == clips else { throw failed("The player still contains an intermediate effect or another timeline snapshot.") }
        return CompositionSnapshot(width: timeline.width, height: timeline.height, fps: instruction.fps, layers: instruction.layers.map(\.clip))
    }

    static func requireForeground(_ raster: Raster, directory: URL) throws {
        let foreground = [UInt8](try Data(contentsOf: directory.appendingPathComponent("Foreground.rgba")))
        guard PostproductionControlsAcceptance.difference(foreground, raster.pixels) <= 3 else {
            throw failed("The baseline does not show the foreground source in its original orientation.")
        }
    }

    static func requireChroma(_ raster: Raster, directory: URL) throws {
        let foreground = [UInt8](try Data(contentsOf: directory.appendingPathComponent("Foreground.rgba")))
        let background = [UInt8](try Data(contentsOf: directory.appendingPathComponent("Background.rgba")))
        guard raster.width == 320, raster.height == 180, foreground.count == 320 * 180 * 4,
              background.count == foreground.count, raster.pixels.count == foreground.count else { throw failed("The actual Chroma comparison dimensions differ.") }
        for y in 10..<170 {
            for x in Array(10..<70) + Array(90..<150) {
                let offset = (y * 320 + x) * 4, expected = x < 80 ? background : foreground
                guard raster.pixels[offset + 3] == 255,
                      (0..<3).allSatisfy({ abs(Int(raster.pixels[offset + $0]) - Int(expected[offset + $0])) <= 5 }) else {
                    throw failed("Chroma must reveal the blue lower image and preserve the separate red region.")
                }
            }
        }
    }

    private static func png(_ raster: Raster) throws -> Data {
        guard let provider = CGDataProvider(data: Data(raster.pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: raster.width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw failed("Cannot retain the actual decoded raster.") }
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw failed("Cannot retain the actual frame PNG.") }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw failed("The actual frame PNG is incomplete.") }
        return data as Data
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native rendered adjustments: " + message) }
}
