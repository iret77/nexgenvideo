import AVFoundation
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Production film review with actual source media")
struct PipelineProductionSequenceReviewStoreTests {
    @Test func audioExpectationOnlyIncludesAudibleClipsInsideTheActualOutputInterval() {
        var timeline = Timeline()
        timeline.tracks = [Track(type: .audio, clips: [Clip(mediaRef: "tone", mediaType: .audio,
            sourceClipType: .audio, startFrame: 60, durationFrames: 30)])]
        let clock = RationalTimebaseV1(ticksPerSecond: 600, fpsNumerator: 30)
        #expect(!PipelineProductionSequenceReviewStore.expectsAudibleAudio(timeline: timeline,
            outputStartTicks: 0, outputDurationTicks: 600, timebase: clock))
        #expect(PipelineProductionSequenceReviewStore.expectsAudibleAudio(timeline: timeline,
            outputStartTicks: 1200, outputDurationTicks: 600, timebase: clock))
        timeline.tracks[0].clips[0].volume = 0
        #expect(!PipelineProductionSequenceReviewStore.expectsAudibleAudio(timeline: timeline,
            outputStartTicks: 1200, outputDurationTicks: 600, timebase: clock))
    }

    @Test func realFilmReviewBindsExternalSourcesActualCutAndPersistedObservations() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly(presentation: .editorSession)
        defer { context.document.close() }
        let editor = context.editor
        let originalTimeline = editor.timeline
        let clip = try #require(originalTimeline.tracks.flatMap(\.clips).first(where: { $0.mediaType == .video }))
        let index = try #require(editor.mediaManifest.entries.firstIndex(where: { $0.id == clip.mediaRef }))
        let originalURL = try #require(editor.mediaResolver.resolveURL(for: clip.mediaRef))
        let originalBytes = try Data(contentsOf: originalURL)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("External film \(UUID().uuidString).mov")
        let alternate = FileManager.default.temporaryDirectory.appendingPathComponent("Relocated film \(UUID().uuidString).mov")
        try originalBytes.write(to: external)
        try originalBytes.write(to: alternate)
        defer { try? FileManager.default.removeItem(at: external); try? FileManager.default.removeItem(at: alternate) }
        editor.mediaManifest.entries[index].source = .external(absolutePath: external.path)
        #expect(throws: (any Error).self) {
            _ = try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: context.dataRoot,
                timeline: originalTimeline, resolver: editor.mediaResolver.snapshot())
        }
        let snapshot = try await PipelineProductionSequenceReviewStore.capture(editor: editor)
        let navigationFinding = SequenceReviewFindingV1(id: "inspect-opening", scope: .wholePlayback, category: .visualArtifact,
            severity: .warning, shotIDs: [], startFrame: 1, endFrame: 10, evidence: "Inspect the opening frames.",
            recommendedAction: .localRepair, provenance: .init(kind: .nativeUser, reviewerID: "native-sequence-review"))
        try await PipelineProductionSequenceReviewStore.openFinding(navigationFinding, snapshot: snapshot, editor: editor)
        #expect(editor.currentFrame == 1)
        #expect(editor.selectedTimelineRange == TimelineRangeSelection(startFrame: 1, endFrame: 10))
        #expect(editor.selectedClipIds == Set(originalTimeline.tracks.flatMap(\.clips)
            .filter { $0.startFrame < 10 && $0.endFrame > 1 }.map(\.id)))
        #expect(editor.workspaceFocus == .postproduction && editor.activePreviewTab == .timeline)
        #expect(editor.timeline == originalTimeline)
        #expect(editor.mediaResolver.resolveURL(for: clip.mediaRef) == external)
        let frozen = try #require(snapshot.input.sources.first(where: { $0.mediaID == clip.mediaRef }))
        #expect(frozen.originIdentity == "external:" + external.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: ProjectLocalFile.requireHash(frozen.frozen.sha256,
            at: frozen.frozen.path, dataRoot: context.dataRoot)) == originalBytes)
        let reel = AVURLAsset(url: try ProjectLocalFile.requireHash(snapshot.reel.sha256, at: snapshot.reel.path, dataRoot: context.dataRoot))
        #expect(CMTimeCompare(try await reel.load(.duration), CMTime(seconds: 8, preferredTimescale: 600)) == 0)
        let audioTracks = try await reel.loadTracks(withMediaType: .audio)
        #expect(!audioTracks.isEmpty)
        try await PipelineProductionSequenceReviewStore.save(snapshot: snapshot, adjacentPairCompleted: true,
            wholePlaybackCompleted: true, findings: [], editor: editor)
        let saved = try #require(try await PipelineProductionSequenceReviewStore.loadCurrent(editor: editor))
        #expect(saved.0.reel == snapshot.reel)
        #expect(saved.1.wholePlaybackCompleted)
        _ = try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: context.dataRoot,
            timeline: originalTimeline, resolver: editor.mediaResolver.snapshot())
        var changed = originalTimeline
        let trackIndex = try #require(changed.tracks.firstIndex(where: { $0.clips.contains { $0.id == clip.id } }))
        let clipIndex = try #require(changed.tracks[trackIndex].clips.firstIndex(where: { $0.id == clip.id }))
        changed.tracks[trackIndex].clips[clipIndex].opacity = 0.5
        #expect(throws: (any Error).self) {
            _ = try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: context.dataRoot,
                timeline: changed, resolver: editor.mediaResolver.snapshot())
        }
        #expect(throws: (any Error).self) {
            _ = try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: context.dataRoot,
                timeline: originalTimeline, resolver: editor.mediaResolver.snapshot(overriding: [clip.mediaRef: alternate]))
        }
        try (originalBytes + Data("changed actual source".utf8)).write(to: external)
        let selectionBeforeStaleSource = editor.selectedClipIds
        await #expect(throws: (any Error).self) {
            try await PipelineProductionSequenceReviewStore.openFinding(navigationFinding, snapshot: snapshot, editor: editor)
        }
        #expect(editor.selectedClipIds == selectionBeforeStaleSource)
        #expect(throws: (any Error).self) {
            _ = try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: context.dataRoot,
                timeline: originalTimeline, resolver: editor.mediaResolver.snapshot())
        }
        try originalBytes.write(to: external)
        _ = try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: context.dataRoot,
            timeline: originalTimeline, resolver: editor.mediaResolver.snapshot())
        let finding = SequenceReviewFindingV1(id: "observed-occlusion", scope: .wholePlayback, category: .visualArtifact,
            severity: .blocking, shotIDs: [try #require(snapshot.shotIDs.first)], startFrame: 0, endFrame: 10,
            evidence: "The visible source is obscured at the opening.", recommendedAction: .localRepair,
            provenance: .init(kind: .nativeUser, reviewerID: "native-sequence-review"))
        try await PipelineProductionSequenceReviewStore.save(snapshot: snapshot, adjacentPairCompleted: true,
            wholePlaybackCompleted: true, findings: [finding], editor: editor)
        let persisted = try #require(try await PipelineProductionSequenceReviewStore.loadCurrent(editor: editor))
        #expect(persisted.1.findings == [finding])
        editor.timeline = changed
        let rangeBeforeStaleCut = editor.selectedTimelineRange
        await #expect(throws: (any Error).self) {
            try await PipelineProductionSequenceReviewStore.openFinding(navigationFinding, snapshot: snapshot, editor: editor)
        }
        #expect(editor.timeline == changed && editor.selectedTimelineRange == rangeBeforeStaleCut)
        let secondCut = try await PipelineProductionSequenceReviewStore.capture(editor: editor)
        #expect(secondCut.input.fingerprint != snapshot.input.fingerprint)
        try await PipelineProductionSequenceReviewStore.save(snapshot: secondCut, adjacentPairCompleted: true,
            wholePlaybackCompleted: true, findings: [], editor: editor)
        editor.timeline = originalTimeline
        #expect(throws: (any Error).self) {
            _ = try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: context.dataRoot,
                timeline: originalTimeline, resolver: editor.mediaResolver.snapshot())
        }
        let returningCut = try #require(try await PipelineProductionSequenceReviewStore.loadCurrent(editor: editor,
            matchingInputFingerprint: snapshot.input.fingerprint))
        #expect(returningCut.1.findings == [finding])
        #expect(returningCut.1.reel == persisted.1.reel)
        await #expect(throws: (any Error).self) {
            try await PipelineProductionSequenceReviewStore.save(snapshot: snapshot, adjacentPairCompleted: true,
                wholePlaybackCompleted: true, findings: [], editor: editor)
        }
        try await PipelineProductionSequenceReviewStore.save(snapshot: snapshot, adjacentPairCompleted: true,
            wholePlaybackCompleted: true, findings: [finding], findingResolutions: [.init(findingID: finding.id,
                reason: "The native reinspection confirms the opening is intentionally covered; the original observation is retained.")], editor: editor)
        let resolved = try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: context.dataRoot,
            timeline: originalTimeline, resolver: editor.mediaResolver.snapshot())
        #expect(resolved.findings == [finding])
        #expect(resolved.supersedes != nil)
        let priorReview = try #require(resolved.supersedes)
        let priorBytes = try Data(contentsOf: ProjectLocalFile.requireHash(priorReview.sha256,
            at: priorReview.path, dataRoot: context.dataRoot))
        #expect(try JSONDecoder().decode(ProductionSequenceReviewV2.self, from: priorBytes).findings == [finding])
        #expect(resolved.findingResolutions.first?.findingID == finding.id)
        try await PipelineProductionSequenceReviewStore.save(snapshot: snapshot, adjacentPairCompleted: true,
            wholePlaybackCompleted: true, findings: [finding], editor: editor)
        try NativeGateWriter.rewind(projectDir: try #require(editor.workingRoot), targetPhase: "render",
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
            declaredProductionContract: editor.declaredProductionContract, executionCoordinator: editor.pipelinePhaseRunCoordinator)
        let repair = PipelineProductionSequenceReviewStore.repairInstructions(dataRoot: context.dataRoot, phase: "render",
            timeline: originalTimeline, resolver: editor.mediaResolver.snapshot())
        #expect(repair?.contains("observed-occlusion") == true)
        #expect(repair?.contains("not current phase approval or delivery authorization") == true)
        #expect(PipelineProductionSequenceReviewStore.repairInstructions(dataRoot: context.dataRoot, phase: "render",
            timeline: changed, resolver: editor.mediaResolver.snapshot()) == nil)
        #expect(throws: (any Error).self) {
            _ = try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: context.dataRoot,
                timeline: originalTimeline, resolver: editor.mediaResolver.snapshot())
        }
    }
}
