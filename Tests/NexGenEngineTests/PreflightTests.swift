import Foundation
import Testing
@testable import NexGenEngine

/// Port of `plugins/musicvideo/tests/`'s (absent) preflight coverage, derived
/// directly from `nexgen_pack_musicvideo/analysis/preflight.py`'s rules:
/// audio missing is a hard blocker, lyrics/reference-images missing are
/// warnings only.
@Suite("Musicvideo Preflight")
struct PreflightTests {
    private func makeProjectDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("missing audio is a hard blocker and blocks start")
    func missingAudioIsHardBlocker() throws {
        let dir = try makeProjectDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = Preflight.run(projectDir: dir)
        #expect(!result.hasAudio)
        #expect(!result.canStart)
        #expect(result.blockers.count == 1)
    }

    @Test("missing lyrics and references are warnings, not blockers")
    func missingLyricsAndReferencesAreWarnings() throws {
        let dir = try makeProjectDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audioDir = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try "fake".write(to: audioDir.appendingPathComponent("song.wav"), atomically: true, encoding: .utf8)

        let result = Preflight.run(projectDir: dir)
        #expect(result.hasAudio)
        #expect(result.canStart)
        #expect(!result.hasLyrics)
        #expect(!result.hasReferences)
        #expect(result.warnings.count == 2)
        #expect(result.needsUserConfirmation)
    }

    @Test("present audio, lyrics, and references produce a clean result")
    func presentInputsProduceCleanResult() throws {
        let dir = try makeProjectDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let audioDir = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try "fake".write(to: audioDir.appendingPathComponent("song.mp3"), atomically: true, encoding: .utf8)

        let lyricsDir = dir.appendingPathComponent("lyrics")
        try FileManager.default.createDirectory(at: lyricsDir, withIntermediateDirectories: true)
        try "la la la".write(to: lyricsDir.appendingPathComponent("lyrics.txt"), atomically: true, encoding: .utf8)

        let importDir = dir.appendingPathComponent("import").appendingPathComponent("characters")
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: importDir.appendingPathComponent("hero.png"))

        let result = Preflight.run(projectDir: dir)
        #expect(result.hasAudio)
        #expect(result.hasLyrics)
        #expect(result.hasReferences)
        #expect(result.canStart)
        #expect(!result.needsUserConfirmation)
        #expect(result.referenceImages == ["import/characters/hero.png"])
        #expect(result.lyricsPath == "lyrics/lyrics.txt")
    }

    @Test("an empty lyrics.txt counts as missing")
    func emptyLyricsFileCountsAsMissing() throws {
        let dir = try makeProjectDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lyricsDir = dir.appendingPathComponent("lyrics")
        try FileManager.default.createDirectory(at: lyricsDir, withIntermediateDirectories: true)
        try Data().write(to: lyricsDir.appendingPathComponent("lyrics.txt"))

        let result = Preflight.run(projectDir: dir)
        #expect(!result.hasLyrics)
    }

    @Test("non-audio files in audio/ are ignored")
    func nonAudioFilesIgnored() throws {
        let dir = try makeProjectDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audioDir = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try "notes".write(to: audioDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let result = Preflight.run(projectDir: dir)
        #expect(!result.hasAudio)
    }
}
