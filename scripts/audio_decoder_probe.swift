import AVFoundation
import Darwin
import Foundation
import NexGenEngine

@main
struct AudioDecoderProbe {
    struct Measurement: Codable {
        let frames: Int
        let durationSeconds: Double
        let finalMarkerRMSE: Double?
        let exactDuration: Bool
        let finalMarkerPreserved: Bool

        init(_ samples: [Float]) {
            frames = samples.count
            durationSeconds = Double(samples.count) / 22_050
            exactDuration = samples.count == 94_815
            let marker = Int(4.295 * 22_050)..<Int(4.299 * 22_050)
            if samples.count >= marker.upperBound {
                let error = marker.reduce(0.0) { sum, index in
                    let expected = 0.5 * sin(2 * Double.pi * 1000 * (Double(index) / 22_050 - 4.292))
                    let difference = Double(samples[index]) - expected
                    return sum + difference * difference
                }
                finalMarkerRMSE = sqrt(error / Double(marker.count))
            } else {
                finalMarkerRMSE = nil
            }
            finalMarkerPreserved = finalMarkerRMSE.map { $0 < 0.08 } ?? false
        }
    }

    struct Conversion: Codable {
        let status: Int
        let outputFrames: Int
        let requestedInputFrames: [UInt32]
    }

    struct LegacyTrace: Codable {
        let sourceFrames: Int64
        let inputFrames: UInt32
        let leadingFrames: UInt32
        let trailingFrames: UInt32
        let calls: [Conversion]
        let firstPass: Measurement
        let drained: Measurement
        let reachedEndOfStream: Bool
    }

    struct Case: Codable {
        let sourceRate: Double
        let legacy: LegacyTrace?
        let actualDecoder: Measurement?
        let error: String?
    }

    struct Report: Codable {
        let os: String
        let cases: [Case]
        let actualDecoderPassed: Bool
    }

    struct Failure: Error { let message: String }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(message: "Expected a report path.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-decoder-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var cases: [Case] = []
        for rate in [44_100.0, 48_000.0] {
            var legacy: LegacyTrace?
            do {
                let url = directory.appendingPathComponent("marker-\(Int(rate)).wav")
                try writeMarker(to: url, rate: rate)
                legacy = try traceLegacy(url)
                let decoded = try AVFoundationAudioDecoder().decode(url)
                guard decoded.sampleRate == 22_050 else { throw Failure(message: "Unexpected decoder sample rate.") }
                cases.append(Case(sourceRate: rate, legacy: legacy, actualDecoder: Measurement(decoded.samples), error: nil))
            } catch {
                cases.append(Case(sourceRate: rate, legacy: legacy, actualDecoder: nil, error: String(describing: error)))
            }
        }
        let passed = cases.count == 2 && cases.allSatisfy {
            $0.actualDecoder?.exactDuration == true && $0.actualDecoder?.finalMarkerPreserved == true && $0.error == nil
        }
        let report = Report(os: ProcessInfo.processInfo.operatingSystemVersionString, cases: cases, actualDecoderPassed: passed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
        if !passed { exit(1) }
    }

    static func writeMarker(to url: URL, rate: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(4.3 * rate)),
              let samples = buffer.floatChannelData?[0] else { throw Failure(message: "Could not allocate source PCM.") }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let time = Double(index) / rate
            samples[index] = time >= 4.292 ? Float(0.5 * sin(2 * .pi * 1000 * (time - 4.292))) : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    // Preserve the previous single-call setup, then observe what subsequent drain calls return.
    static func traceLegacy(_ url: URL) throws -> LegacyTrace {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure(message: "Could not allocate the legacy converter.")
        }
        converter.downmix = true
        try file.read(into: input)
        let capacity = AVAudioFrameCount((Double(file.length) * 22_050 / source.sampleRate).rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failure(message: "Could not allocate legacy output.")
        }
        var fed = false
        var calls: [Conversion] = []
        var first: [Float] = []
        var drained: [Float] = []
        var reachedEnd = false
        for index in 0..<8 {
            output.frameLength = 0
            var requests: [UInt32] = []
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { count, inputStatus in
                requests.append(count)
                if fed { inputStatus.pointee = .endOfStream; return nil }
                fed = true
                inputStatus.pointee = .haveData
                return input
            }
            if let failure { throw failure }
            guard status != .error else { throw Failure(message: "Legacy converter failed.") }
            let samples = output.floatChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: Int(output.frameLength))) } ?? []
            if index == 0 { first = samples }
            drained.append(contentsOf: samples)
            calls.append(Conversion(status: status.rawValue, outputFrames: Int(output.frameLength), requestedInputFrames: requests))
            if status == .endOfStream { reachedEnd = true; break }
        }
        return LegacyTrace(sourceFrames: file.length, inputFrames: input.frameLength,
            leadingFrames: converter.primeInfo.leadingFrames, trailingFrames: converter.primeInfo.trailingFrames,
            calls: calls, firstPass: Measurement(first), drained: Measurement(drained), reachedEndOfStream: reachedEnd)
    }
}
