import AVFoundation
import CoreMedia
import Foundation
import NexGenEngine

enum MusicPerformanceSegmentExporter {
    struct ExportedSegment {
        let path: String
        let sha256: String
        let byteCount: Int64
        let sampleCount: Int64
    }

    static func export(
        sourceURL: URL,
        draft: MusicPerformanceSegmentDraftV1,
        dataRoot: URL
    ) throws -> ExportedSegment {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw ToolError("The approved song has no readable audio track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let channels = 2
        let bytesPerSample = 2
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: draft.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bytesPerSample * 8,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw ToolError("The approved song segment cannot be decoded to PCM.")
        }
        reader.add(output)
        let startSeconds = Double(draft.sourceStartSample) / Double(draft.sampleRate)
        let sampleCount = draft.sourceEndSample - draft.sourceStartSample
        let durationSeconds = Double(sampleCount) / Double(draft.sampleRate)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 1_000_000),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 1_000_000)
        )
        guard reader.startReading() else {
            throw ToolError(reader.error?.localizedDescription ?? "The song segment could not be read.")
        }
        var pcm = Data()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            let status = CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: length,
                destination: &bytes
            )
            guard status == noErr else {
                reader.cancelReading()
                throw ToolError("The decoded song-segment bytes are unavailable.")
            }
            pcm.append(contentsOf: bytes)
        }
        guard reader.status == .completed else {
            throw ToolError(reader.error?.localizedDescription ?? "The song segment export failed.")
        }
        let expectedPCMBytes = Int(sampleCount) * channels * bytesPerSample
        guard pcm.count >= expectedPCMBytes else {
            throw ToolError("The exported song segment is shorter than its approved sample range.")
        }
        if pcm.count > expectedPCMBytes {
            pcm = Data(pcm.prefix(expectedPCMBytes))
        }
        let wave = wavData(
            pcm: pcm,
            sampleRate: draft.sampleRate,
            channels: channels,
            bitsPerSample: bytesPerSample * 8
        )
        let hash = FileDigest.sha256(of: wave)
        let safeID = draft.id.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        let path = "\(PipelineLayout.musicPerformanceSegmentsDir)/\(String(safeID))-\(hash).wav"
        let url = PipelineLayout.url(path, in: dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try wave.write(to: url, options: .atomic)
        return ExportedSegment(
            path: path,
            sha256: hash,
            byteCount: Int64(wave.count),
            sampleCount: sampleCount
        )
    }

    private static func wavData(
        pcm: Data,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> Data {
        var data = Data()
        data.append(Data("RIFF".utf8))
        appendUInt32(UInt32(36 + pcm.count), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(UInt16(channels), to: &data)
        appendUInt32(UInt32(sampleRate), to: &data)
        let byteRate = sampleRate * channels * bitsPerSample / 8
        appendUInt32(UInt32(byteRate), to: &data)
        appendUInt16(UInt16(channels * bitsPerSample / 8), to: &data)
        appendUInt16(UInt16(bitsPerSample), to: &data)
        data.append(Data("data".utf8))
        appendUInt32(UInt32(pcm.count), to: &data)
        data.append(pcm)
        return data
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
