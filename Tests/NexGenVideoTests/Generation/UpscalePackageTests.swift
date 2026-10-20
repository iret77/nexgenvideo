import AppKit
import AVFoundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Upscale reviews exact sources and replacement scope")
@MainActor
struct UpscalePackageTests {
    @Test func imageUpscaleHasFrozenPromptlessParametersAndCanRestoreExactly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Source.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.black, atX: 0, y: 0)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: sourceURL)
        let source = MediaAsset(id: "source", url: sourceURL, type: .image, name: "Source", duration: 1)
        source.sourceWidth = 64; source.sourceHeight = 64
        let editor = EditorViewModel(); editor.mediaAssets = [source]
        let entry = try #require(FalModelRegistry.entries.first { $0.id == "fal-ai/clarity-upscaler" })
        guard case .upscale(let caps) = entry.uiCapabilities else { Issue.record("Expected actual upscale capability"); return }
        let model = UpscaleModelConfig(entry: entry, caps: caps)
        let target = ResolvedGenerationTarget(modelId: model.id, provider: .fal, endpoint: model.id, binding: nil)
        let request = try EditSubmitter.upscaleRequest(asset: source, model: model, target: target)
        let prepared = try await GenerationController.prepare(request, editor: editor).get()
        let package = try await GenerationController.prepareReviewPackage(prepared, editor: editor,
            quoteLoader: { _, _ in GenerationPackageFixture.money() })
        let actualResult = Data(#"{"image":{"url":"https://output.invalid/restored-upscale.png"}}"#.utf8)
        #expect(try FalOutput.urls(from: actualResult, shape: GenerationService.resumedFalOutputShape(package: package))
            == ["https://output.invalid/restored-upscale.png"])
        #expect(package.payload.operation == "upscale")
        #expect(package.payload.modality == "image")
        #expect(package.payload.prompt.isEmpty)
        #expect(package.payload.generationInput.imageURLAssetIds == [source.id])
        #expect(package.payload.generationInput.sourceRange?.trim == nil)
        #expect(package.payload.references.count == 1)
        #expect(package.payload.referenceRoles == ["source"])
        #expect(package.payload.references.first?.sourceSHA256 == package.payload.references.first?.submittedSHA256)
        #expect(try package.pricingInput().modality == .upscale)
        let restored = try package.restoreParameters()
        #expect(try GenerationPackageV1.requestJSON(parameters: restored, references: package.payload.references) == package.payload.requestParametersJSON)
        guard case .upscale(let params) = try restored.bind(["https://simulator.invalid/exact-source"]) else {
            Issue.record("Expected actual upscale parameters"); return
        }
        #expect(params.sourceURL == "https://simulator.invalid/exact-source")
        #expect(params.durationSeconds == 1)
        #expect(editor.mediaAssets.count == 1)
        #expect(editor.generationLog.spendEvents.isEmpty)
        let reviewedBytes = try Data(contentsOf: sourceURL)
        try await GenerationPackageInputs.requireCurrentReferences(package: package, editor: editor)
        source.url = directory.appendingPathComponent("Missing.png")
        await #expect(throws: (any Error).self) {
            try await GenerationPackageInputs.requireCurrentReferences(package: package, editor: editor)
        }
        source.url = sourceURL
        bitmap.setColor(.red, atX: 0, y: 0)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: sourceURL)
        await #expect(throws: (any Error).self) {
            try await GenerationPackageInputs.requireCurrentReferences(package: package, editor: editor)
        }
        try reviewedBytes.write(to: sourceURL)
        try await GenerationPackageInputs.requireCurrentReferences(package: package, editor: editor)
    }

    @Test func trimAndLinkedReplacementScopeArePartOfTheRequest() throws {
        let entry = try #require(FalModelRegistry.entries.first { $0.id == "fal-ai/topaz/upscale/video" })
        guard case .upscale(let caps) = entry.uiCapabilities else { Issue.record("Expected actual upscale capability"); return }
        let model = UpscaleModelConfig(entry: entry, caps: caps)
        let source = MediaAsset(id: "source", url: URL(fileURLWithPath: "/source.mov"), type: .video, name: "Source", duration: 5)
        source.sourceWidth = 960; source.sourceHeight = 540
        let trim = TrimmedSource(sourceURL: source.url, trimStartFrame: 30, trimEndFrame: 60, sourceFramesConsumed: 60, fps: 30)
        let selection = try #require(model.selections(sourceType: .video, sourceWidth: 960, sourceHeight: 540,
            durationSeconds: trim.durationSeconds).first)
        let request = try EditSubmitter.upscaleRequest(asset: source, model: model,
            targetResolution: selection.targetResolution, trimmedSource: trim,
            placement: .replaceClip(id: "picture", resetTrim: true))
        guard case .preparedUpscale(let submission) = request.submission else { Issue.record("Expected prepared upscale"); return }
        #expect(submission.genInput.sourceRange?.trim == trim.record)
        #expect(submission.genInput.sourceVideoAssetId == source.id)
        #expect(submission.genInput.duration == 2)
        #expect(submission.placeholderDuration == 2)
        let editor = EditorViewModel()
        var picture = Fixtures.clip(id: "picture", mediaRef: source.id, start: 0, duration: 60, trimStart: 30)
        picture.linkGroupId = "linked"
        var audio = picture; audio.id = "sound"; audio.mediaType = .audio
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [picture]), Fixtures.audioTrack(clips: [audio])])
        let destination = try GenerationPackageV1.Destination(request.placement, editor: editor)
        #expect(destination.kind == "replace_clip")
        #expect(destination.resetTrim == true)
        #expect(destination.linkedSourcesSHA256 != nil)
        editor.timeline.tracks[1].clips[0].volume = 0.25
        #expect(throws: (any Error).self) { try destination.requireCurrent(editor: editor) }
        editor.timeline.tracks[1].clips[0].volume = audio.volume
        try destination.requireCurrent(editor: editor)
    }

    @Test(arguments: [60.4, 10.0])
    func legacyVideoRerunRequiresExactFullSourceEvidence(duration: Double) async throws {
        let original = try await CompositorFixtures.patternVideoURL()
        let originalDuration = try await AVURLAsset(url: original).load(.duration).seconds
        let frames = Int((duration * 30).rounded())
        let sourceURL = try await VideoTrimExtractor.extract(.init(sourceURL: original, trimStartFrame: 0,
            trimEndFrame: Int((originalDuration * 30).rounded()) - frames, sourceFramesConsumed: frames, fps: 30))
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let measuredDuration = try await AVURLAsset(url: sourceURL).load(.duration).seconds
        #expect(abs(measuredDuration - duration) < 0.1)
        let source = MediaAsset(id: "legacy-source", url: sourceURL, type: .video,
            name: "Original video", duration: measuredDuration)
        source.sourceWidth = Int(CompositorFixtures.renderSize.width)
        source.sourceHeight = Int(CompositorFixtures.renderSize.height)
        let editor = EditorViewModel()
        editor.mediaAssets = [source]
        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries)
        let suite = "legacy-upscale-range." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var quotes: [Double?] = []
        let services = GenerationPanelServices(catalog: catalog, preferences: ModelPreferences(defaults: defaults),
            activation: { .init(active: [.init(provider: .fal, transport: .api)]) }, quoteLoader: { _, pricing in
                quotes.append(pricing.durationSeconds)
                return GenerationPackageFixture.money()
            })
        var input = GenerationInput(prompt: "", model: "fal-ai/topaz/upscale/video",
            duration: Int(measuredDuration.rounded()), aspectRatio: "")
        input.sourceVideoAssetId = source.id
        #expect(input.duration == Int(duration.rounded()))
        let generated = MediaAsset(url: sourceURL.deletingLastPathComponent().appendingPathComponent("result.mp4"),
            type: .video, name: "Prior upscale", duration: Double(input.duration), generationInput: input)
        do {
            _ = try await EditSubmitter.rerun(asset: generated, editor: editor, services: services)
            Issue.record("Equal or rounded durations cannot prove an unrecorded original range")
        } catch let error as EditSubmitter.RerunError {
            guard case .unverifiedSourceRange = error else { Issue.record("Wrong refusal: \(error)"); return }
        }
        #expect(quotes.isEmpty)
        let originalSHA256 = try FileDigest.sha256(of: sourceURL)
        let wrongSHA256 = originalSHA256 == String(repeating: "a", count: 64)
            ? String(repeating: "b", count: 64) : String(repeating: "a", count: 64)
        input.referenceReceipts = [.init(assetID: source.id, displayName: source.name, type: "video",
            sourceSHA256: wrongSHA256, submittedSHA256: wrongSHA256)]
        generated.generationInput = input
        do {
            _ = try await EditSubmitter.rerun(asset: generated, editor: editor, services: services)
            Issue.record("Legacy full-source proof must match the actual prepared bytes before pricing")
        } catch let error as EditSubmitter.RerunError {
            guard case .unverifiedSourceRange = error else { Issue.record("Wrong byte refusal: \(error)"); return }
        }
        #expect(quotes.isEmpty)
        input.referenceReceipts = [.init(assetID: source.id, displayName: source.name, type: "video",
            sourceSHA256: originalSHA256, submittedSHA256: originalSHA256)]
        generated.generationInput = input
        do {
            _ = try await EditSubmitter.rerun(asset: generated, editor: editor, services: services)
            Issue.record("A proven full source must still require its actual review window")
        } catch GenerationRequestError.gate(let message) {
            #expect(message == "Open the project window and close its current sheet before reviewing generation.")
        }
        #expect(quotes == [Double(Int(measuredDuration.rounded(.up)))])
        let model = try #require(catalog.upscale.first { $0.id == input.model })
        let explicitRequest = try EditSubmitter.upscaleRequest(asset: source, model: model,
            target: services.target(model.id))
        guard case .preparedUpscale(let explicit) = explicitRequest.submission else {
            Issue.record("Expected the actual current full-source writer")
            return
        }
        #expect(explicit.genInput.sourceRange != nil)
        #expect(explicit.genInput.sourceRange?.trim == nil)
        generated.generationInput = explicit.genInput
        do {
            _ = try await EditSubmitter.rerun(asset: generated, editor: editor, services: services)
            Issue.record("Explicit full-source requests must still require review before dispatch")
        } catch GenerationRequestError.gate(let message) {
            #expect(message == "Open the project window and close its current sheet before reviewing generation.")
        }
        #expect(quotes.count == 2)
        generated.generationInput = input
        source.url = sourceURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".missing")
        do {
            _ = try await EditSubmitter.rerun(asset: generated, editor: editor, services: services)
            Issue.record("A missing file is distinct from missing range provenance")
        } catch let error as EditSubmitter.RerunError {
            guard case .unavailableSourceFile = error else { Issue.record("Wrong missing-file refusal: \(error)"); return }
        }
        #expect(quotes.count == 2)
        #expect(editor.mediaAssets.count == 1)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func aPreparedUpscaleCannotEmbedAnUnreviewedSourceURL() {
        #expect(throws: (any Error).self) {
            try PreparedProviderParameters(referenceCount: 1) { _ in
                .upscale(.init(sourceURL: "https://unreviewed.invalid/video", durationSeconds: 5))
            }
        }
    }
}
