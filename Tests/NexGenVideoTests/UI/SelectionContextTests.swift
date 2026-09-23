import Foundation
import Testing

@testable import NexGenVideo

@MainActor
@Suite("Selection and source context")
struct SelectionContextTests {
    private func asset(
        _ id: String,
        type: ClipType = .video,
        duration: Double = 4,
        hasAudio: Bool = false
    ) -> MediaAsset {
        let asset = MediaAsset(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(id).mov"),
            type: type,
            name: id,
            duration: duration
        )
        asset.hasAudio = hasAudio
        return asset
    }

    private func editor(assets: [MediaAsset], tracks: [Track] = []) -> EditorViewModel {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: tracks)
        editor.mediaAssets = assets
        return editor
    }

    @Test func sourceAndTimelineKeepIndependentPlayheadsAndSelections() {
        let source = asset("source-a")
        let other = asset("source-b")
        let clip = Fixtures.clip(id: "clip-b", mediaRef: other.id, start: 30, duration: 60)
        let editor = editor(assets: [source, other], tracks: [Fixtures.videoTrack(clips: [clip])])

        editor.selectMediaAsset(source)
        editor.seekSourceToFrame(24)
        editor.markSourceIn()
        editor.seekSourceToFrame(72)
        editor.markSourceOut()
        editor.seekSourceToFrame(48)
        editor.currentFrame = 91

        editor.selectedClipIds = [clip.id]
        editor.activateTimelineSelection(inspectedClipID: clip.id)
        editor.trimClips([(clipId: clip.id, trimStartFrame: 5, trimEndFrame: 0)])

        #expect(editor.currentFrame == 91)
        #expect(editor.selectedMediaAssetIds == [source.id])
        #expect(editor.sourcePreviewState(for: source.id) == SourcePreviewState(
            playheadFrame: 48,
            inFrame: 24,
            outFrame: 72
        ))

        editor.activateMediaAsset(source, preservingSelection: true)

        #expect(editor.activeSourceAsset?.id == source.id)
        #expect(editor.sourcePlayheadFrame == 48)
        #expect(editor.activeSourcePreviewState?.inFrame == 24)
        #expect(editor.activeSourcePreviewState?.outFrame == 72)
        #expect(editor.currentFrame == 91)
        #expect(editor.selectedClipIds == [clip.id])
    }

    @Test func activeObjectIsIndependentFromRememberedMultiSelections() {
        let first = asset("first")
        let second = asset("second")
        let c1 = Fixtures.clip(id: "c1", mediaRef: first.id, start: 0, duration: 30)
        let c2 = Fixtures.clip(id: "c2", mediaRef: second.id, start: 30, duration: 30)
        let editor = editor(
            assets: [first, second],
            tracks: [Fixtures.videoTrack(clips: [c1, c2])]
        )

        editor.selectMediaAsset(first)
        editor.selectedMediaAssetIds.insert(second.id)
        editor.activateMediaAsset(second, preservingSelection: true)

        #expect(editor.selectedMediaAssetIds == [first.id, second.id])
        #expect(editor.activeSourceAsset?.id == second.id)
        #expect(editor.selectionInspectedObject == .mediaAsset(second.id))

        editor.selectedClipIds = [c1.id, c2.id]
        editor.activateTimelineSelection()

        #expect(editor.isTimelinePreviewActive)
        #expect(editor.selectedMediaAssetIds == [first.id, second.id])
        #expect(editor.selectedClipIds == [c1.id, c2.id])
        #expect(editor.inspectedObject == nil)

        editor.selectedClipIds.removeAll()
        editor.activateTimelineSelection()
        #expect(editor.inspectedObject == nil)
    }

    @Test func shiftSelectionCanDeselectActiveAndFinalSources() {
        let first = asset("first")
        let second = asset("second")
        let editor = editor(assets: [first, second])

        editor.selectMediaAsset(first)
        editor.toggleMediaAssetSelection(second)
        #expect(editor.selectedMediaAssetIds == [first.id, second.id])
        #expect(editor.activeSourceAsset?.id == second.id)

        editor.toggleMediaAssetSelection(second)
        #expect(editor.selectedMediaAssetIds == [first.id])
        #expect(editor.activeSourceAsset?.id == second.id)
        #expect(editor.inspectedObject == .mediaAsset(second.id))

        editor.toggleMediaAssetSelection(first)
        #expect(editor.selectedMediaAssetIds.isEmpty)
        #expect(editor.activeSourceAsset?.id == first.id)
        #expect(editor.inspectedObject == .mediaAsset(first.id))
    }

    @Test func rememberedSourcesKeepIndependentPlayheads() {
        let first = asset("first")
        let second = asset("second")
        let editor = editor(assets: [first, second])

        editor.selectMediaAsset(first)
        editor.seekSourceToFrame(12)
        editor.selectMediaAsset(second)
        editor.seekSourceToFrame(30)

        editor.activatePreviousSource()
        #expect(editor.activeSourceAsset?.id == first.id)
        #expect(editor.sourcePlayheadFrame == 12)
        #expect(editor.inspectedObject == .mediaAsset(first.id))

        editor.activateNextSource()
        #expect(editor.activeSourceAsset?.id == second.id)
        #expect(editor.sourcePlayheadFrame == 30)

        editor.applyTimelineSettings(fps: 60, width: 1920, height: 1080)
        #expect(editor.sourcePreviewState(for: first.id).playheadFrame == 24)
        #expect(editor.sourcePreviewState(for: second.id).playheadFrame == 60)
        #expect(editor.sourcePlayheadFrame == 60)
    }

    @Test func selectingATitleMakesThatTimelineObjectActive() {
        let title = Fixtures.clip(
            id: "title",
            mediaRef: "",
            mediaType: .text,
            start: 0,
            duration: 60
        )
        let editor = editor(assets: [], tracks: [Fixtures.videoTrack(clips: [title])])

        editor.selectedClipIds = [title.id]
        editor.activateTimelineSelection(inspectedClipID: title.id)

        #expect(editor.isTimelinePreviewActive)
        #expect(editor.inspectedObject == .clip(title.id))
        #expect(editor.selectionInspectedObject == .clip(title.id))
    }

    @Test func sourceInsertAndOverwriteUseRangeAndUndoWithoutChangingSourceContext() {
        let source = asset("source")
        let downstream = Fixtures.clip(id: "downstream", mediaRef: "other", start: 60, duration: 30)
        let editor = editor(assets: [source], tracks: [Fixtures.videoTrack(clips: [downstream])])
        let undoManager = UndoManager()
        editor.undoManager = undoManager
        editor.selectedClipIds = [downstream.id]
        editor.currentFrame = 30
        editor.selectMediaAsset(source)
        editor.seekSourceToFrame(15)
        editor.markSourceIn()
        editor.seekSourceToFrame(45)
        editor.markSourceOut()

        let inserted = editor.insertActiveSource()

        #expect(inserted.count == 1)
        #expect(editor.clipFor(id: downstream.id)?.startFrame == 90)
        #expect(editor.clipFor(id: inserted[0])?.startFrame == 30)
        #expect(editor.clipFor(id: inserted[0])?.durationFrames == 30)
        #expect(editor.clipFor(id: inserted[0])?.trimStartFrame == 15)
        #expect(undoManager.undoActionName == "Insert Source")

        undoManager.undo()

        #expect(editor.clipFor(id: downstream.id)?.startFrame == 60)
        #expect(editor.clipFor(id: inserted[0]) == nil)
        #expect(editor.activeSourceAsset?.id == source.id)
        #expect(editor.activeSourcePreviewState?.inFrame == 15)
        #expect(editor.activeSourcePreviewState?.outFrame == 45)

        let overwritten = editor.overwriteActiveSource()
        #expect(overwritten.count == 1)
        #expect(editor.clipFor(id: overwritten[0])?.startFrame == 30)
        #expect(editor.clipFor(id: overwritten[0])?.durationFrames == 30)
        #expect(undoManager.undoActionName == "Overwrite Source")

        undoManager.undo()
        #expect(editor.timeline.tracks.flatMap(\.clips) == [downstream])
        #expect(editor.activeSourceAsset?.id == source.id)
    }

    @Test func lockedLinkedAndRippleEditsAreAtomicWhileSourceRangeStaysEditable() {
        let source = asset("source", hasAudio: true)
        var video = Fixtures.clip(id: "video", mediaRef: source.id, start: 0, duration: 60)
        video.linkGroupId = "pair"
        var audio = Fixtures.clip(id: "audio", mediaRef: source.id, mediaType: .audio, start: 0, duration: 60)
        audio.linkGroupId = "pair"
        var lockedAudioTrack = Fixtures.audioTrack(clips: [audio])
        lockedAudioTrack.editLocked = true
        let editor = editor(
            assets: [source],
            tracks: [Fixtures.videoTrack(clips: [video]), lockedAudioTrack]
        )
        let original = editor.timeline

        editor.applyTimelineSettings(fps: 24, width: 1920, height: 1080)

        #expect(editor.splitClip(clipId: video.id, atFrame: 30).isEmpty)
        editor.moveClips([
            (clipId: video.id, toTrack: 0, toFrame: 30),
            (clipId: audio.id, toTrack: 1, toFrame: 30),
        ])
        editor.addClips(
            assets: [source],
            trackIndex: 0,
            startFrame: 90,
            linkedAudioTrackIndex: 1
        )
        let inserted = editor.rippleInsertClips(assets: [source], trackIndex: 0, atFrame: 30)

        #expect(inserted.isEmpty)
        #expect(editor.timeline == original)
        #expect(!editor.canDeleteMediaAssets(ids: [source.id]))

        editor.selectedClipIds = [audio.id]
        editor.selectMediaAsset(source)
        editor.seekSourceToFrame(12)
        editor.markSourceIn()
        editor.seekSourceToFrame(36)
        editor.markSourceOut()

        #expect(editor.activeSourcePreviewState?.inFrame == 12)
        #expect(editor.activeSourcePreviewState?.outFrame == 36)
        #expect(editor.canEditActiveSourceRange)
        #expect(!editor.canInsertActiveSource)
        #expect(editor.canOverwriteActiveSource)

        let beforeInsert = editor.timeline
        #expect(editor.insertActiveSource().isEmpty)
        #expect(editor.timeline == beforeInsert)
        #expect(!editor.overwriteActiveSource().isEmpty)
        #expect(editor.clipFor(id: video.id) == video)
        #expect(editor.clipFor(id: audio.id) == audio)
    }

    @Test func offlineAndDocumentSourcesExposeOnlyValidCommands() {
        let video = asset("offline")
        let document = asset("notes", type: .document, duration: 0)
        let editor = editor(assets: [video, document])

        editor.offlineMediaRefs = [video.id]
        editor.selectMediaAsset(video)
        #expect(!editor.canPlaceActiveSource)
        #expect(editor.canEditActiveSourceRange)

        editor.selectMediaAsset(document)
        #expect(!editor.canPlaceActiveSource)
        #expect(!editor.canEditActiveSourceRange)
        #expect(editor.activeSourceSelectedFrames == nil)
    }

    @Test func lockedCaptionTrackDisablesAtomicFillerRemoval() {
        var caption = Fixtures.clip(
            id: "caption",
            mediaRef: "",
            mediaType: .text,
            start: 0,
            duration: 30
        )
        caption.captionGroupId = "captions"
        caption.textContent = "Um hello"
        var track = Fixtures.videoTrack(clips: [caption])
        track.editLocked = true
        let editor = editor(assets: [], tracks: [track])
        let original = editor.timeline

        #expect(!editor.canRemoveFillerWordsFromCaptions)
        #expect(editor.removeFillerWordsFromCaptions() == 0)
        #expect(editor.timeline == original)

        editor.toggleTrackEditLock(trackIndex: 0)
        #expect(editor.canRemoveFillerWordsFromCaptions)
        #expect(editor.removeFillerWordsFromCaptions() == 1)
        #expect(editor.clipFor(id: caption.id)?.textContent == "hello")
    }

    @Test func trackEditLockIsUndoableAndRedoable() {
        let editor = editor(assets: [], tracks: [Fixtures.videoTrack()])
        let undoManager = UndoManager()
        editor.undoManager = undoManager

        editor.toggleTrackEditLock(trackIndex: 0)
        #expect(editor.timeline.tracks[0].editLocked)
        #expect(undoManager.undoActionName == "Lock Track")

        undoManager.undo()
        #expect(!editor.timeline.tracks[0].editLocked)
        #expect(undoManager.redoActionName == "Lock Track")

        undoManager.redo()
        #expect(editor.timeline.tracks[0].editLocked)
    }

    @Test func multitrackPasteIsDisabledAndAtomicWhenAnyDestinationIsLocked() {
        let video = Fixtures.clip(id: "video", mediaRef: "video", start: 0, duration: 30)
        let audio = Fixtures.clip(
            id: "audio",
            mediaRef: "audio",
            mediaType: .audio,
            start: 0,
            duration: 30
        )
        var lockedAudioTrack = Fixtures.audioTrack(clips: [audio])
        lockedAudioTrack.editLocked = true
        let editor = editor(
            assets: [],
            tracks: [Fixtures.videoTrack(clips: [video]), lockedAudioTrack]
        )
        editor.selectedClipIds = [video.id, audio.id]
        editor.copySelectedClipsToClipboard()
        editor.currentFrame = 60
        let original = editor.timeline

        #expect(!editor.canPasteClips)
        #expect(!editor.canPasteClips(atTrack: 0))
        editor.pasteClipsAtPlayhead()
        editor.pasteClips(atTrack: 0, atFrame: 60)
        #expect(editor.timeline == original)
    }

    @Test func pasteCannotOverwriteAClipWhoseLinkedPartnerIsLocked() {
        var targetVideo = Fixtures.clip(id: "target-video", start: 0, duration: 30)
        targetVideo.linkGroupId = "target-pair"
        let copied = Fixtures.clip(id: "copied", start: 60, duration: 30)
        var targetAudio = Fixtures.clip(
            id: "target-audio",
            mediaType: .audio,
            start: 0,
            duration: 30
        )
        targetAudio.linkGroupId = "target-pair"
        var lockedAudioTrack = Fixtures.audioTrack(clips: [targetAudio])
        lockedAudioTrack.editLocked = true
        let editor = editor(
            assets: [],
            tracks: [Fixtures.videoTrack(clips: [targetVideo, copied]), lockedAudioTrack]
        )
        editor.selectedClipIds = [copied.id]
        editor.copySelectedClipsToClipboard()
        editor.currentFrame = 0
        let original = editor.timeline

        #expect(!editor.canPasteClips(atTrack: 0))
        editor.pasteClips(atTrack: 0, atFrame: 0)
        #expect(editor.timeline == original)
    }

    @Test func deletingActiveObjectsAndUndoRestoresExactContext() {
        let source = asset("source")
        let clip = Fixtures.clip(id: "clip", mediaRef: source.id, start: 0, duration: 60)
        let editor = editor(assets: [source], tracks: [Fixtures.videoTrack(clips: [clip])])
        let undoManager = UndoManager()
        editor.undoManager = undoManager

        editor.selectedClipIds = [clip.id]
        editor.activateTimelineSelection(inspectedClipID: clip.id)
        editor.removeClips(ids: [clip.id])

        #expect(editor.clipFor(id: clip.id) == nil)
        #expect(editor.inspectedObject == nil)
        undoManager.undo()
        #expect(editor.clipFor(id: clip.id) == clip)
        #expect(editor.selectedClipIds == [clip.id])
        #expect(editor.inspectedObject == .clip(clip.id))

        undoManager.removeAllActions()
        editor.selectMediaAsset(source)
        editor.seekSourceToFrame(18)
        editor.markSourceIn()
        editor.deleteMediaAssets(ids: [source.id])

        #expect(editor.activeSourceAsset == nil)
        #expect(editor.mediaAssets.isEmpty)
        undoManager.undo()
        #expect(editor.mediaAssets.map(\.id) == [source.id])
        #expect(editor.activeSourceAsset?.id == source.id)
        #expect(editor.selectedMediaAssetIds == [source.id])
        #expect(editor.inspectedObject == .mediaAsset(source.id))
        #expect(editor.activeSourcePreviewState?.inFrame == 18)
    }
}
