import AVFoundation
import Testing
@testable import NexGenVideo

@Suite("Timeline music prepares its actual source before approval")
@MainActor
struct MusicSourcePreparationTests {
    @Test func videoActionsRequireActualVisibleContentAndKeepWholeTimelineAudioOutro() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [])
        #expect(MusicSourcePreparation.timelineSpan(editor: editor) == nil)
        editor.timeline.tracks = [Fixtures.audioTrack(clips: [Fixtures.clip(mediaType: .audio, start: 0, duration: 180)])]
        #expect(MusicSourcePreparation.timelineSpan(editor: editor) == nil)
        editor.timeline.tracks.insert(Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 60)]), at: 0)
        #expect(MusicSourcePreparation.timelineSpan(editor: editor) == .init(startFrame: 0, frameCount: 180))
        editor.selectedTimelineRange = .init(startFrame: 0, endFrame: 61)
        #expect(MusicSourcePreparation.timelineSpan(editor: editor) == .init(startFrame: 0, frameCount: 61))
        editor.selectedTimelineRange = .init(startFrame: 60, endFrame: 90)
        #expect(MusicSourcePreparation.timelineSpan(editor: editor) == nil)
        editor.selectedTimelineRange = nil
        editor.timeline.tracks[0].hidden = true
        #expect(MusicSourcePreparation.timelineSpan(editor: editor) == nil)
        editor.timeline.tracks[0].hidden = false
        editor.timeline.tracks[0].clips[0].opacity = 0
        #expect(MusicSourcePreparation.timelineSpan(editor: editor) == nil)
    }

    @Test func fractionalSpanAlwaysHasAnExecutableProviderDurationCoveringEveryFrame() throws {
        let continuous = fixtureModel(inputs: ["video"])
        #expect(try MusicSourcePreparation.providerDurationSeconds(spanSeconds: 61.0 / 30, model: continuous) == 3)
        let discrete = fixtureModel(inputs: ["video"], durations: [8, 2, 4])
        #expect(try MusicSourcePreparation.providerDurationSeconds(spanSeconds: 2, model: discrete) == 2)
        #expect(try MusicSourcePreparation.providerDurationSeconds(spanSeconds: 61.0 / 30, model: discrete) == 4)
        #expect(throws: (any Error).self) { try MusicSourcePreparation.providerDurationSeconds(spanSeconds: 8.1, model: discrete) }
        #expect(throws: (any Error).self) { try MusicSourcePreparation.providerDurationSeconds(spanSeconds: .nan, model: continuous) }
    }

    @Test func selectedVisualRangeIsRenderedAndFrozenBeforeSpendWithSourceAndTimelineCAS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("Music.ngv")
        try Fixtures.prepareProjectPackage(at: root)
        let editor = EditorViewModel(); editor.projectURL = root
        defer {
            if let key = ProjectIdentity.existingKey(for: root) { ProjectWorkingCopy.discard(key: key) }
            try? FileManager.default.removeItem(at: directory)
        }
        let video = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let sourceURL = try editor.prepareWorkingMediaDirectory().appendingPathComponent("Original.mov")
        try FileManager.default.copyItem(at: video, to: sourceURL)
        let source = MediaAsset(url: sourceURL, type: .video, name: "Actual source", duration: 8)
        editor.importMediaAsset(source)
        let clip = Fixtures.clip(id: "source-clip", mediaRef: source.id, start: 0, duration: 240)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let timeline = editor.timeline
        let model = fixtureModel(inputs: ["video"])
        let span = 61.0 / 30
        let request = GenerationRequest(modality: .music, modelId: model.id, intent: "", durationSeconds: span,
            placement: .timelineAt(startFrame: 30, spanSeconds: span, actionName: "Add Music"), origin: .panel,
            target: .init(modelId: model.id, provider: .fal, endpoint: model.id, binding: nil),
            submission: .music { compiled in
                .init(mode: .videoToMusic, model: model, prompt: compiled, source: .init(startFrame: 30, frameCount: 61),
                    spanSeconds: span, name: nil)
            })
        let prepared = try await GenerationController.prepare(request, editor: editor).get()
        let package = try await GenerationController.prepareReviewPackage(prepared, editor: editor,
            quoteLoader: { _, _ in GenerationPackageFixture.money() })
        #expect(package.payload.operation == "music")
        #expect(package.payload.modality == "audio")
        #expect(package.payload.references.count == 1)
        let previewID = try #require(package.payload.references.first?.assetID)
        let preview = try #require(editor.mediaAssets.first { $0.id == previewID })
        #expect(preview.type == .video)
        #expect(preview.generationInput == nil)
        #expect(preview.name.contains("30–91"))
        #expect(package.payload.generationInput.duration == 3)
        #expect(package.payload.destination.durationSeconds == span)
        #expect(package.payload.generationInput.referenceVideoAssetIds == [preview.id])
        let duration = try await AVURLAsset(url: preview.url).load(.duration)
        #expect(CMTimeCompare(duration, CMTime(value: 61, timescale: 30)) == 0)
        #expect(try await AVURLAsset(url: preview.url).loadTracks(withMediaType: .audio).isEmpty)
        #expect(editor.timeline == timeline)
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.allSatisfy { $0.generationStatus == .none })
        #expect(prepared.preflight?() == nil)
        #expect(try package.pricingInput().modality == .music)
        let restored = try package.restoreParameters()
        #expect(try GenerationPackageV1.requestJSON(parameters: restored, references: package.payload.references) == package.payload.requestParametersJSON)
        try await GenerationPackageInputs.persist(package: package, snapshot: #require(prepared.references), editor: editor)
        #expect(try await GenerationPackageInputs.restore(package: package, editor: editor).receipts == package.payload.references)
        editor.timeline.tracks[0].clips[0].opacity = 0.4
        #expect(prepared.preflight?() != nil)
        editor.timeline = timeline
        #expect(prepared.preflight?() == nil)
        let entryIndex = try #require(editor.mediaManifest.entries.firstIndex(where: { $0.id == source.id }))
        let originalSource = editor.mediaManifest.entries[entryIndex].source
        source.url = video
        editor.mediaManifest.entries[entryIndex].source = .external(absolutePath: video.path)
        #expect(prepared.preflight?() != nil)
        source.url = sourceURL
        editor.mediaManifest.entries[entryIndex].source = originalSource
        #expect(prepared.preflight?() == nil)
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        #expect(prepared.preflight?() != nil)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func textMusicHasNoInventedVideoAndRetainsItsCompiledDirection() async throws {
        let editor = EditorViewModel()
        let model = fixtureModel(inputs: ["text"])
        let music = MusicGenerationSubmission(mode: .textToMusic, model: model, prompt: "Compiled quiet score",
            intent: "Quiet score", source: .init(startFrame: 10, frameCount: 60), spanSeconds: 2, name: nil)
        let prepared = try await MusicSourcePreparation.prepare(music, editor: editor)
        #expect(prepared.submission.params.prompt == "Compiled quiet score")
        #expect(prepared.submission.genInput.intent == "Quiet score")
        #expect(prepared.submission.references.isEmpty)
        #expect(prepared.preflight() == nil)
        #expect(editor.mediaAssets.isEmpty)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func aTextOnlyOfferingCannotConsumeAHiddenVideoSource() async {
        let editor = EditorViewModel()
        let music = MusicGenerationSubmission(mode: .videoToMusic, model: fixtureModel(inputs: ["text"]),
            prompt: "Compiled direction", source: .init(startFrame: 0, frameCount: 60), spanSeconds: 2, name: nil)
        do {
            _ = try await MusicSourcePreparation.prepare(music, editor: editor)
            Issue.record("A text-only offering accepted a video source.")
        } catch GenerationRequestError.optionsInvalid(let detail) {
            #expect(detail == "Choose a valid music duration and timeline range.")
        } catch {
            Issue.record("Expected capability rejection before project or media preparation: \(error)")
        }
        #expect(editor.mediaAssets.isEmpty)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    private func fixtureModel(inputs: [String], durations: [Int]? = nil) -> AudioModelConfig {
        let caps = AudioCaps(category: "music", voices: nil, defaultVoice: nil, supportsLyrics: false,
            supportsInstrumental: false, supportsStyleInstructions: false, durations: durations, minPromptLength: 0,
            inputs: inputs, promptLabel: nil, minSeconds: 1, maxSeconds: 60)
        let entry = CatalogEntry(id: "fixture-timeline-music", kind: .audio, displayName: "Isolated music fixture",
            allowedEndpoints: ["fixture-timeline-music"], responseShape: .audio, uiCapabilities: .audio(caps))
        return .init(entry: entry, caps: caps)
    }
}
