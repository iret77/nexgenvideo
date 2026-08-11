import CryptoKit
import Foundation
import NexGenEngine

struct PromptBinding: Sendable, Equatable {
    let projectKey: String
    let shotId: String
    let shotFingerprint: String

    static let free = PromptBinding(
        projectKey: "none",
        shotId: "none",
        shotFingerprint: "none"
    )
}

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
    let binding: PromptBinding
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
    /// result. Free and still intent must already be English; a planned video replaces caller action
    /// with the current production plan before linting. `modality` selects the engine builder; callers
    /// that only know a model id resolve it via `modalityForModel`.
    @MainActor
    static func compile(
        intent: String,
        modelId: String,
        modality: PromptComposer.Modality,
        aspectRatio: String = "",
        durationSeconds: Double? = nil,
        editor: EditorViewModel?,
        setting: String = "",
        lighting: String = "",
        style: String = "",
        shotId: String = "none",
        shot: PromptComposer.ShotProjection? = nil
    ) async throws -> CompiledPrompt {
        guard shotId == "none" || shot != nil else {
            throw ToolError(
                "Shot-bound compilation requires the current shot projection."
            )
        }
        if shotId != "none", case .image = modality, let shot {
            try validateImageShotSourceContract(sourceMode: shot.sourceMode)
        }
        let binding = try currentBinding(editor: editor, shotId: shotId)
        let composed = try await PromptComposer.compose(
            intent: intent,
            modality: modality,
            modelId: modelId,
            aspectRatio: aspectRatio,
            durationSeconds: durationSeconds,
            projectDir: editor?.workingRoot,
            setting: setting,
            lighting: lighting,
            style: style,
            shot: shot,
            preserveComposition: preservesComposition(modelId: modelId)
        )
        return CompiledPrompt(
            text: composed.text,
            token: token(
                for: composed.text,
                modelId: modelId,
                binding: binding
            ),
            notes: composed.notes,
            binding: binding)
    }

    /// #223 — a video model that consumes a SOURCE VIDEO is a composition-preserving pass (restyle):
    /// it re-renders footage that already exists, so the prompt must invent nothing. Derived from the
    /// model rather than asked for as a tool argument — the gate then applies itself, and there is no
    /// new knob for the agent to forget or misuse.
    @MainActor
    static func preservesComposition(modelId: String) -> Bool {
        VideoModelConfig.allModels.first { $0.id == modelId }?.requiresSourceVideo == true
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

    static func token(
        for text: String,
        modelId: String,
        binding: PromptBinding = .free
    ) -> String {
        let material = "\(salt)|\(binding.projectKey)|\(binding.shotId)|"
            + "\(binding.shotFingerprint)|\(modelId)|\(text)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func validateImageShotSourceContract(
        sourceMode: SourceMode
    ) throws {
        guard sourceMode == .generated else {
            throw ToolError(
                "Only generated shots can use shot-bound image generation. "
                    + "Imported and AI-enhanced shots never enter Frames."
            )
        }
    }

    static func validate(
        token: String,
        text: String,
        modelId: String,
        binding: PromptBinding = .free
    ) -> Bool {
        token == self.token(
            for: text,
            modelId: modelId,
            binding: binding
        )
    }

    @MainActor
    static func currentBinding(
        editor: EditorViewModel?,
        shotId: String
    ) throws -> PromptBinding {
        let root = editor?.workingRoot.flatMap {
            DataRootResolver.dataRoot(of: $0)
        }
        let projectKey = editor?.projectId ?? root?.standardizedFileURL
            .resolvingSymlinksInPath().path ?? "none"
        guard shotId != "none" else {
            return PromptBinding(
                projectKey: projectKey,
                shotId: "none",
                shotFingerprint: "none"
            )
        }
        guard let root,
              let shotlist = (try? loadShotlist(dataRoot: root)) ?? nil,
              let shot = shotlist.shots.first(where: { $0.id == shotId }) else {
            throw ToolError(
                "No current shot '\(shotId)' is available for prompt binding."
            )
        }
        return PromptBinding(
            projectKey: projectKey,
            shotId: shotId,
            shotFingerprint: try shotFingerprint(shot)
        )
    }

    static func shotFingerprint(_ shot: Shot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(shot)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The gate itself, shared by every generate tool. `rawPrompt: true` is honored only when the
    /// pro toggle is on; otherwise the prompt must carry a valid compileToken for this model.
    @MainActor
    static func enforceGate(
        args: [String: Any],
        prompt: String,
        modelId: String,
        editor: EditorViewModel? = nil
    ) throws {
        let shotId = args.string("shotId") ?? "none"
        if args.bool("rawPrompt") == true {
            guard rawPromptsAllowed else {
                throw ToolError(
                    "Raw prompts are disabled. Compile via compile_prompt(intent, model) and pass "
                    + "compiledPrompt + compileToken — or the user can enable \u{201C}Raw prompts (pro)\u{201D} "
                    + "in Settings \u{2192} Providers.")
            }
            guard shotId == "none" else {
                throw ToolError(
                    "Raw prompts cannot render a pipeline shot. Compile the current shot first."
                )
            }
            return
        }
        let binding = try currentBinding(editor: editor, shotId: shotId)
        guard let token = args.string("compileToken"), validate(
            token: token,
            text: prompt,
            modelId: modelId,
            binding: binding
        ) else {
            throw ToolError(
                "Uncompiled prompt. NGV never sends raw prompts to content models: call "
                + "compile_prompt(intent, model, shotId) first and pass its compiledPrompt, "
                + "compileToken, and shotId "
                + "here unchanged. If essential details are missing, ask the user BEFORE generating.")
        }
    }
}
