import AVFoundation
import Testing
@testable import NexGenVideo

@Suite("Timeline music prepares its actual source before approval")
@MainActor
struct MusicSourcePreparationTests {
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
        let request = GenerationRequest(modality: .music, modelId: model.id, intent: "", durationSeconds: 2,
            placement: .timelineAt(startFrame: 30, spanSeconds: 2, actionName: "Add Music"), origin: .panel,
            target: .init(modelId: model.id, provider: .fal, endpoint: model.id, binding: nil),
            submission: .music { compiled in
                .init(mode: .videoToMusic, model: model, prompt: compiled, source: .init(startFrame: 30, frameCount: 60),
                    spanSeconds: 2, name: nil)
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
        #expect(preview.name.contains("30–90"))
        #expect(package.payload.generationInput.referenceVideoAssetIds == [preview.id])
        let duration = try await AVURLAsset(url: preview.url).load(.duration)
        #expect(abs(duration.seconds - 2) < 1.0 / 30.0)
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
        await #expect(throws: (any Error).self) { try await MusicSourcePreparation.prepare(music, editor: editor) }
        #expect(editor.mediaAssets.isEmpty)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    private func fixtureModel(inputs: [String]) -> AudioModelConfig {
        let caps = AudioCaps(category: "music", voices: nil, defaultVoice: nil, supportsLyrics: false,
            supportsInstrumental: false, supportsStyleInstructions: false, durations: nil, minPromptLength: 0,
            inputs: inputs, promptLabel: nil, minSeconds: 1, maxSeconds: 60)
        let entry = CatalogEntry(id: "fixture-timeline-music", kind: .audio, displayName: "Isolated music fixture",
            allowedEndpoints: ["fixture-timeline-music"], responseShape: .audio, uiCapabilities: .audio(caps))
        return .init(entry: entry, caps: caps)
    }
}
