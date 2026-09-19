import Foundation
import Testing
@testable import NexGenVideo

@Suite("Higgsfield model contracts")
struct HiggsfieldMappingTests {
    private func model(_ operation: HiggsfieldModel.Operation) throws -> HiggsfieldModel {
        try #require(HiggsfieldModelRegistry.models.first { $0.operation == operation })
    }

    @Test func firstLastFramesAreNotReferenceArrays() throws {
        let model = try model(.imageToVideo)
        let params = VideoGenerationParams(prompt: "Exact compiled prompt", duration: 5,
            aspectRatio: "16:9", resolution: "720p", startFrameURL: "https://cdn.example.com/start.png",
            endFrameURL: "https://cdn.example.com/end.png", generateAudio: false)
        let object = try #require(JSONSerialization.jsonObject(with: HiggsfieldInputBuilder.body(model: model, params: .video(params))) as? [String: Any])
        #expect(object["prompt"] as? String == params.prompt)
        #expect(object["image_url"] as? String == params.startFrameURL)
        #expect(object["end_image_url"] as? String == params.endFrameURL)
        #expect(object["aspect_ratio"] == nil)
        #expect(object["image_urls"] == nil)
        #expect(object["generate_audio"] as? Bool == false)
        #expect(model.entry.offers?.first?.resolvedVideoCapabilities?.requiresReferenceImage == true)
    }

    @Test func referenceRouteEnforcesPublishedLimitsAndInputRoles() throws {
        let model = try model(.referenceToVideo)
        let references = (0..<30).map { "https://cdn.example.com/\($0).png" }
        let valid = VideoGenerationParams(prompt: "Compiled", duration: 30, aspectRatio: "21:9", resolution: "720p",
            referenceImageURLs: references, referenceVideoURLs: ["https://cdn.example.com/ref.mp4"],
            referenceAudioURLs: ["https://cdn.example.com/ref.wav"])
        let object = try #require(JSONSerialization.jsonObject(with: HiggsfieldInputBuilder.body(model: model, params: .video(valid))) as? [String: Any])
        #expect(object["image_urls"] as? [String] == references)
        #expect(object["video_urls"] as? [String] == valid.referenceVideoURLs)
        #expect(object["audio_urls"] as? [String] == valid.referenceAudioURLs)
        let tooMany = VideoGenerationParams(prompt: "Compiled", duration: 5, aspectRatio: "16:9", resolution: "720p",
            referenceImageURLs: references + ["https://cdn.example.com/extra.png"])
        #expect(throws: (any Error).self) { try HiggsfieldInputBuilder.body(model: model, params: .video(tooMany)) }
        let empty = VideoGenerationParams(prompt: "Compiled", duration: 5, aspectRatio: "16:9", resolution: "720p")
        #expect(throws: (any Error).self) { try HiggsfieldInputBuilder.body(model: model, params: .video(empty)) }
    }

    @Test func editAndExtensionKeepExactSourceAndDistinctDurationSemantics() throws {
        let params = VideoGenerationParams(prompt: "Compiled", duration: 8, aspectRatio: "16:9", resolution: "720p",
            sourceVideoURL: "https://cdn.example.com/approved-source.mp4")
        let edit = try model(.edit)
        let extend = try model(.extend)
        let editBody = try #require(JSONSerialization.jsonObject(with: HiggsfieldInputBuilder.body(model: edit, params: .video(params))) as? [String: Any])
        let extendBody = try #require(JSONSerialization.jsonObject(with: HiggsfieldInputBuilder.body(model: extend, params: .video(params))) as? [String: Any])
        #expect(editBody["video_url"] as? String == params.sourceVideoURL)
        #expect(extendBody["video_url"] as? String == params.sourceVideoURL)
        #expect(editBody["duration"] == nil)
        #expect(extendBody["duration"] as? Int == 8)
        #expect(extend.entry.offers?.first?.productionInputPolicy?.sourceOperation == .extendForward)
        #expect(edit.entry.offers?.first?.productionInputPolicy?.preservesSourceComposition == true)
    }

    @Test func invalidOptionsAndLocalPathsFailBeforeSubmission() throws {
        for params in [
            VideoGenerationParams(prompt: "Compiled", duration: 3, aspectRatio: "16:9", resolution: "720p"),
            VideoGenerationParams(prompt: "Compiled", duration: 5, aspectRatio: "16:9", resolution: "1080p")
        ] {
            let model = try model(.textToVideo)
            #expect(throws: (any Error).self) { try HiggsfieldInputBuilder.body(model: model, params: .video(params)) }
        }
        let imageModel = try model(.imageToVideo)
        let local = VideoGenerationParams(prompt: "Compiled", duration: 5, aspectRatio: "16:9", resolution: "720p",
            startFrameURL: "/tmp/local.png")
        #expect(throws: (any Error).self) { try HiggsfieldInputBuilder.body(model: imageModel, params: .video(local)) }
    }

    @Test func soulPreservesCompiledPromptAndDisablesProviderRewrite() throws {
        let params = ImageGenerationParams(prompt: "Exact compiled prompt", aspectRatio: "4:3", resolution: "1080p",
            quality: nil, imageURLs: [], numImages: 1)
        let object = try #require(JSONSerialization.jsonObject(with: HiggsfieldInputBuilder.body(model: model(.image), params: .image(params))) as? [String: Any])
        #expect(object["enhance_prompt"] as? Bool == false)
        #expect(object["batch_size"] as? Int == 1)
        #expect(object["prompt"] as? String == params.prompt)
    }

    @Test @MainActor func signingOutOfOneTransportPreservesTheOther() throws {
        let catalog = ModelCatalog()
        catalog.load(entries: [])
        let api = try model(.image).entry
        let mcp = CatalogEntry(id: "soul_mcp", kind: .image, displayName: "Soul MCP", allowedEndpoints: [],
            responseShape: .images, uiCapabilities: api.uiCapabilities,
            offers: [ProviderOffer(provider: .higgsfield, transport: .mcp, providerRef: "generate_image", modelParam: "soul")])
        catalog.applyDiscovered([api, mcp], for: .higgsfield)
        _ = CatalogDiscovery.publishHiggsfield(.init(provider: .higgsfield, mcpConfigured: false, oauthConnected: false,
            entries: [], directResult: .success([api])), catalog: catalog)
        #expect(catalog.discoveredEntries(for: .higgsfield, transport: .api).count == 1)
        #expect(catalog.discoveredEntries(for: .higgsfield, transport: .mcp).isEmpty)
        _ = CatalogDiscovery.publishHiggsfield(.init(provider: .higgsfield, mcpConfigured: true, oauthConnected: true,
            entries: [mcp], directResult: .inactive), catalog: catalog)
        #expect(catalog.discoveredEntries(for: .higgsfield, transport: .api).isEmpty)
        #expect(catalog.discoveredEntries(for: .higgsfield, transport: .mcp).count == 1)
        _ = CatalogDiscovery.publishHiggsfield(.init(provider: .higgsfield, mcpConfigured: true, oauthConnected: true,
            entries: [mcp], directResult: .authenticationFailure("invalid")), catalog: catalog)
        #expect(catalog.discoveredEntries(for: .higgsfield, transport: .mcp).count == 1)
    }

    @Test @MainActor func sourceContractsAndHostingAreNative() throws {
        for model in HiggsfieldModelRegistry.models where model.operation != .image {
            let caps = try #require(model.entry.offers?.first?.resolvedVideoCapabilities)
            #expect(caps.contractViolation == nil)
        }
        #expect(GenerationService.referenceHosting(for: .higgsfield) == .higgsfield)
        #expect(ProviderManifest.nominalProvider(forModelId: HiggsfieldModelRegistry.idPrefix + "unknown") == .higgsfield)
    }
}
