import Testing
@testable import NexGenVideo

@Suite("Models settings availability projection")
struct ModelsPaneProjectionTests {
    private let image: [ModelsPaneProjection.Row] = [
        .init(id: "image-ready", displayName: "Ready Image"),
        .init(id: "image-locked", displayName: "Locked Image"),
    ]
    private let video: [ModelsPaneProjection.Row] = [
        .init(id: "video-ready", displayName: "Ready Video"),
    ]

    @Test("Only runnable models enter settings sections")
    func filtersUnavailableModels() {
        let sections = ModelsPaneProjection.sections(
            image: image,
            video: video,
            audio: [],
            query: "",
            canRun: { $0.hasSuffix("ready") }
        )

        #expect(sections.flatMap(\.rows).map(\.id) == ["image-ready", "video-ready"])
        #expect(sections.contains { $0.id == "audio" } == false)
    }

    @Test("Provider search includes upscalers and trims newlines")
    func providerSearchIncludesUpscaling() {
        let sections = ModelsPaneProjection.sections(
            image: [.init(id: "image", displayName: "Image", providers: "Runway")],
            video: [], audio: [],
            upscale: [.init(id: "upscale", displayName: "Clarity", providers: "fal.ai")],
            query: "  FAL\n", canRun: { _ in true }
        )
        #expect(sections.map(\.id) == ["upscale"])
        #expect(sections.flatMap(\.rows).map(\.id) == ["upscale"])
    }

    @Test("Upscale menus respect visibility, provider availability and media type")
    func upscaleChoicesRespectSettings() {
        let models = FalModelRegistry.entries.compactMap { entry -> UpscaleModelConfig? in
            guard case .upscale(let caps) = entry.uiCapabilities else { return nil }
            return UpscaleModelConfig(entry: entry, caps: caps)
        }
        let visible = UpscaleModelConfig.availableModels(in: models, for: .image,
                                                         isEnabled: { _ in true }, canRun: { _ in true })
        #expect(visible.map(\.id) == ["fal-ai/clarity-upscaler"])
        #expect(UpscaleModelConfig.availableModels(in: models, for: .image,
                    isEnabled: { _ in false }, canRun: { _ in true }).isEmpty)
        #expect(UpscaleModelConfig.availableModels(in: models, for: .image,
                    isEnabled: { _ in true }, canRun: { _ in false }).isEmpty)
    }

    @Test("8K upscale is limited to the verified model, video dimensions and duration")
    func eightKAvailabilityMatchesProviderContract() throws {
        let entry = try #require(FalModelRegistry.entries.first {
            $0.id == "bria/video/increase-resolution"
        })
        guard case .upscale(let caps) = entry.uiCapabilities else {
            Issue.record("Bria must be registered as an upscaler")
            return
        }
        let model = UpscaleModelConfig(entry: entry, caps: caps)

        let from1080 = try #require(model.selection(
            sourceType: .video,
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            durationSeconds: 29,
            targetResolution: "8K"
        ))
        #expect(from1080.scaleFactor == 4)
        #expect(from1080.targetResolution == "8K")

        let from4K = try #require(model.selection(
            sourceType: .video,
            sourceWidth: 3_840,
            sourceHeight: 2_160,
            durationSeconds: 10,
            targetResolution: "8k"
        ))
        #expect(from4K.scaleFactor == 2)
        #expect(model.selection(
            sourceType: .video,
            sourceWidth: 1_280,
            sourceHeight: 720,
            durationSeconds: 10,
            targetResolution: "8K"
        ) == nil)
        #expect(model.selection(
            sourceType: .image,
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            durationSeconds: 1,
            targetResolution: "8K"
        ) == nil)
        #expect(model.selection(
            sourceType: .video,
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            durationSeconds: 30,
            targetResolution: "8K"
        ) == nil)
    }

    @Test("8K approval estimate uses the verified per-second price")
    func eightKCostEstimate() throws {
        let entry = try #require(FalModelRegistry.entries.first {
            $0.id == "bria/video/increase-resolution"
        })
        guard case .upscale(let caps) = entry.uiCapabilities else {
            Issue.record("Bria must be registered as an upscaler")
            return
        }
        let model = UpscaleModelConfig(entry: entry, caps: caps)

        #expect(CostEstimator.upscaleCost(model: model, durationSeconds: 10) == 140)
        #expect(CostEstimator.upscaleCost(model: model, durationSeconds: 1.1) == 16)

        let unpricedEntry = try #require(FalModelRegistry.entries.first {
            $0.id == "fal-ai/clarity-upscaler"
        })
        guard case .upscale(let unpricedCaps) = unpricedEntry.uiCapabilities else {
            Issue.record("Clarity must be registered as an upscaler")
            return
        }
        let unpriced = UpscaleModelConfig(entry: unpricedEntry, caps: unpricedCaps)
        #expect(CostEstimator.upscaleCost(model: unpriced, durationSeconds: 10) == nil)
    }

    @Test("video upscale provenance uses the project source slot")
    func videoUpscaleProvenance() {
        var input = GenerationInput(
            prompt: "",
            model: "bria/video/increase-resolution",
            duration: 10,
            aspectRatio: "",
            resolution: "8K",
            imageURLAssetIds: ["legacy-source"]
        )

        EditSubmitter.recordUpscaleProvenance(
            in: &input,
            uploadedURLs: ["https://provider.example/source.mp4"],
            sourceAssetID: "project-video",
            sourceType: .video
        )

        #expect(input.sourceVideoAssetId == "project-video")
        #expect(input.imageURLAssetIds == nil)
        #expect(input.imageURLs == ["https://provider.example/source.mp4"])
        #expect(input.resolution == "8K")
    }

    @Test("Search operates on the same runnable subset")
    func searchDoesNotReintroduceUnavailableModels() {
        let sections = ModelsPaneProjection.sections(
            image: image,
            video: video,
            audio: [],
            query: "locked",
            canRun: { $0 == "image-ready" }
        )

        #expect(sections.isEmpty)
    }
}
