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
        #expect(editor.clipFor(id: "sound")?.mediaRef == "result")
        #expect(editor.clipFor(id: "unrelated")?.mediaRef == "source")
        #expect(editor.clipFor(id: "picture")?.trimStartFrame == (resetTrim ? 0 : 15))
        #expect(editor.clipFor(id: "sound")?.trimEndFrame == (resetTrim ? 0 : 9))
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
