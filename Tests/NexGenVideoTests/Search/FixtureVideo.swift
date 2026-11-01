import AVFoundation
import CoreVideo
import Foundation

/// Renders a small H.264 video of solid-color scenes for sampler/indexer tests.
enum FixtureVideo {
    struct Scene {
        let rgb: (UInt8, UInt8, UInt8)
        let seconds: Double
    }

    static func write(scenes: [Scene], fps: Int32 = 5, size: Int = 320, transform: CGAffineTransform = .identity,
                      presentation: (timescale: Int32, ticks: [Int64], end: Int64)? = nil,
                      fileType: AVFileType = .mp4) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).\(fileType == .mov ? "mov" : "mp4")")
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if presentation != nil { settings[AVVideoCompressionPropertiesKey] = [AVVideoAllowFrameReorderingKey: false] }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        if let presentation {
            writer.movieTimeScale = presentation.timescale
            input.mediaTimeScale = presentation.timescale
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frameIndex: Int64 = 0
        for scene in scenes {
            let buffer = try solidBuffer(rgb: scene.rgb, size: size, pool: adaptor.pixelBufferPool)
            for _ in 0..<Int(scene.seconds * Double(fps)) {
                let deadline = Date().addingTimeInterval(10)
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing, Date() < deadline else { throw NSError(domain: "FixtureVideo", code: 3) }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let time: CMTime
                if let presentation {
                    guard presentation.ticks.indices.contains(Int(frameIndex)) else { throw NSError(domain: "FixtureVideo", code: 4) }
                    time = CMTime(value: presentation.ticks[Int(frameIndex)], timescale: presentation.timescale)
                } else { time = CMTime(value: frameIndex, timescale: fps) }
                guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? NSError(domain: "FixtureVideo", code: 5) }
                frameIndex += 1
            }
        }
        if let presentation {
            guard Int(frameIndex) == presentation.ticks.count else { throw NSError(domain: "FixtureVideo", code: 6) }
            writer.endSession(atSourceTime: CMTime(value: presentation.end, timescale: presentation.timescale))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "FixtureVideo", code: 1)
        }
        return url
    }

    private static func solidBuffer(rgb: (UInt8, UInt8, UInt8), size: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { throw NSError(domain: "FixtureVideo", code: 2) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<size {
            for x in 0..<size {
                let p = base + y * bytesPerRow + x * 4
                p[0] = rgb.2; p[1] = rgb.1; p[2] = rgb.0; p[3] = 255
            }
        }
        return buffer
    }
}
