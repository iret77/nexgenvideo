import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import NexGenVideo

struct SpatialClaySequencePresentationTests {
    private func completeClock() throws -> SpatialClayRenderer.SequenceClock {
        try SpatialClayRenderer.sequenceClock(.init(numerator: 240_741, denominator: 24_000),
            numerator: 24_000, denominator: 1_001, count: 241)
    }

    private func sample(index: Int = 240, duration: CMTime = CMTime(value: 1_001, timescale: 24_000),
                        offset: Int64 = 0, trim: Int64? = nil) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let image = try #require(pixel)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
            formatDescriptionOut: &format) == noErr)
        let description = try #require(format)
        var timing = CMSampleTimingInfo(duration: duration,
            presentationTimeStamp: CMTime(value: Int64(index) * 1_001 + offset, timescale: 24_000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &buffer) == noErr)
        let result = try #require(buffer)
        if let trim {
            let value = try #require(CMTimeCopyAsDictionary(CMTime(value: trim, timescale: 24_000), allocator: nil))
            CMSetAttachment(result, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                value: value, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return result
    }

    @Test func trimmedSamplesUseTheExactOutputTimeline() throws {
        let clock = try completeClock()
        let last = try sample(trim: 500)
        #expect(CMTimeCompare(CMSampleBufferGetDuration(last), CMTime(value: 1_001, timescale: 24_000)) == 0)
        #expect(CMTimeCompare(CMSampleBufferGetDuration(last), clock.sampleDuration(240)) != 0)
        #expect(CMTimeCompare(CMSampleBufferGetOutputDuration(last), CMTime(value: 501, timescale: 24_000)) == 0)
        #expect(SpatialClayRenderer.sequenceSampleHasExpectedPresentation(last, index: 240, clock: clock))
        #expect(SpatialClayRenderer.sequenceSampleHasExpectedPresentation(try sample(index: 239), index: 239, clock: clock))
    }

    @Test func incorrectOrUnknownOutputTimingIsRejected() throws {
        let clock = try completeClock()
        let trims: [Int64?] = [nil, 499, 501]
        for trim in trims {
            #expect(!SpatialClayRenderer.sequenceSampleHasExpectedPresentation(try sample(trim: trim), index: 240, clock: clock))
        }
        #expect(!SpatialClayRenderer.sequenceSampleHasExpectedPresentation(try sample(offset: 1, trim: 500), index: 240, clock: clock))
        #expect(!SpatialClayRenderer.sequenceSampleHasExpectedPresentation(try sample(duration: .invalid), index: 240, clock: clock))
        let valid = try sample(trim: 500)
        for index in [-1, 239, 241] {
            #expect(!SpatialClayRenderer.sequenceSampleHasExpectedPresentation(valid, index: index, clock: clock))
        }
    }

    @Test func h264RoundTripPreservesTheExactPartialFinalFrame() async throws {
        let url = try await FixtureVideo.write(scenes: [.init(rgb: (30, 100, 50), seconds: 1)], fps: 3, size: 64,
            presentation: (timescale: 24_000, ticks: [0, 1_001, 2_002], end: 2_503), fileType: .mov)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        #expect(CMTimeCompare(try await asset.load(.duration), CMTime(value: 2_503, timescale: 24_000)) == 0)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let expected = try SpatialClayRenderer.sequenceClock(.init(numerator: 2_503, denominator: 24_000),
            numerator: 24_000, denominator: 1_001, count: 3)
        let settings: [[String: Any]?] = [nil, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]]
        for outputSettings in settings {
            let reader = try AVAssetReader(asset: asset)
            defer { if reader.status == .reading { reader.cancelReading() } }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            try #require(reader.canAdd(output))
            reader.add(output)
            try #require(reader.startReading())
            for index in 0..<3 {
                let sample = try #require(output.copyNextSampleBuffer())
                if outputSettings != nil { #expect(CMSampleBufferGetImageBuffer(sample) != nil) }
                #expect(SpatialClayRenderer.sequenceSampleHasExpectedPresentation(sample, index: index, clock: expected),
                    "frame \(index): raw \(CMSampleBufferGetDuration(sample)), output \(CMSampleBufferGetOutputDuration(sample))")
            }
            #expect(output.copyNextSampleBuffer() == nil && reader.status == .completed)
        }
    }
}
