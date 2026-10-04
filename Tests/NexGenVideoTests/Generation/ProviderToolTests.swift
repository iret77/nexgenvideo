import Testing
import Foundation
import MCP

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

    @Test func refusalsNameOnlyPathsThatPerformTheOperation() {
        let inpaint = ToolExecutor.generationRefusal(for: "inpaint")
        #expect(inpaint.contains("generate_image"))
        #expect(inpaint.contains("supportsMask=true"))
        #expect(inpaint.contains("maskMediaRef"))
        #expect(inpaint.contains("Video inpainting has no gated NexGenVideo path"))
        #expect(!inpaint.contains("generate_video"))
        #expect(!inpaint.contains("upscale_media"))

        let outpaint = ToolExecutor.generationRefusal(for: "outpaint_image")
        #expect(outpaint.contains("Outpainting has no gated NexGenVideo path"))
        #expect(!outpaint.contains("generate_"))
        #expect(!outpaint.contains("upscale_media"))

        let upscale = ToolExecutor.generationRefusal(for: "video_upscale")
        #expect(upscale.contains("upscale_media"))
        #expect(!upscale.contains("generate_"))

        let generation = ToolExecutor.generationRefusal(for: "text_to_speech")
        #expect(generation.contains("generate_audio"))
        #expect(!generation.contains("upscale_media"))
    }

    @Test func workflowToolsPass() {
        for name in ["reframe", "remove_background", "roto", "reference_upload",
                     "lookup_character", "get_project", "extend_clip"] {
            #expect(ToolExecutor.looksLikeGeneration(name) == false, "\(name) should pass")
        }
    }

    @Test func argumentsPreserveMCPTypes() {
        let out = ToolExecutor.mcpArguments([
            "image_url": "https://x/y.png",
            "count": 3,
            "ratio": 1.5,
            "hd": true,
            "params": ["model": "x", "count": 1],
        ])
        #expect(out["image_url"] == .string("https://x/y.png"))
        #expect(out["count"] == .int(3))
        #expect(out["ratio"] == .double(1.5))
        #expect(out["hd"] == .bool(true))
        guard case .object(let params)? = out["params"] else {
            Issue.record("Expected nested params object")
            return
        }
        #expect(params["model"] == .string("x"))
        #expect(params["count"] == .int(1))
    }

    @Test func nonObjectArgumentsAreEmpty() {
        #expect(ToolExecutor.mcpArguments(nil).isEmpty)
        #expect(ToolExecutor.mcpArguments("nope").isEmpty)
    }

    // Prompt-engine gate: a tool whose schema exposes a creative prompt is generation (refused here);
    // a prompt-free workflow tool passes. Shapes mirror the real Higgsfield MCP (nested under params).
    @Test func advertisesPromptDetectsNestedPromptField() throws {
        let generation = #"{"type":"object","properties":{"params":{"type":"object","properties":{"model":{"type":"string"},"prompt":{"type":"string"}}}}}"#
        let workflow = #"{"type":"object","properties":{"params":{"type":"object","properties":{"aspect_ratio":{"type":"string"},"media_id":{"type":"string"}}}}}"#
        let gen = try JSONDecoder().decode(Value.self, from: Data(generation.utf8))
        let wf = try JSONDecoder().decode(Value.self, from: Data(workflow.utf8))
        #expect(ToolExecutor.advertisesPrompt(gen))
        #expect(ToolExecutor.advertisesPrompt(wf) == false)
    }

    @Test func argumentsCarryingAPromptAreRefused() {
        #expect(ToolExecutor.argumentsCarryPrompt(["prompt": "a neon city"]))
        #expect(ToolExecutor.argumentsCarryPrompt(["lyrics": "la la la"]))
        #expect(ToolExecutor.argumentsCarryPrompt(["aspect_ratio": "16:9", "media_id": "abc"]) == false)
        // Nested and stringified-JSON prompts must not slip past.
        #expect(ToolExecutor.argumentsCarryPrompt(["params": ["prompt": "x"]]))
        #expect(ToolExecutor.argumentsCarryPrompt(["params": #"{"prompt":"x"}"#]))
        #expect(ToolExecutor.argumentsCarryPrompt(nil) == false)
    }
}
