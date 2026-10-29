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

    @Test func timelineEditedDuringAlignmentRejectsStaleMove() async throws {
        let reference = Fixtures.clip(id: "reference", mediaRef: "ref", start: 100, duration: 200)
        let target = Fixtures.clip(id: "target", mediaRef: "target", start: 800, duration: 200)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 25, tracks: [Fixtures.videoTrack(clips: [reference]), Fixtures.videoTrack(clips: [target])])
        var expected = editor.timeline
        expected.tracks[1].clips[0].startFrame = 900
        let report = await editor.syncClips(referenceClipId: reference.id, targetClipIds: [target.id],
            evidence: evidence(timings: [
                "ref": SourceTiming(timecode: SourceTimecode(frame: 1_000, quanta: 25, dropFrame: false)),
                "target": SourceTiming(timecode: SourceTimecode(frame: 1_250, quanta: 25, dropFrame: false))]),
            beforePublication: { editor.timeline.tracks[1].clips[0].startFrame = 900 })
        #expect(editor.timeline == expected)
        #expect(report.synced.isEmpty && report.failures.count == 1)
        #expect(report.failures.first?.reason.contains("changed") == true)
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

    @Test func sourceBytesChangedAtSameURLRejectStaleAlignment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncBytes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditorViewModel()
        for id in ["ref", "target"] {
            let url = directory.appendingPathComponent(id + ".mp4")
            try Data("original source".utf8).write(to: url)
            let asset = MediaAsset(id: id, url: url, type: .video, name: id, duration: 8)
            editor.mediaAssets.append(asset)
            editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
        }
        editor.timeline = Fixtures.timeline(fps: 25, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "reference", mediaRef: "ref", start: 100, duration: 200)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "target", mediaRef: "target", start: 800, duration: 200)])])
        let before = editor.timeline
        let target = directory.appendingPathComponent("target.mp4")
        let report = await editor.syncClips(referenceClipId: "reference", targetClipIds: ["target"],
            evidence: evidence(timings: [
                "ref": SourceTiming(timecode: SourceTimecode(frame: 1_000, quanta: 25, dropFrame: false)),
                "target": SourceTiming(timecode: SourceTimecode(frame: 1_250, quanta: 25, dropFrame: false))]),
            beforePublication: { try? Data("replacement source".utf8).write(to: target) })
        #expect(editor.timeline == before && report.synced.isEmpty)
        #expect(report.failures.count == 1 && report.failures.first?.reason.contains("source changed") == true)
    }

    @Test func editingThenUndoDuringEvaluationUsesOriginalSnapshot() async throws {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 25, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "reference", mediaRef: "ref", start: 100, duration: 200)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "target", mediaRef: "target", start: 800, duration: 200)])])
        let before = editor.timeline
        let report = await editor.syncClips(referenceClipId: "reference", targetClipIds: ["target"],
            evidence: evidence(timings: [
                "ref": SourceTiming(timecode: SourceTimecode(frame: 1_000, quanta: 25, dropFrame: false)),
                "target": SourceTiming(timecode: SourceTimecode(frame: 1_250, quanta: 25, dropFrame: false))]),
            beforePublication: { editor.timeline = before },
            beforeEvaluation: { editor.timeline.tracks[0].clips[0].startFrame = 1_100 })
        #expect(report.synced.first?.offsetFrames == -450)
        #expect(editor.timeline.tracks[1].clips[0].startFrame == 350)
    }

    @Test func newlyResolvedSourceRejectsStaleAlignment() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SyncRelink-" + UUID().uuidString + ".mp4")
        try Data("relinked source".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 25, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "reference", mediaRef: "ref", start: 100, duration: 200)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "target", mediaRef: "target", start: 800, duration: 200)])])
        let before = editor.timeline
        let report = await editor.syncClips(referenceClipId: "reference", targetClipIds: ["target"],
            evidence: evidence(timings: [
                "ref": SourceTiming(timecode: SourceTimecode(frame: 1_000, quanta: 25, dropFrame: false)),
                "target": SourceTiming(timecode: SourceTimecode(frame: 1_250, quanta: 25, dropFrame: false))]),
            beforePublication: {
                let asset = MediaAsset(id: "target", url: url, type: .video, name: "Relinked", duration: 8)
                editor.mediaAssets.append(asset)
                editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
            })
        #expect(editor.timeline == before && report.synced.isEmpty)
        #expect(report.failures.first?.reason.contains("source changed") == true)
    }

    @Test(arguments: [false, true])
    func cancelledSyncDoesNotPublish(afterSourceCapture: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SyncCancel-" + UUID().uuidString + ".mp4")
        try Data("source bytes for cancellation".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let editor = EditorViewModel()
        let asset = MediaAsset(id: "ref", url: url, type: .video, name: "Reference", duration: 8)
        editor.mediaAssets.append(asset)
        editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
        editor.timeline = Fixtures.timeline(fps: 25, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "reference", mediaRef: "ref", start: 100, duration: 200)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "target", mediaRef: "target", start: 800, duration: 200)])])
        let before = editor.timeline
        let timing = evidence(timings: [
            "ref": SourceTiming(timecode: SourceTimecode(frame: 1_000, quanta: 25, dropFrame: false)),
            "target": SourceTiming(timecode: SourceTimecode(frame: 1_250, quanta: 25, dropFrame: false))])
        let job = Task {
            await editor.syncClips(referenceClipId: "reference", targetClipIds: ["target"], evidence: timing,
                beforeEvaluation: { if afterSourceCapture { withUnsafeCurrentTask { $0?.cancel() } } })
        }
        if !afterSourceCapture { job.cancel() }
        let report = await job.value
        #expect(editor.timeline == before && report.synced.isEmpty)
        #expect(report.failures.first?.reason == "Synchronization was cancelled.")
    }

    @Test func unreadableSourceReportsReadFailureWithoutChangingTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncUnreadable-" + UUID().uuidString + ".mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditorViewModel()
        let asset = MediaAsset(id: "source", url: directory, type: .video, name: "Unavailable", duration: 8)
        editor.mediaAssets.append(asset)
        editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
        editor.timeline = Fixtures.timeline(fps: 25, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "reference", mediaRef: "source", start: 100, duration: 200)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "target", mediaRef: "source", start: 800, duration: 200)])])
        let before = editor.timeline
        let report = await editor.syncClips(referenceClipId: "reference", targetClipIds: ["target"],
            evidence: evidence(timings: ["source": SourceTiming(timecode: SourceTimecode(frame: 1_000, quanta: 25, dropFrame: false))]))
        #expect(editor.timeline == before && report.synced.isEmpty)
        #expect(report.failures.first?.reason == "A source file could not be read for verification. Relink it, then synchronize again.")
    }

    @Test(arguments: [false, true])
    func externalSymlinkSourceBindsActualTarget(retarget: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncSymlink-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real.mp4"), link = directory.appendingPathComponent("link.mp4")
        try Data("video source bytes".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let editor = EditorViewModel()
        let asset = MediaAsset(id: "source", url: link, type: .video, name: "External", duration: 8)
        editor.mediaAssets.append(asset)
        var entry = asset.toManifestEntry(projectURL: nil)
        entry.source = .external(absolutePath: link.path)
        editor.mediaManifest.entries.append(entry)
        editor.timeline = Fixtures.timeline(fps: 25, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "reference", mediaRef: "source", start: 100, duration: 200)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "target", mediaRef: "source", start: 800, duration: 200)])])
        let report = await editor.syncClips(referenceClipId: "reference", targetClipIds: ["target"],
            evidence: evidence(timings: ["source": SourceTiming(timecode: SourceTimecode(frame: 1_000, quanta: 25, dropFrame: false))]),
            beforePublication: {
                guard retarget else { return }
                do {
                    let replacement = directory.appendingPathComponent("replacement.mp4")
                    try Data("video source bytes".utf8).write(to: replacement)
                    try FileManager.default.removeItem(at: link)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
                } catch { Issue.record(error) }
            })
        if retarget {
            #expect(report.synced.isEmpty && report.failures.first?.reason.contains("source changed") == true)
            #expect(editor.timeline.tracks[1].clips[0].startFrame == 800)
        } else {
            #expect(report.failures.isEmpty && report.synced.count == 1)
            #expect(editor.timeline.tracks[1].clips[0].startFrame == 100)
        }
    }

    @Test func incompatibleTimecodeFallsBackToAudioWithReason() async throws {
        let referenceSamples = signal(count: 2_000, seed: 101)
        let targetSamples = Array(referenceSamples[300..<1_500])
        let reference = Fixtures.clip(id: "reference", mediaRef: "ref", start: 0, duration: 300)
        let target = Fixtures.clip(id: "target", mediaRef: "target", start: 300, duration: 300)
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
        #expect(abs(success.offsetFrames + 210) <= 1)
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
