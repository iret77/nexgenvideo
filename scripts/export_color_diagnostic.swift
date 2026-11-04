import AVFoundation
import CoreImage
import Foundation

@main
struct ExportColorDiagnostic {
    struct Snapshot {
        let metadata: [String: Any]
        let raw: [UInt8]
        let rec709: [UInt8]
    }

    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure("Expected the bound evidence directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = try await snapshot(root.appendingPathComponent("GUI acceptance source.mp4"), label: "source", root: root)
        let exported = try await snapshot(root.appendingPathComponent("user-export.mp4"), label: "export", root: root)
        let result: [String: Any] = [
            "schema": "nexgenvideo/export-color-diagnostic/1",
            "classification": "native-decoder-color-observation-only", "appAcceptance": false,
            "source": source.metadata, "export": exported.metadata,
            "nativeUnmanagedRGBMAE": try error(source.raw, exported.raw),
            "nativeCommonRec709RGBMAE": try error(source.rec709, exported.rec709),
            "existingAcceptanceThreshold": 15,
            "commonOutputColorSpace": "kCGColorSpaceITUR_709",
            "appBuilds": 0, "appLaunches": 0, "nativeAppUnitRuns": 0,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("native-color.json"))
    }

    @MainActor
    static func snapshot(_ url: URL, label: String, root: URL) async throws -> Snapshot {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1 else { throw Failure("Expected exactly one video track") }
        let descriptions = try await tracks[0].load(.formatDescriptions)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else { throw Failure("The native reader rejected BGRA output") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(value: 30, timescale: 30), duration: CMTime(value: 1, timescale: 30))
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw Failure("The native reader did not produce the bound sample: \(String(describing: reader.error))")
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let image = CIImage(cvPixelBuffer: buffer)
        var metadata: [String: Any] = [
            "filename": url.lastPathComponent, "sampleTimeSeconds": pts,
            "dimensions": [CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)],
            "pixelFormat": CVPixelBufferGetPixelFormatType(buffer),
            "formatDescriptionExtensions": descriptions.map { String(describing: CMFormatDescriptionGetExtensions($0)) },
            "propagatingAttachments": String(describing: CVBufferCopyAttachments(buffer, .shouldPropagate)),
            "nonpropagatingAttachments": String(describing: CVBufferCopyAttachments(buffer, .shouldNotPropagate)),
            "effectiveCIColorSpace": String(describing: image.colorSpace), "hasEffectiveCIColorSpace": image.colorSpace != nil
        ]
        let observation = root.appendingPathComponent("native-" + label + "-observation.json")
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: observation)
        guard abs(pts - 1) < 0.000001, CVPixelBufferGetWidth(buffer) == 320,
              CVPixelBufferGetHeight(buffer) == 180 else { throw Failure("The native sample time or dimensions differ") }
        guard image.colorSpace != nil, let rec709 = CGColorSpace(name: CGColorSpace.itur_709),
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            throw Failure("The native sample has no effective color space")
        }
        let rawImage = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let rawContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let managedContext = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: rec709])
        let raw = render(rawImage, context: rawContext, colorSpace: nil)
        let managed = render(image, context: managedContext, colorSpace: rec709)
        metadata["unmanagedRGBSamples"] = samples(raw)
        metadata["commonRec709RGBSamples"] = samples(managed)
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: observation)
        reader.cancelReading()
        return Snapshot(metadata: metadata, raw: raw, rec709: managed)
    }

    static func render(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace?) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        bytes.withUnsafeMutableBytes { storage in
            context.render(image, toBitmap: storage.baseAddress!, rowBytes: 320 * 4,
                           bounds: CGRect(x: 0, y: 0, width: 320, height: 180), format: .RGBA8, colorSpace: colorSpace)
        }
        return bytes
    }

    static func samples(_ bytes: [UInt8]) -> [[UInt8]] {
        [30, 90, 150, 210, 290].map { x in Array(bytes[((60 * 320 + x) * 4)..<((60 * 320 + x) * 4 + 3)]) }
    }

    static func error(_ left: [UInt8], _ right: [UInt8]) throws -> Double {
        guard left.count == 320 * 180 * 4, left.count == right.count else { throw Failure("Incomplete native RGB data") }
        var total = 0
        for i in stride(from: 0, to: left.count, by: 4) {
            for channel in 0..<3 { total += abs(Int(left[i + channel]) - Int(right[i + channel])) }
        }
        return Double(total) / Double(320 * 180 * 3)
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
