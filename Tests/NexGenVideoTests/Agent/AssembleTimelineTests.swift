import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

/// The native `assemble_timeline` workflow tool: places the phase's rendered shots on a dedicated
/// assembly video track cut to the beat, lays the song at frame 0, skips unrendered shots, and
/// rebuilds in place on a second call. Driven through ToolExecutor against a temp scaffolded project
/// with a synthetic analysis + shotlist + render manifest.
@MainActor
@Suite("assemble_timeline")
struct AssembleTimelineTests {

    // 120 BPM at 30 fps: beats every 0.5 s (15 frames), downbeats every 2 s.
    private static let analysisJSON = """
        {
          "beats": [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
          "downbeats": [0.0, 2.0, 4.0],
          "bpm": 120.0,
          "duration_s": 4.0,
          "sections": [
            {"start": 0.0, "end": 2.0, "index": 0, "cluster": 0},
            {"start": 2.0, "end": 4.0, "index": 1, "cluster": 1}
          ]
        }
        """

    /// Scaffold a project, drop a stub song in audio/, write the analysis artifact, save a 3-shot
    /// shotlist (s003 will be left unrendered), and write two stub render outputs on disk. Returns
    /// (harness, dataRoot, cleanup-root, [output paths]).
    private func setup() throws -> (ToolHarness, URL, URL, [String]) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo", mode: .section)

        // Song stub in audio/ so the analysis artifact path resolves to analysis/song.json.
        let audioDir = dataRoot.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: audioDir.appendingPathComponent("song.wav"))

        let analysisDir = dataRoot.appendingPathComponent("analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: analysisDir, withIntermediateDirectories: true)
        try Data(Self.analysisJSON.utf8).write(to: analysisDir.appendingPathComponent("song.json"))

        let song = try Song(title: "t", audioPath: "audio/song.wav", analysisPath: "analysis/song.json", bpm: 120.0, durationS: 4.0)
        func shot(_ id: String, _ section: String, _ start: Double, _ end: Double) throws -> Shot {
            try Shot(
                id: id, section: section, timeStart: start, timeEnd: end, durationS: end - start,
                type: .performance, description: "desc", visualPrompt: "a wide shot", mood: "m"
            )
        }
        let shotlist = try Shotlist(
            schema_: shotlistSchemaVersion, mode: .section, project: "demo", song: song,
            generated: "2026-01-01", generator: "test",
            shots: [
                try shot("s001", "verse", 0.0, 1.0),
                try shot("s002", "verse", 1.0, 2.0),
                try shot("s003", "chorus", 2.0, 4.0),
            ]
        )
        _ = try saveShotlist(shotlist, to: dataRoot)

        // Two stub rendered clips on disk (content irrelevant — only the extension/type matter).
        let outA = tmp.appendingPathComponent("s001.mp4")
        let outB = tmp.appendingPathComponent("s002.mp4")
        try Data("clipA".utf8).write(to: outA)
        try Data("clipB".utf8).write(to: outB)

        return (ToolHarness(), dataRoot, tmp, [outA.path, outB.path])
    }

    /// Record s001 and s002 as rendered for `phase`; s003 stays unrendered.
    private func recordTwoRenders(_ h: ToolHarness, dataRoot: URL, outputs: [String], phase: String = "final") async throws {
        _ = try await h.runOK("record_render", args: [
            "project_dir": dataRoot.path, "phase": phase, "shot_id": "s001", "output": outputs[0],
        ])
        _ = try await h.runOK("record_render", args: [
            "project_dir": dataRoot.path, "phase": phase, "shot_id": "s002", "output": outputs[1],
        ])
    }

    // MARK: - happy path

    @Test("places rendered shots on beats, lays the song at frame 0, skips the unrendered shot")
    func assemblesToTheBeat() async throws {
        let (h, dataRoot, cleanup, outputs) = try setup()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try await recordTwoRenders(h, dataRoot: dataRoot, outputs: outputs)

        let result = try #require(try await h.runOK("assemble_timeline", args: [
            "project_dir": dataRoot.path, "phase": "final",
        ]) as? [String: Any])

        #expect(result["shots_placed"] as? Int == 2)
        let placements = try #require(result["placements"] as? [[String: Any]])
        #expect(placements.count == 2)
        // s001 starts at beat 0 (frame 0), s002 at beat 2 (frame 30) — both land exactly on beats.
        let startFrames = placements.compactMap { $0["start_frame"] as? Int }
        #expect(startFrames == [0, 30])
        for f in startFrames { #expect(f % 15 == 0) }

        // s003 was never rendered → skipped, not fatal.
        let skipped = try #require(result["skipped"] as? [[String: Any]])
        #expect(skipped.contains { $0["shot_id"] as? String == "s003" })

        // The video track carries exactly the two placed clips.
        let videoIndex = try #require(result["video_track_index"] as? Int)
        #expect(h.editor.timeline.tracks[videoIndex].type == .video)
        #expect(h.editor.timeline.tracks[videoIndex].clips.count == 2)

        // The song is the sync anchor: one audio clip at frame 0.
        let songTrack = try #require(result["song_track"] as? [String: Any])
        #expect(songTrack["placed"] as? Bool == true)
        #expect(songTrack["already_present"] as? Bool == false)
        let audioClips = h.editor.timeline.tracks.filter { $0.type == .audio }.flatMap { $0.clips }
        #expect(audioClips.count == 1)
        #expect(audioClips.first?.startFrame == 0)
    }

    // MARK: - re-run replaces, does not duplicate

    @Test("assembling again rebuilds in place — no duplicated clips or song")
    func reRunReplaces() async throws {
        let (h, dataRoot, cleanup, outputs) = try setup()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try await recordTwoRenders(h, dataRoot: dataRoot, outputs: outputs)

        _ = try await h.runOK("assemble_timeline", args: ["project_dir": dataRoot.path, "phase": "final"])
        let videoClipsAfterFirst = h.editor.timeline.tracks.filter { $0.type == .video }.flatMap { $0.clips }.count
        #expect(videoClipsAfterFirst == 2)

        let second = try #require(try await h.runOK("assemble_timeline", args: [
            "project_dir": dataRoot.path, "phase": "final",
        ]) as? [String: Any])
        #expect(second["shots_placed"] as? Int == 2)

        // Still two video clips and one song clip — the assembly was rebuilt, not appended.
        let videoClips = h.editor.timeline.tracks.filter { $0.type == .video }.flatMap { $0.clips }
        let audioClips = h.editor.timeline.tracks.filter { $0.type == .audio }.flatMap { $0.clips }
        #expect(videoClips.count == 2)
        #expect(audioClips.count == 1)

        // The song was already placed on the second run.
        let songTrack = try #require(second["song_track"] as? [String: Any])
        #expect(songTrack["already_present"] as? Bool == true)
        #expect(songTrack["placed"] as? Bool == false)
    }

    // MARK: - actionable errors

    @Test("errors when no shots are rendered yet")
    func errorsWithoutRenders() async throws {
        let (h, dataRoot, cleanup, _) = try setup()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let result = await h.runRaw("assemble_timeline", args: ["project_dir": dataRoot.path, "phase": "final"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("No rendered shots"))
    }

    @Test("errors when the analysis artifact is missing")
    func errorsWithoutAnalysis() async throws {
        let (h, dataRoot, cleanup, outputs) = try setup()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try FileManager.default.removeItem(at: dataRoot.appendingPathComponent("analysis/song.json"))
        try await recordTwoRenders(h, dataRoot: dataRoot, outputs: outputs)

        let result = await h.runRaw("assemble_timeline", args: ["project_dir": dataRoot.path, "phase": "final"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("analysis"))
    }
}
