import Foundation

// Curated fal.ai model catalog plus the per-model request "dialect" the runtime
// needs to map our generic params onto each model's `input` schema and to read
// its result. `entries` feeds the shared ModelCatalog (and thus the UI + agent);
// `model(for:)` gives the runtime the encoding recipe.
//
// Scope: text-driven generation plus the reference-driven variants that the fal
// storage upload now feeds — image-to-video (`image_url`), image edit
// (`image_urls`), and Seedance 2.0 reference-to-video (`image_urls` /
// `video_urls` / `audio_urls`). Each model's caps advertise exactly the
// reference inputs it accepts so the UI never offers an input that can't run.

enum FalImageSizeMode: Sendable {
    case imageSizeEnum   // `image_size`: square_hd / landscape_16_9 / …
    case aspectRatio     // `aspect_ratio`: "16:9" passthrough
    case none            // model takes no size param (e.g. Gemini edit)
}

enum FalImageRefField: Sendable {
    case none            // no input image (text-to-image)
    case single          // `image_url` (FLUX Kontext)
    case array           // `image_urls` (Gemini / nano-banana edit)
}

enum FalDurationMode: Sendable {
    case plainSeconds    // "5"   (Kling, Seedance, Hailuo)
    case secondsSuffix   // "8s"  (Veo)
}

enum FalAudioMode: Sendable {
    case tts             // { text, voice } → audio.url
    case soundEffect     // { text }        → audio.url
    case music           // { prompt, seconds_total } → audio_file.url
    case musicMs         // ElevenLabs Music: { prompt, music_length_ms, force_instrumental } → audio.url
}

enum FalUpscaleKind: Sendable {
    case image           // `image_url` in → `image.url` out (single object)
    case video           // `video_url` in → `video.url` out
}

struct FalModel: Sendable {
    let entry: CatalogEntry
    var imageSize: FalImageSizeMode = .imageSizeEnum
    var imageRef: FalImageRefField = .none
    var videoDuration: FalDurationMode = .plainSeconds
    var videoSendsAspectRatio: Bool = true
    var videoSendsResolution: Bool = false
    var videoGeneratesAudio: Bool = false
    var videoImageRef: Bool = false   // image-to-video: emit `image_url` from the reference image
    var videoReferenceArrays: Bool = false   // reference-to-video: emit image_urls/video_urls/audio_urls
    var audioMode: FalAudioMode = .tts
    var upscaleKind: FalUpscaleKind? = nil
}

enum FalModelRegistry {
    static let models: [FalModel] = imageModels + videoModels + audioModels + upscaleModels
    static let entries: [CatalogEntry] = models.map(\.entry)

    private static let byId: [String: FalModel] =
        Dictionary(models.map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func model(for id: String) -> FalModel? { byId[id] }

    // MARK: - Image (text-to-image)

    private static let imageAspects = ["1:1", "16:9", "9:16", "4:3", "3:4"]

    private static let imageModels: [FalModel] = [
        image("fal-ai/flux/schnell", "FLUX.1 [schnell]"),
        image("fal-ai/flux/dev", "FLUX.1 [dev]"),
        image("fal-ai/flux-pro/v1.1", "FLUX1.1 [pro]"),
        image("fal-ai/flux-pro/v1.1-ultra", "FLUX1.1 [pro] Ultra", size: .aspectRatio),
        image("fal-ai/recraft/v3/text-to-image", "Recraft V3", maxImages: 1),
        image("fal-ai/ideogram/v3", "Ideogram V3"),
        image("fal-ai/imagen4", "Imagen 4", size: .aspectRatio),
        image("fal-ai/qwen-image", "Qwen-Image"),
        image("fal-ai/stable-diffusion-v35-large", "Stable Diffusion 3.5 Large"),
        // Image-to-image / edit (needs a reference image — uses the fal storage upload).
        imageEdit("fal-ai/flux-pro/kontext", "FLUX.1 Kontext [pro]", size: .aspectRatio, ref: .single),
        imageEdit("fal-ai/gemini-25-flash-image/edit", "Gemini 2.5 Flash (edit)", size: .none, ref: .array),
    ]

    private static func image(
        _ id: String, _ name: String,
        size: FalImageSizeMode = .imageSizeEnum, maxImages: Int = 4
    ) -> FalModel {
        FalModel(
            entry: CatalogEntry(
                id: id, kind: .image, displayName: name,
                allowedEndpoints: [id], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil, aspectRatios: imageAspects, qualities: nil,
                    supportsImageReference: false, maxImages: maxImages
                ))
            ),
            imageSize: size
        )
    }

    private static func imageEdit(
        _ id: String, _ name: String, size: FalImageSizeMode, ref: FalImageRefField
    ) -> FalModel {
        FalModel(
            entry: CatalogEntry(
                id: id, kind: .image, displayName: name,
                allowedEndpoints: [id], responseShape: .images,
                uiCapabilities: .image(ImageCaps(
                    resolutions: nil, aspectRatios: imageAspects, qualities: nil,
                    supportsImageReference: true, maxImages: 1
                ))
            ),
            imageSize: size, imageRef: ref
        )
    }

    // MARK: - Video (text-to-video)

    // Seedance 2.0 aspect set (verified: fal-ai/seedance-2.0-api). Adds 21:9
    // ultrawide over the 1.0 set; "auto" is a provider default we don't surface.
    private static let seedance2Aspects = ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9"]

    private static let videoModels: [FalModel] = [
        video("fal-ai/kling-video/v2.5-turbo/pro/text-to-video", "Kling 2.5 Turbo Pro",
              durations: [5, 10], aspects: ["16:9", "9:16", "1:1"]),
        video("fal-ai/bytedance/seedance/v1/pro/text-to-video", "Seedance 1.0 Pro",
              durations: [5, 10], aspects: ["16:9", "9:16", "1:1", "4:3", "3:4"],
              resolutions: ["480p", "720p", "1080p"], sendsResolution: true),
        // Seedance 2.0 — ByteDance's namespace on fal (no `fal-ai/` prefix; the
        // queue path IS the id, verified against the official examples + fal.run
        // cURL). Native audio (`generate_audio`, default true), up to 15s. GA
        // endpoints cap at 720p.
        video("bytedance/seedance-2.0/text-to-video", "Seedance 2.0",
              durations: [5, 10, 15], aspects: seedance2Aspects,
              resolutions: ["480p", "720p"], sendsResolution: true, generatesAudio: true),
        // Reference-to-video: up to 9 image + 3 video + 3 audio refs (≤12 total),
        // bound in the prompt as @Image1/@Video1/@Audio1. This is the multi-ref
        // consistency path the musicvideo pack drives via seedance_input_mode=reference.
        videoRef("bytedance/seedance-2.0/reference-to-video", "Seedance 2.0 (reference)",
                 durations: [5, 10, 15], aspects: seedance2Aspects, resolutions: ["480p", "720p"],
                 maxImages: 9, maxVideos: 3, maxAudios: 3, maxTotal: 12),
        video("fal-ai/veo3", "Veo 3",
              durations: [4, 6, 8], aspects: ["16:9", "9:16"], resolutions: ["720p", "1080p"],
              duration: .secondsSuffix, sendsResolution: true, generatesAudio: true),
        video("fal-ai/minimax/hailuo-02/standard/text-to-video", "Hailuo 02 Standard",
              durations: [6, 10], aspects: ["16:9", "9:16"], sendsAspect: false),
        // Image-to-video: the input image is a required image reference; aspect is image-driven.
        video("fal-ai/kling-video/v2.5-turbo/pro/image-to-video", "Kling 2.5 Turbo Pro (image)",
              durations: [5, 10], aspects: ["16:9", "9:16"], sendsAspect: false, i2v: true),
        video("fal-ai/bytedance/seedance/v1/pro/image-to-video", "Seedance 1.0 Pro (image)",
              durations: [5, 10], aspects: ["16:9", "9:16"], resolutions: ["480p", "720p", "1080p"],
              sendsAspect: false, sendsResolution: true, i2v: true),
        video("bytedance/seedance-2.0/image-to-video", "Seedance 2.0 (image)",
              durations: [5, 10, 15], aspects: ["16:9", "9:16"], resolutions: ["480p", "720p"],
              sendsAspect: false, sendsResolution: true, generatesAudio: true, i2v: true),
    ]

    private static func video(
        _ id: String, _ name: String,
        durations: [Int], aspects: [String], resolutions: [String]? = nil,
        duration: FalDurationMode = .plainSeconds,
        sendsAspect: Bool = true, sendsResolution: Bool = false, generatesAudio: Bool = false,
        i2v: Bool = false
    ) -> FalModel {
        FalModel(
            entry: CatalogEntry(
                id: id, kind: .video, displayName: name,
                allowedEndpoints: [id], responseShape: .video,
                uiCapabilities: .video(videoCaps(durations: durations, aspects: aspects, resolutions: resolutions, requiresImage: i2v))
            ),
            videoDuration: duration,
            videoSendsAspectRatio: sendsAspect,
            videoSendsResolution: sendsResolution,
            videoGeneratesAudio: generatesAudio,
            videoImageRef: i2v
        )
    }

    private static func videoCaps(durations: [Int], aspects: [String], resolutions: [String]?, requiresImage: Bool = false) -> VideoCaps {
        VideoCaps(
            durations: durations, resolutions: resolutions, aspectRatios: aspects,
            supportsFirstFrame: false, supportsLastFrame: false,
            maxReferenceImages: requiresImage ? 1 : 0, maxReferenceVideos: 0, maxReferenceAudios: 0,
            maxTotalReferences: requiresImage ? 1 : 0, maxCombinedVideoRefSeconds: nil, maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false, referenceTagNoun: "reference",
            requiresSourceVideo: false, requiresReferenceImage: requiresImage
        )
    }

    // Reference-to-video: multi-modal reference arrays (image_urls/video_urls/
    // audio_urls), aspect + resolution still sent. References are optional (the
    // prompt can stand alone), so `requiresReferenceImage` stays false.
    private static func videoRef(
        _ id: String, _ name: String,
        durations: [Int], aspects: [String], resolutions: [String]?,
        maxImages: Int, maxVideos: Int, maxAudios: Int, maxTotal: Int
    ) -> FalModel {
        FalModel(
            entry: CatalogEntry(
                id: id, kind: .video, displayName: name,
                allowedEndpoints: [id], responseShape: .video,
                uiCapabilities: .video(VideoCaps(
                    durations: durations, resolutions: resolutions, aspectRatios: aspects,
                    supportsFirstFrame: false, supportsLastFrame: false,
                    maxReferenceImages: maxImages, maxReferenceVideos: maxVideos,
                    maxReferenceAudios: maxAudios, maxTotalReferences: maxTotal,
                    maxCombinedVideoRefSeconds: 15, maxCombinedAudioRefSeconds: 15,
                    framesAndReferencesExclusive: false, referenceTagNoun: "reference",
                    requiresSourceVideo: false, requiresReferenceImage: false
                ))
            ),
            videoSendsResolution: true,
            videoGeneratesAudio: true,
            videoReferenceArrays: true
        )
    }

    // MARK: - Audio (text-to-speech / sfx / music)

    private static let elevenLabsVoices = [
        "Rachel", "Aria", "Roger", "Sarah", "Laura", "Charlie",
        "George", "Callum", "River", "Liam", "Charlotte", "Alice",
    ]

    private static let audioModels: [FalModel] = [
        audio("fal-ai/elevenlabs/tts/multilingual-v2", "ElevenLabs Multilingual v2",
              mode: .tts, caps: ttsCaps),
        audio("fal-ai/elevenlabs/sound-effects", "ElevenLabs Sound Effects",
              mode: .soundEffect, caps: sfxCaps),
        audio("fal-ai/stable-audio", "Stable Audio",
              mode: .music, caps: musicCaps),
        audio("fal-ai/elevenlabs/music", "ElevenLabs Music",
              mode: .musicMs, caps: elevenMusicCaps),
    ]

    private static func audio(_ id: String, _ name: String, mode: FalAudioMode, caps: AudioCaps) -> FalModel {
        FalModel(
            entry: CatalogEntry(
                id: id, kind: .audio, displayName: name,
                allowedEndpoints: [id], responseShape: .audio,
                uiCapabilities: .audio(caps)
            ),
            audioMode: mode
        )
    }

    private static let ttsCaps = AudioCaps(
        category: "tts", voices: elevenLabsVoices, defaultVoice: "Rachel",
        supportsLyrics: false, supportsInstrumental: false, supportsStyleInstructions: false,
        durations: nil, minPromptLength: 1, inputs: ["text"],
        promptLabel: "Text to speak", minSeconds: nil, maxSeconds: nil
    )

    private static let sfxCaps = AudioCaps(
        category: "sfx", voices: nil, defaultVoice: nil,
        supportsLyrics: false, supportsInstrumental: false, supportsStyleInstructions: false,
        durations: nil, minPromptLength: 1, inputs: ["text"],
        promptLabel: "Sound description", minSeconds: nil, maxSeconds: nil
    )

    private static let musicCaps = AudioCaps(
        category: "music", voices: nil, defaultVoice: nil,
        supportsLyrics: false, supportsInstrumental: true, supportsStyleInstructions: false,
        durations: nil, minPromptLength: 1, inputs: ["text"],
        promptLabel: "Music description", minSeconds: 1, maxSeconds: 47
    )

    private static let elevenMusicCaps = AudioCaps(
        category: "music", voices: nil, defaultVoice: nil,
        supportsLyrics: false, supportsInstrumental: true, supportsStyleInstructions: false,
        durations: nil, minPromptLength: 1, inputs: ["text"],
        promptLabel: "Music description", minSeconds: 3, maxSeconds: 600
    )

    // MARK: - Upscale

    private static let upscaleModels: [FalModel] = [
        upscale("fal-ai/clarity-upscaler", "Clarity Upscaler", kind: .image, speed: "Medium", p75: 30),
        upscale("fal-ai/topaz/upscale/video", "Topaz Video Upscale", kind: .video, speed: "Slow", p75: 120),
    ]

    private static func upscale(_ id: String, _ name: String, kind: FalUpscaleKind, speed: String, p75: Int) -> FalModel {
        let shape: CatalogEntry.ResponseShape = (kind == .video) ? .video : .upscaledImage
        let types = (kind == .video) ? ["video"] : ["image"]
        return FalModel(
            entry: CatalogEntry(
                id: id, kind: .upscale, displayName: name,
                allowedEndpoints: [id], responseShape: shape,
                uiCapabilities: .upscale(UpscaleCaps(speed: speed, p75DurationSeconds: p75, supportedTypes: types))
            ),
            upscaleKind: kind
        )
    }
}
