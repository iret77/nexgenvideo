import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Bounded caption and speech revision")
struct CaptionRevisionTests {
    @Test func selectedTextChangesPreserveTimingSourcesAndSingleUndoRedo() throws {
        let (editor, source) = try fixture()
        let before = editor.timeline
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let plan = try CaptionRevisionPlan.captions([
            .init(clipID: "caption-a", text: "Correct name"), .init(clipID: "caption-b", text: "Unselected")
        ], scope: CaptionRevisionScope.capture(editor), editor: editor)
        #expect(editor.timeline == before)
        #expect(plan.rows.map(\.timeRange) == ["0.00–1.00 s", "2.00–3.00 s"])
        let restored = try JSONDecoder().decode(AgentDialog.self, from: JSONEncoder().encode(plan.dialog))
        #expect(restored.captionRevision == plan && restored.purpose == .captionRevision)
        #expect(throws: (any Error).self) { try plan.apply(selected: [], editor: editor) }
        #expect(throws: (any Error).self) { try plan.apply(selected: ["foreign"], editor: editor) }
        #expect(try plan.apply(selected: ["caption-a"], editor: editor) == 1)
        var expected = before; expected.tracks[2].clips[0].textContent = "Correct name"
        #expect(editor.timeline == expected)
        #expect(try Data(contentsOf: source) == Data("original audio".utf8))
        undo.undo(); #expect(editor.timeline == before && !undo.canUndo)
        undo.redo(); #expect(editor.timeline == expected)
    }

    @Test func staleTimelineAndSameLengthSourceChangeRejectTheWholePlan() throws {
        for sourceChanged in [false, true] {
            let (editor, source) = try fixture()
            let plan = try CaptionRevisionPlan.captions([.init(clipID: "caption-a", text: "New name")],
                scope: CaptionRevisionScope.capture(editor), editor: editor)
            if sourceChanged {
                try Data("replaced audio".utf8).write(to: source)
            } else { editor.timeline.tracks[2].clips[1].startFrame += 1 }
            let before = editor.timeline
            #expect(throws: (any Error).self) { try plan.apply(selected: ["caption-a"], editor: editor) }
            #expect(editor.timeline == before)
        }
    }

    @Test func exactLinkedWordCutUsesFrozenSourceAndOneRippleUndo() async throws {
        let (editor, source) = try fixture()
        let before = editor.timeline
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        editor.captionTranscriptionClient = .init(transcribe: { url, video, range, censor, locale in
            #expect(url != source && !video && range == nil && !censor && locale == nil)
            #expect(try Data(contentsOf: url) == Data("original audio".utf8))
            return Self.transcript
        }, supportedLocales: { [] })
        let tool = ToolExecutor(editor: editor)
        let removal = try await tool.prepareWordRemoval(editor, ["words": [1]])
        #expect(removal.ranges == [.init(start: 30, end: 60)])
        let plan = try CaptionRevisionPlan.speech(removal, editor: editor)
        #expect(plan.rows[0].before == "Hello um world." && plan.rows[0].after == "Hello world.")
        #expect(plan.rows[0].timeRange == "1.00–2.00 s" && editor.timeline == before)
        #expect(try plan.apply(selected: ["speech-cuts"], editor: editor) == 1)
        for track in editor.timeline.tracks.prefix(2) {
            #expect(track.clips.map(\.startFrame) == [0, 30])
            #expect(track.clips.map(\.durationFrames) == [30, 90])
            #expect(track.clips.map(\.trimStartFrame) == [0, 60])
        }
        #expect(editor.clipFor(id: "caption-b")?.startFrame == 30)
        let after = editor.timeline
        undo.undo(); #expect(editor.timeline == before && !undo.canUndo)
        undo.redo(); #expect(editor.timeline == after)
    }

    @Test func lateTranscriptionCannotCutChangedTimelineOrSource() async throws {
        for defect in ["timeline", "source", "cancel"] {
            let (editor, source) = try fixture()
            let before = editor.timeline
            editor.captionTranscriptionClient = .init(transcribe: { _, _, _, _, _ in
                if defect == "timeline" { editor.timeline.width += 1 }
                if defect == "source" { try Data("replaced audio".utf8).write(to: source) }
                if defect == "cancel" { throw CancellationError() }
                return Self.transcript
            }, supportedLocales: { [] })
            let tool = ToolExecutor(editor: editor)
            await #expect(throws: (any Error).self) { try await tool.removeWords(editor, ["words": [1]]) }
            #expect(editor.timeline.tracks == before.tracks)
        }
    }

    @Test func taskKindAndSchemaPreventBroaderEdits() async throws {
        let (editor, _) = try fixture()
        let tool = ToolExecutor(editor: editor)
        let captionScope = try CaptionRevisionScope.capture(editor)
        await #expect(throws: (any Error).self) { try await tool.prepareWordRemoval(editor, ["words": [1]], scope: captionScope) }
        #expect(throws: (any Error).self) {
            try CaptionRevisionPlan.captions([.init(clipID: "picture", text: "Must not become text")], scope: captionScope, editor: editor)
        }
        let definition = try #require(ToolDefinitions.all.first { $0.name == .proposeCaptionRevision })
        let invalid: [[String: Any]] = [
            ["kind": "other", "changes": []],
            ["kind": "captions", "changes": [["clipId": "caption-a", "text": "Changed", "startFrame": 20]]],
            ["kind": "speech_cuts", "words": [true]],
            ["kind": "speech_cuts", "words": [[1, 2, 3]]]
        ]
        for value in invalid {
            #expect(throws: (any Error).self) { try validateToolInput(in: value, against: definition.inputSchema, path: "propose_caption_revision") }
        }
        await #expect(throws: (any Error).self) {
            try await tool.proposeCaptionRevision(editor, ["kind": "captions", "changes": [], "words": [1]], origin: .direct)
        }
    }

    private static var transcript: TranscriptionResult {
        .init(text: "Hello um world.", language: "en", words: [
            .init(text: "Hello", start: 0, end: 1), .init(text: "um", start: 1, end: 2),
            .init(text: "world.", start: 2, end: 3)], segments: [.init(text: "Hello um world.", start: 0, end: 3)])
    }

    private func fixture() throws -> (EditorViewModel, URL) {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("caption-revision-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: package)
        let source = package.appendingPathComponent("Voice.wav")
        try Data("original audio".utf8).write(to: source)
        let editor = EditorViewModel(); editor.projectURL = package
        let audio = MediaAsset(id: "voice", url: source, type: .audio, name: "Voice", duration: 5)
        let video = MediaAsset(id: "video", url: source, type: .video, name: "Picture", duration: 5)
        video.hasAudio = false
        editor.mediaAssets = [audio, video]
        editor.mediaManifest.entries = editor.mediaAssets.map { $0.toManifestEntry(projectURL: nil) }
        var picture = Fixtures.clip(id: "picture", mediaRef: video.id, start: 0, duration: 150)
        var voice = Fixtures.clip(id: "voice-clip", mediaRef: audio.id, mediaType: .audio, start: 0, duration: 150)
        picture.linkGroupId = "pair"; voice.linkGroupId = "pair"
        var a = Fixtures.clip(id: "caption-a", mediaRef: "", mediaType: .text, start: 0, duration: 30)
        a.captionGroupId = "captions"; a.textContent = "Wrong name"
        var b = a; b.id = "caption-b"; b.startFrame = 60; b.textContent = "Other name"
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [picture]), Fixtures.audioTrack(clips: [voice]), Track(type: .text, clips: [a, b])])
        return (editor, source)
    }
}
