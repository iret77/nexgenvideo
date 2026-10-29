import Foundation
import Testing
@testable import NexGenVideo

@Suite("Trimmed upscale preserves linked source ranges")
@MainActor
struct UpscaleReplacementRangeTests {
    private let rangeError = "Linked clips use different source ranges. Unlink them or turn off Use trimmed portion only before replacing their source."

    @Test(arguments: ["start", "end", "consumed"])
    func linkingDifferentRangesBlocksOnlyTrimReset(change: String) throws {
        let editor = makeEditor(change: change)
        let picture = try #require(editor.clipFor(id: "picture"))
        let sound = try #require(editor.clipFor(id: "sound"))
        #expect(picture.linkGroupId != nil && picture.linkGroupId == sound.linkGroupId)
        let before = editor.timeline
        let snapshot = GenerationClipReplacement.Snapshot(clipID: picture.id, resetTrim: true, editor: editor)
        #expect(snapshot.targets.count == 2)
        do {
            try snapshot.requireCurrent(editor: editor)
            Issue.record("A trimmed replacement must not reset a different linked source range.")
        } catch { #expect(error.localizedDescription == rangeError) }
        try GenerationClipReplacement.Snapshot(clipID: picture.id, resetTrim: false, editor: editor)
            .requireCurrent(editor: editor)
        #expect(editor.timeline == before)
        #expect(editor.pendingReplacements.isEmpty)
    }

    @Test func separateNativeTrimKeepsItsLinkAndRequiresExplicitUnlinkBeforeTrimmedReplacement() throws {
        let editor = makeEditor()
        let group = try #require(editor.clipFor(id: "picture")?.linkGroupId)
        editor.commitTrim(clipId: "picture", edge: .left, deltaFrames: 3, propagateToLinked: false)
        #expect(editor.clipFor(id: "picture")?.linkGroupId == group)
        #expect(editor.clipFor(id: "sound")?.linkGroupId == group)
        #expect(editor.clipFor(id: "picture")?.trimStartFrame == 18)
        #expect(editor.clipFor(id: "sound")?.trimStartFrame == 15)
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "picture", resetTrim: true, editor: editor)
        #expect(throws: (any Error).self) { try snapshot.requireCurrent(editor: editor) }
        editor.unlinkClips(ids: ["picture"])
        let unlinked = GenerationClipReplacement.Snapshot(clipID: "picture", resetTrim: true, editor: editor)
        #expect(unlinked.targets.count == 1)
        try unlinked.requireCurrent(editor: editor)
    }

    @Test func equalSourceRangesCanHaveDifferentTimelinePositionsAndPlaybackRates() throws {
        let editor = makeEditor()
        editor.timeline.tracks[1].clips[0].startFrame = 20
        editor.timeline.tracks[1].clips[0].durationFrames = 30
        editor.timeline.tracks[1].clips[0].speed = 2
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "picture", resetTrim: true, editor: editor)
        try snapshot.requireCurrent(editor: editor)
        #expect(snapshot.targets.count == 2)
    }

    @Test func otherLinkedMediaDoesNotBecomeAReplacementTarget() throws {
        let editor = makeEditor(change: "start")
        editor.timeline.tracks[1].clips[0].mediaRef = "separate-audio"
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "picture", resetTrim: true, editor: editor)
        #expect(snapshot.targets.map(\.clip.id) == ["picture"])
        try snapshot.requireCurrent(editor: editor)
    }

    @Test(arguments: [false, true])
    func upscaleRetainsOriginalAudioAndOneUndoStep(resetTrim: Bool) throws {
        let editor = makeEditor(change: resetTrim ? nil : "start")
        editor.timeline.tracks[1].clips[0].speed = 2
        editor.timeline.tracks[1].clips[0].durationFrames = 30
        editor.timeline.tracks[1].clips[0].volume = 0.25
        editor.timeline.tracks[1].clips[0].fadeInFrames = 4
        editor.timeline.tracks[1].clips[0].fadeOutFrames = 6
        let before = editor.timeline
        let sound = try #require(editor.clipFor(id: "sound"))
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let request = GenerationRequest(modality: .upscale, modelId: "completion-only", intent: "",
            placement: .replaceClip(id: "picture", resetTrim: resetTrim), origin: .panel,
            submission: .upscale { _, _, _, _, _, _ in "not-submitted" })
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "picture", resetTrim: resetTrim, editor: editor)
        try snapshot.requireCurrent(editor: editor)
        let complete = try #require(GenerationController.replacementOnComplete(request, editor: editor,
            snapshot: snapshot, then: nil))
        editor.markPendingReplacement(clipId: "picture")
        let result = MediaAsset(id: "upscaled", url: URL(fileURLWithPath: "/silent-output.mp4"),
            type: .video, name: "Upscaled", duration: 2)
        result.hasAudio = false
        complete(result)
        let after = editor.timeline
        #expect(editor.clipFor(id: "picture")?.mediaRef == result.id)
        #expect(editor.clipFor(id: "picture")?.trimStartFrame == (resetTrim ? 0 : 15))
        #expect(editor.clipFor(id: "sound") == sound)
        #expect(editor.pendingReplacements.isEmpty)
        undo.undo()
        #expect(editor.timeline == before && !undo.canUndo)
        undo.redo()
        #expect(editor.timeline == after)
    }

    @Test func genericReplacementStillReplacesSameSourceAudio() {
        let editor = makeEditor()
        editor.replaceClipMediaRef(clipId: "picture", newAssetId: "generic-result", resetTrim: true)
        #expect(editor.clipFor(id: "picture")?.mediaRef == "generic-result")
        #expect(editor.clipFor(id: "sound")?.mediaRef == "generic-result")
        #expect(editor.clipFor(id: "sound")?.trimStartFrame == 0)
        #expect(editor.clipFor(id: "sound")?.trimEndFrame == 0)
    }

    @Test func mismatchFailsBeforeSourceReadPricingOrReviewAndReportsOnce() async throws {
        let editor = makeEditor(change: "start")
        let entry = try #require(FalModelRegistry.entries.first { $0.id == "fal-ai/topaz/upscale/video" })
        guard case .upscale(let caps) = entry.uiCapabilities else { Issue.record("Missing actual upscale capability"); return }
        let model = UpscaleModelConfig(entry: entry, caps: caps)
        let catalog = ModelCatalog(); catalog.load(entries: [entry])
        let suite = "UpscaleReplacementRangeTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var quotes = 0
        let services = GenerationPanelServices(catalog: catalog, preferences: ModelPreferences(defaults: defaults),
            activation: { .init() }, quoteLoader: { _, _ in quotes += 1; return GenerationPackageFixture.money() })
        let source = MediaAsset(id: "source", url: URL(fileURLWithPath: "/not-read/source.mov"),
            type: .video, name: "Source", duration: 3)
        source.sourceWidth = 960; source.sourceHeight = 540
        editor.mediaAssets = [source]
        let before = editor.timeline
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "picture", resetTrim: true, editor: editor)
        var failures = 0
        let result = await EditSubmitter.submitUpscale(asset: source, model: model, editor: editor,
            replacementTarget: snapshot, services: services, onFailure: { failures += 1 })
        #expect(result == nil)
        #expect(editor.mediaPanelToast?.message == rangeError)
        #expect(failures == 1 && quotes == 0)
        #expect(editor.timeline == before && editor.pendingReplacements.isEmpty)
        #expect(editor.mediaAssets.count == 1 && editor.generationLog.spendEvents.isEmpty)

        var input = GenerationInput(prompt: "", model: model.id, duration: 3, aspectRatio: "")
        input.sourceVideoAssetId = source.id
        input.sourceRange = .init(trim: nil)
        let previous = MediaAsset(id: "previous", url: URL(fileURLWithPath: "/not-read/previous.mp4"),
            type: .video, name: "Previous upscale", duration: 3, generationInput: input)
        editor.mediaPanelToast = nil
        failures = 0
        do {
            _ = try await EditSubmitter.rerun(asset: previous, editor: editor, onFailure: { failures += 1 },
                replacementTarget: snapshot, services: services)
            Issue.record("A real rerun error must reach its caller.")
        } catch { #expect(error.localizedDescription == rangeError) }
        #expect(editor.mediaPanelToast == nil)
        #expect(failures == 1 && quotes == 0)
        #expect(editor.timeline == before && editor.pendingReplacements.isEmpty)
    }

    private func makeEditor(change: String? = nil) -> EditorViewModel {
        let editor = EditorViewModel()
        let picture = Fixtures.clip(id: "picture", mediaRef: "source", start: 10, duration: 60, trimStart: 15, trimEnd: 9)
        var sound = picture; sound.id = "sound"; sound.mediaType = .audio
        switch change {
        case "start": sound.trimStartFrame += 3
        case "end": sound.trimEndFrame += 3
        case "consumed": sound.durationFrames -= 3
        default: break
        }
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(id: "video", clips: [picture]),
            Fixtures.audioTrack(id: "audio", clips: [sound])])
        editor.linkClips(ids: ["picture", "sound"])
        return editor
    }
}
