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

        init(_ samples: [Float], sampleRate: Double = 22_050) {
            frames = samples.count
            durationSeconds = Double(samples.count) / sampleRate
            exactDuration = samples.count == Int(4.3 * sampleRate)
            let marker = Int(4.295 * sampleRate)..<Int(4.299 * sampleRate)
            if samples.count >= marker.upperBound {
                let error = marker.reduce(0.0) { sum, index in
                    let expected = 0.5 * sin(2 * Double.pi * 1000 * (Double(index) / sampleRate - 4.292))
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
        let inputFramesBeforeConversion: UInt32
        let filePositionBeforeConversion: Int64
        let inputFrames: UInt32
        let filePositionAfterConversion: Int64
        let leadingFrames: UInt32
        let trailingFrames: UInt32
        let calls: [Conversion]
        let firstPass: Measurement
        let drained: Measurement
        let reachedEndOfStream: Bool
    }

    struct Case: Codable {
        let sourceRate: Double
        let writer: String
        var bytesBeforeWriterClose: Int?
        var disk: DiskTrace?
        var fullRequestRead: ReadTrace?
        var remainingLimitedRead: ReadTrace?
        let diagnosticErrors: [ErrorTrace]
        let legacy: LegacyTrace?
        let actualDecoder: Measurement?
        let error: ErrorTrace?
    }

    struct ErrorTrace: Codable {
        let stage: String
        let type: String
        let domain: String
        let code: Int
        let description: String

        init(_ error: Error, stage: String) {
            self.stage = stage
            type = String(reflecting: Swift.type(of: error))
            let native = error as NSError
            domain = native.domain
            code = native.code
            description = String(describing: error) + " | " + native.localizedDescription
        }
    }

    struct DiskTrace: Codable {
        let fileBytes: Int
        let riffDeclaredBytes: Int
        let encoding: Int
        let channels: Int
        let bitsPerSample: Int
        let blockAlign: Int
        let dataDeclaredBytes: Int
        let dataAvailableBytes: Int
        let pcm: Measurement
    }

    struct ReadStep: Codable {
        let index: Int
        let requested: UInt32
        let positionBefore: Int64
        let positionAfter: Int64
        let returnedFrames: UInt32
        let error: ErrorTrace?
    }

    struct ReadTrace: Codable {
        let fileFormat: String
        let processingFormat: String
        let declaredFrames: Int64
        let finalPosition: Int64
        let reads: Int
        let firstAndLastReads: [ReadStep]
        let pcm: Measurement
        let error: ErrorTrace?
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
        for rate in [22_050.0, 44_100.0, 48_000.0] {
          for writer in ["original", "explicitClose", "independentPCM"] {
            var legacy: LegacyTrace?
            var disk: DiskTrace?
            var fullRead: ReadTrace?
            var limitedRead: ReadTrace?
            var openBytes: Int?
            var diagnosticErrors: [ErrorTrace] = []
            var stage = "write \(writer)"
            do {
                let url = directory.appendingPathComponent("marker-\(writer)-\(Int(rate)).wav")
                if writer == "independentPCM" { try writePCM(to: url, rate: rate) }
                else { openBytes = try writeMarker(to: url, rate: rate, close: writer == "explicitClose") }
                stage = "inspect WAV bytes"
                do { disk = try inspectDisk(url) }
                catch { diagnosticErrors.append(ErrorTrace(error, stage: stage)) }
                stage = "trace full-size reads"
                do { fullRead = try traceReads(url, limitToRemaining: false) }
                catch { diagnosticErrors.append(ErrorTrace(error, stage: stage)) }
                stage = "trace remaining-limited reads"
                do { limitedRead = try traceReads(url, limitToRemaining: true) }
                catch { diagnosticErrors.append(ErrorTrace(error, stage: stage)) }
                if writer == "original" {
                    stage = "legacy conversion"
                    do { legacy = try traceLegacy(url) }
                    catch { diagnosticErrors.append(ErrorTrace(error, stage: stage)) }
                }
                stage = "actual decoder"
                let decoded = try AVFoundationAudioDecoder().decode(url)
                guard decoded.sampleRate == 22_050 else { throw Failure(message: "Unexpected decoder sample rate.") }
                cases.append(Case(sourceRate: rate, writer: writer, bytesBeforeWriterClose: openBytes, disk: disk,
                    fullRequestRead: fullRead, remainingLimitedRead: limitedRead,
                    diagnosticErrors: diagnosticErrors, legacy: legacy, actualDecoder: Measurement(decoded.samples), error: nil))
            } catch {
                cases.append(Case(sourceRate: rate, writer: writer, bytesBeforeWriterClose: openBytes, disk: disk,
                    fullRequestRead: fullRead, remainingLimitedRead: limitedRead,
                    diagnosticErrors: diagnosticErrors, legacy: legacy, actualDecoder: nil, error: ErrorTrace(error, stage: stage)))
            }
          }
        }
        let passed = cases.count == 9 && cases.allSatisfy {
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

    static func writeMarker(to url: URL, rate: Double, close: Bool) throws -> Int {
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
        let openBytes = try Data(contentsOf: url).count
        if close { file.close() }
        return openBytes
    }

    static func writePCM(to url: URL, rate: Double) throws {
        let frames = Int(4.3 * rate)
        var data = Data()
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        integer(UInt32(36 + frames * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(rate)); integer(UInt32(rate) * 2)
        integer(UInt16(2)); integer(UInt16(16))
        data.append(contentsOf: "data".utf8)
        integer(UInt32(frames * 2))
        for index in 0..<frames {
            let time = Double(index) / rate
            let sample = time >= 4.292 ? 0.5 * sin(2 * .pi * 1000 * (time - 4.292)) : 0
            integer(Int16((sample * 32767).rounded()))
        }
        try data.write(to: url, options: .atomic)
    }

    static func inspectDisk(_ url: URL) throws -> DiskTrace {
        let data = try Data(contentsOf: url)
        func number(_ offset: Int, _ bytes: Int) throws -> UInt32 {
            guard offset >= 0, offset + bytes <= data.count else { throw Failure(message: "Truncated WAV integer.") }
            return (0..<bytes).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        func text(_ offset: Int) -> String { String(decoding: data[offset..<offset + 4], as: UTF8.self) }
        guard data.count >= 12, text(0) == "RIFF", text(8) == "WAVE" else { throw Failure(message: "Missing WAV RIFF header.") }
        var format: (encoding: Int, channels: Int, rate: Double, align: Int, bits: Int)?
        var payload: (offset: Int, declared: Int, available: Int)?
        var cursor = 12
        while cursor + 8 <= data.count {
            let id = text(cursor)
            let size = Int(try number(cursor + 4, 4))
            let start = cursor + 8
            let available = min(size, data.count - start)
            if id == "fmt ", available >= 16 {
                let encoding = try number(start, 2)
                var sampleEncoding = encoding
                if encoding == 0xfffe && available >= 40 { sampleEncoding = try number(start + 24, 2) }
                format = (Int(sampleEncoding), Int(try number(start + 2, 2)), Double(try number(start + 4, 4)),
                    Int(try number(start + 12, 2)), Int(try number(start + 14, 2)))
            } else if id == "data" { payload = (start, size, available) }
            cursor = start + size + size % 2
        }
        guard let format, let payload, format.channels == 1, format.align > 0,
              (format.encoding == 3 && format.bits == 32) || (format.encoding == 1 && format.bits == 16) else {
            throw Failure(message: "Unexpected WAV encoding or missing PCM chunks.")
        }
        let samples = try (0..<payload.available / format.align).map { index -> Float in
            let offset = payload.offset + index * format.align
            if format.encoding == 3 { return Float(bitPattern: try number(offset, 4)) }
            return Float(Int16(bitPattern: UInt16(try number(offset, 2)))) / 32768
        }
        return DiskTrace(fileBytes: data.count, riffDeclaredBytes: Int(try number(4, 4)) + 8,
            encoding: format.encoding, channels: format.channels, bitsPerSample: format.bits, blockAlign: format.align,
            dataDeclaredBytes: payload.declared, dataAvailableBytes: payload.available,
            pcm: Measurement(samples, sampleRate: format.rate))
    }

    static func traceReads(_ url: URL, limitToRemaining: Bool) throws -> ReadTrace {
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw Failure(message: "Could not allocate diagnostic read buffer.")
        }
        var steps: [ReadStep] = []
        var samples: [Float] = []
        var failure: ErrorTrace?
        for index in 0..<128 {
            let before = file.framePosition
            let requested = limitToRemaining ? AVAudioFrameCount(min(4096, max(0, file.length - before))) : 4096
            if requested == 0 { break }
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: requested) }
            catch { failure = ErrorTrace(error, stage: "read \(index), request \(requested), position \(before)") }
            steps.append(ReadStep(index: index, requested: requested, positionBefore: before,
                positionAfter: file.framePosition, returnedFrames: buffer.frameLength, error: failure))
            if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            if failure != nil || buffer.frameLength == 0 { break }
        }
        let retained = steps.filter { $0.index < 2 || $0.index >= steps.count - 4 }
        return ReadTrace(fileFormat: String(describing: file.fileFormat), processingFormat: String(describing: file.processingFormat),
            declaredFrames: file.length, finalPosition: file.framePosition, reads: steps.count, firstAndLastReads: retained,
            pcm: Measurement(samples, sampleRate: file.processingFormat.sampleRate), error: failure)
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
        let inputFramesBeforeConversion = input.frameLength
        let filePositionBeforeConversion = file.framePosition
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
        return LegacyTrace(sourceFrames: file.length, inputFramesBeforeConversion: inputFramesBeforeConversion,
            filePositionBeforeConversion: filePositionBeforeConversion, inputFrames: input.frameLength,
            filePositionAfterConversion: file.framePosition,
            leadingFrames: converter.primeInfo.leadingFrames, trailingFrames: converter.primeInfo.trailingFrames,
            calls: calls, firstPass: Measurement(first), drained: Measurement(drained), reachedEndOfStream: reachedEnd)
    }
}
