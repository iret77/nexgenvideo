import Foundation

// Maps our generic generation params onto each fal model's `input` object, and
// reads result URLs back out of the per-modality result shape. All field names
// and enums are taken from fal.ai's published model schemas (June 2026).

enum FalInputBuilder {

    static func imageInput(_ p: ImageGenerationParams, sizeMode: FalImageSizeMode, refField: FalImageRefField, count: Int) -> [String: Any] {
        var input: [String: Any] = ["prompt": p.prompt]
        if count > 1 { input["num_images"] = count }   // 1 is every model's default; omit so edit models never see an unsupported field
        switch sizeMode {
        case .imageSizeEnum: input["image_size"] = imageSizeEnum(p.aspectRatio)
        case .aspectRatio:   input["aspect_ratio"] = p.aspectRatio
        case .none:          break
        }
        switch refField {
        case .none:   break
        case .single: if let first = p.imageURLs.first { input["image_url"] = first }
        case .array:  if !p.imageURLs.isEmpty { input["image_urls"] = p.imageURLs }
        }
        return input
    }

    static func videoInput(_ p: VideoGenerationParams, model: FalModel) -> [String: Any] {
        var input: [String: Any] = ["prompt": p.prompt]
        switch model.videoDuration {
        case .plainSeconds:  input["duration"] = String(p.duration)
        case .secondsSuffix: input["duration"] = "\(p.duration)s"
        }
        if model.videoImageRef, let image = p.referenceImageURLs.first { input["image_url"] = image }
        if model.videoSendsAspectRatio { input["aspect_ratio"] = p.aspectRatio }
        if model.videoSendsResolution, let resolution = p.resolution { input["resolution"] = resolution }
        if model.videoGeneratesAudio { input["generate_audio"] = p.generateAudio }
        return input
    }

    static func audioInput(_ p: AudioGenerationParams, model: FalModel) -> [String: Any] {
        switch model.audioMode {
        case .tts:
            return ["text": p.prompt, "voice": p.voice ?? "Rachel"]
        case .soundEffect:
            return ["text": p.prompt]
        case .music:
            return ["prompt": p.prompt, "seconds_total": p.durationSeconds ?? 30]
        }
    }

    static func upscaleInput(_ p: UpscaleGenerationParams, model: FalModel) -> [String: Any] {
        let urlField = (model.upscaleKind == .video) ? "video_url" : "image_url"
        return [urlField: p.sourceURL]   // upscale_factor defaults to 2x on fal
    }

    /// Map our aspect-ratio label to fal's `image_size` enum.
    static func imageSizeEnum(_ aspectRatio: String) -> String {
        switch aspectRatio {
        case "1:1": return "square_hd"
        case "16:9": return "landscape_16_9"
        case "9:16": return "portrait_16_9"
        case "4:3": return "landscape_4_3"
        case "3:4": return "portrait_4_3"
        default: return "square_hd"
        }
    }
}

enum FalOutput {
    /// Extract result URLs from a fal result payload for the given response shape.
    static func urls(from data: Data, shape: CatalogEntry.ResponseShape) -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        switch shape {
        case .images:
            let images = json["images"] as? [[String: Any]] ?? []
            return images.compactMap { $0["url"] as? String }
        case .upscaledImage:
            // Image upscalers return a single `image` object, not an `images` array.
            if let image = json["image"] as? [String: Any], let url = image["url"] as? String { return [url] }
            return []
        case .video:
            if let video = json["video"] as? [String: Any], let url = video["url"] as? String { return [url] }
            return []
        case .audio:
            // ElevenLabs returns `audio.url`; music/SFX models return `audio_file.url`.
            if let audio = json["audio"] as? [String: Any], let url = audio["url"] as? String { return [url] }
            if let audio = json["audio_file"] as? [String: Any], let url = audio["url"] as? String { return [url] }
            return []
        }
    }
}
