import Testing
import Foundation

@testable import NexGenVideo

@Suite("run_provider_tool — capability tool-calls, both gates held (M4)")
struct ProviderToolTests {

    @Test func generationVerbsAreRefused() {
        // Must go through the gated generate_* / upscale paths, not the generic tool passthrough.
        for name in ["generate_video", "text_to_speech", "img2img", "t2v", "video_upscale",
                     "outpaint_image", "inpaint", "dream_shaper", "elevenlabs_tts"] {
            #expect(ToolExecutor.looksLikeGeneration(name), "\(name) should be refused")
        }
    }

    @Test func workflowToolsPass() {
        for name in ["reframe", "remove_background", "roto", "reference_upload",
                     "lookup_character", "get_project", "extend_clip"] {
            #expect(ToolExecutor.looksLikeGeneration(name) == false, "\(name) should pass")
        }
    }

    @Test func argumentsCoerceToStrings() {
        let out = ToolExecutor.stringArguments([
            "image_url": "https://x/y.png",
            "count": 3,
            "ratio": 1.5,
            "hd": true,
            "opts": ["a": 1],
        ])
        #expect(out["image_url"] == "https://x/y.png")
        #expect(out["count"] == "3")
        #expect(out["ratio"] == "1.5")
        #expect(out["hd"] == "true")
        #expect(out["opts"]?.contains("\"a\"") == true)  // nested object JSON-encoded, not dropped
    }

    @Test func nonObjectArgumentsAreEmpty() {
        #expect(ToolExecutor.stringArguments(nil).isEmpty)
        #expect(ToolExecutor.stringArguments("nope").isEmpty)
    }
}
