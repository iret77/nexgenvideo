import AVFoundation
import CryptoKit
import Darwin
import Foundation

@main
struct ClaySampleTimingProbe {
    struct Time: Encodable {
        let value: Int64
        let timescale: Int32
        let flags: UInt32
        let epoch: Int64

        init(_ time: CMTime) {
            value = time.value
            timescale = time.timescale
            flags = time.flags.rawValue
            epoch = time.epoch
        }
    }

    struct Sample: Encodable {
        let ordinal: Int
        let mediaSamplesBefore: Int
        let sampleCount: Int
        let rawPresentation: Time
        let outputPresentation: Time
        let rawDuration: Time
        let outputDuration: Time
        let formatPresent: Bool
        let dataPresent: Bool
        let imagePresent: Bool
        let description: String

        init(_ sample: CMSampleBuffer, ordinal: Int, mediaSamplesBefore: Int) {
            self.ordinal = ordinal
            self.mediaSamplesBefore = mediaSamplesBefore
            sampleCount = CMSampleBufferGetNumSamples(sample)
            rawPresentation = Time(CMSampleBufferGetPresentationTimeStamp(sample))
            outputPresentation = Time(CMSampleBufferGetOutputPresentationTimeStamp(sample))
            rawDuration = Time(CMSampleBufferGetDuration(sample))
            outputDuration = Time(CMSampleBufferGetOutputDuration(sample))
            formatPresent = CMSampleBufferGetFormatDescription(sample) != nil
            dataPresent = CMSampleBufferGetDataBuffer(sample) != nil
            imagePresent = CMSampleBufferGetImageBuffer(sample) != nil
            description = String(describing: sample)
        }
    }

    struct Stream: Encodable {
        let mode: String
        var samples: [Sample] = []
        var mediaSamples = 0
        var readerStatus: Int?
        var completed = false
        var error: String?
    }

    struct Report: Encodable {
        let schema = "nexgenvideo/clay-sample-timing-diagnostic/1"
        let diagnosticOnly = true
        let sourceSHA = ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? ""
        let runID = ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? ""
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        var fixtureSHA256: String?
        var duration: Time?
        var trackStart: Time?
        var trackDuration: Time?
        var streams: [Stream] = []
        var completed = false
        var error: String?
    }

    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var report = Report()
        do {
            try persist(report, in: directory)
            let fixture = try await FixtureVideo.write(scenes: [.init(rgb: (30, 100, 50), seconds: 1)], fps: 3, size: 64,
                presentation: (timescale: 24_000, ticks: [0, 1_001, 2_002], end: 2_503), fileType: .mov)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let movie = directory.appendingPathComponent("fixture.mov")
            try FileManager.default.copyItem(at: fixture, to: movie)
            report.fixtureSHA256 = SHA256.hash(data: try Data(contentsOf: movie)).map { String(format: "%02x", $0) }.joined()
            let asset = AVURLAsset(url: movie)
            report.duration = Time(try await asset.load(.duration))
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No video track") }
            let range = try await track.load(.timeRange)
            report.trackStart = Time(range.start)
            report.trackDuration = Time(range.duration)
            try persist(report, in: directory)
            let settings: [[String: Any]?] = [nil, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]]
            for outputSettings in settings {
                let index = report.streams.count
                report.streams.append(Stream(mode: outputSettings == nil ? "compressed" : "decoded"))
                var reader: AVAssetReader?
                do {
                    let active = try AVAssetReader(asset: asset)
                    reader = active
                    defer { if active.status == .reading { active.cancelReading() } }
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                    output.alwaysCopiesSampleData = false
                    guard active.canAdd(output) else { throw failure("Cannot add reader output") }
                    active.add(output)
                    guard active.startReading() else { throw active.error ?? failure("Cannot start reader") }
                    while let sample = output.copyNextSampleBuffer() {
                        guard report.streams[index].samples.count < 16 else { throw failure("Sample capture exceeded 16 buffers") }
                        let record = Sample(sample, ordinal: report.streams[index].samples.count,
                            mediaSamplesBefore: report.streams[index].mediaSamples)
                        report.streams[index].samples.append(record)
                        report.streams[index].mediaSamples += record.sampleCount
                        try persist(report, in: directory)
                    }
                    report.streams[index].completed = active.status == .completed && report.streams[index].mediaSamples == 3
                    guard report.streams[index].completed else { throw active.error ?? failure("Reader did not finish all three samples") }
                } catch {
                    report.streams[index].error = String(describing: error)
                }
                report.streams[index].readerStatus = reader?.status.rawValue
                try persist(report, in: directory)
            }
            report.completed = report.streams.count == 2 && report.streams.allSatisfy(\.completed)
        } catch {
            report.error = String(describing: error)
        }
        do {
            try persist(report, in: directory)
        } catch {
            FileHandle.standardError.write(Data("Could not persist the timing diagnostic: \(error)\n".utf8))
            exit(1)
        }
        exit(report.completed ? 0 : 1)
    }

    private static func persist(_ report: Report, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("samples.json"), options: .atomic)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ClaySampleTimingProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
