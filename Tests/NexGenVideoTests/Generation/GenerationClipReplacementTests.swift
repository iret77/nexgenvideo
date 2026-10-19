import Foundation
import Testing
@testable import NexGenVideo

@Suite("Generated replacement protects the reviewed target")
@MainActor
struct GenerationClipReplacementTests {
    @Test(arguments: [true, false])
    func linkedReplacementIsOneUndoRedoStep(resetTrim: Bool) {
        let editor = makeEditor()
        let before = editor.timeline
        let undo = UndoManager(); undo.groupsByEvent = false
        editor.undoManager = undo
        let handlers = completion(clipID: "picture", resetTrim: resetTrim, editor: editor)
        handlers(output())
        let after = editor.timeline
        #expect(editor.clipFor(id: "picture")?.mediaRef == "result")
        #expect(editor.clipFor(id: "sound")?.mediaRef == "source")
        #expect(editor.clipFor(id: "unrelated")?.mediaRef == "source")
        #expect(editor.clipFor(id: "picture")?.trimStartFrame == (resetTrim ? 0 : 15))
        #expect(editor.clipFor(id: "sound")?.trimEndFrame == 9)
        #expect(editor.pendingReplacements.isEmpty)
        undo.undo()
        #expect(editor.timeline == before)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(editor.timeline == after)
        handlers(output("second-output"))
        #expect(editor.timeline == after)
    }

    @Test(arguments: ["anchor", "linked", "added-link", "removed-link", "fps", "relocated"])
    func delayedCompletionNeverOverwritesChangedTarget(change: String) {
        let editor = makeEditor()
        let handlers = completion(clipID: "picture", resetTrim: true, editor: editor)
        switch change {
        case "anchor": editor.timeline.tracks[0].clips[0].trimStartFrame += 1
        case "linked": editor.timeline.tracks[1].clips[0].volume = 0.25
        case "added-link":
            var clip = Fixtures.clip(id: "new-link", start: 70, duration: 20)
            clip.mediaRef = "source"; clip.linkGroupId = "pair"
            editor.timeline.tracks[0].clips.append(clip)
        case "removed-link": editor.timeline.tracks[1].clips.removeFirst()
        case "relocated":
            let clip = editor.timeline.tracks[0].clips.removeFirst()
            editor.timeline.tracks[1].clips.append(clip)
        default: editor.timeline.fps = 24
        }
        let current = editor.timeline
        let generated = output()
        editor.mediaAssets.append(generated)
        handlers(generated)
        #expect(editor.timeline == current)
        #expect(editor.mediaAssets.contains(where: { $0.id == generated.id }))
        #expect(editor.mediaPanelToast != nil)
        #expect(editor.pendingReplacements.isEmpty)
    }

    @Test func unrelatedEditDoesNotPreventReplacement() {
        let editor = makeEditor()
        let handlers = completion(clipID: "picture", resetTrim: false, editor: editor)
        editor.timeline.tracks[0].clips[1].opacity = 0.4
        handlers(output())
        #expect(editor.clipFor(id: "picture")?.mediaRef == "result")
        #expect(editor.clipFor(id: "unrelated")?.opacity == 0.4)

    }

    @Test func closeAndReopenSameProjectInvalidatesOldCompletion() throws {
        let editor = makeEditor()
        let original = editor.timeline
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = directory.appendingPathComponent("Replacement.ngv")
        try Fixtures.prepareProjectPackage(at: package, timeline: original)
        defer { try? FileManager.default.removeItem(at: directory) }
        editor.projectURL = package
        let generation = try #require(editor.openWorkingCopyGeneration)
        let key = try #require(editor.openWorkingCopyKey)
        let home = try #require(editor.workingRoot)
        let handlers = completion(clipID: "picture", resetTrim: true, editor: editor)
        editor.projectURL = nil
        editor.projectURL = package
        editor.timeline = original
        #expect(editor.openWorkingCopyKey == key)
        #expect(editor.workingRoot == home)
        #expect(editor.openWorkingCopyGeneration != generation)
        let before = editor.timeline
        handlers(output())
        #expect(editor.timeline == before)
    }

    @Test func missingTargetIsAVisibleFailure() {
        let editor = makeEditor()
        let handlers = completion(clipID: "missing", resetTrim: false, editor: editor)
        let before = editor.timeline
        handlers(output())
        #expect(editor.timeline == before)
        #expect(editor.mediaPanelToast != nil)
        #expect(editor.pendingReplacements.isEmpty)
    }

    @Test(arguments: [false, true])
    func audioCompletionProtectsTheReviewedClip(changed: Bool) throws {
        let editor = makeEditor()
        let request = try audioRequest(clipID: "sound", resetTrim: false)
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "sound", resetTrim: false, editor: editor)
        let complete = try #require(GenerationController.audioOnComplete(request, editor: editor,
            snapshot: snapshot, then: nil))
        editor.markPendingReplacement(clipId: "sound")
        if changed { editor.timeline.tracks[1].clips[0].trimStartFrame += 1 }
        let before = editor.timeline
        let picture = try #require(editor.clipFor(id: "picture"))
        let generated = MediaAsset(id: "audio-result", url: URL(fileURLWithPath: "/generated.wav"),
            type: .audio, name: "Generated audio", duration: 2)
        editor.mediaAssets.append(generated)
        complete(generated)
        if changed {
            #expect(editor.timeline == before)
            #expect(editor.mediaPanelToast != nil)
        } else { #expect(editor.clipFor(id: "sound")?.mediaRef == generated.id) }
        #expect(editor.clipFor(id: "picture") == picture)
        #expect(editor.mediaAssets.contains { $0.id == generated.id })
        #expect(editor.pendingReplacements.isEmpty)
    }

    @Test(arguments: [false, true])
    func audioReplacementPreservesPairedPictureAndIsOneUndoRedoStep(resetTrim: Bool) throws {
        let editor = makeEditor()
        editor.timeline.tracks[0].clips[0].trimStartFrame = 20
        var second = try #require(editor.clipFor(id: "sound"))
        second.id = "second-sound"; second.volume = 0.25
        editor.timeline.tracks[1].clips.append(second)
        editor.linkClips(ids: ["picture", "sound", "second-sound"])
        let before = editor.timeline
        let picture = try #require(editor.clipFor(id: "picture"))
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "sound", resetTrim: resetTrim, editor: editor)
        #expect(snapshot.targets.count == 3)
        #expect(editor.clipFor(id: "sound")?.sourceClipType == .video)
        try snapshot.requireCurrent(editor: editor, modality: .audio)
        let complete = try #require(GenerationController.audioOnComplete(try audioRequest(clipID: "sound", resetTrim: resetTrim),
            editor: editor, snapshot: snapshot, then: nil))
        editor.markPendingReplacement(clipId: "sound")
        let generated = audioOutput()
        editor.mediaAssets.append(generated)
        complete(generated)
        let after = editor.timeline
        #expect(editor.clipFor(id: "picture") == picture)
        #expect(editor.clipFor(id: "unrelated")?.mediaRef == "source")
        for id in ["sound", "second-sound"] {
            let clip = try #require(editor.clipFor(id: id))
            #expect(clip.mediaRef == generated.id && clip.mediaType == .audio)
            #expect(clip.trimStartFrame == (resetTrim ? 0 : 15))
            #expect(clip.trimEndFrame == (resetTrim ? 0 : 9))
        }
        #expect(editor.clipFor(id: "second-sound")?.volume == 0.25)
        #expect(editor.pendingReplacements.isEmpty)
        undo.undo()
        #expect(editor.timeline == before && !undo.canUndo)
        undo.redo()
        #expect(editor.timeline == after)
    }

    @Test func differentLinkedAudioRangesStillRefuseTrimReset() throws {
        let editor = makeEditor()
        var second = try #require(editor.clipFor(id: "sound"))
        second.id = "second-sound"; second.trimStartFrame += 1
        editor.timeline.tracks[1].clips.append(second)
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "sound", resetTrim: true, editor: editor)
        #expect(throws: (any Error).self) { try snapshot.requireCurrent(editor: editor, modality: .audio) }
        try GenerationClipReplacement.Snapshot(clipID: "sound", resetTrim: false, editor: editor)
            .requireCurrent(editor: editor, modality: .audio)
    }

    @Test func audioOntoPictureFailsBeforePreparationOrSpend() async throws {
        let editor = makeEditor()
        let before = editor.timeline
        var preflightCalls = 0
        let result = await GenerationController.prepare(try audioRequest(clipID: "picture", resetTrim: false),
            editor: editor, preflight: { preflightCalls += 1; return nil })
        guard case .failure(let error) = result else { Issue.record("Audio cannot replace the picture anchor."); return }
        #expect(error.localizedDescription.contains("Audio generation replaces audio clips"))
        #expect(preflightCalls == 0 && editor.generationLog.spendEvents.isEmpty)
        #expect(editor.timeline == before && editor.pendingReplacements.isEmpty)
    }

    @Test func wrongActualResultTypeDoesNotReplaceOrLoseTheGeneratedAsset() throws {
        let editor = makeEditor()
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "sound", resetTrim: false, editor: editor)
        let complete = try #require(GenerationController.audioOnComplete(try audioRequest(clipID: "sound", resetTrim: false),
            editor: editor, snapshot: snapshot, then: nil))
        editor.markPendingReplacement(clipId: "sound")
        let before = editor.timeline
        let wrong = output()
        editor.mediaAssets.append(wrong)
        complete(wrong)
        #expect(editor.timeline == before && editor.pendingReplacements.isEmpty)
        #expect(editor.mediaAssets.contains { $0 === wrong })
        #expect(editor.mediaPanelToast?.message.contains("type does not match the approved generation") == true)
    }

    @Test func sharedSetterUsesActualAudioTypeAndCannotReplaceThePicture() throws {
        let editor = makeEditor()
        let generated = audioOutput()
        editor.mediaAssets.append(generated)
        let before = editor.timeline
        editor.replaceClipMediaRef(clipId: "picture", newAssetId: generated.id)
        #expect(editor.timeline == before)
        editor.replaceClipMediaRef(clipId: "sound", newAssetId: generated.id, replacementType: .video)
        #expect(editor.timeline == before)
        editor.replaceClipMediaRef(clipId: "sound", newAssetId: generated.id)
        #expect(editor.clipFor(id: "sound")?.mediaRef == generated.id)
        #expect(editor.clipFor(id: "picture") == before.tracks[0].clips[0])
    }

    @Test func lateFailureCannotClearAnotherOpenGenerationPendingMarker() throws {
        let editor = makeEditor()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = directory.appendingPathComponent("Replacement.ngv")
        try Fixtures.prepareProjectPackage(at: package, timeline: editor.timeline)
        defer { try? FileManager.default.removeItem(at: directory) }
        editor.projectURL = package
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "picture", resetTrim: false, editor: editor)
        let request = GenerationRequest(modality: .upscale, modelId: "callback-fixture", intent: "",
            placement: .replaceClip(id: "picture", resetTrim: false), origin: .panel,
            submission: .upscale { _, _, _, _, _, _ in "not-executed" })
        let failed = try #require(GenerationController.failureHandler(request, editor: editor,
            snapshot: snapshot, then: nil))
        editor.projectURL = nil
        editor.projectURL = package
        editor.markPendingReplacement(clipId: "picture")
        let current = editor.pendingReplacements
        #expect(!current.isEmpty)
        failed()
        #expect(editor.pendingReplacements == current)
    }

    private func audioRequest(clipID: String, resetTrim: Bool) throws -> GenerationRequest {
        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries)
        let model = try #require(catalog.audio.first)
        return GenerationRequest(modality: .audio, modelId: model.id, intent: "A quiet pulse",
            placement: .replaceClip(id: clipID, resetTrim: resetTrim), origin: .panel,
            submission: .audio { compiled in
                AudioGenerationSubmission.make(
                    genInput: GenerationInput(prompt: compiled, model: model.id, duration: 2, aspectRatio: ""),
                    model: model, params: AudioGenerationParams(prompt: compiled, voice: nil, lyrics: nil,
                        styleInstructions: nil, instrumental: false, durationSeconds: 2))
            })
    }

    private func audioOutput() -> MediaAsset {
        MediaAsset(id: "audio-result", url: URL(fileURLWithPath: "/generated.wav"), type: .audio, name: "Generated audio", duration: 2)
    }

    private func completion(clipID: String, resetTrim: Bool, editor: EditorViewModel) -> @MainActor (MediaAsset) -> Void {
        let snapshot = GenerationClipReplacement.Snapshot(clipID: clipID, resetTrim: resetTrim, editor: editor)
        let request = GenerationRequest(modality: .upscale, modelId: "unused-callback-fixture", intent: "",
            placement: .replaceClip(id: clipID, resetTrim: resetTrim), origin: .panel,
            submission: .upscale { _, _, _, _, _, _ in "not-executed" })
        editor.markPendingReplacement(clipId: clipID)
        return GenerationController.replacementOnComplete(request, editor: editor, snapshot: snapshot, then: nil)!
    }

    private func makeEditor() -> EditorViewModel {
        let editor = EditorViewModel()
        var picture = Fixtures.clip(id: "picture", mediaRef: "source", start: 10, duration: 60, trimStart: 15, trimEnd: 9)
        picture.linkGroupId = "pair"
        var sound = picture; sound.id = "sound"; sound.mediaType = .audio
        let unrelated = Fixtures.clip(id: "unrelated", mediaRef: "source", start: 80, duration: 30)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(id: "video", clips: [picture, unrelated]),
            Fixtures.audioTrack(id: "audio", clips: [sound])])
        return editor
    }

    private func output(_ id: String = "result") -> MediaAsset {
        MediaAsset(id: id, url: URL(fileURLWithPath: "/generated.mov"), type: .video, name: "Generated", duration: 2)
    }
}
