import Testing
import Foundation
@testable import NexGenVideo

// Offline correctness for the fal.ai request/response mapping. The generation
// layer is built against fal's published schemas but unverified against the live
// API; these lock in the field names + output shapes so a transcription slip
// (e.g. image_url vs image_urls, video vs video_url) fails here, not silently at
// generation time.

@Suite("FalInputBuilder — image")
struct FalImageInputTests {
    @Test func fluxUsesImageSizeEnumAndOmitsNumImagesWhenOne() {
        let p = ImageGenerationParams(prompt: "a cat", aspectRatio: "16:9", resolution: nil, quality: nil, imageURLs: [], numImages: 1)
        let input = FalInputBuilder.imageInput(p, sizeMode: .imageSizeEnum, refField: .none, count: 1)
        #expect(input["prompt"] as? String == "a cat")
        #expect(input["image_size"] as? String == "landscape_16_9")
        #expect(input["num_images"] == nil)
        #expect(input["image_url"] == nil)
    }

    @Test func multiImageSendsNumImages() {
        let p = ImageGenerationParams(prompt: "x", aspectRatio: "1:1", resolution: nil, quality: nil, imageURLs: [], numImages: 4)
        let input = FalInputBuilder.imageInput(p, sizeMode: .imageSizeEnum, refField: .none, count: 4)
        #expect(input["num_images"] as? Int == 4)
    }

    @Test func aspectRatioModeSendsAspectRatio() {
        let p = ImageGenerationParams(prompt: "x", aspectRatio: "16:9", resolution: nil, quality: nil, imageURLs: [], numImages: 1)
        let input = FalInputBuilder.imageInput(p, sizeMode: .aspectRatio, refField: .none, count: 1)
        #expect(input["aspect_ratio"] as? String == "16:9")
        #expect(input["image_size"] == nil)
    }

    @Test func editSingleEmitsImageUrl() throws {
        let kontext = try #require(FalModelRegistry.model(for: "fal-ai/flux-pro/kontext"))
        let p = ImageGenerationParams(prompt: "edit", aspectRatio: "1:1", resolution: nil, quality: nil, imageURLs: ["https://x/src.png"], numImages: 1)
        let input = FalInputBuilder.imageInput(p, sizeMode: kontext.imageSize, refField: kontext.imageRef, count: 1)
        #expect(input["image_url"] as? String == "https://x/src.png")
        #expect(input["aspect_ratio"] as? String == "1:1")
    }

    @Test func editArrayEmitsImageUrlsAndNoSize() throws {
        let gemini = try #require(FalModelRegistry.model(for: "fal-ai/gemini-25-flash-image/edit"))
        let p = ImageGenerationParams(prompt: "edit", aspectRatio: "1:1", resolution: nil, quality: nil, imageURLs: ["a", "b"], numImages: 1)
        let input = FalInputBuilder.imageInput(p, sizeMode: gemini.imageSize, refField: gemini.imageRef, count: 1)
        #expect(input["image_urls"] as? [String] == ["a", "b"])
        #expect(input["image_size"] == nil)
        #expect(input["aspect_ratio"] == nil)
    }

    @Test func imageSizeEnumMapping() {
        #expect(FalInputBuilder.imageSizeEnum("1:1") == "square_hd")
        #expect(FalInputBuilder.imageSizeEnum("16:9") == "landscape_16_9")
        #expect(FalInputBuilder.imageSizeEnum("9:16") == "portrait_16_9")
        #expect(FalInputBuilder.imageSizeEnum("4:3") == "landscape_4_3")
        #expect(FalInputBuilder.imageSizeEnum("3:4") == "portrait_4_3")
    }
}

@Suite("FalInputBuilder — video")
struct FalVideoInputTests {
    @Test func klingPlainSecondsAndAspect() throws {
        let kling = try #require(FalModelRegistry.model(for: "fal-ai/kling-video/v2.5-turbo/pro/text-to-video"))
        let p = VideoGenerationParams(prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil)
        let input = FalInputBuilder.videoInput(p, model: kling)
        #expect(input["duration"] as? String == "5")
        #expect(input["aspect_ratio"] as? String == "16:9")
        #expect(input["resolution"] == nil)
        #expect(input["image_url"] == nil)
    }

    @Test func veoSecondsSuffixAndGenerateAudio() throws {
        let veo = try #require(FalModelRegistry.model(for: "fal-ai/veo3"))
        let p = VideoGenerationParams(prompt: "p", duration: 8, aspectRatio: "16:9", resolution: "1080p")
        let input = FalInputBuilder.videoInput(p, model: veo)
        #expect(input["duration"] as? String == "8s")
        #expect(input["generate_audio"] as? Bool == true)
        #expect(input["resolution"] as? String == "1080p")
    }

    @Test func seedanceSendsResolution() throws {
        let seedance = try #require(FalModelRegistry.model(for: "fal-ai/bytedance/seedance/v1/pro/text-to-video"))
        let p = VideoGenerationParams(prompt: "p", duration: 5, aspectRatio: "16:9", resolution: "720p")
        let input = FalInputBuilder.videoInput(p, model: seedance)
        #expect(input["resolution"] as? String == "720p")
    }

    @Test func imageToVideoEmitsImageUrlAndNoAspect() throws {
        let i2v = try #require(FalModelRegistry.model(for: "fal-ai/kling-video/v2.5-turbo/pro/image-to-video"))
        let p = VideoGenerationParams(prompt: "p", duration: 5, aspectRatio: "16:9", resolution: nil, referenceImageURLs: ["https://x/ref.png"])
        let input = FalInputBuilder.videoInput(p, model: i2v)
        #expect(input["image_url"] as? String == "https://x/ref.png")
        #expect(input["aspect_ratio"] == nil)
    }

    @Test func seedance2TextToVideoSendsResolutionAudioAspect() throws {
        let m = try #require(FalModelRegistry.model(for: "bytedance/seedance-2.0/text-to-video"))
        let p = VideoGenerationParams(prompt: "p", duration: 10, aspectRatio: "21:9", resolution: "720p")
        let input = FalInputBuilder.videoInput(p, model: m)
        #expect(input["duration"] as? String == "10")
        #expect(input["resolution"] as? String == "720p")
        #expect(input["aspect_ratio"] as? String == "21:9")
        #expect(input["generate_audio"] as? Bool == true)
        #expect(input["image_urls"] == nil)
    }

    @Test func seedance2ImageToVideoEmitsImageUrlAndAudio() throws {
        let m = try #require(FalModelRegistry.model(for: "bytedance/seedance-2.0/image-to-video"))
        let p = VideoGenerationParams(
            prompt: "p", duration: 5, aspectRatio: "16:9", resolution: "720p",
            referenceImageURLs: ["https://x/first.png"]
        )
        let input = FalInputBuilder.videoInput(p, model: m)
        #expect(input["image_url"] as? String == "https://x/first.png")
        #expect(input["aspect_ratio"] == nil)   // i2v: aspect follows the image
        #expect(input["resolution"] as? String == "720p")
        #expect(input["generate_audio"] as? Bool == true)
    }

    @Test func seedance2ReferenceToVideoEmitsRefArrays() throws {
        let m = try #require(FalModelRegistry.model(for: "bytedance/seedance-2.0/reference-to-video"))
        let p = VideoGenerationParams(
            prompt: "@Image1 dances", duration: 15, aspectRatio: "16:9", resolution: "720p",
            referenceImageURLs: ["https://x/a.png", "https://x/b.png"],
            referenceVideoURLs: ["https://x/m.mp4"],
            referenceAudioURLs: ["https://x/s.mp3"]
        )
        let input = FalInputBuilder.videoInput(p, model: m)
        #expect(input["image_urls"] as? [String] == ["https://x/a.png", "https://x/b.png"])
        #expect(input["video_urls"] as? [String] == ["https://x/m.mp4"])
        #expect(input["audio_urls"] as? [String] == ["https://x/s.mp3"])
        #expect(input["image_url"] == nil)   // arrays, not a single ref
        #expect(input["aspect_ratio"] as? String == "16:9")
        #expect(input["generate_audio"] as? Bool == true)
    }
}

@Suite("FalInputBuilder — audio / upscale")
struct FalAudioUpscaleInputTests {
    @Test func ttsEmitsTextAndVoice() throws {
        let tts = try #require(FalModelRegistry.model(for: "fal-ai/elevenlabs/tts/multilingual-v2"))
        let p = AudioGenerationParams(prompt: "hello", voice: "Aria", lyrics: nil, styleInstructions: nil, instrumental: false, durationSeconds: nil)
        let input = FalInputBuilder.audioInput(p, model: tts)
        #expect(input["text"] as? String == "hello")
        #expect(input["voice"] as? String == "Aria")
    }

    @Test func soundEffectEmitsTextOnly() throws {
        let sfx = try #require(FalModelRegistry.model(for: "fal-ai/elevenlabs/sound-effects"))
        let p = AudioGenerationParams(prompt: "thunder", voice: nil, lyrics: nil, styleInstructions: nil, instrumental: false, durationSeconds: nil)
        let input = FalInputBuilder.audioInput(p, model: sfx)
        #expect(input["text"] as? String == "thunder")
        #expect(input["voice"] == nil)
    }

    @Test func musicEmitsPromptAndSecondsTotal() throws {
        let music = try #require(FalModelRegistry.model(for: "fal-ai/stable-audio"))
        let p = AudioGenerationParams(prompt: "lofi", voice: nil, lyrics: nil, styleInstructions: nil, instrumental: true, durationSeconds: 30)
        let input = FalInputBuilder.audioInput(p, model: music)
        #expect(input["prompt"] as? String == "lofi")
        #expect(input["seconds_total"] as? Int == 30)
    }

    @Test func upscaleImageVsVideoSourceField() throws {
        let clarity = try #require(FalModelRegistry.model(for: "fal-ai/clarity-upscaler"))
        let topaz = try #require(FalModelRegistry.model(for: "fal-ai/topaz/upscale/video"))
        let up = UpscaleGenerationParams(sourceURL: "https://x/in.media", durationSeconds: 1)
        #expect(FalInputBuilder.upscaleInput(up, model: clarity)["image_url"] as? String == "https://x/in.media")
        #expect(FalInputBuilder.upscaleInput(up, model: topaz)["video_url"] as? String == "https://x/in.media")
    }
}

@Suite("FalOutput — result parsing")
struct FalOutputTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func imagesArray() {
        #expect(FalOutput.urls(from: data(#"{"images":[{"url":"u1"},{"url":"u2"}]}"#), shape: .images) == ["u1", "u2"])
    }

    @Test func videoNestedObject() {
        #expect(FalOutput.urls(from: data(#"{"video":{"url":"v"}}"#), shape: .video) == ["v"])
        // Guard against the flat `video_url` shape ever being assumed.
        #expect(FalOutput.urls(from: data(#"{"video_url":"v"}"#), shape: .video) == [])
    }

    @Test func audioElevenLabsVsMusicKey() {
        #expect(FalOutput.urls(from: data(#"{"audio":{"url":"a"}}"#), shape: .audio) == ["a"])
        #expect(FalOutput.urls(from: data(#"{"audio_file":{"url":"a"}}"#), shape: .audio) == ["a"])
    }

    @Test func upscaledImageSingleObject() {
        #expect(FalOutput.urls(from: data(#"{"image":{"url":"i"}}"#), shape: .upscaledImage) == ["i"])
    }
}

@Suite("FalModelRegistry — dialect wiring")
struct FalRegistryTests {
    @Test func catalogHasAllModalities() {
        let kinds = Set(FalModelRegistry.models.map { $0.entry.kind })
        #expect(kinds.contains(.image))
        #expect(kinds.contains(.video))
        #expect(kinds.contains(.audio))
        #expect(kinds.contains(.upscale))
        #expect(FalModelRegistry.entries.count == FalModelRegistry.models.count)
    }

    @Test func sizeDialectsAssignedCorrectly() throws {
        #expect(try #require(FalModelRegistry.model(for: "fal-ai/flux/dev")).imageSize == .imageSizeEnum)
        #expect(try #require(FalModelRegistry.model(for: "fal-ai/flux-pro/v1.1-ultra")).imageSize == .aspectRatio)
        #expect(try #require(FalModelRegistry.model(for: "fal-ai/imagen4")).imageSize == .aspectRatio)
    }

    @Test func imageToVideoModelsCarryRefDialect() throws {
        #expect(try #require(FalModelRegistry.model(for: "fal-ai/kling-video/v2.5-turbo/pro/image-to-video")).videoImageRef == true)
        #expect(try #require(FalModelRegistry.model(for: "fal-ai/kling-video/v2.5-turbo/pro/text-to-video")).videoImageRef == false)
    }

    @Test func seedance2FamilyPresentWithCorrectCaps() throws {
        let t2v = try #require(FalModelRegistry.model(for: "bytedance/seedance-2.0/text-to-video"))
        #expect(t2v.videoGeneratesAudio == true)
        #expect(t2v.videoSendsResolution == true)
        guard case .video(let t2vCaps) = t2v.entry.uiCapabilities else { return #expect(Bool(false)) }
        #expect(t2vCaps.resolutions == ["480p", "720p"])

        let ref = try #require(FalModelRegistry.model(for: "bytedance/seedance-2.0/reference-to-video"))
        #expect(ref.videoReferenceArrays == true)
        #expect(ref.videoImageRef == false)
        guard case .video(let refCaps) = ref.entry.uiCapabilities else { return #expect(Bool(false)) }
        #expect(refCaps.maxReferenceImages == 9)
        #expect(refCaps.maxReferenceVideos == 3)
        #expect(refCaps.maxReferenceAudios == 3)
        #expect(refCaps.maxTotalReferences == 12)
    }
}
