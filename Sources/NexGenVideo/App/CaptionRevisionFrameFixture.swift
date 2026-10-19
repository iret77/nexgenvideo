import AVFoundation
import CoreGraphics
import NexGenEngine

nonisolated enum CaptionRevisionFrameFixture {
    static func write(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? GateBlocked("Caption frame fixture writer failed.") }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<180 {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? GateBlocked("Caption frame fixture writer stopped.") }
                try await Task.sleep(for: .milliseconds(5))
            }
            try Task.checkCancellation()
            var pixel: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
                  let pixel else { throw GateBlocked("Caption frame fixture buffer is missing.") }
            CVPixelBufferLockBaseAddress(pixel, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 320, height: 180,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                CVPixelBufferUnlockBaseAddress(pixel, []); throw GateBlocked("Caption frame fixture cannot draw its actual pixels.")
            }
            context.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.05, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 80 + 120 * Double(frame) / 179, y: 65, width: 50, height: 50))
            let bits = [1, 0] + (0..<8).map { (frame >> $0) & 1 } + (0..<8).map { 1 - ((frame >> $0) & 1) }
            for (cell, bit) in bits.enumerated() {
                context.setFillColor(CGColor(gray: CGFloat(bit), alpha: 1))
                for y in [0, 148] { context.fill(CGRect(x: CGFloat(32 + cell * 14), y: CGFloat(y), width: 14, height: 32)) }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? GateBlocked("Caption frame fixture append failed.")
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 6, timescale: 1)); input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? GateBlocked("Caption frame fixture did not finish.") }
    }

    static func identity(rows: Data) throws -> Int {
        guard rows.count == 2 * 320 * 4 else { throw GateBlocked("The decoded frame identity rows have the wrong dimensions.") }
        let bytes = [UInt8](rows)
        let identities = (0..<2).compactMap { row -> Int? in
            var bits: [Int] = []
            for cell in 0..<18 {
                let values = (4..<10).flatMap { x in (0..<3).map { channel in Int(bytes[row * 1280 + (32 + cell * 14 + x) * 4 + channel]) } }
                let mean = Double(values.reduce(0, +)) / Double(values.count)
                if mean < 64 { bits.append(0) } else if mean > 191 { bits.append(1) } else { return nil }
            }
            guard bits[0] == 1, bits[1] == 0, (0..<8).allSatisfy({ bits[$0 + 2] + bits[$0 + 10] == 1 }) else { return nil }
            return (0..<8).reduce(0) { $0 | (bits[$1 + 2] << $1) }
        }
        guard identities.count == 2, let identity = identities.first, identities.allSatisfy({ $0 == identity }) else {
            throw GateBlocked("The actual frame index or its complementary bits could not be decoded.")
        }
        return identity
    }
}
