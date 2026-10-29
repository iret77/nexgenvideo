import Foundation
import Testing
@testable import NexGenVideo

@Suite("Generation panel preserves recorded inputs")
@MainActor
struct GenerationPanelRecoveryTests {
    @Test func originalIntentAndActualTrimAreRestoredInsteadOfCompiledDirectionAndWholeSource() throws {
        let video = MediaAsset(id: "source", url: URL(fileURLWithPath: "/source.mov"), type: .video, name: "Original film", duration: 10)
        var input = GenerationInput(prompt: "Compiled camera and project direction", intent: "Keep the original gesture", model: "editor", duration: 2, aspectRatio: "16:9")
        input.sourceVideoAssetId = video.id
        input.sourceRange = .init(trim: .init(trimStartFrame: 30, trimEndFrame: 210, sourceFramesConsumed: 60, fps: 30))
        let restored = try GenerationPanelSeed.restore(input, assets: [video])
        #expect(restored.intent == "Keep the original gesture")
        #expect(restored.sourceTrim?.sourceURL == video.url)
        #expect(restored.sourceTrim?.trimStartFrame == 30)
        #expect(restored.sourceTrim?.sourceFramesConsumed == 60)
        #expect(restored.sourceTrim?.durationSeconds == 2)
        input.intent = nil
        #expect(try GenerationPanelSeed.restore(input, assets: [video]).intent == input.prompt)
    }

    @Test func missingReferenceMaskAndUnprovenTransformedVideoAreVisibleFailures() throws {
        let video = MediaAsset(id: "source", url: URL(fileURLWithPath: "/source.mov"), type: .video, name: "Original film", duration: 10)
        var input = GenerationInput(prompt: "A direction", model: "model", duration: 2, aspectRatio: "16:9")
        input.referenceImageAssetIds = ["removed"]
        #expect(throws: (any Error).self) { try GenerationPanelSeed.restore(input, assets: [video]) }
        input.referenceImageAssetIds = nil; input.imageMaskAssetId = "removed-mask"
        #expect(throws: (any Error).self) { try GenerationPanelSeed.restore(input, assets: [video]) }
        input.imageMaskAssetId = nil; input.sourceVideoAssetId = video.id
        input.referenceReceipts = [.init(assetID: video.id, displayName: video.name, type: "video",
            sourceSHA256: String(repeating: "a", count: 64), submittedSHA256: String(repeating: "b", count: 64))]
        #expect(throws: (any Error).self) { try GenerationPanelSeed.restore(input, assets: [video]) }
        input.sourceRange = .init(trim: .init(trimStartFrame: 30, trimEndFrame: 210, sourceFramesConsumed: 60, fps: 30))
        #expect(try GenerationPanelSeed.restore(input, assets: [video]).sourceTrim != nil)
    }

    @Test func videoAudioSelectionUsesEnabledExecutableCategoryAndActualRange() {
        let preferred = audio(VideoToAudioEditKind.music.preferredModelId, maximum: 5)
        let alternative = audio("another-provider-current-model", maximum: 60)
        let sfx = audio("sound-effects", category: "sfx", maximum: 60)
        let all = [preferred, alternative, sfx]
        let music = VideoToAudioEditKind.music
        #expect(music.select(in: all, spanSeconds: 4, isEnabled: { _ in true }, canRun: { _ in true })?.id == preferred.id)
        #expect(music.select(in: all, spanSeconds: 20, isEnabled: { _ in true }, canRun: { _ in true })?.id == alternative.id)
        #expect(music.select(in: all, spanSeconds: 4, isEnabled: { $0 != preferred.id }, canRun: { _ in true })?.id == alternative.id)
        #expect(music.select(in: all, spanSeconds: 4, isEnabled: { _ in true }, canRun: { $0 == alternative.id })?.id == alternative.id)
        #expect(music.select(in: all, spanSeconds: 4, isEnabled: { _ in false }, canRun: { _ in true }) == nil)
    }

    @Test func sourceOnlyOfferingIsShownBeforeSourceAssignmentAndPriorExecutableBindingSurvives() throws {
        let catalog = ModelCatalog(); catalog.load(entries: ModelCatalog.launchEntries)
        let suite = "Generation panel selection " + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = GenerationPanelServices(catalog: catalog, preferences: ModelPreferences(defaults: defaults),
            activation: { .init(active: Set(GenerationProvider.allCases.flatMap { provider in
                [ProviderActivation.Key(provider: provider, transport: .api), .init(provider: provider, transport: .mcp)]
            })) }, quoteLoader: { _, _ in GenerationPackageFixture.money() })
        let sourceOnly = try #require(catalog.video.first { services.target($0.id, sourceVideo: false).binding == nil
            && services.target($0.id, sourceVideo: true).binding != nil })
        let chosen = services.videoTarget(sourceOnly.id, hasSource: false)
        #expect(chosen.binding?.resolvedVideoCapabilities?.inputPolicy.requiresSourceVideo == true)
        #expect(services.videoTarget(sourceOnly.id, hasSource: true, preferred: chosen) == chosen)
        let disabled = GenerationPanelServices(catalog: catalog, preferences: services.preferences,
            activation: { .init() }, quoteLoader: services.quoteLoader)
        #expect(!disabled.canRun(sourceOnly.id))
        #expect(disabled.videoTarget(sourceOnly.id, hasSource: false).binding == nil)
    }

    @Test func audioSubmissionStoresTheExactReproducibleSourceTrim() {
        let source = MediaAsset(id: "source", url: URL(fileURLWithPath: "/source.mov"), type: .video, name: "Original", duration: 10)
        let trim = TrimmedSource(sourceURL: source.url, trimStartFrame: 30, trimEndFrame: 210, sourceFramesConsumed: 60, fps: 30)
        let model = audio("current-video-audio", maximum: 60)
        let input = GenerationInput(prompt: "Compiled sound", model: model.id, duration: 2, aspectRatio: "")
        let params = AudioGenerationParams(prompt: input.prompt, voice: nil, lyrics: nil, styleInstructions: nil,
            instrumental: false, durationSeconds: 2)
        let trimmed = AudioGenerationSubmission.make(genInput: input, model: model, params: params, references: [source], trimmedSourceOverride: trim)
        #expect(trimmed.genInput.sourceRange?.trim == trim.record)
        let full = AudioGenerationSubmission.make(genInput: input, model: model, params: params, references: [source])
        #expect(full.genInput.sourceRange != nil)
        #expect(full.genInput.sourceRange?.trim == nil)
    }

    private func audio(_ id: String, category: String = "music", maximum: Int) -> AudioModelConfig {
        let caps = AudioCaps(category: category, voices: nil, defaultVoice: nil, supportsLyrics: false,
            supportsInstrumental: false, supportsStyleInstructions: false, durations: nil, minPromptLength: 0,
            inputs: ["video"], promptLabel: nil, minSeconds: 1, maxSeconds: maximum)
        let entry = CatalogEntry(id: id, kind: .audio, displayName: id, allowedEndpoints: [id], responseShape: .audio, uiCapabilities: .audio(caps))
        return .init(entry: entry, caps: caps)
    }
}
