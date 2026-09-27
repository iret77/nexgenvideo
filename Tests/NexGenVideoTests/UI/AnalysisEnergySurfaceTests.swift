import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Measured analysis energy")
struct AnalysisEnergySurfaceTests {
    private func analysis(_ samples: String) throws -> AnalysisSurfaceData {
        let json = "{\"duration_s\":120,\"energy_curve\":\(samples)}"
        return try JSONDecoder().decode(AnalysisSurfaceData.self, from: Data(json.utf8))
    }

    @Test func measuredEnergyRetainsRecordedTimeAndAmplitudeWithoutRequiringBeats() throws {
        let value = try analysis("[{\"t\":0,\"rms\":0},{\"t\":30,\"rms\":0.75},{\"t\":120,\"rms\":0.25}]")
        let samples = try #require(value.measuredEnergy)
        #expect(samples.map(\.t) == [0, 30, 120])
        #expect(samples.map(\.rms) == [0, 0.75, 0.25])
        #expect(!value.hasBeatGrid)
    }

    @Test(arguments: [
        "[]",
        "[{\"t\":0,\"rms\":0.5}]",
        "[{\"t\":30,\"rms\":0.5},{\"t\":20,\"rms\":0.2}]",
        "[{\"t\":0,\"rms\":0.5},{\"t\":121,\"rms\":0.2}]",
        "[{\"t\":0,\"rms\":0.5},{\"t\":120,\"rms\":1.2}]",
        "[{\"t\":0,\"rms\":0.5},{\"t\":0,\"rms\":0.2}]",
    ])
    func missingOrInvalidSamplesAreUnavailable(_ samples: String) throws {
        #expect(try analysis(samples).measuredEnergy == nil)
    }

    @Test func waveformSourceRequiresTheRecordedPathAndExactTrackBytes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("pipeline")
        let audio = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let song = audio.appendingPathComponent("Song.wav")
        try Data("recorded track bytes".utf8).write(to: song)
        var value = try analysis("[]")
        value.songPath = "audio/Song.wav"
        #expect(value.verifiedSourceURL(dataRoot: root) == nil)
        value.songSHA256 = try FileDigest.sha256(of: song)
        #expect(value.verifiedSourceURL(dataRoot: root) == song)
        value.songPath = "audio/Another.wav"
        #expect(value.verifiedSourceURL(dataRoot: root) == nil)
        value.songPath = "audio/Song.wav"
        try Data("replacement track bytes".utf8).write(to: song)
        #expect(value.verifiedSourceURL(dataRoot: root) == nil)
    }

}
