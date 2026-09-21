import Foundation
import Testing
@testable import NexGenVideo

@Suite("Source timing")
struct SourceTimingTests {
    private let ntsc = 1001.0 / 30_000.0

    @Test func exactFrameDurationPreservesNTSCTime() throws {
        let timecode = SourceTimecode(
            frame: 30_000,
            quanta: 30,
            dropFrame: true,
            frameDuration: ntsc
        )
        let exactSeconds = try #require(timecode.seconds)
        #expect(abs(exactSeconds - 1_001) < 1e-9)

        let approximate = SourceTimecode(frame: 17_982, quanta: 30, dropFrame: true)
        let exact = SourceTimecode(
            frame: 17_982,
            quanta: 30,
            dropFrame: true,
            frameDuration: ntsc
        )
        let approximateSeconds = try #require(approximate.seconds)
        let ntscSeconds = try #require(exact.seconds)
        #expect(abs(approximateSeconds - ntscSeconds) > 0.5)
    }

    @Test func compatibilityRequiresMatchingRateDropModeAndDuration() {
        let reference = SourceTimecode(
            frame: 100,
            quanta: 30,
            dropFrame: true,
            frameDuration: ntsc
        )
        #expect(reference.compatibility(with: SourceTimecode(
            frame: 500,
            quanta: 30,
            dropFrame: true,
            frameDuration: ntsc
        )).isCompatible)
        #expect(!reference.compatibility(with: SourceTimecode(
            frame: 500,
            quanta: 25,
            dropFrame: false,
            frameDuration: 1.0 / 25
        )).isCompatible)
        #expect(!reference.compatibility(with: SourceTimecode(
            frame: 500,
            quanta: 30,
            dropFrame: false,
            frameDuration: 1.0 / 30
        )).isCompatible)
        #expect(!reference.compatibility(with: SourceTimecode(
            frame: 500,
            quanta: 30,
            dropFrame: true,
            frameDuration: 1.0 / 30
        )).isCompatible)
    }

    @Test func timecodeAlignmentHandlesOffsetTrimAndSpeed() throws {
        func start(
            referenceStart: Int = 0,
            referenceTrim: Int = 0,
            referenceSpeed: Double = 1,
            referenceFrame: Int,
            targetTrim: Int = 0,
            targetFrame: Int
        ) throws -> Int {
            try #require(EditorViewModel.timecodeAlignedStart(
                refStartFrame: referenceStart,
                refTrimStartFrame: referenceTrim,
                refSpeed: referenceSpeed,
                refTimecode: SourceTimecode(
                    frame: referenceFrame,
                    quanta: 25,
                    dropFrame: false
                ),
                targetTrimStartFrame: targetTrim,
                targetTimecode: SourceTimecode(
                    frame: targetFrame,
                    quanta: 25,
                    dropFrame: false
                ),
                fps: 25
            ))
        }
        #expect(try start(referenceStart: 120, referenceFrame: 90_000, targetFrame: 90_000) == 120)
        #expect(try start(referenceFrame: 1_000, targetFrame: 1_250) == 250)
        #expect(try start(referenceStart: 100, referenceTrim: 50, referenceFrame: 0, targetFrame: 0) == 50)
        #expect(try start(referenceSpeed: 2, referenceFrame: 0, targetFrame: 250) == 125)
    }

    @Test func parsesQuickTimeCaptureDatesAndComputesTrimmedLag() throws {
        let colon = try #require(SourceTimingReader.parseQuickTimeDate("2026-07-06T12:24:41-07:00"))
        #expect(colon == SourceTimingReader.parseQuickTimeDate("2026-07-06T12:24:41-0700"))
        #expect(SourceTimingReader.parseQuickTimeDate("2026-07-06T12:24:41.125-07:00") != nil)
        #expect(SourceTimingReader.parseQuickTimeDate("not a date") == nil)

        let lag = EditorViewModel.captureDateLagSeconds(
            referenceDate: colon,
            referenceTrimStartFrame: 25,
            targetDate: colon.addingTimeInterval(10),
            targetTrimStartFrame: 75,
            fps: 25
        )
        #expect(lag == 12)
    }

    @Test func decodesSigned32And64BitTimecodeSamples() {
        #expect(SourceTimingReader.decodeTimecodeFrame(
            bytes: [0xFF, 0xFF, 0xFF, 0xFE],
            is64Bit: false
        ) == -2)
        #expect(SourceTimingReader.decodeTimecodeFrame(
            bytes: [0, 0, 0, 1, 0, 0, 0, 2],
            is64Bit: true
        ) == 4_294_967_298)
        #expect(SourceTimingReader.decodeTimecodeFrame(bytes: [0, 1], is64Bit: false) == nil)
    }
}
