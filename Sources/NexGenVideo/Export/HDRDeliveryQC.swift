import AVFoundation
import CoreMedia
import NexGenEngine

enum HDRDeliveryQC {
    static func probe(
        outputURL: URL,
        spec: DeliverySpecV1
    ) async throws -> DeliveryHDRQCV1 {
        let outputSHA256 = try FileDigest.sha256(of: outputURL)
        let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        let parsed = try ISOBMFFHDRInspector.inspect(data)
        let container = DeliveryHDRContainerQCV1(
            fileType: parsed.fileType,
            sampleEntry: parsed.sampleEntry,
            hasHEVCConfiguration: parsed.hasHEVCConfiguration,
            profileIDC: parsed.profileIDC,
            lumaBitDepth: parsed.lumaBitDepth,
            chromaBitDepth: parsed.chromaBitDepth,
            colorPrimariesIndex: parsed.colorPrimariesIndex,
            transferFunctionIndex: parsed.transferFunctionIndex,
            matrixIndex: parsed.matrixIndex,
            fullRangeFlag: parsed.fullRangeFlag
        )

        let asset = AVURLAsset(url: outputURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let description = try await videoTrack.load(.formatDescriptions).first else {
            throw ToolError("HDR QC could not read the exported video track.")
        }
        let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary
        let track = DeliveryHDRTrackQCV1(
            codec: fourCC(CMFormatDescriptionGetMediaSubType(description)),
            bitsPerComponent: number(
                extensions[kCMFormatDescriptionExtension_BitsPerComponent]
            ) ?? parsed.lumaBitDepth,
            colorPrimaries: colorPrimaries(
                extensions[kCMFormatDescriptionExtension_ColorPrimaries]
            ),
            transferFunction: transferFunction(
                extensions[kCMFormatDescriptionExtension_TransferFunction]
            ),
            yCbCrMatrix: matrix(
                extensions[kCMFormatDescriptionExtension_YCbCrMatrix]
            ),
            fullRange: (extensions[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool) ?? false
        )

        let duration = try await asset.load(.duration)
        let frameDuration = CMTime(
            value: CMTimeValue(spec.fpsDenominator),
            timescale: CMTimeScale(spec.fpsNumerator)
        )
        let lastTime = CMTimeCompare(duration, frameDuration) > 0
            ? CMTimeSubtract(duration, frameDuration)
            : .zero
        let times = [
            CMTime.zero,
            CMTimeMultiplyByRatio(duration, multiplier: 3, divisor: 8),
            CMTimeMultiplyByRatio(duration, multiplier: 5, divisor: 8),
            lastTime,
        ]
        var frames: [DeliveryHDRReferenceFrameQCV1] = []
        for (index, time) in times.enumerated() {
            frames.append(try await referenceFrame(
                asset: asset,
                track: videoTrack,
                time: time,
                frameDuration: frameDuration,
                index: index
            ))
        }

        let result = DeliveryHDRQCV1(
            outputSHA256: outputSHA256,
            conversion: HDRVideoExporter.conversionID,
            track: track,
            container: container,
            referenceFrames: frames,
            passed: true
        )
        try DeliveryValidatorV1.validate(hdrQC: result, outputSHA256: outputSHA256)
        return result
    }

    private static func referenceFrame(
        asset: AVAsset,
        track: AVAssetTrack,
        time: CMTime,
        frameDuration: CMTime,
        index: Int
    ) async throws -> DeliveryHDRReferenceFrameQCV1 {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            AVVideoAllowWideColorKey: true,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ToolError("HDR QC cannot decode a 10-bit reference frame.")
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: time,
            duration: CMTimeMultiply(frameDuration, multiplier: 2)
        )
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw ToolError("HDR QC could not read reference frame \(index + 1).")
        }
        defer { reader.cancelReading() }
        let measurement = try measure(buffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        return .init(
            index: index,
            presentationTimeValue: pts.value,
            presentationTimeTimescale: pts.timescale,
            pixelFormat: fourCC(CVPixelBufferGetPixelFormatType(buffer)),
            lumaMinimumCode: measurement.minimum,
            lumaMaximumCode: measurement.maximum,
            outOfRangePixelCount: measurement.outOfRange,
            pixelCount: measurement.pixelCount,
            chromaCbMeanCode: measurement.chromaCbMean,
            chromaCrMeanCode: measurement.chromaCrMean,
            pixelSHA256: measurement.sha256
        )
    }

    private static func measure(
        _ buffer: CVPixelBuffer
    ) throws -> (
        minimum: Int,
        maximum: Int,
        outOfRange: Int,
        pixelCount: Int,
        chromaCbMean: Double,
        chromaCrMean: Double,
        sha256: String
    ) {
        guard CVPixelBufferGetPixelFormatType(buffer) == pixelFormat,
              CVPixelBufferIsPlanar(buffer),
              CVPixelBufferGetPlaneCount(buffer) == 2 else {
            throw ToolError("HDR QC received a non-Main10 reference frame.")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), width > 0, height > 0 else {
            throw ToolError("HDR QC received an empty reference frame.")
        }
        var minimum = Int.max
        var maximum = Int.min
        var outside = 0
        var digestBytes = Data(capacity: width * height * 2)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            digestBytes.append(row.assumingMemoryBound(to: UInt8.self), count: width * 2)
            let values = row.assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                let code = Int(values[x] >> 6)
                minimum = min(minimum, code)
                maximum = max(maximum, code)
                if !(64...940).contains(code) { outside += 1 }
            }
        }
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        guard let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
              chromaWidth > 0, chromaHeight > 0 else {
            throw ToolError("HDR QC received an empty chroma plane.")
        }
        var cbTotal: UInt64 = 0
        var crTotal: UInt64 = 0
        for y in 0..<chromaHeight {
            let row = chroma.advanced(by: y * chromaBytesPerRow)
            digestBytes.append(
                row.assumingMemoryBound(to: UInt8.self),
                count: chromaWidth * 4
            )
            let values = row.assumingMemoryBound(to: UInt16.self)
            for x in 0..<chromaWidth {
                cbTotal += UInt64(values[x * 2] >> 6)
                crTotal += UInt64(values[x * 2 + 1] >> 6)
            }
        }
        let chromaPixelCount = Double(chromaWidth * chromaHeight)
        return (
            minimum,
            maximum,
            outside,
            width * height,
            Double(cbTotal) / chromaPixelCount,
            Double(crTotal) / chromaPixelCount,
            FileDigest.sha256(of: digestBytes)
        )
    }

    private static var pixelFormat: OSType {
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    private static func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func colorPrimaries(_ value: Any?) -> String {
        (value as? String) == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
            ? "bt2020" : "unknown"
    }

    private static func transferFunction(_ value: Any?) -> String {
        (value as? String) == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            ? "hlg" : "unknown"
    }

    private static func matrix(_ value: Any?) -> String {
        (value as? String) == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String)
            ? "bt2020-ncl" : "unknown"
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}

enum ISOBMFFHDRInspector {
    struct Metadata: Equatable {
        let fileType: String
        let sampleEntry: String
        let hasHEVCConfiguration: Bool
        let profileIDC: Int
        let lumaBitDepth: Int
        let chromaBitDepth: Int
        let colorPrimariesIndex: Int
        let transferFunctionIndex: Int
        let matrixIndex: Int
        let fullRangeFlag: Bool?
    }

    private struct Box {
        let type: String
        let payload: Range<Int>
    }

    static func inspect(_ data: Data) throws -> Metadata {
        let top = try boxes(in: data, range: data.startIndex..<data.endIndex)
        guard let ftyp = top.first(where: { $0.type == "ftyp" }),
              let moov = top.first(where: { $0.type == "moov" }) else {
            throw ToolError("HDR QC found no QuickTime container metadata.")
        }
        let brands = try fileTypeBrands(data, box: ftyp)
        let fileType = brands.contains("qt  ") ? "mov" : "unknown"

        for trak in try boxes(in: data, range: moov.payload) where trak.type == "trak" {
            guard let mdia = try child("mdia", in: trak, data: data),
                  let minf = try child("minf", in: mdia, data: data),
                  let stbl = try child("stbl", in: minf, data: data),
                  let stsd = try child("stsd", in: stbl, data: data) else { continue }
            let entryStart = stsd.payload.lowerBound + 8
            guard entryStart <= stsd.payload.upperBound else { continue }
            for entry in try boxes(in: data, range: entryStart..<stsd.payload.upperBound)
                where entry.type == "hvc1" {
                let childrenStart = entry.payload.lowerBound + 78
                guard childrenStart <= entry.payload.upperBound else { continue }
                let children = try boxes(
                    in: data,
                    range: childrenStart..<entry.payload.upperBound
                )
                guard let configuration = children.first(where: { $0.type == "hvcC" }),
                      let color = children.first(where: { $0.type == "colr" }) else { continue }
                let hevc = try hevcConfiguration(data, box: configuration)
                let cicp = try colorInformation(data, box: color)
                return .init(
                    fileType: fileType,
                    sampleEntry: entry.type,
                    hasHEVCConfiguration: true,
                    profileIDC: hevc.profileIDC,
                    lumaBitDepth: hevc.lumaBitDepth,
                    chromaBitDepth: hevc.chromaBitDepth,
                    colorPrimariesIndex: cicp.primaries,
                    transferFunctionIndex: cicp.transfer,
                    matrixIndex: cicp.matrix,
                    fullRangeFlag: cicp.fullRange
                )
            }
        }
        throw ToolError("HDR QC found no HEVC Main10 sample description.")
    }

    private static func boxes(in data: Data, range: Range<Int>) throws -> [Box] {
        var result: [Box] = []
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let shortSize = Int(try uint32(data, at: cursor))
            let type = try string(data, at: cursor + 4, count: 4)
            var header = 8
            let size: Int
            if shortSize == 1 {
                guard cursor + 16 <= range.upperBound else {
                    throw ToolError("HDR QC found a truncated extended atom header.")
                }
                let extended = try uint64(data, at: cursor + 8)
                guard extended <= UInt64(Int.max) else {
                    throw ToolError("HDR QC found an oversized atom.")
                }
                size = Int(extended)
                header = 16
            } else if shortSize == 0 {
                size = range.upperBound - cursor
            } else {
                size = shortSize
            }
            guard size >= header, cursor + size <= range.upperBound else {
                throw ToolError("HDR QC found a malformed \(type) atom.")
            }
            result.append(.init(
                type: type,
                payload: (cursor + header)..<(cursor + size)
            ))
            cursor += size
        }
        return result
    }

    private static func child(
        _ type: String,
        in parent: Box,
        data: Data
    ) throws -> Box? {
        try boxes(in: data, range: parent.payload).first(where: { $0.type == type })
    }

    private static func fileTypeBrands(_ data: Data, box: Box) throws -> [String] {
        guard box.payload.count >= 8 else {
            throw ToolError("HDR QC found a malformed ftyp atom.")
        }
        var brands = [try string(data, at: box.payload.lowerBound, count: 4)]
        var cursor = box.payload.lowerBound + 8
        while cursor + 4 <= box.payload.upperBound {
            brands.append(try string(data, at: cursor, count: 4))
            cursor += 4
        }
        return brands
    }

    private static func hevcConfiguration(
        _ data: Data,
        box: Box
    ) throws -> (profileIDC: Int, lumaBitDepth: Int, chromaBitDepth: Int) {
        guard box.payload.count >= 19 else {
            throw ToolError("HDR QC found a truncated hvcC atom.")
        }
        let start = box.payload.lowerBound
        return (
            Int(data[start + 1] & 0x1f),
            8 + Int(data[start + 17] & 0x07),
            8 + Int(data[start + 18] & 0x07)
        )
    }

    private static func colorInformation(
        _ data: Data,
        box: Box
    ) throws -> (primaries: Int, transfer: Int, matrix: Int, fullRange: Bool?) {
        guard box.payload.count >= 10 else {
            throw ToolError("HDR QC found a truncated colr atom.")
        }
        let start = box.payload.lowerBound
        let type = try string(data, at: start, count: 4)
        guard type == "nclc" || type == "nclx" else {
            throw ToolError("HDR QC found an unsupported colr atom.")
        }
        let fullRange = type == "nclx" && box.payload.count >= 11
            ? (data[start + 10] & 0x80) != 0
            : nil
        return (
            Int(try uint16(data, at: start + 4)),
            Int(try uint16(data, at: start + 6)),
            Int(try uint16(data, at: start + 8)),
            fullRange
        )
    }

    private static func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= data.startIndex, offset + 2 <= data.endIndex else {
            throw ToolError("HDR QC read beyond the container metadata.")
        }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= data.startIndex, offset + 4 <= data.endIndex else {
            throw ToolError("HDR QC read beyond the container metadata.")
        }
        return UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func uint64(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= data.startIndex, offset + 8 <= data.endIndex else {
            throw ToolError("HDR QC read beyond the container metadata.")
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = value << 8 | UInt64(data[offset + index])
        }
        return value
    }

    private static func string(
        _ data: Data,
        at offset: Int,
        count: Int
    ) throws -> String {
        guard offset >= data.startIndex, offset + count <= data.endIndex,
              let value = String(
                data: data.subdata(in: offset..<(offset + count)),
                encoding: .ascii
              ) else {
            throw ToolError("HDR QC could not decode container metadata.")
        }
        return value
    }
}
