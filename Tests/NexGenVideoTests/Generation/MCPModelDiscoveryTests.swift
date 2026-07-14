import Testing
import Foundation
import MCP

@testable import NexGenVideo

/// The pure Tool→CatalogEntry mapping + the gate invariant for runtime MCP model discovery (#163).
/// Fixtures are trimmed from the REAL Higgsfield MCP payloads (`models_explore(action:list)` and its
/// `tools/list`), so the mapping is tested against the shape it will actually meet. The live browser
/// OAuth + discovery round-trip is verified on-device (no account in CI).
@Suite("MCP model discovery — tool → catalog mapping + gate")
struct MCPModelDiscoveryTests {

    private func tool(_ name: String, _ description: String? = nil) -> MCPProviderClient.DiscoveredTool {
        MCPProviderClient.DiscoveredTool(name: name, description: description, inputSchema: .object([:]))
    }

    // Real Higgsfield generate + catalog + editing tools, as `tools/list` returns them.
    private var higgsfieldTools: [MCPProviderClient.DiscoveredTool] {
        [tool("generate_video", "Generate a video."),
         tool("generate_image", "Generate an image."),
         tool("generate_audio", "Generate speech/voice audio (text-to-speech)."),
         tool("models_explore", "Find generation models."),
         tool("upscale_image", "Enhance or increase resolution."),
         tool("reframe", "Change a video's aspect ratio."),
         tool("remove_background", "Cutout / transparent background.")]
    }

    // Two real items from models_explore(action:list, type:video), plus the paging envelope.
    private let videoListing = #"""
    {"items":[
      {"id":"cinematic_studio_3_0","name":"Cinema Studio Video 3.0","provider_name":"Higgsfield",
       "description":"Most advanced cinema-grade model","output_type":"video",
       "parameters":[{"name":"resolution","type":"string","default":"720p","options":["480p","720p","1080p","4k"]},
                     {"name":"generate_audio","type":"bool","default":false}],
       "medias":[{"name":"medias","type":"image","roles":["image","start_image","end_image"]}],
       "aspect_ratios":["auto","21:9","16:9","9:16"],"tags":["cinematic","premium"],"duration_range":{"min":4,"max":15}},
      {"id":"cinematic_studio_video","name":"Cinema Studio Video","provider_name":"Higgsfield",
       "description":"Solid cinematic","output_type":"video",
       "medias":[{"name":"medias","type":"image","roles":["image","start_image","end_image"]}],
       "aspect_ratios":["1:1","16:9","9:16"],"tags":["cinematic"],"durations":[5,10]}
    ],"has_more":true,"next_page_token":"4"}
    """#

    // MARK: - tool classification

    @Test func generateToolsMapToModalitiesEditorsExcluded() {
        let byModality = MCPModelDiscovery.generateToolsByModality(higgsfieldTools)
        #expect(byModality[.video] == "generate_video")
        #expect(byModality[.image] == "generate_image")
        #expect(byModality[.audio] == "generate_audio")
        // models_explore, upscale_image, reframe, remove_background are not generators → no bucket.
        #expect(byModality[.upscale] == nil)
        #expect(byModality.count == 3)
    }

    @Test func audioBeatsBroaderVideoImageKeywords() {
        // A "sound" tool must bucket as audio, not get grabbed by a stray token.
        #expect(MCPModelDiscovery.modality(name: "generate_sound_effect", description: nil) == .audio)
        #expect(MCPModelDiscovery.modality(name: "upscale_video", description: "enhance") == .upscale)
        #expect(MCPModelDiscovery.isGenerative(name: "upscale_image", description: "Enhance resolution") == false)
        #expect(MCPModelDiscovery.isGenerative(name: "generate_video", description: "Generate a video.") == true)
    }

    // MARK: - listing parse

    @Test func parseListingReadsItemsAndCursor() {
        let (items, next) = MCPModelDiscovery.parseListing(videoListing)
        #expect(items.count == 2)
        #expect(items.first?.id == "cinematic_studio_3_0")
        #expect(items.first?.outputType == "video")
        #expect(next == "4")   // has_more:true → cursor surfaced
    }

    @Test func parseListingLastPageHasNoCursor() {
        let lastPage = #"{"items":[{"id":"x","output_type":"video"}],"has_more":false,"next_page_token":"9"}"#
        #expect(MCPModelDiscovery.parseListing(lastPage).next == nil)
    }

    @Test func parseListingToleratesGarbageAndBareArray() {
        #expect(MCPModelDiscovery.parseListing("not json").items.isEmpty)
        let bare = #"[{"id":"solo","output_type":"image"}]"#
        let (items, next) = MCPModelDiscovery.parseListing(bare)
        #expect(items.map(\.id) == ["solo"])
        #expect(next == nil)
    }

    // MARK: - the mapping core

    @Test func modelsMapToGatedMcpCatalogEntries() {
        let (models, _) = MCPModelDiscovery.parseListing(videoListing)
        let byModality = MCPModelDiscovery.generateToolsByModality(higgsfieldTools)
        let entries = MCPModelDiscovery.catalogEntries(
            models: models, toolsByModality: byModality, provider: .higgsfield)

        #expect(entries.count == 2)
        let top = try! #require(entries.first { $0.id == "cinematic_studio_3_0" })
        #expect(top.displayName == "Cinema Studio Video 3.0")
        #expect(top.kind == .video)

        // The offer routes through the resolver over MCP, naming the generate TOOL + the MODEL id.
        let offer = try! #require(top.offers?.first)
        #expect(offer.provider == .higgsfield)
        #expect(offer.transport == .mcp)
        #expect(offer.providerRef == "generate_video")   // the tool NGV drives as client
        #expect(offer.modelParam == "cinematic_studio_3_0")  // the model arg NGV sends

        // Capabilities are lifted from the model's declared params/medias/ranges.
        guard case let .video(caps) = top.uiCapabilities else { Issue.record("expected video caps"); return }
        #expect(caps.resolutions == ["480p", "720p", "1080p", "4k"])
        #expect(caps.aspectRatios == ["21:9", "16:9", "9:16"])   // "auto" filtered out
        #expect(caps.durations == Array(4...15))                 // duration_range expanded
        #expect(caps.supportsFirstFrame)                         // start_image role present
        #expect(caps.supportsLastFrame)                          // end_image role present
        #expect(caps.maxReferenceImages == 1)                    // image media present
        #expect(top.card?.tags == ["cinematic", "premium"])

        // The second item uses an explicit durations list, not a range.
        let solid = try! #require(entries.first { $0.id == "cinematic_studio_video" })
        guard case let .video(caps2) = solid.uiCapabilities else { Issue.record("expected video caps"); return }
        #expect(caps2.durations == [5, 10])
    }

    @Test func audioModelInfersCategoryFromTags() {
        let listing = #"""
        {"items":[
          {"id":"sonilo_music","name":"Sonilo Music","output_type":"audio","tags":["audio","music"]},
          {"id":"seed_audio","name":"Seed Audio 1.0","output_type":"audio","tags":["audio","tts"]}
        ]}
        """#
        let (models, _) = MCPModelDiscovery.parseListing(listing)
        let entries = MCPModelDiscovery.catalogEntries(
            models: models, toolsByModality: [.audio: "generate_audio"], provider: .higgsfield)
        let music = try! #require(entries.first { $0.id == "sonilo_music" })
        guard case let .audio(caps) = music.uiCapabilities else { Issue.record("expected audio caps"); return }
        #expect(caps.category == "music")
        #expect(caps.supportsLyrics)
        let tts = try! #require(entries.first { $0.id == "seed_audio" })
        guard case let .audio(caps2) = tts.uiCapabilities else { Issue.record("expected audio caps"); return }
        #expect(caps2.category == "tts")
    }

    @Test func modelWithNoGenerateToolForItsModalityIsDropped() {
        let (models, _) = MCPModelDiscovery.parseListing(videoListing)
        // Only an audio generate tool is available → video models can't dispatch → dropped.
        let entries = MCPModelDiscovery.catalogEntries(
            models: models, toolsByModality: [.audio: "generate_audio"], provider: .higgsfield)
        #expect(entries.isEmpty)
    }

    @Test func toolOnlyFallbackWhenNoCatalog() {
        // A provider with no model catalog: one entry per generate tool, dispatched by tool name,
        // no model argument.
        let entries = MCPModelDiscovery.catalogEntriesFromTools(higgsfieldTools, provider: .openart)
        #expect(entries.count == 3)   // video + image + audio, editors excluded
        let video = try! #require(entries.first { $0.id == "generate_video" })
        #expect(video.offers?.first?.transport == .mcp)
        #expect(video.offers?.first?.providerRef == "generate_video")
        #expect(video.offers?.first?.modelParam == nil)
    }

    // MARK: - gate invariant

    /// A discovered model routes through the SAME prompt-engine gate as every content model: its offer
    /// is `.generation` over `.mcp`, so `GenerationController` compiles+tokens before dispatch, and the
    /// model id carries the model arg. Discovery adds models; it never opens a raw-prompt bypass.
    @Test @MainActor func discoveredModelIsAGatedGenerationBinding() {
        let (models, _) = MCPModelDiscovery.parseListing(videoListing)
        let byModality = MCPModelDiscovery.generateToolsByModality(higgsfieldTools)
        let entries = MCPModelDiscovery.catalogEntries(
            models: models, toolsByModality: byModality, provider: .higgsfield)
        ModelCatalog.shared.applyDiscovered(entries, for: .higgsfield)
        defer { ModelCatalog.shared.setDiscovered([:]) }

        let bindings = ProviderManifest.bindings(forModelId: "cinematic_studio_3_0")
        #expect(bindings.count == 1)
        let b = try! #require(bindings.first)
        #expect(b.kind == .generation)      // gated path, not an ungated `.tool`
        #expect(b.transport == .mcp)
        #expect(b.provider == .higgsfield)
        #expect(b.providerRef == "generate_video")
        #expect(b.modelParam == "cinematic_studio_3_0")

        // The gate itself rejects a raw prompt for this discovered model, and accepts only a valid token.
        #expect(throws: (any Error).self) {
            try PromptCompiler.enforceGate(args: [:], prompt: "a neon skyline", modelId: "cinematic_studio_3_0")
        }
        let token = PromptCompiler.token(for: "a neon skyline", modelId: "cinematic_studio_3_0")
        #expect(throws: Never.self) {
            try PromptCompiler.enforceGate(
                args: ["compileToken": token], prompt: "a neon skyline", modelId: "cinematic_studio_3_0")
        }
    }
}
