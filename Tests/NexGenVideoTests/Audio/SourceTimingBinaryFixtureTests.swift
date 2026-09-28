import Foundation
import Testing
@testable import NexGenVideo

@Suite("Source timing binary fixtures")
struct SourceTimingBinaryFixtureTests {
    private struct Vectors: Decodable {
        struct RTMD: Decodable {
            let name: String
            let timescale: UInt32
            let delta: UInt32
            let hour: UInt8
            let minute: UInt8
            let second: UInt8
            let flag: UInt8
            let frame: UInt8
            let expectedFrame: Int
            let expectedQuanta: Int
            let expectedDropFrame: Bool
        }

        struct BWF: Decodable {
            let name: String
            let magic: String
            let sampleRate: UInt32
            let timeReference: UInt64
        }

        let rtmd: [RTMD]
        let bwf: [BWF]
    }

    private var vectorsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FCPXML/source-timing-vectors.json")
    }

    private func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: vectorsURL))
    }

    private func be32(_ value: UInt32) -> Data {
        var encoded = value.bigEndian
        return Swift.withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private func be64(_ value: UInt64) -> Data {
        var encoded = value.bigEndian
        return Swift.withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private func le32(_ value: UInt32) -> Data {
        var encoded = value.littleEndian
        return Swift.withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private func le64(_ value: UInt64) -> Data {
        var encoded = value.littleEndian
        return Swift.withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private func box(_ type: String, _ body: Data) -> Data {
        be32(UInt32(8 + body.count)) + Data(type.utf8) + body
    }

    private func chunk(_ type: String, _ body: Data) -> Data {
        var data = Data(type.utf8) + le32(UInt32(body.count)) + body
        if body.count.isMultiple(of: 2) == false { data.append(0) }
        return data
    }

    private func rtmdFile(
        timescale: UInt32,
        delta: UInt32,
        hour: UInt8,
        minute: UInt8,
        second: UInt8,
        flag: UInt8,
        frame: UInt8,
        useCo64: Bool,
        variableSampleSizes: Bool = true,
        stscDescriptionIndex: UInt32 = 2,
        declaredFirstSampleSize: UInt32 = 18
    ) -> Data {
        var sample = Data(repeating: 0, count: 13)
        sample += Data([hour, minute, second, flag, frame])
        let secondChunk = Data(repeating: 0xA5, count: 20)

        func moov(sampleOffset: UInt64) -> Data {
            let mdhdBody = Data([0, 0, 0, 0])
                + be32(0) + be32(0)
                + be32(timescale) + be32(delta)
                + Data(repeating: 0, count: 4)
            let stsd = box(
                "stsd",
                be32(0) + be32(2)
                    + box("avc1", Data())
                    + box("rtmd", Data())
            )
            let stts = box("stts", be32(0) + be32(1) + be32(3) + be32(delta))
            let stsc = box(
                "stsc",
                be32(0) + be32(2)
                    + be32(1) + be32(1) + be32(stscDescriptionIndex)
                    + be32(2) + be32(2) + be32(1)
            )
            let stszBody: Data = variableSampleSizes
                ? be32(0) + be32(3) + be32(declaredFirstSampleSize) + be32(10) + be32(10)
                : be32(declaredFirstSampleSize) + be32(3)
            let stsz = box("stsz", stszBody)
            let offsets: Data
            if useCo64 {
                offsets = box(
                    "co64",
                    be32(0) + be32(2) + be64(sampleOffset) + be64(sampleOffset + 18)
                )
            } else {
                offsets = box(
                    "stco",
                    be32(0) + be32(2) + be32(UInt32(sampleOffset)) + be32(UInt32(sampleOffset + 18))
                )
            }
            let stbl = box("stbl", stsd + stts + stsc + stsz + offsets)
            return box(
                "moov",
                box("trak", box("mdia", box("mdhd", mdhdBody) + box("minf", stbl)))
            )
        }

        let placeholder = moov(sampleOffset: 0)
        let offset = UInt64(placeholder.count + 8)
        return moov(sampleOffset: offset) + box("mdat", sample + secondChunk)
    }

    private func bwfFile(magic: String, sampleRate: UInt32, timeReference: UInt64) -> Data {
        var format = Data([1, 0, 2, 0])
        format += le32(sampleRate)
        format += Data(repeating: 0, count: 8)
        var bext = Data(repeating: 0, count: 338)
        bext += le64(timeReference)
        let core = chunk("JUNK", Data([1, 2, 3]))
            + chunk("fmt ", format)
            + chunk("bext", bext)
        if magic == "RF64" {
            let ds64 = chunk(
                "ds64",
                le64(UInt64(core.count + 64)) + le64(4) + le64(0) + le32(0)
            )
            return Data("RF64".utf8) + le32(UInt32.max) + Data("WAVE".utf8)
                + ds64 + core
                + Data("data".utf8) + le32(UInt32.max) + Data(repeating: 0, count: 4)
        }
        let body = Data("WAVE".utf8) + core + chunk("data", Data(repeating: 0, count: 4))
        return Data("RIFF".utf8) + le32(UInt32(body.count)) + body
    }

    @Test func sonyRTMDVectorsCoverMultiDescriptionTablesSTSCSTSZAndCo64() throws {
        for (index, vector) in try vectors().rtmd.enumerated() {
            let data = rtmdFile(
                timescale: vector.timescale,
                delta: vector.delta,
                hour: vector.hour,
                minute: vector.minute,
                second: vector.second,
                flag: vector.flag,
                frame: vector.frame,
                useCo64: index.isMultiple(of: 2),
                variableSampleSizes: index != 2
            )
            let timecode = try #require(SourceTimingReader.rtmdTimecode(data), "RTMD vector \(vector.name)")
            #expect(timecode.frame == vector.expectedFrame, "RTMD vector \(vector.name)")
            #expect(timecode.quanta == vector.expectedQuanta, "RTMD vector \(vector.name)")
            #expect(timecode.dropFrame == vector.expectedDropFrame, "RTMD vector \(vector.name)")
            #expect(timecode.tick == SourceTimecode.Tick(
                numerator: Int64(vector.delta),
                denominator: Int64(vector.timescale)
            ), "RTMD vector \(vector.name)")
            #expect(timecode.origin == .sonyRTMD, "RTMD vector \(vector.name)")
        }
    }

    @Test func rtmdRejectsWrongSampleDescriptionSizeRangeAndTruncation() {
        let wrongDescription = rtmdFile(
            timescale: 30_000, delta: 1_001,
            hour: 0, minute: 1, second: 0, flag: 0, frame: 0,
            useCo64: false,
            stscDescriptionIndex: 1
        )
        #expect(SourceTimingReader.rtmdTimecode(wrongDescription) == nil)

        let undersized = rtmdFile(
            timescale: 30_000, delta: 1_001,
            hour: 0, minute: 1, second: 0, flag: 0, frame: 0,
            useCo64: true,
            declaredFirstSampleSize: 17
        )
        #expect(SourceTimingReader.rtmdTimecode(undersized) == nil)

        let invalidFrame = rtmdFile(
            timescale: 30_000, delta: 1_001,
            hour: 0, minute: 1, second: 0, flag: 0, frame: 30,
            useCo64: false
        )
        #expect(SourceTimingReader.rtmdTimecode(invalidFrame) == nil)
        #expect(SourceTimingReader.rtmdTimecode(Data(invalidFrame.dropLast(25))) == nil)
        let impossibleDropRate = rtmdFile(
            timescale: 25_000, delta: 1_000,
            hour: 0, minute: 1, second: 0, flag: 1, frame: 0,
            useCo64: false
        )
        #expect(SourceTimingReader.rtmdTimecode(impossibleDropRate) == nil)
        #expect(SourceTimingReader.rtmdTimecode(Data([0xFF, 0xFF, 0xFF, 0xFF]) + Data("moov".utf8)) == nil)
    }

    @Test func bwfVectorsCoverOddChunksRF64AndZeroOrigin() throws {
        for vector in try vectors().bwf {
            let timecode = try #require(SourceTimingReader.bwfTimecode(bwfFile(
                magic: vector.magic,
                sampleRate: vector.sampleRate,
                timeReference: vector.timeReference
            )), "BWF vector \(vector.name)")
            #expect(timecode.frame == Int(vector.timeReference), "BWF vector \(vector.name)")
            #expect(timecode.quanta == Int(vector.sampleRate), "BWF vector \(vector.name)")
            #expect(timecode.dropFrame == false, "BWF vector \(vector.name)")
            #expect(
                timecode.tick == SourceTimecode.Tick(
                    numerator: 1,
                    denominator: Int64(vector.sampleRate)
                ),
                "BWF vector \(vector.name)"
            )
            #expect(timecode.origin == .bwf, "BWF vector \(vector.name)")
        }
    }

    @Test func bwfRejectsMalformedChunksMissingMetadataAndImpossibleSizes() {
        #expect(SourceTimingReader.bwfTimecode(Data()) == nil)
        #expect(SourceTimingReader.bwfTimecode(Data([82, 73, 70, 70, 0, 0, 0, 0, 65, 86, 73, 32])) == nil)

        var format = Data([1, 0, 2, 0])
        format += le32(48_000) + Data(repeating: 0, count: 8)
        let noBextBody = Data("WAVE".utf8) + chunk("fmt ", format)
        let noBext = Data("RIFF".utf8) + le32(UInt32(noBextBody.count)) + noBextBody
        #expect(SourceTimingReader.bwfTimecode(noBext) == nil)

        let oversized = Data("RIFF".utf8) + le32(12) + Data("WAVEbext".utf8) + le32(UInt32.max)
        #expect(SourceTimingReader.bwfTimecode(oversized) == nil)
        #expect(SourceTimingReader.bwfTimecode(Data(bwfFile(
            magic: "RF64", sampleRate: 48_000, timeReference: 10
        ).dropLast(340))) == nil)
    }

    @Test func sourceTimecodePriorityIsContainerThenRTMDThenBWF() throws {
        let loaded = try vectors()
        let vector = try #require(loaded.rtmd.first)
        let rtmd = rtmdFile(
            timescale: vector.timescale,
            delta: vector.delta,
            hour: vector.hour,
            minute: vector.minute,
            second: vector.second,
            flag: vector.flag,
            frame: vector.frame,
            useCo64: true
        )
        let container = SourceTimecode(frame: 42, quanta: 24, dropFrame: false, origin: .container)
        #expect(SourceTimingReader.selectTimecode(container: container, data: rtmd) == container)
        #expect(SourceTimingReader.selectTimecode(container: nil, data: rtmd)?.origin == .sonyRTMD)

        let bwf = bwfFile(magic: "RIFF", sampleRate: 48_000, timeReference: 172_800_000)
        #expect(SourceTimingReader.selectTimecode(container: nil, data: bwf)?.origin == .bwf)
        #expect(SourceTimingReader.selectTimecode(container: nil, data: Data()) == nil)
    }
}
