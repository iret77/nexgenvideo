import Foundation
import MCP

/// Turns a provider's runtime MCP discovery into model-catalog entries — the pure, testable core of
/// provider MCP discovery (#163). No I/O: the coordinator (`CatalogDiscovery`) drives the tool
/// calls; everything here is data-in / data-out, so the Tool→CatalogEntry mapping is unit-tested
/// against the providers' real payload shapes without a live account.
///
/// LLM → NGV → Provider stays intact: discovered entries carry an `.mcp` `.generation` offer, so the
/// resolver routes them through the gated `GenerationController` path (compile+token) exactly like the
/// REST providers — discovery adds models, never a raw-prompt bypass.
enum MCPModelDiscovery {

    enum Modality: String, Sendable, CaseIterable {
        case video, image, audio, upscale
    }

    // MARK: - Tool classification

    /// Whether a discovered tool *creates* content (vs. edits existing media). Only creators become
    /// catalog models; editors (upscale/outpaint/reframe/remove-background/motion-control) are workflow
    /// `.tool`s reached via `run_provider_tool`, not the model picker.
    static func isGenerative(name: String, description: String?) -> Bool {
        let hay = (name + " " + (description ?? "")).lowercased()
        let signals = ["generate", "create", "text-to", "text2", "txt2", "t2v", "t2i", "i2v", "animate", "synthesi"]
        return signals.contains { hay.contains($0) }
    }

    /// The modality a tool/model serves, by keyword — the same vocabulary dispatch matches on.
    static func modality(name: String, description: String?) -> Modality? {
        let hay = (name + " " + (description ?? "")).lowercased()
        // Order matters: audio/upscale keywords are checked before the broad video/image ones so a
        // "sound" or "upscale" tool isn't mis-bucketed by a stray "image"/"video" token.
        if ["audio", "music", "sound", "speech", "voice", "tts"].contains(where: hay.contains) { return .audio }
        if ["upscale", "super-resolution", "super resolution"].contains(where: hay.contains) { return .upscale }
        if ["video", "animate", "motion", "i2v", "t2v"].contains(where: hay.contains) { return .video }
        if ["image", "picture", "txt2img", "t2i", "img"].contains(where: hay.contains) { return .image }
        return nil
    }

    /// The generate TOOL that serves each modality — the dispatch target (`providerRef`) a discovered
    /// model binds to. First generative match per modality wins; editors are ignored.
    static func generateToolsByModality(_ tools: [MCPProviderClient.DiscoveredTool]) -> [Modality: String] {
        var out: [Modality: String] = [:]
        for tool in tools where isGenerative(name: tool.name, description: tool.description) {
            guard let m = modality(name: tool.name, description: tool.description), out[m] == nil else { continue }
            out[m] = tool.name
        }
        return out
    }

    // MARK: - Model-catalog listing (models_explore-style)

    /// One model as a provider's catalog tool reports it. Every field but `id` is optional so a lean
    /// provider payload still decodes; unknown keys are ignored.
    struct ModelItem: Decodable, Sendable, Equatable {
        let id: String
        let name: String?
        let description: String?
        let outputType: String?
        let aspectRatios: [String]?
        let durations: [Int]?
        let durationRange: SpanRange?
        let parameters: [Param]?
        let medias: [Media]?
        let tags: [String]?

        struct SpanRange: Decodable, Sendable, Equatable { let min: Int?; let max: Int? }
        struct Param: Decodable, Sendable, Equatable {
            let name: String?
            let options: [Scalar]?
        }
        struct Media: Decodable, Sendable, Equatable {
            let name: String?
            let type: String?
            let roles: [String]?
            let min: Int?
            let max: Int?
        }
        /// A param option value that may arrive as string / number / bool — normalized to its text.
        struct Scalar: Decodable, Sendable, Equatable {
            let text: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { text = s }
                else if let i = try? c.decode(Int.self) { text = String(i) }
                else if let d = try? c.decode(Double.self) { text = String(d) }
                else if let b = try? c.decode(Bool.self) { text = String(b) }
                else { text = "" }
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, name, description, parameters, medias, tags
            case outputType = "output_type"
            case aspectRatios = "aspect_ratios"
            case durations
            case durationRange = "duration_range"
        }
    }

    private struct Listing: Decodable {
        let items: [ModelItem]?
        let hasMore: Bool?
        let nextPageToken: String?
        enum CodingKeys: String, CodingKey {
            case items
            case hasMore = "has_more"
            case nextPageToken = "next_page_token"
        }
    }

    /// Parse a catalog tool's textual result into models + the next-page cursor (nil when the last
    /// page or unpaged). Tolerant: accepts the `{items,has_more,next_page_token}` envelope or a bare
    /// `[ModelItem]` array; returns `([], nil)` on anything it can't read (never throws).
    static func parseListing(_ text: String) -> (items: [ModelItem], next: String?) {
        guard let data = text.data(using: .utf8) else { return ([], nil) }
        let decoder = JSONDecoder()
        if let listing = try? decoder.decode(Listing.self, from: data), let items = listing.items {
            return (items, listing.hasMore == true ? listing.nextPageToken : nil)
        }
        if let bare = try? decoder.decode([ModelItem].self, from: data) {
            return (bare, nil)
        }
        return ([], nil)
    }

    // MARK: - Mapping (the unit-tested core)

    /// Map a provider's enumerated models onto catalog entries, one per model, each bound to the
    /// generate tool of its modality. A model whose modality has no discovered generate tool is
    /// dropped (nothing could dispatch it). This is the pure Tool→CatalogEntry contract.
    static func catalogEntries(
        models: [ModelItem],
        toolsByModality: [Modality: String],
        toolSchemasByModality: [Modality: Value] = [:],
        allowsLocalMedia: Bool = true,
        provider: GenerationProvider
    ) -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        var seen = Set<String>()
        for model in models {
            guard !model.id.isEmpty, !seen.contains(model.id) else { continue }
            guard let modality = modalityOf(model), let tool = toolsByModality[modality] else { continue }
            if let schema = toolSchemasByModality[modality],
               !generationSchemaSupports(
                   model: model, modality: modality, schema: schema, modelParam: model.id,
                   includeMedia: allowsLocalMedia
               ) {
                continue
            }
            seen.insert(model.id)
            let offer = ProviderOffer(provider: provider, transport: .mcp,
                                      providerRef: tool, modelParam: model.id,
                                      mcpMediaRoles: allowsLocalMedia
                                        ? Array(mediaRoles(model)).sorted() : [])
            out.append(entry(
                for: model, modality: modality, offer: offer,
                allowsLocalMedia: allowsLocalMedia
            ))
        }
        return out
    }

    /// A generate tool with no separate model catalog (its `model` is a single implicit choice, or the
    /// provider advertises no catalog): one entry per discovered generate tool, dispatched by tool name
    /// with no `model` argument. The fallback when a provider has no `mcpModelCatalog` hint.
    static func catalogEntriesFromTools(
        _ tools: [MCPProviderClient.DiscoveredTool],
        provider: GenerationProvider
    ) -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        for (modality, tool) in generateToolsByModality(tools).sorted(by: { $0.value < $1.value })
        where modality != .upscale {
            guard let discoveredTool = tools.first(where: { $0.name == tool }) else { continue }
            let item = ModelItem(id: tool, name: "\(provider.displayName) \(modality.rawValue.capitalized)",
                                 description: discoveredTool.description,
                                 outputType: modality.rawValue, aspectRatios: nil, durations: nil,
                                 durationRange: nil, parameters: nil, medias: nil, tags: nil)
            guard generationSchemaSupports(
                model: item,
                modality: modality,
                schema: discoveredTool.inputSchema,
                modelParam: nil,
                includeMedia: false
            ) else { continue }
            let offer = ProviderOffer(provider: provider, transport: .mcp, providerRef: tool, modelParam: nil)
            out.append(entry(for: item, modality: modality, offer: offer, allowsLocalMedia: false))
        }
        return out
    }

    // MARK: - Entry construction

    private static func modalityOf(_ model: ModelItem) -> Modality? {
        switch (model.outputType ?? "").lowercased() {
        case "video": return .video
        case "image": return .image
        case "audio": return .audio
        case "upscale": return .upscale
        default: return nil   // "3d" and unknowns have no ModelKind — skip
        }
    }

    private static func entry(
        for model: ModelItem,
        modality: Modality,
        offer: ProviderOffer,
        allowsLocalMedia: Bool
    ) -> CatalogEntry {
        let displayName = model.name?.isEmpty == false ? model.name! : model.id
        let card = ModelCard(strengths: nil, weaknesses: nil, bestFor: model.description,
                             rank: nil, tags: model.tags)
        switch modality {
        case .video:
            return CatalogEntry(
                id: model.id, kind: .video, displayName: displayName,
                allowedEndpoints: [model.id], responseShape: .video,
                uiCapabilities: .video(videoCaps(model, allowsLocalMedia: allowsLocalMedia)),
                card: card, offers: [offer])
        case .image:
            return CatalogEntry(
                id: model.id, kind: .image, displayName: displayName,
                allowedEndpoints: [model.id], responseShape: .images,
                uiCapabilities: .image(imageCaps(model, allowsLocalMedia: allowsLocalMedia)),
                card: card, offers: [offer])
        case .audio:
            return CatalogEntry(
                id: model.id, kind: .audio, displayName: displayName,
                allowedEndpoints: [model.id], responseShape: .audio,
                uiCapabilities: .audio(audioCaps(model)), card: card, offers: [offer])
        case .upscale:
            return CatalogEntry(
                id: model.id, kind: .upscale, displayName: displayName,
                allowedEndpoints: [model.id], responseShape: .upscaledImage,
                uiCapabilities: .upscale(UpscaleCaps(speed: "Medium", p75DurationSeconds: 60,
                                                     supportedTypes: ["image", "video"])),
                card: card, offers: [offer])
        }
    }

    private static func videoCaps(_ model: ModelItem, allowsLocalMedia: Bool) -> VideoCaps {
        let roles = allowsLocalMedia ? mediaRoles(model) : []
        let hasImageRef = allowsLocalMedia && hasImageMedia(model)
        return VideoCaps(
            durations: model.durations ?? [],
            durationRange: durationRange(model.durationRange),
            supportsAutomaticDuration: supportsAutomaticDuration(model),
            resolutions: options(model, param: "resolution"),
            aspectRatios: aspectRatios(model),
            supportsFirstFrame: roles.contains("start_image"),
            supportsLastFrame: roles.contains("end_image"),
            maxReferenceImages: hasImageRef ? 1 : 0,
            maxReferenceVideos: 0, maxReferenceAudios: 0,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil, maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false, referenceTagNoun: "image",
            requiresSourceVideo: false, requiresReferenceImage: false)
    }

    private static func imageCaps(_ model: ModelItem, allowsLocalMedia: Bool) -> ImageCaps {
        ImageCaps(
            resolutions: options(model, param: "resolution"),
            aspectRatios: aspectRatios(model),
            qualities: options(model, param: "quality") ?? options(model, param: "mode"),
            supportsImageReference: allowsLocalMedia && hasImageMedia(model),
            maxImages: maxOutputImages(model))
    }

    private static func audioCaps(_ model: ModelItem) -> AudioCaps {
        let tags = (model.tags ?? []).map { $0.lowercased() }
        let acceptsVideo = hasMedia(model, type: "video")
        let category: String
        if tags.contains(where: { $0.contains("music") }) { category = "music" }
        else if tags.contains(where: { $0.contains("sfx") || $0.contains("sound-effect") }) { category = "sfx" }
        else { category = "tts" }
        let span = expandedRange(model.durationRange)
        return AudioCaps(
            category: category, voices: nil, defaultVoice: nil,
            supportsLyrics: category == "music", supportsInstrumental: category == "music",
            supportsStyleInstructions: false,
            durations: model.durations,
            minPromptLength: acceptsVideo ? 0 : 1,
            inputs: acceptsVideo ? ["text", "video"] : ["text"],
            promptLabel: nil,
            minSeconds: span.first, maxSeconds: span.last)
    }

    // MARK: - Field helpers

    private static func aspectRatios(_ model: ModelItem) -> [String] {
        (model.aspectRatios ?? []).filter { $0.lowercased() != "auto" }
    }

    private static func durationRange(_ range: ModelItem.SpanRange?) -> VideoDurationCapabilities.Range? {
        guard let min = range?.min, let max = range?.max, min <= max else { return nil }
        return .init(min: min, max: max)
    }

    private static func supportsAutomaticDuration(_ model: ModelItem) -> Bool {
        model.parameters?
            .first { ($0.name ?? "").lowercased() == "duration" }?
            .options?
            .contains { $0.text.lowercased() == "auto" } == true
    }

    /// A `{min,max}` range → an inclusive list of second-choices, capped so an unbounded range never
    /// balloons the picker (beyond the cap only the two anchors are offered).
    private static func expandedRange(_ range: ModelItem.SpanRange?) -> [Int] {
        guard let lo = range?.min, let hi = range?.max, lo <= hi else { return [] }
        if hi - lo > 30 { return [lo, hi] }
        return Array(lo...hi)
    }

    private static func options(_ model: ModelItem, param: String) -> [String]? {
        guard let opts = model.parameters?.first(where: { ($0.name ?? "") == param })?.options, !opts.isEmpty
        else { return nil }
        let texts = opts.map(\.text).filter { !$0.isEmpty && $0.lowercased() != "auto" }
        return texts.isEmpty ? nil : texts
    }

    private static func mediaRoles(_ model: ModelItem) -> Set<String> {
        Set((model.medias ?? []).flatMap { $0.roles ?? [] }.map { $0.lowercased() })
    }

    private static func hasImageMedia(_ model: ModelItem) -> Bool {
        hasMedia(model, type: "image")
    }

    private static func hasMedia(_ model: ModelItem, type: String) -> Bool {
        (model.medias ?? []).contains { ($0.type ?? "").lowercased() == type }
    }

    private static func maxOutputImages(_ model: ModelItem) -> Int {
        let names = Set(["batch_size", "num_images", "number_of_images"])
        let declared = model.parameters?
            .filter { names.contains(($0.name ?? "").lowercased()) }
            .flatMap { $0.options ?? [] }
            .compactMap { Int($0.text) }
            .max()
        return max(1, min(4, declared ?? 1))
    }

    private static func generationSchemaSupports(
        model: ModelItem,
        modality: Modality,
        schema: Value,
        modelParam: String?,
        includeMedia: Bool
    ) -> Bool {
        let roles = includeMedia ? Array(mediaRoles(model)).sorted() : []
        let params: BackendGenerationParams
        switch modality {
        case .image:
            params = .image(ImageGenerationParams(
                prompt: "schema preflight", aspectRatio: aspectRatios(model).first ?? "1:1",
                resolution: options(model, param: "resolution")?.first,
                quality: options(model, param: "quality")?.first,
                imageURLs: includeMedia && hasImageMedia(model)
                    ? ["https://example.invalid/reference.jpg"] : [],
                numImages: 1
            ))
        case .video:
            let declared = includeMedia ? mediaRoles(model) : []
            params = .video(VideoGenerationParams(
                prompt: "schema preflight",
                duration: .seconds(model.durations?.first ?? model.durationRange?.min ?? 5),
                aspectRatio: aspectRatios(model).first ?? "16:9",
                resolution: options(model, param: "resolution")?.first,
                startFrameURL: declared.contains("start_image")
                    ? "https://example.invalid/start.jpg" : nil,
                endFrameURL: declared.contains("end_image")
                    ? "https://example.invalid/end.jpg" : nil,
                referenceImageURLs: declared.contains("image") || declared.contains("image_references")
                    ? ["https://example.invalid/reference.jpg"] : [],
                referenceVideoURLs: declared.contains("video") || declared.contains("video_references")
                    ? ["https://example.invalid/reference.mp4"] : [],
                referenceAudioURLs: declared.contains("audio") || declared.contains("audio_references")
                    ? ["https://example.invalid/reference.wav"] : []
            ))
        case .audio:
            params = .audio(AudioGenerationParams(
                prompt: "schema preflight", voice: nil, lyrics: nil,
                styleInstructions: nil, instrumental: false,
                durationSeconds: model.durations?.first,
                videoURL: includeMedia && hasMedia(model, type: "video")
                    ? "https://example.invalid/reference.mp4" : nil
            ))
        case .upscale:
            params = .upscale(UpscaleGenerationParams(
                sourceURL: "https://example.invalid/source.png", durationSeconds: 1
            ))
        }
        return (try? MCPGenerationArguments.make(
            for: params, model: modelParam, schema: schema, mediaRoles: roles
        )) != nil
    }
}
