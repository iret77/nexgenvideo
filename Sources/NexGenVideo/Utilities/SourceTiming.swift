import AVFoundation
import Foundation

struct RationalSeconds: Sendable, Equatable {
    let numerator: Int64
    let denominator: Int64

    init?(numerator: Int64, denominator: Int64) {
        guard denominator > 0 else { return nil }
        let divisor = Self.greatestCommonDivisor(numerator.magnitude, UInt64(denominator))
        self.numerator = numerator / Int64(divisor)
        self.denominator = denominator / Int64(divisor)
    }

    init?(_ time: CMTime) {
        guard time.isNumeric, time.timescale > 0 else { return nil }
        self.init(numerator: time.value, denominator: Int64(time.timescale))
    }

    init?(seconds: Double, scale: Int64 = 1_000_000) {
        guard seconds.isFinite, seconds >= 0, scale > 0 else { return nil }
        let scaled = (seconds * Double(scale)).rounded()
        guard scaled.isFinite,
              scaled >= Double(Int64.min),
              scaled < Double(Int64.max) else { return nil }
        self.init(numerator: Int64(scaled), denominator: scale)
    }

    var seconds: Double { Double(numerator) / Double(denominator) }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var x = lhs
        var y = rhs
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return max(1, x)
    }
}

struct SourceTimecode: Sendable, Equatable {
    enum Origin: String, Codable, Sendable, Equatable {
        case container
        case sonyRTMD = "sony_rtmd"
        case bwf
    }

    struct Tick: Sendable, Equatable {
        let numerator: Int64
        let denominator: Int64
    }

    struct Compatibility: Sendable, Equatable {
        let isCompatible: Bool
        let reason: String
    }

    let frame: Int
    let quanta: Int
    let dropFrame: Bool
    let frameDuration: Double?
    let tick: Tick?
    let origin: Origin

    init(
        frame: Int,
        quanta: Int,
        dropFrame: Bool,
        frameDuration: Double? = nil,
        tick: Tick? = nil,
        origin: Origin = .container
    ) {
        self.frame = frame
        self.quanta = quanta
        self.dropFrame = dropFrame
        self.frameDuration = frameDuration
        self.tick = tick
        self.origin = origin
    }

    var secondsPerFrame: Double? {
        if let tick, tick.numerator > 0, tick.denominator > 0 {
            return Double(tick.numerator) / Double(tick.denominator)
        }
        if let frameDuration, frameDuration.isFinite, frameDuration > 0 { return frameDuration }
        guard quanta > 0 else { return nil }
        return 1 / Double(quanta)
    }

    var seconds: Double? {
        secondsPerFrame.map { Double(frame) * $0 }
    }

    var rationalSeconds: (numerator: Int64, denominator: Int64)? {
        guard quanta > 0 else { return nil }
        if let tick, tick.numerator > 0, tick.denominator > 0 {
            let (numerator, overflow) = Int64(frame).multipliedReportingOverflow(by: tick.numerator)
            guard !overflow else { return nil }
            return (numerator, tick.denominator)
        }
        return (Int64(frame), Int64(quanta))
    }

    func frames(atFPS fps: Int) -> Int {
        guard fps > 0, let seconds else { return 0 }
        let value = (seconds * Double(fps)).rounded()
        guard value.isFinite, value >= Double(Int.min), value < Double(Int.max) else { return 0 }
        return Int(value)
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
    var duration: RationalSeconds? = nil
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
        async let duration = readDuration(url: url)
        return await SourceTiming(timecode: timecode, captureDate: captureDate, duration: duration)
    }

    static func readDuration(url: URL) async -> RationalSeconds? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration >= .zero else { return nil }
        return RationalSeconds(duration)
    }

    static func readTimecode(url: URL) async -> SourceTimecode? {
        if let timecode = await readContainerTimecode(url: url) { return timecode }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return selectFallbackTimecode(from: data)
    }

    static func selectTimecode(container: SourceTimecode?, data: Data?) -> SourceTimecode? {
        container ?? data.flatMap(selectFallbackTimecode)
    }

    private static func selectFallbackTimecode(from data: Data) -> SourceTimecode? {
        rtmdTimecode(data) ?? bwfTimecode(data)
    }

    private static func readContainerTimecode(url: URL) async -> SourceTimecode? {
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
        let exactTick: SourceTimecode.Tick? = tick.isNumeric && tick.value > 0 && tick.timescale > 0
            ? .init(numerator: tick.value, denominator: Int64(tick.timescale))
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
            if presentationTime.isNumeric {
                guard let sampleOffset = sampleFrameOffset(
                    presentationTime: presentationTime,
                    frameDuration: tick
                ) else { return nil }
                let (adjusted, overflow) = signedFrame.subtractingReportingOverflow(sampleOffset)
                guard !overflow else { return nil }
                signedFrame = adjusted
            }
            return SourceTimecode(
                frame: signedFrame,
                quanta: quanta,
                dropFrame: dropFrame,
                frameDuration: exactDuration,
                tick: exactTick,
                origin: .container
            )
        }
        return nil
    }

    static func sampleFrameOffset(presentationTime: CMTime, frameDuration: CMTime) -> Int? {
        guard presentationTime.isNumeric,
              frameDuration.isNumeric,
              presentationTime.timescale > 0,
              frameDuration.timescale > 0,
              frameDuration.value > 0 else { return nil }

        var numeratorA = presentationTime.value
        var numeratorB = Int64(frameDuration.timescale)
        var denominatorA = Int64(presentationTime.timescale)
        var denominatorB = frameDuration.value

        let firstDivisor = greatestCommonDivisor(numeratorA.magnitude, UInt64(denominatorB))
        numeratorA /= Int64(firstDivisor)
        denominatorB /= Int64(firstDivisor)
        let secondDivisor = greatestCommonDivisor(UInt64(numeratorB), UInt64(denominatorA))
        numeratorB /= Int64(secondDivisor)
        denominatorA /= Int64(secondDivisor)

        let (numerator, numeratorOverflow) = numeratorA.multipliedReportingOverflow(by: numeratorB)
        let (denominator, denominatorOverflow) = denominatorA.multipliedReportingOverflow(by: denominatorB)
        guard !numeratorOverflow, !denominatorOverflow, denominator > 0 else { return nil }
        return roundedRatio(numerator: numerator, denominator: denominator)
    }

    private static func roundedRatio(numerator: Int64, denominator: Int64) -> Int? {
        guard denominator > 0 else { return nil }
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        guard remainder.magnitude >= (UInt64(denominator) + 1) / 2 else {
            return Int(exactly: quotient)
        }
        let (rounded, overflow) = quotient.addingReportingOverflow(numerator >= 0 ? 1 : -1)
        return overflow ? nil : Int(exactly: rounded)
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var x = lhs
        var y = rhs
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return max(1, x)
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

    static func rtmdTimecode(_ data: Data) -> SourceTimecode? {
        guard let moov = mp4Children(data, in: 0..<data.count).first(where: { $0.type == "moov" })?.body
        else { return nil }
        for track in mp4Children(data, in: moov) where track.type == "trak" {
            guard let media = mp4Child("mdia", data, in: track.body),
                  let mediaInfo = mp4Child("minf", data, in: media),
                  let sampleTable = mp4Child("stbl", data, in: mediaInfo),
                  let sampleDescription = mp4Child("stsd", data, in: sampleTable),
                  let descriptionIndex = rtmdDescriptionIndex(data, stsd: sampleDescription),
                  let sampleToChunk = mp4Child("stsc", data, in: sampleTable),
                  sampleToChunkUsesDescription(data, stsc: sampleToChunk, index: descriptionIndex),
                  let sampleSizeTable = mp4Child("stsz", data, in: sampleTable),
                  let sampleSize = firstSampleSize(data, stsz: sampleSizeTable),
                  sampleSize >= 18,
                  let mediaHeader = mp4Child("mdhd", data, in: media),
                  let timeToSample = mp4Child("stts", data, in: sampleTable),
                  let version = byte(data, mediaHeader.lowerBound),
                  let timescale = bigEndian(
                    data,
                    mediaHeader.lowerBound + (version == 1 ? 20 : 12),
                    count: 4
                  ),
                  let timingEntryCount = bigEndian(data, timeToSample.lowerBound + 4, count: 4),
                  let timedSampleCount = bigEndian(data, timeToSample.lowerBound + 8, count: 4),
                  let delta = bigEndian(data, timeToSample.lowerBound + 12, count: 4),
                  timingEntryCount > 0,
                  timedSampleCount > 0,
                  timescale > 0,
                  delta > 0 else { continue }

            let sampleOffset: Int?
            if let chunkOffsets = mp4Child("stco", data, in: sampleTable),
               let count = bigEndian(data, chunkOffsets.lowerBound + 4, count: 4), count > 0 {
                sampleOffset = bigEndian(data, chunkOffsets.lowerBound + 8, count: 4).flatMap(Int.init(exactly:))
            } else if let chunkOffsets = mp4Child("co64", data, in: sampleTable),
                      let count = bigEndian(data, chunkOffsets.lowerBound + 4, count: 4), count > 0 {
                sampleOffset = bigEndian(data, chunkOffsets.lowerBound + 8, count: 8).flatMap(Int.init(exactly:))
            } else {
                sampleOffset = nil
            }
            guard let offset = sampleOffset,
                  offset >= 0,
                  sampleSize <= data.count - offset,
                  let hours = byte(data, offset + 13),
                  let minutes = byte(data, offset + 14),
                  let seconds = byte(data, offset + 15),
                  let dropFlag = byte(data, offset + 16),
                  let frames = byte(data, offset + 17) else { continue }

            let quanta = Int((Double(timescale) / Double(delta)).rounded())
            guard quanta > 0,
                  hours < 24,
                  minutes < 60,
                  seconds < 60,
                  Int(frames) < quanta else { continue }
            let sonyNTSC = delta == 1_001 && timescale % 30_000 == 0 && quanta % 30 == 0
            let dropFrame = dropFlag != 0 || sonyNTSC
            guard !dropFrame || quanta % 30 == 0 else { continue }
            var frame = (Int(hours) * 3_600 + Int(minutes) * 60 + Int(seconds)) * quanta + Int(frames)
            if dropFrame {
                let dropped = quanta / 15
                let totalMinutes = Int(hours) * 60 + Int(minutes)
                frame -= dropped * (totalMinutes - totalMinutes / 10)
            }
            return SourceTimecode(
                frame: frame,
                quanta: quanta,
                dropFrame: dropFrame,
                frameDuration: Double(delta) / Double(timescale),
                tick: .init(numerator: Int64(delta), denominator: Int64(timescale)),
                origin: .sonyRTMD
            )
        }
        return nil
    }

    static func bwfTimecode(_ data: Data) -> SourceTimecode? {
        let magic = fourCC(data, 0)
        guard magic == "RIFF" || magic == "RF64", fourCC(data, 8) == "WAVE" else { return nil }
        let extendedSizes = magic == "RF64" ? rf64ChunkSizes(data) : [:]
        var extendedSizeIndex: [String: Int] = [:]
        var position = 12
        var sampleRate = 0
        var timeReference: UInt64?
        while position + 8 <= data.count {
            guard let type = fourCC(data, position),
                  let storedSize = littleEndian(data, position + 4, count: 4) else { break }
            let size: UInt64
            if storedSize == UInt64(UInt32.max) {
                let index = extendedSizeIndex[type, default: 0]
                guard let values = extendedSizes[type], index < values.count else { break }
                size = values[index]
                extendedSizeIndex[type] = index + 1
            } else {
                size = storedSize
            }
            guard let chunkSize = Int(exactly: size) else { break }
            let padding = chunkSize & 1
            guard chunkSize <= data.count - position - 8,
                  padding <= data.count - position - 8 - chunkSize,
                  position <= Int.max - 8 - chunkSize - padding else { break }
            if type == "fmt ", chunkSize >= 8 {
                sampleRate = Int(littleEndian(data, position + 12, count: 4) ?? 0)
            } else if type == "bext", chunkSize >= 346 {
                timeReference = littleEndian(data, position + 8 + 338, count: 8)
            }
            if sampleRate > 0, timeReference != nil { break }
            position += 8 + chunkSize + padding
        }
        guard let timeReference,
              sampleRate > 0,
              let frame = Int(exactly: timeReference) else { return nil }
        return SourceTimecode(
            frame: frame,
            quanta: sampleRate,
            dropFrame: false,
            frameDuration: 1 / Double(sampleRate),
            tick: .init(numerator: 1, denominator: Int64(sampleRate)),
            origin: .bwf
        )
    }

    private static func rtmdDescriptionIndex(_ data: Data, stsd: Range<Int>) -> UInt64? {
        guard let count = bigEndian(data, stsd.lowerBound + 4, count: 4), count > 0 else { return nil }
        var position = stsd.lowerBound + 8
        for index in 1...count {
            guard let sizeValue = bigEndian(data, position, count: 4),
                  let size = Int(exactly: sizeValue),
                  size >= 8,
                  position <= stsd.upperBound - size else { return nil }
            if fourCC(data, position + 4) == "rtmd" { return index }
            position += size
        }
        return nil
    }

    private static func sampleToChunkUsesDescription(
        _ data: Data,
        stsc: Range<Int>,
        index: UInt64
    ) -> Bool {
        guard let count = bigEndian(data, stsc.lowerBound + 4, count: 4), count > 0,
              let firstChunk = bigEndian(data, stsc.lowerBound + 8, count: 4),
              let samplesPerChunk = bigEndian(data, stsc.lowerBound + 12, count: 4),
              let description = bigEndian(data, stsc.lowerBound + 16, count: 4) else { return false }
        return firstChunk == 1 && samplesPerChunk > 0 && description == index
    }

    private static func firstSampleSize(_ data: Data, stsz: Range<Int>) -> Int? {
        guard let defaultSize = bigEndian(data, stsz.lowerBound + 4, count: 4),
              let sampleCount = bigEndian(data, stsz.lowerBound + 8, count: 4),
              sampleCount > 0 else { return nil }
        let size = defaultSize > 0
            ? defaultSize
            : bigEndian(data, stsz.lowerBound + 12, count: 4)
        return size.flatMap(Int.init(exactly:))
    }

    private static func rf64ChunkSizes(_ data: Data) -> [String: [UInt64]] {
        guard fourCC(data, 12) == "ds64",
              let storedSize = littleEndian(data, 16, count: 4),
              let size = Int(exactly: storedSize),
              size >= 28,
              size <= data.count - 20,
              let dataSize = littleEndian(data, 28, count: 8),
              let tableLength = littleEndian(data, 44, count: 4) else { return [:] }
        var result: [String: [UInt64]] = ["data": [dataSize]]
        var position = 48
        for _ in 0..<tableLength {
            guard position <= 20 + size - 12,
                  let type = fourCC(data, position),
                  let chunkSize = littleEndian(data, position + 4, count: 8) else { return [:] }
            result[type, default: []].append(chunkSize)
            position += 12
        }
        return result
    }

    private static func byte(_ data: Data, _ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    private static func bigEndian(_ data: Data, _ offset: Int, count: Int) -> UInt64? {
        guard offset >= 0, count > 0, count <= 8, offset + count <= data.count else { return nil }
        return (0..<count).reduce(0) { value, index in
            value << 8 | UInt64(data[data.startIndex + offset + index])
        }
    }

    private static func littleEndian(_ data: Data, _ offset: Int, count: Int) -> UInt64? {
        guard offset >= 0, count > 0, count <= 8, offset + count <= data.count else { return nil }
        return (0..<count).reversed().reduce(0) { value, index in
            value << 8 | UInt64(data[data.startIndex + offset + index])
        }
    }

    private static func fourCC(_ data: Data, _ offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let start = data.startIndex + offset
        return String(bytes: data[start..<start + 4], encoding: .ascii)
    }

    private static func mp4Children(
        _ data: Data,
        in range: Range<Int>
    ) -> [(type: String, body: Range<Int>)] {
        var result: [(String, Range<Int>)] = []
        var position = range.lowerBound
        while position + 8 <= range.upperBound {
            guard let size32 = bigEndian(data, position, count: 4),
                  let type = fourCC(data, position + 4) else { break }
            var bodyStart = position + 8
            let size: Int
            if size32 == 1 {
                guard let large = bigEndian(data, position + 8, count: 8),
                      let exactSize = Int(exactly: large) else { break }
                size = exactSize
                bodyStart = position + 16
            } else if size32 == 0 {
                size = range.upperBound - position
            } else {
                guard let exactSize = Int(exactly: size32) else { break }
                size = exactSize
            }
            guard size >= bodyStart - position,
                  position <= range.upperBound - size else { break }
            result.append((type, bodyStart..<(position + size)))
            position += size
        }
        return result
    }

    private static func mp4Child(_ type: String, _ data: Data, in range: Range<Int>) -> Range<Int>? {
        mp4Children(data, in: range).first(where: { $0.type == type })?.body
    }
}
