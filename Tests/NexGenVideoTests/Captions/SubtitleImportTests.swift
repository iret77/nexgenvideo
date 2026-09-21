import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Caption file import")
struct SubtitleImportTests {
    private func temporaryFile(
        name: String,
        contents: String
    ) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ngv-caption-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file, options: .atomic)
        return (directory, file)
    }

    @Test func importCreatesEditableClipsWithFilenameLanguageAndOneUndoStep() async throws {
        let fixture = try temporaryFile(
            name: "dialogue.en.srt",
            contents: "1\n00:00:01,000 --> 00:00:02,000\nHello.\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld.\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undoManager = undo

        let ids = try await editor.importCaptions(
            from: fixture.file,
            sourceFilename: fixture.file.lastPathComponent,
            sourceAssetID: "subtitle-asset"
        )
        let clips = editor.timeline.tracks.flatMap(\.clips)

        #expect(ids.count == 2)
        #expect(clips.map(\.textContent) == ["Hello.", "World."])
        #expect(clips.map(\.startFrame) == [30, 90])
        #expect(clips.allSatisfy { $0.mediaType == .text && $0.captionGroupId != nil })
        #expect(clips.allSatisfy {
            $0.captionProvenance == CaptionProvenance(
                sourceFilename: "dialogue.en.srt",
                sourceFormat: "srt",
                languageIdentifier: "en",
                sourceAssetID: "subtitle-asset"
            )
        })
        #expect(undo.undoActionName == "Add Captions")

        undo.undo()
        #expect(editor.timeline.tracks.isEmpty)
        #expect(undo.redoActionName == "Add Captions")
        undo.redo()
        #expect(editor.timeline.tracks.flatMap(\.clips).map(\.textContent) == ["Hello.", "World."])
    }

    @Test func malformedImportIsAtomicAndDoesNotRegisterUndo() async throws {
        let fixture = try temporaryFile(
            name: "broken.srt",
            contents: "1\nnot a timestamp\nDo not place this.\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
        let before = editor.timeline
        let undo = UndoManager()
        editor.undoManager = undo

        await #expect(throws: SubtitleFileParser.ParseError.self) {
            try await editor.importCaptions(from: fixture.file)
        }

        #expect(editor.timeline == before)
        #expect(!undo.canUndo)
    }

    @Test func overlappingImportPreservesEveryCueOnSeparateTracks() async throws {
        let fixture = try temporaryFile(
            name: "overlap.vtt",
            contents: "WEBVTT\nLanguage: ja\n\n00:00.000 --> 00:02.000\n一\n\n00:01.000 --> 00:03.000\n二\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let editor = EditorViewModel()

        let ids = try await editor.importCaptions(from: fixture.file)

        #expect(ids.count == 2)
        #expect(editor.timeline.tracks.count == 2)
        #expect(Set(editor.timeline.tracks.flatMap(\.clips).compactMap(\.textContent)) == ["一", "二"])
        #expect(editor.timeline.tracks.flatMap(\.clips).allSatisfy {
            $0.captionProvenance?.languageIdentifier == "ja"
        })
        #expect(editor.mediaPanelToast?.message.contains("overlapping cues") == true)
    }

    @Test func reimportCreatesANewEditableGroupAndUndoOnlyRemovesThatImport() async throws {
        let fixture = try temporaryFile(
            name: "captions.srt",
            contents: "1\n00:00:01,000 --> 00:00:02,000\nAgain.\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undoManager = undo

        _ = try await editor.importCaptions(from: fixture.file)
        let firstGroup = try #require(editor.timeline.tracks.flatMap(\.clips).first?.captionGroupId)
        _ = try await editor.importCaptions(from: fixture.file)
        let clips = editor.timeline.tracks.flatMap(\.clips)

        #expect(clips.count == 2)
        #expect(Set(clips.compactMap(\.captionGroupId)).count == 2)
        #expect(clips.contains { $0.captionGroupId == firstGroup })

        undo.undo()
        let remaining = editor.timeline.tracks.flatMap(\.clips)
        #expect(remaining.count == 1)
        #expect(remaining.first?.captionGroupId == firstGroup)
    }

    @Test func captionProvenanceSurvivesProjectRoundTrip() throws {
        var clip = Fixtures.clip(mediaType: .text, start: 10, duration: 20)
        clip.textContent = "Persistent"
        clip.captionProvenance = CaptionProvenance(
            sourceFilename: "captions.fr.vtt",
            sourceFormat: "webVTT",
            languageIdentifier: "fr",
            sourceAssetID: "source-id"
        )
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)

        #expect(decoded.tracks[0].clips[0].captionProvenance == clip.captionProvenance)
    }

    @Test func subtitleAssetsNeverEnterTheGenericDropPlan() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
        let asset = MediaAsset(
            id: "subtitle",
            url: URL(fileURLWithPath: "/tmp/captions.srt"),
            type: .subtitle,
            name: "captions",
            duration: 4
        )

        let plan = editor.resolveDropPlan(
            cursor: .existingTrack(0),
            assets: [asset],
            atFrame: 42
        )

        #expect(plan.placements.isEmpty)
        #expect(plan.visualTarget == nil)
        #expect(plan.audioTarget == nil)
    }
}
