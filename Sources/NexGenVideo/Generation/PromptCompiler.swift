import CryptoKit
import Foundation

/// The mandatory prompt GATE (Epic #98 / issue #100): every prompt bound for a content model passes
/// through here. User chat input — and the agent's own phrasing — is *intent*, never a raw model
/// prompt; NGV's value is that several cheap LLM turns prepare the input before one expensive content
/// render.
///
/// Composition (translate → merge locked ledger directives → build the provider prompt → lint) now
/// lives in `PromptComposer` (the engine path, concept §5). This file is only the gate: mint a
/// process-stable token over a compiled prompt, validate it, and enforce that generate_* callers
/// carry one (or the pro raw-prompt escape). Raw sends exist only behind the pro toggle.
struct CompiledPrompt: Sendable {
    let text: String
    let token: String
    let notes: [String]
}

enum PromptCompiler {
    /// Settings → Providers "Raw prompts (pro)". Off by default — the gate is the default path.
    static let rawPromptsDefaultsKey = "allowRawPrompts"

    static var rawPromptsAllowed: Bool {
        UserDefaults.standard.bool(forKey: rawPromptsDefaultsKey)
    }

    /// Process-stable salt: a compileToken can only come from compile_prompt in this app run —
    /// the agent cannot fabricate one to sneak an uncompiled prompt past the gate.
    private static let salt = UUID().uuidString

    /// Per-model prompt length caps. Runway's promptText is hard-capped at 1000 chars (verified
    /// against their SDK); other providers get a generous but finite bound.
    static func lengthCap(modelId: String) -> Int {
        modelId.hasPrefix("runway/") ? 1000 : 2500
    }

    /// Compile intent → model-ready prompt via the engine composer, then mint the gate token over the
    /// result. The `compile_prompt` tool contract is unchanged: intent must already be English and
    /// contradiction-free (the agent's part), composition + lint is the engine's part, the token is
    /// the gate's. `modality` selects the engine builder; callers that only know a model id resolve it
    /// via `modalityForModel`.
    @MainActor
    static func compile(
        intent: String,
        modelId: String,
        modality: PromptComposer.Modality,
        aspectRatio: String = "",
        durationSeconds: Double? = nil,
        editor: EditorViewModel?
    ) async throws -> CompiledPrompt {
        let composed = try await PromptComposer.compose(
            intent: intent,
            modality: modality,
            modelId: modelId,
            aspectRatio: aspectRatio,
            durationSeconds: durationSeconds,
            projectDir: editor?.workingRoot
        )
        return CompiledPrompt(
            text: composed.text,
            token: token(for: composed.text, modelId: modelId),
            notes: composed.notes)
    }

    /// Resolve a model id to its composition modality (the `compile_prompt` tool only receives a model
    /// id). Video/image use the engine builders; everything audio-shaped composes as merged text.
    @MainActor
    static func modalityForModel(_ modelId: String) -> PromptComposer.Modality {
        if VideoModelConfig.allModels.contains(where: { $0.id == modelId }) { return .video }
        if ImageModelConfig.allModels.contains(where: { $0.id == modelId }) { return .image }
        if AudioModelConfig.allModels.contains(where: { $0.id == modelId }) { return .audio }
        return .video
    }

    static func token(for text: String, modelId: String) -> String {
        let digest = SHA256.hash(data: Data("\(salt)|\(modelId)|\(text)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(token: String, text: String, modelId: String) -> Bool {
        token == self.token(for: text, modelId: modelId)
    }

    /// The gate itself, shared by every generate tool. `rawPrompt: true` is honored only when the
    /// pro toggle is on; otherwise the prompt must carry a valid compileToken for this model.
    static func enforceGate(args: [String: Any], prompt: String, modelId: String) throws {
        if args.bool("rawPrompt") == true {
            guard rawPromptsAllowed else {
                throw ToolError(
                    "Raw prompts are disabled. Compile via compile_prompt(intent, model) and pass "
                    + "compiledPrompt + compileToken — or the user can enable \u{201C}Raw prompts (pro)\u{201D} "
                    + "in Settings \u{2192} Providers.")
            }
            return
        }
        guard let token = args.string("compileToken"), validate(token: token, text: prompt, modelId: modelId) else {
            throw ToolError(
                "Uncompiled prompt. NGV never sends raw prompts to content models: call "
                + "compile_prompt(intent, model) first and pass its compiledPrompt and compileToken "
                + "here unchanged. If essential details are missing, ask the user BEFORE generating.")
        }
    }
}
