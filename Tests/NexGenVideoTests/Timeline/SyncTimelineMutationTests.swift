import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Clip synchronization timeline mutation")
struct SyncTimelineMutationTests {
    private func signal(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return 0.05 + Float((state >> 33) % 10_000) / 10_000
        }
    }

    private func evidence(
        timings: [String: SourceTiming] = [:],
        envelopes: [String: [Float]] = [:]
    ) -> EditorViewModel.SyncEvidence {
        EditorViewModel.SyncEvidence(
            timings: timings,
            envelopes: envelopes.mapValues {
                AudioEnvelope(hopSeconds: AudioEnvelopeExtractor.hopSeconds, samples: $0)
            }
        )
    }

    @Test func compatibleSourceTimecodeTakesPriority() async throws {
        let reference = Fixtures.clip(id: "reference", mediaRef: "ref", start: 100, duration: 200)
        let target = Fixtures.clip(id: "target", mediaRef: "target", start: 800, duration: 200)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 25, tracks: [
            Fixtures.videoTrack(clips: [reference]),
            Fixtures.videoTrack(clips: [target]),
        ])

        let report = await editor.syncClips(
            referenceClipId: reference.id,
            targetClipIds: [target.id],
            evidence: evidence(timings: [
                "ref": SourceTiming(timecode: SourceTimecode(frame: 1_000, quanta: 25, dropFrame: false)),
                "target": SourceTiming(timecode: SourceTimecode(frame: 1_250, quanta: 25, dropFrame: false)),
            ])
        )

        let success = try #require(report.synced.first)
        #expect(success.method == .sourceTimecode)
        #expect(success.offsetFrames == -450)
        #expect(editor.findClip(id: target.id).map {
            editor.timeline.tracks[$0.trackIndex].clips[$0.clipIndex].startFrame
        } == 350)
    }

    @Test func incompatibleTimecodeFallsBackToAudioWithReason() async throws {
        let referenceSamples = signal(count: 2_000, seed: 101)
        let targetSamples = Array(referenceSamples[300..<1_500])
        let reference = Fixtures.clip(id: "reference", mediaRef: "ref", start: 0, duration: 300)
        let target = Fixtures.clip(id: "target", mediaRef: "target", start: 500, duration: 300)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [reference]),
            Fixtures.videoTrack(clips: [target]),
        ])

        let report = await editor.syncClips(
            referenceClipId: reference.id,
            targetClipIds: [target.id],
            searchWindowSeconds: 10,
            evidence: evidence(
                timings: [
                    "ref": SourceTiming(timecode: SourceTimecode(frame: 0, quanta: 25, dropFrame: false)),
                    "target": SourceTiming(timecode: SourceTimecode(frame: 0, quanta: 30, dropFrame: false)),
                ],
                envelopes: ["ref": referenceSamples, "target": targetSamples]
            )
        )

        let success = try #require(report.synced.first)
        #expect(success.method == .audio)
        #expect(success.reason.contains("rates differ"))
        #expect(abs(success.offsetFrames + 410) <= 1)
    }

    @Test func captureDateWithoutAudioNeverMovesAClip() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let reference = Fixtures.clip(id: "reference", mediaRef: "ref", start: 0, duration: 300)
        let target = Fixtures.clip(id: "target", mediaRef: "target", start: 500, duration: 300)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [reference]),
            Fixtures.videoTrack(clips: [target]),
        ])
        let before = editor.timeline

        let report = await editor.syncClips(
            referenceClipId: reference.id,
            targetClipIds: [target.id],
            evidence: evidence(timings: [
                "ref": SourceTiming(captureDate: date),
                "target": SourceTiming(captureDate: date.addingTimeInterval(12)),
            ])
        )

        #expect(editor.timeline == before)
        #expect(report.synced.isEmpty)
        #expect(report.failures.first?.method == .captureDate)
        #expect(report.failures.first?.reason.contains("not precise enough") == true)
    }

    @Test func audioSyncHandlesRecorderTrackLongerThanReference() async throws {
        let referenceSamples = signal(count: 1_200, seed: 102)
        let targetSamples = signal(count: 1_500, seed: 103)
            + referenceSamples
            + signal(count: 1_700, seed: 104)
        let reference = Fixtures.clip(id: "reference", mediaRef: "ref", start: 0, duration: 360)
        let target = Fixtures.clip(id: "target", mediaRef: "target", start: 0, duration: 1_260)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [reference]),
            Fixtures.videoTrack(clips: [target]),
        ])

        let report = await editor.syncClips(
            referenceClipId: reference.id,
            targetClipIds: [target.id],
            mode: .audio,
            searchWindowSeconds: 20,
            evidence: evidence(envelopes: ["ref": referenceSamples, "target": targetSamples])
        )

        #expect(report.synced.first?.method == .audio)
        #expect(report.shiftedFrames == 450)
        #expect(report.failures.isEmpty)
    }

    @Test func captureDateCannotChooseBetweenRepeatedAudioMatches() async {
        let motif = signal(count: 600, seed: 105)
        let spacer = signal(count: 600, seed: 106)
        let referenceSamples = motif + spacer + motif
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let reference = Fixtures.clip(id: "reference", mediaRef: "ref", start: 0, duration: 540)
        let target = Fixtures.clip(id: "target", mediaRef: "target", start: 0, duration: 180)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [reference]),
            Fixtures.videoTrack(clips: [target]),
        ])
        let before = editor.timeline

        let report = await editor.syncClips(
            referenceClipId: reference.id,
            targetClipIds: [target.id],
            mode: .audio,
            searchWindowSeconds: 2,
            evidence: evidence(
                timings: [
                    "ref": SourceTiming(captureDate: date),
                    "target": SourceTiming(captureDate: date.addingTimeInterval(12)),
                ],
                envelopes: ["ref": referenceSamples, "target": motif]
            )
        )

        #expect(editor.timeline == before)
        #expect(report.synced.isEmpty)
        #expect(report.failures.first?.reason.contains("repeated audio") == true)
    }

    @Test func linkedPlacementsAndGroupShiftAreOneUndoableAction() throws {
        var targetVideo = Fixtures.clip(id: "target-video", start: 50, duration: 80)
        targetVideo.linkGroupId = "target-group"
        var targetAudio = Fixtures.clip(
            id: "target-audio",
            mediaType: .audio,
            start: 50,
            duration: 80
        )
        targetAudio.linkGroupId = "target-group"
        let reference = Fixtures.clip(id: "reference", start: 10, duration: 80)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [reference]),
            Fixtures.videoTrack(clips: [targetVideo]),
            Fixtures.audioTrack(clips: [targetAudio]),
        ])
        let before = editor.timeline
        let undoManager = UndoManager()
        editor.undoManager = undoManager
        var report = EditorViewModel.SyncBatchReport()

        editor.applySyncPlacements(
            referenceClipId: reference.id,
            placements: [EditorViewModel.SyncPlacement(
                resultClipId: targetVideo.id,
                carrierClipId: targetAudio.id,
                rawStart: -20,
                confidence: 0.92,
                method: .audio,
                reason: "5/5 audio anchors agreed.",
                driftPPM: 120,
                matchedAnchors: 5,
                evaluatedAnchors: 5,
                dependsOnClipId: nil
            )],
            report: &report
        )

        #expect(report.shiftedFrames == 20)
        #expect(report.synced.count == 1)
        #expect(report.synced[0].offsetFrames == -50)
        let referenceLocation = try #require(editor.findClip(id: reference.id))
        #expect(referenceLocation.clipIndex == 0)
        let allClips = editor.timeline.tracks.flatMap(\.clips)
        #expect(allClips.first(where: { $0.id == reference.id })?.startFrame == 30)
        #expect(allClips.first(where: { $0.id == targetVideo.id })?.startFrame == 0)
        #expect(allClips.first(where: { $0.id == targetAudio.id })?.startFrame == 0)
        #expect(undoManager.canUndo)

        undoManager.undo()
        #expect(editor.timeline == before)
        #expect(undoManager.canUndo == false)
        #expect(undoManager.canRedo)
    }

    @Test func ambiguousOrWeakResultsDoNotMutateTimeline() {
        let reference = Fixtures.clip(id: "reference", start: 0, duration: 80)
        let target = Fixtures.clip(id: "target", start: 100, duration: 80)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [reference]),
            Fixtures.videoTrack(clips: [target]),
        ])
        let before = editor.timeline
        var report = EditorViewModel.SyncBatchReport(failures: [
            EditorViewModel.SyncFailure(
                clipId: target.id,
                method: .audio,
                confidence: 0.49,
                reason: "Competing repeated audio matches are equally plausible. No move was applied."
            ),
        ])

        editor.applySyncPlacements(
            referenceClipId: reference.id,
            placements: [],
            report: &report
        )

        #expect(editor.timeline == before)
        #expect(report.synced.isEmpty)
        #expect(report.failures.count == 1)
    }

    @Test func synchronizationNeverOverwritesUnselectedTimelineMaterial() {
        let reference = Fixtures.clip(id: "reference", start: 0, duration: 80)
        let target = Fixtures.clip(
            id: "target",
            mediaRef: "target-media",
            mediaType: .audio,
            start: 120,
            duration: 80
        )
        let blocker = Fixtures.clip(
            id: "existing-take",
            mediaRef: "other-media",
            mediaType: .audio,
            start: 30,
            duration: 80
        )
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [reference]),
            Fixtures.audioTrack(clips: [blocker, target]),
        ])
        let before = editor.timeline
        var report = EditorViewModel.SyncBatchReport()

        editor.applySyncPlacements(
            referenceClipId: reference.id,
            placements: [EditorViewModel.SyncPlacement(
                resultClipId: target.id,
                carrierClipId: target.id,
                rawStart: 20,
                confidence: 0.9,
                method: .audio,
                reason: "4/4 audio anchors agreed.",
                driftPPM: 0,
                matchedAnchors: 4,
                evaluatedAnchors: 4,
                dependsOnClipId: nil
            )],
            report: &report
        )

        #expect(editor.timeline == before)
        #expect(report.synced.isEmpty)
        #expect(report.failures.count == 1)
        #expect(report.failures[0].reason.contains(blocker.id))
    }
}
