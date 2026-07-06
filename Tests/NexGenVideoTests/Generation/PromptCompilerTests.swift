import Foundation
import Testing

@testable import NexGenVideo

@Suite("PromptCompiler — gate")
@MainActor
struct PromptCompilerTests {

    // MARK: Compile → token (composition now runs the engine; see PromptComposerTests for detail)

    @Test func compileMintsAValidTokenOverTheComposedPrompt() throws {
        let compiled = try PromptCompiler.compile(
            intent: "an elephant on a beach", modelId: "fal-ai/veo3", modality: .video, editor: nil)
        // Composition is the engine's job; the gate's job is that the returned token validates the
        // returned text for the model. The composed text is longer than the raw intent.
        #expect(!compiled.text.isEmpty)
        #expect(PromptCompiler.validate(token: compiled.token, text: compiled.text, modelId: "fal-ai/veo3"))
    }

    @Test func emptyIntentThrows() {
        #expect(throws: (any Error).self) {
            _ = try PromptCompiler.compile(
                intent: "   \n ", modelId: "fal-ai/veo3", modality: .video, editor: nil)
        }
    }

    @Test func runwayLengthCapIsEnforced() {
        // A very long intent composes past Runway's 1000-char cap → compile throws.
        let long = String(repeating: "a very long lit description of a lantern-lit hall ", count: 40)
        #expect(throws: (any Error).self) {
            _ = try PromptCompiler.compile(
                intent: long, modelId: "runway/gen4.5", modality: .video, editor: nil)
        }
    }

    @Test func tokenIsBoundToModelAndText() throws {
        let compiled = try PromptCompiler.compile(
            intent: "a red car on a wet street at night", modelId: "fal-ai/veo3", modality: .video, editor: nil)
        // Different model → invalid; different text → invalid.
        #expect(!PromptCompiler.validate(token: compiled.token, text: compiled.text, modelId: "runway/gen4.5"))
        #expect(!PromptCompiler.validate(token: compiled.token, text: compiled.text + "!", modelId: "fal-ai/veo3"))
    }

    // MARK: Gate — token mint / validate / enforce (unchanged by the #114 refactor)

    @Test func gateRejectsUncompiledAndFabricatedTokens() throws {
        // No token at all.
        #expect(throws: ToolError.self) {
            try PromptCompiler.enforceGate(args: ["prompt": "raw"], prompt: "raw", modelId: "fal-ai/veo3")
        }
        // Fabricated token.
        #expect(throws: ToolError.self) {
            try PromptCompiler.enforceGate(
                args: ["compileToken": "deadbeefdeadbeef"], prompt: "raw", modelId: "fal-ai/veo3")
        }
        // A genuine compile passes the gate for its own text.
        let compiled = try PromptCompiler.compile(
            intent: "a red car on a wet street at night", modelId: "fal-ai/veo3", modality: .video, editor: nil)
        try PromptCompiler.enforceGate(
            args: ["compileToken": compiled.token], prompt: compiled.text, modelId: "fal-ai/veo3")
    }

    @Test func rawPromptRequiresProSetting() {
        let key = PromptCompiler.rawPromptsDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set(false, forKey: key)
        #expect(throws: ToolError.self) {
            try PromptCompiler.enforceGate(args: ["rawPrompt": true], prompt: "raw", modelId: "fal-ai/veo3")
        }

        UserDefaults.standard.set(true, forKey: key)
        #expect(throws: Never.self) {
            try PromptCompiler.enforceGate(args: ["rawPrompt": true], prompt: "raw", modelId: "fal-ai/veo3")
        }
    }
}
