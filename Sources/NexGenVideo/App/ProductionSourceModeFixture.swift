import AVFoundation
import Foundation
import CoreGraphics
import ImageIO
import NexGenEngine
import UniformTypeIdentifiers

enum ProductionSourceModeFixture {
    nonisolated static func firstFramePNG(source: URL) async throws -> Data {
        try await Task.detached {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let decoded = try await generator.image(at: .zero)
            guard CMTimeCompare(decoded.actualTime, .zero) == 0 else { throw GateBlocked("The actual source decoder did not return its first frame.") }
            let bytes = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(encoder, decoded.image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
            return bytes as Data
        }.value
    }

    nonisolated static func makeMovingVideo(durationSeconds: Int = 8) async throws -> URL {
        guard (8...30).contains(durationSeconds) else { throw GateBlocked("Use an actual 8–30-second source for this bounded provider acceptance.") }
        return try await Task.detached(priority: .userInitiated) {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("Source modes moving video " + UUID().uuidString + ".mov")
            let writer = try AVAssetWriter(url: output, fileType: .mov)
            let width = 864, height = 486, fps = 30
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            guard writer.canAdd(input) else { throw GateBlocked("The actual video writer cannot accept the source stream.") }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            do {
                for frame in 0..<(durationSeconds * fps) {
                    var waits = 0
                    while !input.isReadyForMoreMediaData {
                        try Task.checkCancellation(); waits += 1
                        guard waits < 2_000, writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    try autoreleasepool {
                        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
                        var buffer: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw CocoaError(.fileWriteUnknown) }
                        CVPixelBufferLockBaseAddress(buffer, [])
                        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                        guard let data = CVPixelBufferGetBaseAddress(buffer), let image = CGContext(data: data,
                            width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw CocoaError(.fileWriteUnknown) }
                        image.setFillColor(CGColor(gray: 0.85, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: width, height: height))
                        image.setFillColor(CGColor(red: 0.75, green: 0.12, blue: 0.08, alpha: 1))
                        image.fillEllipse(in: CGRect(x: width / 3 + (frame * 3) % (width / 3), y: 200, width: 72, height: 72))
                        image.setFillColor(CGColor(gray: Double(frame % fps) / Double(fps), alpha: 1))
                        image.fill(CGRect(x: 0, y: 0, width: width, height: 24))
                        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
                            throw writer.error ?? CocoaError(.fileWriteUnknown)
                        }
                    }
                }
                input.markAsFinished()
                await writer.finishWriting()
                guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await RunwayVideoExtensionContract.requireSource(output, aspectRatio: "16:9")
                return output
            } catch {
                writer.cancelWriting()
                throw error
            }
        }.value
    }
}
