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
        #expect(SpatialClayRenderer.SequenceFrameTiming(last).matches(index: 240, clock: clock, endingAt: clock.duration))
        #expect(SpatialClayRenderer.SequenceFrameTiming(try sample(index: 239)).matches(index: 239, clock: clock, endingAt: clock.presentation(240)))
    }

    @Test func incorrectOrUnknownOutputTimingIsRejected() throws {
        let clock = try completeClock()
        let trims: [Int64?] = [501, 1_001]
        for trim in trims {
            #expect(!SpatialClayRenderer.SequenceFrameTiming(try sample(trim: trim)).matches(index: 240, clock: clock, endingAt: clock.duration))
        }
        #expect(!SpatialClayRenderer.SequenceFrameTiming(try sample(offset: 1, trim: 500)).matches(index: 240, clock: clock, endingAt: clock.duration))
        #expect(!SpatialClayRenderer.SequenceFrameTiming(try sample(duration: .invalid)).matches(index: 240, clock: clock, endingAt: .invalid))
        let valid = try sample(trim: 500)
        for index in [-1, 239, 241] {
            #expect(!SpatialClayRenderer.SequenceFrameTiming(valid).matches(index: index, clock: clock, endingAt: clock.duration))
        }
    }

    @Test func unspecifiedDecodedDurationsRequireObservedBoundaries() throws {
        let clock = try completeClock()
        let unknown = SpatialClayRenderer.SequenceFrameTiming(try sample(index: 239, duration: .invalid))
        let next = SpatialClayRenderer.SequenceFrameTiming(try sample(duration: .invalid))
        #expect(unknown.matches(index: 239, clock: clock, endingAt: next.presentation))
        #expect(!unknown.matches(index: 239, clock: clock, endingAt: CMTimeAdd(next.presentation, CMTime(value: 1, timescale: 24_000))))
        #expect(!unknown.matches(index: 239, clock: clock, endingAt: .invalid))
        #expect(next.matches(index: 240, clock: clock, endingAt: CMTime(value: 240_741, timescale: 24_000)))
        #expect(!next.matches(index: 240, clock: clock, endingAt: CMTime(value: 241_241, timescale: 24_000)))
        for count in [0, 2] {
            let wrong = SpatialClayRenderer.SequenceFrameTiming(sampleCount: count, presentation: next.presentation, duration: .invalid)
            #expect(!wrong.matches(index: 240, clock: clock, endingAt: clock.duration))
        }
        for duration in [CMTime.zero, .indefinite, .positiveInfinity, CMTime(value: -1, timescale: 24_000), CMTime(value: 500, timescale: 24_000)] {
            let last = SpatialClayRenderer.SequenceFrameTiming(sampleCount: 1, presentation: next.presentation, duration: duration)
            #expect(!last.matches(index: 240, clock: clock, endingAt: clock.duration))
        }
        let clipped = SpatialClayRenderer.SequenceFrameTiming(try sample())
        #expect(clipped.matches(index: 240, clock: clock, endingAt: clock.duration))
        let trimmed = SpatialClayRenderer.SequenceFrameTiming(try sample(trim: 499))
        #expect(trimmed.matches(index: 240, clock: clock, endingAt: clock.duration))
        let incorrectDurations: [Int64] = [-1, 1_000, 1_002]
        for ticks in incorrectDurations {
            let wrong = SpatialClayRenderer.SequenceFrameTiming(sampleCount: 1, presentation: unknown.presentation,
                duration: CMTime(value: ticks, timescale: 24_000))
            #expect(!wrong.matches(index: 239, clock: clock, endingAt: next.presentation))
        }
    }

    @Test func h264RoundTripPreservesTheExactPartialFinalFrame() async throws {
        let url = try await FixtureVideo.write(scenes: [.init(rgb: (30, 100, 50), seconds: 1)], fps: 3, size: 64,
            presentation: (timescale: 24_000, ticks: [0, 1_001, 2_002], end: 2_503), fileType: .mov)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        #expect(CMTimeCompare(try await asset.load(.duration), CMTime(value: 2_503, timescale: 24_000)) == 0)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let trackRange = try await track.load(.timeRange)
        #expect(CMTimeCompare(trackRange.start, .zero) == 0)
        #expect(CMTimeCompare(trackRange.duration, CMTime(value: 2_503, timescale: 24_000)) == 0)
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
            var index = 0
            var leadingMarker = false, trailingMarker = false
            var previous: SpatialClayRenderer.SequenceFrameTiming?
            while let sample = output.copyNextSampleBuffer() {
                let timing = SpatialClayRenderer.SequenceFrameTiming(sample)
                if timing.sampleCount == 0 {
                    let atStart = index == 0 && CMTimeCompare(timing.presentation, .zero) == 0
                    let atEnd = index == 3 && CMTimeCompare(timing.presentation, CMTimeRangeGetEnd(trackRange)) == 0
                    try #require(outputSettings == nil)
                    try #require(timing.presentation.isNumeric && timing.duration.isNumeric)
                    #expect(CMTimeCompare(timing.duration, .zero) == 0)
                    #expect(CMSampleBufferGetFormatDescription(sample) == nil)
                    #expect(CMSampleBufferGetDataBuffer(sample) == nil)
                    try #require((atStart && !leadingMarker) || (atEnd && !trailingMarker))
                    leadingMarker = leadingMarker || atStart
                    trailingMarker = trailingMarker || atEnd
                    continue
                }
                try #require(index < 3)
                if outputSettings != nil { #expect(CMSampleBufferGetImageBuffer(sample) != nil) }
                #expect(timing.hasExpectedStart(index: index, clock: expected))
                if let previous {
                    #expect(previous.matches(index: index - 1, clock: expected, endingAt: timing.presentation))
                }
                previous = timing
                index += 1
            }
            #expect(index == 3 && reader.status == .completed)
            let last = try #require(previous)
            #expect(last.matches(index: 2, clock: expected, endingAt: CMTimeRangeGetEnd(trackRange)))
        }
    }
}
