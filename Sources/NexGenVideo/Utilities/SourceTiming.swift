import AVFoundation
import Foundation

struct SourceTimecode: Sendable, Equatable {
    struct Compatibility: Sendable, Equatable {
        let isCompatible: Bool
        let reason: String
    }

    let frame: Int
    let quanta: Int
    let dropFrame: Bool
    let frameDuration: Double?

    init(frame: Int, quanta: Int, dropFrame: Bool, frameDuration: Double? = nil) {
        self.frame = frame
        self.quanta = quanta
        self.dropFrame = dropFrame
        self.frameDuration = frameDuration
    }

    var secondsPerFrame: Double? {
        if let frameDuration, frameDuration.isFinite, frameDuration > 0 { return frameDuration }
        guard quanta > 0 else { return nil }
        return 1 / Double(quanta)
    }

    var seconds: Double? {
        secondsPerFrame.map { Double(frame) * $0 }
    }

    func compatibility(with other: SourceTimecode) -> Compatibility {
        guard quanta > 0, other.quanta > 0,
              let lhsDuration = secondsPerFrame,
              let rhsDuration = other.secondsPerFrame else {
            return Compatibility(isCompatible: false, reason: "Source timecode has an invalid frame duration.")
        }
        guard quanta == other.quanta else {
            return Compatibility(
                isCompatible: false,
                reason: "Source timecode rates differ (\(quanta) and \(other.quanta) frame quanta)."
            )
        }
        guard dropFrame == other.dropFrame else {
            return Compatibility(isCompatible: false, reason: "Source timecode drop-frame modes differ.")
        }
        let relativeDifference = abs(lhsDuration - rhsDuration) / max(lhsDuration, rhsDuration)
        guard relativeDifference <= 0.000_001 else {
            return Compatibility(isCompatible: false, reason: "Source timecode frame durations differ.")
        }
        let format = dropFrame ? "DF" : "NDF"
        return Compatibility(
            isCompatible: true,
            reason: "Matching \(quanta)-frame \(format) source timecode."
        )
    }
}

struct SourceTiming: Sendable, Equatable {
    var timecode: SourceTimecode?
    var captureDate: Date?
}

enum SourceTimingReader {
    static func cache(mediaRefs: Set<String>, urls: [String: URL]) async -> [String: SourceTiming] {
        await withTaskGroup(of: (String, SourceTiming).self) { group in
            for mediaRef in mediaRefs {
                guard let url = urls[mediaRef] else { continue }
                group.addTask { (mediaRef, await read(url: url)) }
            }
            var result: [String: SourceTiming] = [:]
            for await (mediaRef, timing) in group where timing != SourceTiming() {
                result[mediaRef] = timing
            }
            return result
        }
    }

    static func read(url: URL) async -> SourceTiming {
        async let timecode = readTimecode(url: url)
        async let captureDate = readCaptureDate(url: url)
        return await SourceTiming(timecode: timecode, captureDate: captureDate)
    }

    static func readTimecode(url: URL) async -> SourceTimecode? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let format = try? await track.load(.formatDescriptions).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(format))
        let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(format)
        let dropFrame = flags & UInt32(kCMTimeCodeFlag_DropFrame) != 0
        guard quanta > 0 else { return nil }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let byteCount: Int
        switch subtype {
        case kCMTimeCodeFormatType_TimeCode32:
            byteCount = MemoryLayout<UInt32>.size
        case kCMTimeCodeFormatType_TimeCode64:
            byteCount = MemoryLayout<UInt64>.size
        default:
            return nil
        }

        let tick = CMTimeCodeFormatDescriptionGetFrameDuration(format)
        let exactDuration = tick.isNumeric && tick.seconds.isFinite && tick.seconds > 0
            ? tick.seconds
            : nil
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = [UInt8](repeating: 0, count: byteCount)
            let copyStatus = bytes.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: buffer.baseAddress!
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else { return nil }
            guard var signedFrame = decodeTimecodeFrame(
                bytes: bytes,
                is64Bit: subtype == kCMTimeCodeFormatType_TimeCode64
            ) else { return nil }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            if let exactDuration,
               presentationTime.isNumeric,
               presentationTime.seconds.isFinite {
                let sampleOffset = (presentationTime.seconds / exactDuration).rounded()
                guard sampleOffset.isFinite,
                      sampleOffset >= Double(Int.min),
                      sampleOffset < Double(Int.max) else { return nil }
                let (adjusted, overflow) = signedFrame.subtractingReportingOverflow(Int(sampleOffset))
                guard !overflow else { return nil }
                signedFrame = adjusted
            }
            return SourceTimecode(
                frame: signedFrame,
                quanta: quanta,
                dropFrame: dropFrame,
                frameDuration: exactDuration
            )
        }
        return nil
    }

    static func decodeTimecodeFrame(bytes: [UInt8], is64Bit: Bool) -> Int? {
        let required = is64Bit ? MemoryLayout<UInt64>.size : MemoryLayout<UInt32>.size
        guard bytes.count >= required else { return nil }
        var encoded: UInt64 = 0
        for byte in bytes.prefix(required) { encoded = encoded << 8 | UInt64(byte) }
        if is64Bit { return Int(exactly: Int64(bitPattern: encoded)) }
        return Int(Int32(bitPattern: UInt32(truncatingIfNeeded: encoded)))
    }

    static func readCaptureDate(url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata),
              let item = AVMetadataItem.metadataItems(
                  from: items,
                  filteredByIdentifier: .quickTimeMetadataCreationDate
              ).first else { return nil }
        if let date = try? await item.load(.dateValue) { return date }
        guard let string = try? await item.load(.stringValue) else { return nil }
        return parseQuickTimeDate(string)
    }

    static func parseQuickTimeDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: string) { return date }

        let compactZone = DateFormatter()
        compactZone.locale = Locale(identifier: "en_US_POSIX")
        compactZone.calendar = Calendar(identifier: .gregorian)
        compactZone.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZ"
        return compactZone.date(from: string)
    }
}
