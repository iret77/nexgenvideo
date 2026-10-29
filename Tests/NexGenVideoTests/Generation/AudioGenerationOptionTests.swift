import Foundation
import Testing
@testable import NexGenVideo

@Suite("Audio request options stay explicit")
@MainActor
struct AudioGenerationOptionTests {
    @Test func variableAudioDurationIsOfferedAndValidatedUsingActualBoundsWithoutRounding() throws {
        let catalog = ModelCatalog(); catalog.load(entries: ModelCatalog.launchEntries)
        let music = try #require(catalog.audio.first { $0.id == "fal-ai/elevenlabs/music" })
        #expect(music.durations == nil)
        #expect(music.supportsDurationSelection)
        #expect(music.minSeconds == 3)
        #expect(music.maxSeconds == 600)
        #expect(music.validate(spanSeconds: 2.999) != nil)
        #expect(music.validate(spanSeconds: 3) == nil)
        #expect(music.validate(spanSeconds: 600) == nil)
        #expect(music.validate(spanSeconds: 600.001) != nil)
        #expect(music.validate(spanSeconds: .nan) != nil)
        #expect(music.validate(spanSeconds: .infinity) != nil)
        #expect(music.validate(params: params(duration: 2)) != nil)
        #expect(music.validate(params: params(duration: 3)) == nil)
    }

    @Test func rerunCannotSilentlyDiscardUnavailableAudioOptions() throws {
        let restricted = audio(voices: ["Current voice"])
        var input = GenerationInput(prompt: "Compiled words", model: restricted.id, duration: 4, aspectRatio: "")
        try GenerationPanelSeed.requireAudioOptions(input, model: restricted)
        input.voice = "Old voice"
        #expect(throws: (any Error).self) { try GenerationPanelSeed.requireAudioOptions(input, model: restricted) }
        input.voice = "Current voice"
        try GenerationPanelSeed.requireAudioOptions(input, model: restricted)
        input.lyrics = "Recorded original words"
        #expect(throws: (any Error).self) { try GenerationPanelSeed.requireAudioOptions(input, model: restricted) }
        input.lyrics = nil; input.styleInstructions = "Recorded delivery"
        #expect(throws: (any Error).self) { try GenerationPanelSeed.requireAudioOptions(input, model: restricted) }
        input.styleInstructions = nil; input.instrumental = true
        #expect(throws: (any Error).self) { try GenerationPanelSeed.requireAudioOptions(input, model: restricted) }
        input.instrumental = false; input.referenceVideoAssetIds = ["actual-original-source"]
        #expect(throws: (any Error).self) { try GenerationPanelSeed.requireAudioOptions(input, model: restricted) }
        input.referenceVideoAssetIds = nil; input.sourceVideoAssetId = "legacy-original-source"
        #expect(throws: (any Error).self) { try GenerationPanelSeed.requireAudioOptions(input, model: restricted) }
    }

    @Test func originalSupportedOptionsAreRetainedAndVideoAudioUsesTrimmedDurationForModelChoice() throws {
        let supported = audio(voices: ["Current voice"], extras: true)
        var input = GenerationInput(prompt: "Compiled words", model: supported.id, duration: 4, aspectRatio: "")
        input.voice = "Current voice"; input.lyrics = "Original words"
        input.styleInstructions = "Quiet"; input.instrumental = true; input.referenceVideoAssetIds = ["source"]
        try GenerationPanelSeed.requireAudioOptions(input, model: supported)
        let catalog = ModelCatalog(); catalog.load(entries: try ManualAudioGenerationTransport.entries())
        let defaultsName = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let services = GenerationPanelServices(catalog: catalog, preferences: ModelPreferences(defaults: defaults),
            activation: { .init(active: [.init(provider: .higgsfield, transport: .mcp)]) },
            quoteLoader: { _, _ in GenerationPackageFixture.money() })
        let source = MediaAsset(id: "video", url: URL(fileURLWithPath: "/actual-source.mov"), type: .video, name: "Source", duration: 50)
        let seed = try #require(EditSubmitter.videoAudioSeed(for: source, kind: .sfx, effectiveDuration: 2, services: services))
        #expect(seed.duration == 2)
        #expect(seed.referenceVideoAssetIds == [source.id])
        #expect(seed.model == "native-acceptance-video-sfx")
        services.preferences.setEnabled(seed.model, false)
        #expect(EditSubmitter.videoAudioSeed(for: source, kind: .sfx, effectiveDuration: 2, services: services) == nil)
    }

    @Test func canonicalPreparationRejectsUnsupportedOptionsBeforeApprovalOrDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("Audio.ngv")
        try Fixtures.prepareProjectPackage(at: root)
        let editor = EditorViewModel(); editor.projectURL = root
        defer {
            if let key = ProjectIdentity.existingKey(for: root) { ProjectWorkingCopy.discard(key: key) }
            try? FileManager.default.removeItem(at: directory)
        }
        let model = audio(voices: ["Current voice"])
        let request = GenerationRequest(modality: .audio, modelId: model.id, intent: "", durationSeconds: 4,
            placement: .mediaLibrary(folderId: nil), origin: .panel,
            submission: .audio { prompt in
                .make(genInput: .init(prompt: prompt, model: model.id, duration: 4, aspectRatio: ""), model: model,
                    params: .init(prompt: "Recorded original direction", voice: "Current voice", lyrics: "Unsupported words",
                        styleInstructions: nil, instrumental: false, durationSeconds: 4))
            })
        let result = await GenerationController.prepare(request, editor: editor)
        guard case .failure(let error) = result else { Issue.record("Unsupported lyrics reached a prepared request."); return }
        #expect(error.localizedDescription.contains("lyrics"))
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
    }

    private func params(duration: Int) -> AudioGenerationParams {
        .init(prompt: "A quiet piano motif", voice: nil, lyrics: nil, styleInstructions: nil,
            instrumental: true, durationSeconds: duration)
    }

    private func audio(voices: [String], extras: Bool = false) -> AudioModelConfig {
        let caps = AudioCaps(category: "music", voices: voices, defaultVoice: voices.first,
            supportsLyrics: extras, supportsInstrumental: extras, supportsStyleInstructions: extras,
            durations: [2, 4], minPromptLength: 1, inputs: extras ? ["text", "video"] : ["text"],
            promptLabel: nil, minSeconds: 2, maxSeconds: 4)
        let entry = CatalogEntry(id: "recorded-audio-options", kind: .audio, displayName: "Recorded options",
            allowedEndpoints: [], responseShape: .audio, uiCapabilities: .audio(caps))
        return .init(entry: entry, caps: caps)
    }
}
