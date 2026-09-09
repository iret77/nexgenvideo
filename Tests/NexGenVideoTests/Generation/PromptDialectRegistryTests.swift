import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Prompt dialect registry")
struct PromptDialectRegistryTests {
    @Test("known model families resolve explicitly")
    func knownFamilies() throws {
        #expect(try dialect("bytedance/seedance-2.5/reference-to-video").id == "seedance-2.5")
        #expect(try dialect("fal-ai/kling-video/v2.5-turbo/pro/text-to-video").id == "kling")
        #expect(try dialect("fal-ai/veo3").id == "veo")
        #expect(try dialect("runway/gen4.5").id == "runway-video")
        #expect(try dialect("higgsfield/minimax-h3").id == "minimax-h3")
        #expect(try dialect("higgsfield/grok-imagine-video").id == "grok-imagine")
    }

    @Test("unknown and merely similar model variants fail closed")
    func unsupportedFamilies() {
        #expect(throws: PromptDialectRegistryError.self) {
            try dialect("unverified/video-model")
        }
        #expect(throws: PromptDialectRegistryError.self) {
            try dialect("fal-ai/minimax/hailuo-02/standard/text-to-video")
        }
    }

    private func dialect(_ modelID: String) throws -> VideoPromptDialectV1 {
        try PromptDialectRegistry.requireVideoDialect(
            modelID: modelID,
            modeID: "text-to-video"
        )
    }
}
