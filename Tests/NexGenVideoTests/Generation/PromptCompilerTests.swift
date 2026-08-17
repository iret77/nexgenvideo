import Foundation
import Testing
import NexGenEngine

@testable import NexGenVideo

@Suite("PromptCompiler — gate")
@MainActor
struct PromptCompilerTests {

    // MARK: Compile → token (composition now runs the engine; see PromptComposerTests for detail)

    @Test func compileMintsAValidTokenOverTheComposedPrompt() async throws {
        let compiled = try await PromptCompiler.compile(
            intent: "an elephant on a beach", modelId: "fal-ai/veo3", modality: .video, editor: nil)
        // Composition is the engine's job; the gate's job is that the returned token validates the
        // returned text for the model. The composed text is longer than the raw intent.
        #expect(!compiled.text.isEmpty)
        #expect(PromptCompiler.validate(token: compiled.token, text: compiled.text, modelId: "fal-ai/veo3"))
    }

    @Test func emptyIntentThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await PromptCompiler.compile(
                intent: "   \n ", modelId: "fal-ai/veo3", modality: .video, editor: nil)
        }
    }

    @Test func runwayLengthCapIsEnforced() async {
        // A very long intent composes past Runway's 1000-char cap → compile throws.
        let long = String(repeating: "a very long lit description of a lantern-lit hall ", count: 40)
        await #expect(throws: (any Error).self) {
            _ = try await PromptCompiler.compile(
                intent: long, modelId: "runway/gen4.5", modality: .video, editor: nil)
        }
    }

    @Test func tokenIsBoundToModelAndText() async throws {
        let compiled = try await PromptCompiler.compile(
            intent: "a red car on a wet street at night", modelId: "fal-ai/veo3", modality: .video, editor: nil)
        // Different model → invalid; different text → invalid.
        #expect(!PromptCompiler.validate(token: compiled.token, text: compiled.text, modelId: "runway/gen4.5"))
        #expect(!PromptCompiler.validate(token: compiled.token, text: compiled.text + "!", modelId: "fal-ai/veo3"))
    }

    @Test func rememberedIntentCanBeRecompiledForAUserSelectedModel() async throws {
        let original = try await PromptCompiler.compile(
            intent: "a weathered grey mouse sheriff standing alone in a sun-baked desert town at golden hour",
            modelId: "fal-ai/flux-pro",
            modality: .image,
            editor: nil
        )
        let adapted = try await PromptCompiler.recompile(
            token: original.token,
            text: original.text,
            for: "google/gemini-3-pro-image",
            editor: nil
        )

        #expect(PromptCompiler.validate(
            token: adapted.token,
            text: adapted.text,
            modelId: "google/gemini-3-pro-image"
        ))
        #expect(!PromptCompiler.validate(
            token: original.token,
            text: original.text,
            modelId: "google/gemini-3-pro-image"
        ))
    }

    @Test func tokenIsBoundToProjectShotAndPlanFingerprint() {
        let first = PromptBinding(
            projectKey: "/project-a/pipeline",
            shotId: "s001",
            shotFingerprint: "plan-a"
        )
        let token = PromptCompiler.token(
            for: "compiled",
            modelId: "fal-ai/veo3",
            binding: first
        )
        #expect(PromptCompiler.validate(
            token: token,
            text: "compiled",
            modelId: "fal-ai/veo3",
            binding: first
        ))
        for changed in [
            PromptBinding(
                projectKey: "/project-b/pipeline",
                shotId: "s001",
                shotFingerprint: "plan-a"
            ),
            PromptBinding(
                projectKey: "/project-a/pipeline",
                shotId: "s002",
                shotFingerprint: "plan-a"
            ),
            PromptBinding(
                projectKey: "/project-a/pipeline",
                shotId: "s001",
                shotFingerprint: "plan-b"
            ),
        ] {
            #expect(!PromptCompiler.validate(
                token: token,
                text: "compiled",
                modelId: "fal-ai/veo3",
                binding: changed
            ))
        }
    }

    @Test func shotBoundImageCompilationRejectsNonGeneratedSourcesBeforeBinding() async throws {
        var shot = try Shot(
            id: "s001",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .performance,
            description: "Performance",
            visualPrompt: "A performer holds a measured opening pose.",
            mood: "focused"
        )
        for sourceMode in [SourceMode.imported, .aiEnhanced] {
            shot.sourceMode = sourceMode
            let projection = PromptComposer.ShotProjection(shot)
            await #expect(throws: ToolError.self) {
                _ = try await PromptCompiler.compile(
                    intent: "A performer holds a measured opening pose.",
                    modelId: "openai/gpt-image-2",
                    modality: .image,
                    editor: nil,
                    shotId: "s001",
                    shot: projection
                )
            }
        }
        #expect(throws: Never.self) {
            try PromptCompiler.validateImageShotSourceContract(
                sourceMode: .generated
            )
        }
    }

    // MARK: Gate — token mint / validate / enforce (unchanged by the #114 refactor)

    @Test func gateRejectsUncompiledAndFabricatedTokens() async throws {
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
        let compiled = try await PromptCompiler.compile(
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
        #expect(throws: ToolError.self) {
            try PromptCompiler.enforceGate(
                args: ["rawPrompt": true, "shotId": "s001"],
                prompt: "raw",
                modelId: "fal-ai/veo3"
            )
        }
    }
}
