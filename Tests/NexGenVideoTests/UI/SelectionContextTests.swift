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
        editor.activateTimelineSelection()
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

    @Test func contextActivatedClipOverridesRememberedBatchWithoutReplacingIt() {
        let firstAsset = asset("first")
        let secondAsset = asset("second")
        let first = Fixtures.clip(id: "first-clip", mediaRef: firstAsset.id, start: 0, duration: 30)
        let second = Fixtures.clip(id: "second-clip", mediaRef: secondAsset.id, start: 30, duration: 30)
        let editor = editor(
            assets: [firstAsset, secondAsset],
            tracks: [Fixtures.videoTrack(clips: [first, second])]
        )
        editor.selectedClipIds = [first.id, second.id]

        editor.activateTimelineSelection()
        #expect(editor.isTimelineBatchSelection)
        #expect(editor.inspectedObject == nil)
        #expect(editor.selectionContextHint == "2 timeline clips are selected")

        editor.activateTimelineClipContext(second.id)

        #expect(editor.selectedClipIds == [first.id, second.id])
        #expect(!editor.isTimelineBatchSelection)
        #expect(editor.activeTimelineInspectionClipID == second.id)
        #expect(editor.timelineInspectorClipIDs == [second.id])
        #expect(editor.inspectedObject == .clip(second.id))
        #expect(editor.selectionInspectedObject == .clip(second.id))
        #expect(editor.selectionContextHint?.contains("second") == true)

        editor.activateTimelineSelection()
        #expect(editor.isTimelineBatchSelection)
        #expect(editor.inspectedObject == nil)
    }

    @Test func linkedAVSelectionRemainsAnIntentionalBatch() {
        let source = asset("source", hasAudio: true)
        var video = Fixtures.clip(id: "video", mediaRef: source.id, start: 0, duration: 30)
        video.linkGroupId = "pair"
        var audio = Fixtures.clip(
            id: "audio",
            mediaRef: source.id,
            mediaType: .audio,
            start: 0,
            duration: 30
        )
        audio.linkGroupId = "pair"
        let editor = editor(
            assets: [source],
            tracks: [Fixtures.videoTrack(clips: [video]), Fixtures.audioTrack(clips: [audio])]
        )
        editor.selectedClipIds = editor.expandToLinkGroup([video.id])

        editor.activateTimelineSelection()

        #expect(editor.isTimelineBatchSelection)
        #expect(editor.timelineInspectorClipIDs == [video.id, audio.id])
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
        editor.activateTimelineSelection()

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

    @Test func sourceOverwriteReplacesLinkedAudioOnItsExistingTrack() {
        let oldSource = asset("old", hasAudio: true)
        let newSource = asset("new", hasAudio: true)
        var oldVideo = Fixtures.clip(id: "old-video", mediaRef: oldSource.id, start: 0, duration: 90)
        oldVideo.linkGroupId = "old-pair"
        var oldAudio = Fixtures.clip(
            id: "old-audio",
            mediaRef: oldSource.id,
            mediaType: .audio,
            start: 0,
            duration: 90
        )
        oldAudio.linkGroupId = "old-pair"
        let editor = editor(
            assets: [oldSource, newSource],
            tracks: [Fixtures.videoTrack(clips: [oldVideo]), Fixtures.audioTrack(clips: [oldAudio])]
        )
        editor.selectedClipIds = [oldVideo.id]
        editor.currentFrame = 30
        editor.selectMediaAsset(newSource)
        editor.seekSourceToFrame(0)
        editor.markSourceIn()
        editor.seekSourceToFrame(30)
        editor.markSourceOut()

        let created = editor.overwriteActiveSource()

        #expect(created.count == 2)
        #expect(editor.timeline.tracks.count == 2)
        let videos = editor.timeline.tracks[0].clips
        let audios = editor.timeline.tracks[1].clips
        #expect(videos.count == 3)
        #expect(audios.count == 3)
        #expect(videos.map(\.startFrame) == [0, 30, 60])
        #expect(audios.map(\.startFrame) == [0, 30, 60])
        #expect(videos.first { $0.startFrame == 30 }?.mediaRef == newSource.id)
        #expect(audios.first { $0.startFrame == 30 }?.mediaRef == newSource.id)
        #expect(!videos.contains { $0.id == oldVideo.id && $0.durationFrames == 90 })
        #expect(!audios.contains { $0.id == oldAudio.id && $0.durationFrames == 90 })
    }

    @Test func timelineUndoAndRedoDoNotReplaceANewerSourceContext() {
        let source = asset("source")
        let clip = Fixtures.clip(id: "clip", mediaRef: source.id, start: 0, duration: 30)
        let editor = editor(assets: [source], tracks: [Fixtures.videoTrack(clips: [clip])])
        let undoManager = UndoManager()
        editor.undoManager = undoManager
        editor.selectedClipIds = [clip.id]
        editor.activateTimelineSelection()
        editor.moveClips([(clipId: clip.id, toTrack: 0, toFrame: 30)])
        editor.selectMediaAsset(source)

        undoManager.undo()
        #expect(editor.clipFor(id: clip.id)?.startFrame == 0)
        #expect(editor.activeSourceAsset?.id == source.id)
        #expect(editor.inspectedObject == .mediaAsset(source.id))

        undoManager.redo()
        #expect(editor.clipFor(id: clip.id)?.startFrame == 30)
        #expect(editor.activeSourceAsset?.id == source.id)
        #expect(editor.inspectedObject == .mediaAsset(source.id))
    }

    @Test func sourceTransportCommandsNeverMoveTheRememberedTimelinePlayhead() {
        let source = asset("source")
        let editor = editor(assets: [source])
        editor.currentFrame = 70
        editor.selectMediaAsset(source)
        editor.seekSourceToFrame(10)

        editor.stepForward()
        editor.skipForward()
        editor.stepBackward()
        editor.skipBackward(frames: 3)

        #expect(editor.sourcePlayheadFrame == 12)
        #expect(editor.currentFrame == 70)
    }

    @Test func reactivatingTheSameSourcePreservesPlaybackAndStillImagesCannotPlay() {
        let video = asset("video")
        let image = asset("image", type: .image)
        let editor = editor(assets: [video, image])
        editor.selectMediaAsset(video)
        editor.isPlaying = true

        editor.activateMediaAsset(video, preservingSelection: true)
        #expect(editor.isPlaying)

        editor.selectMediaAsset(image)
        editor.isPlaying = true
        editor.toggleSourcePlayback()
        #expect(!editor.isPlaying)
    }

    @Test func rippleInsertMovesUnlockedDownstreamLinkedPartnersAndRefusesLockedOnes() {
        let insertedSource = asset("inserted", duration: 1)
        var downstreamVideo = Fixtures.clip(id: "downstream-video", start: 60, duration: 30)
        downstreamVideo.linkGroupId = "downstream-pair"
        var downstreamAudio = Fixtures.clip(
            id: "downstream-audio",
            mediaType: .audio,
            start: 60,
            duration: 30
        )
        downstreamAudio.linkGroupId = "downstream-pair"
        let unlocked = editor(
            assets: [insertedSource],
            tracks: [
                Fixtures.videoTrack(clips: [downstreamVideo]),
                Fixtures.audioTrack(clips: [downstreamAudio]),
            ]
        )

        #expect(!unlocked.rippleInsertClips(
            assets: [insertedSource],
            trackIndex: 0,
            atFrame: 0
        ).isEmpty)
        #expect(unlocked.clipFor(id: downstreamVideo.id)?.startFrame == 90)
        #expect(unlocked.clipFor(id: downstreamAudio.id)?.startFrame == 90)

        let explicit = editor(
            assets: [insertedSource],
            tracks: [
                Fixtures.videoTrack(clips: [downstreamVideo]),
                Fixtures.audioTrack(clips: [downstreamAudio]),
            ]
        )
        #expect(!explicit.rippleInsertClips(
            specs: [.init(
                asset: insertedSource,
                durationFrames: 30,
                trimStartFrame: 0,
                trimEndFrame: 0
            )],
            trackIndex: 0,
            atFrame: 0
        ).isEmpty)
        #expect(explicit.clipFor(id: downstreamVideo.id)?.startFrame == 90)
        #expect(explicit.clipFor(id: downstreamAudio.id)?.startFrame == 90)

        var lockedAudioTrack = Fixtures.audioTrack(clips: [downstreamAudio])
        lockedAudioTrack.editLocked = true
        let locked = editor(
            assets: [insertedSource],
            tracks: [Fixtures.videoTrack(clips: [downstreamVideo]), lockedAudioTrack]
        )
        let before = locked.timeline

        #expect(locked.rippleInsertClips(
            assets: [insertedSource],
            trackIndex: 0,
            atFrame: 0
        ).isEmpty)
        #expect(locked.timeline == before)

        #expect(locked.rippleInsertClips(
            specs: [.init(
                asset: insertedSource,
                durationFrames: 30,
                trimStartFrame: 0,
                trimEndFrame: 0
            )],
            trackIndex: 0,
            atFrame: 0
        ).isEmpty)
        #expect(locked.timeline == before)
    }

    @Test func multiClipSplitAndTrimAreSingleUndoableCommands() {
        var video = Fixtures.clip(id: "video", start: 0, duration: 60)
        video.linkGroupId = "pair"
        var audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 60)
        audio.linkGroupId = "pair"
        let editor = editor(
            assets: [],
            tracks: [Fixtures.videoTrack(clips: [video]), Fixtures.audioTrack(clips: [audio])]
        )
        let undoManager = UndoManager()
        editor.undoManager = undoManager
        editor.selectedClipIds = [video.id, audio.id]
        editor.currentFrame = 30

        editor.splitAtPlayhead()
        #expect(editor.timeline.tracks.flatMap(\.clips).count == 4)
        undoManager.undo()
        #expect(editor.timeline.tracks.flatMap(\.clips) == [video, audio])
        undoManager.redo()
        #expect(editor.timeline.tracks.flatMap(\.clips).count == 4)

        undoManager.removeAllActions()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ])
        editor.selectedClipIds = [video.id, audio.id]
        editor.currentFrame = 20
        editor.trimStartToPlayhead()
        #expect(editor.clipFor(id: video.id)?.startFrame == 20)
        #expect(editor.clipFor(id: audio.id)?.startFrame == 20)
        undoManager.undo()
        #expect(editor.clipFor(id: video.id)?.startFrame == 0)
        #expect(editor.clipFor(id: audio.id)?.startFrame == 0)
        undoManager.redo()
        #expect(editor.clipFor(id: video.id)?.startFrame == 20)
        #expect(editor.clipFor(id: audio.id)?.startFrame == 20)
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
        editor.activateTimelineSelection()
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
