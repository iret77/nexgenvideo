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
