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
        #expect(music.select(in: all, spanSeconds: 4, isEnabled: { $0 == sfx.id }, canRun: { _ in true }) == nil)
    }

    @Test func sourceOnlyOfferingIsShownBeforeSourceAssignmentAndPriorExecutableBindingSurvives() throws {
        let catalog = ModelCatalog(); catalog.load(entries: RunwayModelRegistry.entries)
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

    @Test func aPendingSeedCannotMixItsEditDestinationWithThePreviouslyRestoredRequest() throws {
        let editor = EditorViewModel()
        let source = MediaAsset(id: "source", url: URL(fileURLWithPath: "/source.mov"), type: .video, name: "Source", duration: 10)
        editor.mediaAssets = [source]
        var firstInput = GenerationInput(prompt: "First request", model: "fixture", duration: 2, aspectRatio: "16:9")
        firstInput.sourceVideoAssetId = source.id
        editor.seedGenerationPanel(asset: source, stored: firstInput, replacementClipId: "first-clip")
        let first = try #require(editor.pendingPanelSeed)
        let firstRestored = try GenerationPanelSeed.restore(first.stored, assets: editor.mediaAssets)
        #expect(editor.pendingEditReplacementClipId == nil)
        #expect(GenerationPanelSeed.commitEditContext(first, restored: firstRestored, editor: editor))
        #expect(editor.pendingEditReplacementClipId == "first-clip")

        var secondInput = firstInput
        secondInput.prompt = "Second request"
        let trim = TrimmedSource(sourceURL: source.url, trimStartFrame: 30, trimEndFrame: 210, sourceFramesConsumed: 60, fps: 30)
        let placement = PendingAudioPlacement(startFrame: 120, spanSeconds: 2, actionName: "Fixture placement")
        editor.seedGenerationPanel(asset: source, stored: secondInput, replacementClipId: "second-clip",
            trimmedSource: trim, audioPlacement: placement)
        let second = try #require(editor.pendingPanelSeed)
        #expect(first.id != second.id && first.asset.id == second.asset.id)
        #expect(editor.pendingEditReplacementClipId == "first-clip")
        #expect(editor.pendingEditTrimmedSource == nil && editor.pendingEditAudioPlacement == nil)
        #expect(!GenerationPanelSeed.commitEditContext(first, restored: firstRestored, editor: editor))
        #expect(editor.pendingPanelSeed?.id == second.id)
        let secondRestored = try GenerationPanelSeed.restore(second.stored, assets: editor.mediaAssets)
        #expect(GenerationPanelSeed.commitEditContext(second, restored: secondRestored, editor: editor))
        #expect(editor.pendingPanelSeed == nil && editor.pendingEditReplacementClipId == "second-clip")
        #expect(editor.pendingEditTrimmedSource?.record == trim.record)
        #expect(editor.pendingEditAudioPlacement?.startFrame == 120)

        secondInput.referenceImageAssetIds = ["missing"]
        editor.seedGenerationPanel(asset: source, stored: secondInput, replacementClipId: "must-not-apply")
        let failed = try #require(editor.pendingPanelSeed)
        #expect(throws: (any Error).self) { try GenerationPanelSeed.restore(failed.stored, assets: editor.mediaAssets) }
        #expect(editor.pendingPanelSeed?.id == failed.id)
        #expect(editor.pendingEditReplacementClipId == "second-clip")
    }

    @Test func editContextCannotPublishIntoANewerGenerationAtTheSameProjectHome() throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("seed-context-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: package)
        defer { try? FileManager.default.removeItem(at: package) }
        let editor = EditorViewModel()
        editor.projectURL = package
        defer { editor.releaseWorkingCopy() }
        let key = try #require(editor.openWorkingCopyKey)
        let source = MediaAsset(id: "same-source", url: package.appendingPathComponent("source.mov"), type: .video, name: "Source", duration: 2)
        let input = GenerationInput(prompt: "Retain this request", model: "fixture", duration: 2, aspectRatio: "16:9")
        editor.seedGenerationPanel(asset: source, stored: input, replacementClipId: "same-clip")
        let old = try #require(editor.pendingPanelSeed)
        let restored = try GenerationPanelSeed.restore(old.stored, assets: [])
        let reopened = try ProjectWorkingCopy.open(key: key, packageURL: package)
        editor.adoptWorkingCopy(reopened, key: key, packageURL: package)
        #expect(editor.workingRoot == old.context.home)
        #expect(!old.context.matches(editor: editor))
        #expect(!GenerationPanelSeed.commitEditContext(old, restored: restored, editor: editor))
        #expect(editor.pendingEditReplacementClipId == nil)
        editor.seedGenerationPanel(asset: source, stored: input, replacementClipId: "same-clip")
        let current = try #require(editor.pendingPanelSeed)
        #expect(current.context.matches(editor: editor))
        #expect(GenerationPanelSeed.commitEditContext(current, restored: restored, editor: editor))
        #expect(editor.pendingEditReplacementClipId == "same-clip")
    }

    private func audio(_ id: String, category: String = "music", maximum: Int) -> AudioModelConfig {
        let caps = AudioCaps(category: category, voices: nil, defaultVoice: nil, supportsLyrics: false,
            supportsInstrumental: false, supportsStyleInstructions: false, durations: nil, minPromptLength: 0,
            inputs: ["video"], promptLabel: nil, minSeconds: 1, maxSeconds: maximum)
        let entry = CatalogEntry(id: id, kind: .audio, displayName: id, allowedEndpoints: [id], responseShape: .audio, uiCapabilities: .audio(caps))
        return .init(entry: entry, caps: caps)
    }
}
