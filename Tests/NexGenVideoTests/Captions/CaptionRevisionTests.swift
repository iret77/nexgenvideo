import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Bounded caption and speech revision")
struct CaptionRevisionTests {
    @Test func selectedTextChangesPreserveTimingSourcesAndSingleUndoRedo() async throws {
        let (editor, source) = try fixture()
        let before = editor.timeline
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let plan = try await CaptionRevisionPlan.captions([
            .init(clipID: "caption-a", text: "Correct name"), .init(clipID: "caption-b", text: "Unselected")
        ], scope: await CaptionRevisionScope.capture(editor), editor: editor)
        #expect(editor.timeline == before)
        #expect(plan.rows.map(\.timeRange) == ["0.00–1.00 s", "2.00–3.00 s"])
        let restored = try JSONDecoder().decode(AgentDialog.self, from: JSONEncoder().encode(plan.makeDialog()))
        #expect(restored.captionRevision == plan && restored.purpose == .captionRevision)
        await #expect(throws: (any Error).self) { try await plan.apply(selected: [], editor: editor) }
        await #expect(throws: (any Error).self) { try await plan.apply(selected: ["foreign"], editor: editor) }
        #expect(try await plan.apply(selected: ["caption-a"], editor: editor) == 1)
        var expected = before; expected.tracks[2].clips[0].textContent = "Correct name"
        #expect(editor.timeline == expected)
        #expect(try Data(contentsOf: source) == Data("original audio".utf8))
        undo.undo(); #expect(editor.timeline == before && !undo.canUndo)
        undo.redo(); #expect(editor.timeline == expected)
    }

    @Test func staleTimelineRejectsCaptionTextButOfflineAudioDoesNotBlockIt() async throws {
        let (editor, source) = try fixture()
        let plan = try await CaptionRevisionPlan.captions([.init(clipID: "caption-a", text: "New name")],
            scope: await CaptionRevisionScope.capture(editor), editor: editor)
        let original = editor.timeline
        editor.timeline.tracks[2].clips[1].startFrame += 1
        let changed = editor.timeline
        await #expect(throws: (any Error).self) { try await plan.apply(selected: ["caption-a"], editor: editor) }
        #expect(editor.timeline == changed)
        editor.timeline = original
        try FileManager.default.moveItem(at: source, to: source.appendingPathExtension("offline"))
        #expect(try await plan.apply(selected: ["caption-a"], editor: editor) == 1)
        var expected = original; expected.tracks[2].clips[0].textContent = "New name"
        #expect(editor.timeline == expected)
    }

    @Test func changedAudioOrLinkedVideoRejectsSpeechDecision() async throws {
        for id in ["voice", "video"] {
            let (editor, _) = try fixture()
            editor.captionTranscriptionClient = .init(transcribe: { _, _, _, _, _ in Self.transcript }, supportedLocales: { [] })
            let removal = try await ToolExecutor(editor: editor).prepareWordRemoval(editor, ["words": [1]])
            let plan = try await CaptionRevisionPlan.speech(removal, editor: editor)
            let url = try #require(editor.mediaAssets.first(where: { $0.id == id })?.url)
            let bytes = try Data(contentsOf: url)
            try Data(repeating: 120, count: bytes.count).write(to: url)
            let before = editor.timeline
            await #expect(throws: (any Error).self) { try await plan.apply(selected: ["speech-cuts"], editor: editor) }
            #expect(editor.timeline == before)
        }
    }

    @Test func frozenTranscriptCannotSubstituteAnABAChangedSource() async throws {
        let (editor, source) = try fixture()
        let scope = try await CaptionRevisionScope.capture(editor, kind: .speechCuts)
        let original = try Data(contentsOf: source)
        try Data("replaced audio".utf8).write(to: source)
        let frozen = try CaptionInputSnapshot.freeze(["voice": source])
        defer { frozen.discard() }
        try original.write(to: source)
        try await scope.validate(editor)
        #expect(throws: (any Error).self) { try scope.validateFrozen(frozen) }
    }

    @Test func directWordCutStillWorksUnsavedWithUnrelatedMissingSource() async throws {
        let (editor, _) = try fixture()
        editor.projectURL = nil
        editor.timeline.tracks.append(Track(type: .video, clips: [Fixtures.clip(id: "missing-broll", mediaRef: "missing", start: 200, duration: 30)]))
        editor.captionTranscriptionClient = .init(transcribe: { _, _, _, _, _ in Self.transcript }, supportedLocales: { [] })
        _ = try await ToolExecutor(editor: editor).removeWords(editor, ["words": [1]])
        #expect(editor.timeline.tracks[0].clips.map(\.durationFrames) == [30, 90])
        #expect(editor.timeline.tracks[1].clips.map(\.durationFrames) == [30, 90])
        #expect(editor.timeline.tracks[3].clips.first?.startFrame == 170)
    }

    @Test func directWordCutRoutesUnalignedCaptionToNativeReviewWithoutMutation() async throws {
        let (editor, _) = try fixture()
        editor.timeline.tracks[2].clips[0].durationFrames = 90
        editor.timeline.tracks[2].clips[1].startFrame = 90
        editor.captionTranscriptionClient = .init(transcribe: { _, _, _, _, _ in Self.transcript }, supportedLocales: { [] })
        let before = editor.timeline
        do {
            _ = try await ToolExecutor(editor: editor).removeWords(editor, ["words": [1]])
            Issue.record("An unaligned caption must require a reviewed replacement.")
        } catch {
            #expect(error.localizedDescription.contains("propose_caption_revision"))
            #expect(error.localizedDescription.contains("kind=speech_cuts"))
            #expect(error.localizedDescription.contains("remove_words does not accept captionChanges"))
        }
        #expect(editor.timeline == before)
    }

    @Test func offlineManifestAssetIsSkippedDirectlyButRefusesNativeSpeechProposal() async throws {
        let (editor, source) = try fixture()
        let offlineURL = source.deletingLastPathComponent().appendingPathComponent("Offline.wav")
        try Data("offline audio".utf8).write(to: offlineURL)
        let offline = MediaAsset(id: "offline", url: offlineURL, type: .audio, name: "Offline", duration: 1)
        editor.mediaAssets.append(offline)
        editor.mediaManifest.entries.append(offline.toManifestEntry(projectURL: nil))
        editor.timeline.tracks.append(Fixtures.audioTrack(clips: [Fixtures.clip(id: "offline-clip", mediaRef: offline.id, mediaType: .audio, start: 200, duration: 30)]))
        try FileManager.default.moveItem(at: offlineURL, to: offlineURL.appendingPathExtension("missing"))
        editor.captionTranscriptionClient = .init(transcribe: { _, _, _, _, _ in Self.transcript }, supportedLocales: { [] })
        let tool = ToolExecutor(editor: editor)
        let original = editor.timeline
        do {
            _ = try await tool.prepareWordRemoval(editor, ["words": [1]])
            Issue.record("A native speech proposal must not use an offline source.")
        } catch {
            #expect(error.localizedDescription == "A caption source is unavailable. Relink it before preparing changes.")
        }
        #expect(editor.timeline == original)
        let transcript = try await tool.timelineWords(editor)
        #expect(transcript.words.count == 3 && transcript.skipped.count == 1)
        #expect(transcript.skipped[0]["clipId"] as? String == "offline-clip")
        _ = try await tool.removeWords(editor, ["words": [1]])
        #expect(editor.timeline.tracks[0].clips.map(\.durationFrames) == [30, 90])
        #expect(editor.timeline.tracks[3].clips.first?.startFrame == 170)
    }

    @Test func failedTranscriptionRefusesPartialNativeSpeechProposalWithoutMutation() async throws {
        let (editor, source) = try fixture()
        let secondURL = source.deletingLastPathComponent().appendingPathComponent("Second.wav")
        let secondBytes = Data("untranscribable second source".utf8)
        try secondBytes.write(to: secondURL)
        let second = MediaAsset(id: "second", url: secondURL, type: .audio, name: "Second", duration: 1)
        editor.mediaAssets.append(second)
        editor.mediaManifest.entries.append(second.toManifestEntry(projectURL: nil))
        editor.timeline.tracks.append(Fixtures.audioTrack(clips: [Fixtures.clip(id: "second-clip", mediaRef: second.id,
            mediaType: .audio, start: 200, duration: 30)]))
        let calls = TranscriptCalls()
        editor.captionTranscriptionClient = .init(transcribe: { url, _, _, _, _ in
            calls.count += 1
            if try Data(contentsOf: url) == secondBytes { throw TranscriptionError.decodeFailed }
            return Self.transcript
        }, supportedLocales: { [] })
        let before = editor.timeline
        do {
            _ = try await ToolExecutor(editor: editor).prepareWordRemoval(editor, ["words": [1]])
            Issue.record("A partial transcript must not become an actionable speech proposal.")
        } catch {
            #expect(error.localizedDescription == "The complete speech transcript is unavailable. Relink or transcribe the missing source before requesting cuts.")
        }
        #expect(calls.count == 2)
        #expect(editor.timeline == before)
        #expect(try Data(contentsOf: source) == Data("original audio".utf8))
    }

    @Test func speechReadsTheResolvedManifestSourceInsteadOfStaleAssetURL() async throws {
        let (editor, source) = try fixture()
        let stale = source.appendingPathExtension("stale")
        try Data("stale bytes".utf8).write(to: stale)
        let asset = try #require(editor.mediaAssets.first { $0.id == "voice" })
        asset.url = stale
        let expected = try Data(contentsOf: source)
        editor.captionTranscriptionClient = .init(transcribe: { url, _, _, _, _ in
            let actual = try Data(contentsOf: url)
            #expect(actual == expected)
            return Self.transcript
        }, supportedLocales: { [] })
        let removal = try await ToolExecutor(editor: editor).prepareWordRemoval(editor, ["words": [1]])
        #expect(removal.edits.ranges == [.init(start: 30, end: 60)])
    }

    @Test func proposalRejectsIgnoredIndicesAndInvalidArgumentsBeforeReadingSources() async throws {
        let (editor, _) = try fixture()
        let calls = TranscriptCalls()
        editor.captionTranscriptionClient = .init(transcribe: { _, _, _, _, _ in calls.count += 1; return Self.transcript }, supportedLocales: { [] })
        let tool = ToolExecutor(editor: editor)
        await #expect(throws: (any Error).self) { try await tool.prepareWordRemoval(editor, ["words": []]) }
        #expect(calls.count == 0)
        await #expect(throws: (any Error).self) { try await tool.prepareWordRemoval(editor, ["words": [1, 999]]) }
        #expect(calls.count == 1)
        #expect(editor.timeline.tracks[0].clips.count == 1)
    }

    @Test func withdrawnNativeDecisionCannotApplyAnOtherwiseCurrentPlan() async throws {
        let (editor, _) = try fixture()
        let before = editor.timeline
        let scope = try await CaptionRevisionScope.capture(editor)
        let plan = try await CaptionRevisionPlan.captions([.init(clipID: "caption-a", text: "New name")],
            scope: scope, editor: editor)
        do {
            _ = try await plan.apply(selected: ["caption-a"], editor: editor, authorize: { false })
            Issue.record("A withdrawn native decision applied caption changes.")
        } catch {
            #expect(error.localizedDescription == "The caption decision changed. Reopen the proposal before applying it.")
        }
        #expect(editor.timeline == before)
    }

    @Test func exactLinkedWordCutUsesFrozenSourceAndOneRippleUndo() async throws {
        let (editor, source) = try fixture()
        let before = editor.timeline
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        editor.captionTranscriptionClient = .init(transcribe: { url, video, range, censor, locale in
            #expect(url != source && !video && range == nil && !censor && locale == nil)
            let actual = try Data(contentsOf: url)
            #expect(actual == Data("original audio".utf8))
            return Self.transcript
        }, supportedLocales: { [] })
        let tool = ToolExecutor(editor: editor)
        let removal = try await tool.prepareWordRemoval(editor, ["words": [1]])
        #expect(removal.ranges == [.init(start: 30, end: 60)])
        let plan = try await CaptionRevisionPlan.speech(removal, editor: editor)
        #expect(plan.rows[0].before == "Hello um world." && plan.rows[0].after == "Hello world.")
        #expect(plan.rows[0].timeRange == "1.00–2.00 s" && editor.timeline == before)
        #expect(try await plan.apply(selected: ["speech-cuts"], editor: editor) == 1)
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
        let captionScope = try await CaptionRevisionScope.capture(editor)
        await #expect(throws: (any Error).self) { try await tool.prepareWordRemoval(editor, ["words": [1]], scope: captionScope) }
        await #expect(throws: (any Error).self) {
            try await CaptionRevisionPlan.captions([.init(clipID: "picture", text: "Must not become text")], scope: captionScope, editor: editor)
        }
        let definition = try #require(ToolDefinitions.all.first { $0.name == .proposeCaptionRevision })
        let invalid: [[String: Any]] = [
            ["kind": "other", "changes": []],
            ["kind": "captions", "changes": [["clipId": "caption-a", "text": "Changed", "startFrame": 20]]],
            ["kind": "speech_cuts", "words": [true]],
            ["kind": "speech_cuts", "words": [[1, 2, 3]]],
            ["kind": "speech_cuts", "words": [1], "captionChanges": [["clipId": "caption-a", "text": "Kept", "duration": 4]]]
        ]
        for value in invalid {
            #expect(throws: (any Error).self) { try validateToolInput(in: value, against: definition.inputSchema, path: "propose_caption_revision") }
        }
        await #expect(throws: (any Error).self) {
            try await tool.proposeCaptionRevision(editor, ["kind": "captions", "changes": [], "words": [1]], origin: .direct)
        }
    }

    @MainActor private final class TranscriptCalls { var count = 0 }

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
        let videoURL = package.appendingPathComponent("Picture.mov")
        try Data("original video".utf8).write(to: videoURL)
        let video = MediaAsset(id: "video", url: videoURL, type: .video, name: "Picture", duration: 5)
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
