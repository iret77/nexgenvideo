import CryptoKit
import Foundation
import NexGenEngine

struct PromptBinding: Codable, Sendable, Equatable {
    let projectKey: String
    let shotId: String
    let shotFingerprint: String
    let routeArtifactSHA256: String
    let requirementSHA256: String
    let capabilitiesSHA256: String
    let routeSHA256: String
    let referencePlanSHA256: String
    let orderedBindingsSHA256: String
    let styleFingerprint: String
    let compilerInputsSHA256: String?
    let promptDialectID: String
    let promptDialectVersion: Int
    let frameReferencePlanSHA256: String
    let promptIRSHA256: String

    private enum CodingKeys: String, CodingKey {
        case projectKey, shotId, shotFingerprint, routeArtifactSHA256
        case requirementSHA256, capabilitiesSHA256, routeSHA256
        case referencePlanSHA256, orderedBindingsSHA256, styleFingerprint
        case compilerInputsSHA256, promptDialectID, promptDialectVersion
        case frameReferencePlanSHA256
        case promptIRSHA256
    }

    init(
        projectKey: String,
        shotId: String,
        shotFingerprint: String,
        routeArtifactSHA256: String = "none",
        requirementSHA256: String = "none",
        capabilitiesSHA256: String = "none",
        routeSHA256: String = "none",
        referencePlanSHA256: String = "none",
        orderedBindingsSHA256: String = "none",
        styleFingerprint: String = "none",
        compilerInputsSHA256: String? = "none",
        promptDialectID: String = "none",
        promptDialectVersion: Int = 0,
        frameReferencePlanSHA256: String = "none",
        promptIRSHA256: String = "none"
    ) {
        self.projectKey = projectKey
        self.shotId = shotId
        self.shotFingerprint = shotFingerprint
        self.routeArtifactSHA256 = routeArtifactSHA256
        self.requirementSHA256 = requirementSHA256
        self.capabilitiesSHA256 = capabilitiesSHA256
        self.routeSHA256 = routeSHA256
        self.referencePlanSHA256 = referencePlanSHA256
        self.orderedBindingsSHA256 = orderedBindingsSHA256
        self.styleFingerprint = styleFingerprint
        self.compilerInputsSHA256 = compilerInputsSHA256
        self.promptDialectID = promptDialectID
        self.promptDialectVersion = promptDialectVersion
        self.frameReferencePlanSHA256 = frameReferencePlanSHA256
        self.promptIRSHA256 = promptIRSHA256
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            projectKey: try values.decode(String.self, forKey: .projectKey),
            shotId: try values.decode(String.self, forKey: .shotId),
            shotFingerprint: try values.decode(String.self, forKey: .shotFingerprint),
            routeArtifactSHA256: try values.decodeIfPresent(String.self, forKey: .routeArtifactSHA256) ?? "none",
            requirementSHA256: try values.decodeIfPresent(String.self, forKey: .requirementSHA256) ?? "none",
            capabilitiesSHA256: try values.decodeIfPresent(String.self, forKey: .capabilitiesSHA256) ?? "none",
            routeSHA256: try values.decodeIfPresent(String.self, forKey: .routeSHA256) ?? "none",
            referencePlanSHA256: try values.decodeIfPresent(String.self, forKey: .referencePlanSHA256) ?? "none",
            orderedBindingsSHA256: try values.decodeIfPresent(String.self, forKey: .orderedBindingsSHA256) ?? "none",
            styleFingerprint: try values.decodeIfPresent(String.self, forKey: .styleFingerprint) ?? "none",
            compilerInputsSHA256: try values.decodeIfPresent(String.self, forKey: .compilerInputsSHA256) ?? "none",
            promptDialectID: try values.decodeIfPresent(String.self, forKey: .promptDialectID) ?? "none",
            promptDialectVersion: try values.decodeIfPresent(Int.self, forKey: .promptDialectVersion) ?? 0,
            frameReferencePlanSHA256: try values.decodeIfPresent(
                String.self,
                forKey: .frameReferencePlanSHA256
            ) ?? "none",
            promptIRSHA256: try values.decodeIfPresent(
                String.self,
                forKey: .promptIRSHA256
            ) ?? "none"
        )
    }

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
    private struct CompileRecipe: Sendable {
        let intent: String
        let modelId: String
        let modality: PromptComposer.Modality
        let aspectRatio: String
        let durationSeconds: Double?
        let setting: String
        let lighting: String
        let style: String
        let preserveComposition: Bool
        let binding: PromptBinding
    }

    /// Settings → Providers "Raw prompts (pro)". Off by default — the gate is the default path.
    static let rawPromptsDefaultsKey = "allowRawPrompts"

    static var rawPromptsAllowed: Bool {
        UserDefaults.standard.bool(forKey: rawPromptsDefaultsKey)
    }

    /// Process-stable salt: a compileToken can only come from compile_prompt in this app run —
    /// the agent cannot fabricate one to sneak an uncompiled prompt past the gate.
    private static let salt = UUID().uuidString
    @MainActor private static var recipesByToken: [String: CompileRecipe] = [:]
    @MainActor private static var recipeOrder: [String] = []
    private static let maxRememberedRecipes = 128

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
        shot: PromptComposer.ShotProjection? = nil,
        preserveCompositionOverride: Bool? = nil
    ) async throws -> CompiledPrompt {
        guard shotId == "none" || shot != nil else {
            throw ToolError(
                "Shot-bound compilation requires the current shot projection."
            )
        }
        if shotId != "none", case .image = modality, let shot {
            try validateImageShotSourceContract(sourceMode: shot.sourceMode)
        }
        let binding = try await currentBinding(
            editor: editor,
            shotId: shotId,
            modality: modality,
            modelId: modelId
        )
        let videoContext: PromptComposer.VideoContext?
        let imageContext: PromptComposer.ImageContext?
        if case .video = modality {
            videoContext = try currentVideoContext(
                editor: editor,
                shotId: shotId,
                modelId: modelId,
                shot: shot,
                expectedBinding: binding
            )
        } else {
            videoContext = nil
        }
        if case .image = modality,
           let plan = try currentFrameReferencePlan(
               editor: editor,
               shotId: shotId,
               modelId: modelId
           ) {
            guard plan.fingerprint == binding.frameReferencePlanSHA256 else {
                throw ToolError(
                    "The frame reference plan changed during prompt compilation. Compile the current shot again."
                )
            }
            imageContext = PromptComposer.ImageContext(
                references: plan.bindings
            )
        } else {
            imageContext = nil
        }
        let preserveComposition = preserveCompositionOverride
            ?? preservesComposition(modelId: modelId)
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
            preserveComposition: preserveComposition,
            videoContext: videoContext,
            imageContext: imageContext
        )
        guard try await currentBinding(
            editor: editor,
            shotId: shotId,
            modality: modality,
            modelId: modelId
        ) == binding else {
            throw ToolError(
                "The project direction changed during prompt compilation. Compile the current shot again."
            )
        }
        let compiledBinding = binding.withPromptIRSHA256(
            composed.sourceIRSHA256 ?? "none"
        )
        let compiled = CompiledPrompt(
            text: composed.text,
            token: token(
                for: composed.text,
                modelId: modelId,
                binding: compiledBinding
            ),
            notes: composed.notes,
            binding: compiledBinding)
        remember(
            compiled,
            recipe: CompileRecipe(
                intent: intent,
                modelId: modelId,
                modality: modality,
                aspectRatio: aspectRatio,
                durationSeconds: durationSeconds,
                setting: setting,
                lighting: lighting,
                style: style,
                preserveComposition: preserveComposition,
                binding: compiledBinding
            )
        )
        return compiled
    }

    /// Recompile remembered gated intent for a user-selected model without accepting arbitrary text.
    @MainActor
    static func recompile(
        token: String,
        text: String,
        for modelId: String,
        editor: EditorViewModel?,
        allowCurrentRoutingChange: Bool = false,
        preserveCompositionOverride: Bool? = nil
    ) async throws -> CompiledPrompt {
        guard let recipe = recipesByToken[token],
              validate(
                token: token,
                text: text,
                modelId: recipe.modelId,
                binding: recipe.binding
              ) else {
            throw ToolError("The compiled prompt can no longer be adapted to another model.")
        }
        let current = try await currentBinding(
            editor: editor,
            shotId: recipe.binding.shotId,
            modality: recipe.modality,
            modelId: recipe.modelId
        )
        guard current.matchesCurrentState(of: recipe.binding)
                || (allowCurrentRoutingChange
                    && current.hasSameShotPlan(as: recipe.binding)) else {
            throw ToolError("The project changed while the generation approval was open. Compile the current shot again.")
        }
        return try await compile(
            intent: recipe.intent,
            modelId: modelId,
            modality: recipe.modality,
            aspectRatio: recipe.aspectRatio,
            durationSeconds: recipe.durationSeconds,
            editor: editor,
            setting: recipe.setting,
            lighting: recipe.lighting,
            style: recipe.style,
            shotId: recipe.binding.shotId,
            shot: try currentShotProjection(editor: editor, shotId: recipe.binding.shotId),
            preserveCompositionOverride: preserveCompositionOverride
        )
    }

    @MainActor
    static func rememberedRecipe(token: String, text: String, modelId: String) -> GenerationCompileRecipe? {
        guard let recipe = recipesByToken[token], recipe.modelId == modelId,
              validate(token: token, text: text, modelId: modelId, binding: recipe.binding) else { return nil }
        return GenerationCompileRecipe(intent: recipe.intent, setting: recipe.setting, lighting: recipe.lighting,
            style: recipe.style, preserveComposition: recipe.preserveComposition, styleFingerprint: recipe.binding.styleFingerprint)
    }

    @MainActor
    static func rememberedCompositionModeMatches(
        token: String,
        text: String,
        modelId: String,
        preserveComposition: Bool
    ) -> Bool {
        guard let recipe = recipesByToken[token],
              recipe.modelId == modelId,
              recipe.preserveComposition == preserveComposition else {
            return false
        }
        return validate(
            token: token,
            text: text,
            modelId: recipe.modelId,
            binding: recipe.binding
        )
    }

    @MainActor
    private static func remember(_ compiled: CompiledPrompt, recipe: CompileRecipe) {
        recipesByToken[compiled.token] = recipe
        recipeOrder.removeAll { $0 == compiled.token }
        recipeOrder.append(compiled.token)
        while recipeOrder.count > maxRememberedRecipes {
            recipesByToken.removeValue(forKey: recipeOrder.removeFirst())
        }
    }

    /// Apply preservation during the initial compile only when every runnable exact endpoint agrees.
    /// A mixed logical model is normalized again against the exact approved endpoint before submission.
    @MainActor
    static func preservesComposition(modelId: String) -> Bool {
        preservesComposition(
            bindings: ProviderManifest.bindings(forModelId: modelId),
            activation: .current()
        )
    }

    nonisolated static func preservesComposition(
        bindings: [ProviderBinding],
        activation: ProviderActivation
    ) -> Bool {
        let modes = bindings.compactMap { binding -> Bool? in
            guard activation.isActive(binding.provider, binding.transport),
                  let capabilities = binding.resolvedVideoCapabilities,
                  capabilities.contractViolation == nil,
                  binding.productionInputPolicy == capabilities.inputPolicy else {
                return nil
            }
            return capabilities.inputPolicy.preservesSourceComposition
        }
        return !modes.isEmpty && modes.allSatisfy { $0 }
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
            + "\(binding.shotFingerprint)|\(binding.routeArtifactSHA256)|"
            + "\(binding.requirementSHA256)|\(binding.capabilitiesSHA256)|"
            + "\(binding.routeSHA256)|\(binding.referencePlanSHA256)|"
            + "\(binding.orderedBindingsSHA256)|\(binding.styleFingerprint)|\(binding.compilerInputsSHA256 ?? "none")|"
            + "\(binding.promptDialectID)|\(binding.promptDialectVersion)|"
            + "\(binding.frameReferencePlanSHA256)|\(binding.promptIRSHA256)|"
            + "\(modelId)|\(text)"
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
    static func rememberedBinding(
        token: String,
        text: String,
        modelId: String
    ) -> PromptBinding? {
        guard let recipe = recipesByToken[token],
              recipe.modelId == modelId,
              validate(
                  token: token,
                  text: text,
                  modelId: modelId,
                  binding: recipe.binding
              ) else {
            return nil
        }
        return recipe.binding
    }

    @MainActor
    static func currentBinding(
        editor: EditorViewModel?,
        shotId: String,
        modality: PromptComposer.Modality,
        modelId: String? = nil
    ) async throws -> PromptBinding {
        let root = editor?.workingRoot.flatMap {
            DataRootResolver.dataRoot(of: $0)
        }
        let projectKey = editor?.projectId ?? root?.standardizedFileURL
            .resolvingSymlinksInPath().path ?? "none"
        let styleFingerprint = try await Task.detached(priority: .utility) {
            guard modality.usesVisualStyle, let root, try ProductionStyleStoreV1.load(dataRoot: root) != nil else { return "none" }
            let snapshot = try ProductionStyleStoreV1.snapshot(dataRoot: root)
            return FileDigest.sha256(of: Data((snapshot.inputFingerprint + ":" + snapshot.artifactFingerprint).utf8))
        }.value
        let compilerInputsSHA256 = try await PromptComposer.inputFingerprint(projectDir: editor?.workingRoot)
        guard editor?.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) == root,
              (editor?.projectId ?? root?.standardizedFileURL.resolvingSymlinksInPath().path ?? "none") == projectKey else {
            throw ToolError("The active project changed while validating its production style. Compile again in the active project.")
        }
        guard shotId != "none" else {
            let dialect: VideoPromptDialectV1?
            if case .video = modality, let modelId {
                let modeID = inferredFreeVideoModeID(modelId)
                dialect = try PromptDialectRegistry.requireVideoDialect(
                    modelID: modelId,
                    modeID: modeID
                )
            } else {
                dialect = nil
            }
            return PromptBinding(
                projectKey: projectKey,
                shotId: "none",
                shotFingerprint: "none",
                styleFingerprint: styleFingerprint,
                compilerInputsSHA256: compilerInputsSHA256,
                promptDialectID: dialect?.id ?? "none",
                promptDialectVersion: dialect?.version ?? 0
            )
        }
        guard let root,
              let shotlist = (try? loadShotlist(dataRoot: root)) ?? nil,
              let shot = shotlist.shots.first(where: { $0.id == shotId }) else {
            throw ToolError(
                "No current shot '\(shotId)' is available for prompt binding."
            )
        }
        if case .video = modality {
            let routing = try PipelineProductionRouting.requireCurrent(
                shotID: shotId,
                dataRoot: root
            )
            if let modelId, routing.modelID != modelId {
                throw ToolError(
                    "Shot '\(shotId)' is routed to '\(routing.modelID)', not '\(modelId)'. Resolve the current route before compiling."
                )
            }
            let modeID = try videoModeID(routing)
            let dialect = try PromptDialectRegistry.requireVideoDialect(
                modelID: routing.modelID,
                endpointID: routing.target.endpoint,
                modeID: modeID
            )
            return PromptBinding(
                projectKey: projectKey,
                shotId: shotId,
                shotFingerprint: try shotFingerprint(shot),
                routeArtifactSHA256: routing.routeArtifactSHA256,
                requirementSHA256: routing.route.requirementSHA256,
                capabilitiesSHA256: routing.route.capabilitiesSHA256,
                routeSHA256: routing.route.routeSHA256,
                referencePlanSHA256: routing.referencePlanSHA256,
                orderedBindingsSHA256: routing.orderedBindingsSHA256,
                styleFingerprint: styleFingerprint,
                compilerInputsSHA256: compilerInputsSHA256,
                promptDialectID: dialect.id,
                promptDialectVersion: dialect.version
            )
        }
        let framePlan: FrameReferencePlanV1?
        if case .image = modality, let modelId {
            framePlan = try currentFrameReferencePlan(
                editor: editor,
                shotId: shotId,
                modelId: modelId
            )
        } else {
            framePlan = nil
        }
        return PromptBinding(
            projectKey: projectKey,
            shotId: shotId,
            shotFingerprint: try shotFingerprint(shot),
            styleFingerprint: styleFingerprint,
            compilerInputsSHA256: compilerInputsSHA256,
            frameReferencePlanSHA256: framePlan?.fingerprint ?? "none"
        )
    }

    @MainActor
    static func currentFrameReferencePlan(
        editor: EditorViewModel?,
        shotId: String,
        modelId: String
    ) throws -> FrameReferencePlanV1? {
        guard shotId != "none",
              let editor,
              let projectHome = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: projectHome) else {
            return nil
        }
        let activePack: String?
        do {
            activePack = try ProjectPackGate.requireLiveMutation(
                projectURL: projectHome,
                declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let registry = PackCatalog.registry(activePack: activePack)
        guard let provider = registry.frameReferencePlanProvider else {
            return nil
        }
        guard let model = ImageModelConfig.allModels.first(where: {
            $0.id == modelId
        }) else {
            throw ToolError("The selected frame model '\(modelId)' is unavailable.")
        }
        guard let plan = provider.planFrameReferences(
            dataRoot: dataRoot,
            shotID: shotId,
            maxReferenceImages: model.maxReferenceImages
        ) else {
            throw ToolError(
                "The active format pack could not plan frame references for shot '\(shotId)'."
            )
        }
        guard plan.isExecutable else {
            let details = plan.deficits.map(\.detail).joined(separator: " ")
            throw ToolError(
                details.isEmpty
                    ? "The frame reference plan for shot '\(shotId)' exceeds the selected model's limits."
                    : details
            )
        }
        return plan
    }

    @MainActor
    private static func currentVideoContext(
        editor: EditorViewModel?,
        shotId: String,
        modelId: String,
        shot: PromptComposer.ShotProjection?,
        expectedBinding: PromptBinding
    ) throws -> PromptComposer.VideoContext {
        guard shotId != "none" else {
            let modeID = inferredFreeVideoModeID(modelId)
            return PromptComposer.VideoContext(
                modeID: modeID,
                dialect: try PromptDialectRegistry.requireVideoDialect(
                    modelID: modelId,
                    modeID: modeID
                ),
                references: [],
                startState: "",
                endState: "",
                blocking: [],
                timedActionBeats: [],
                continuityLocks: [],
                transitionIntent: nil
            )
        }
        guard let root = editor?.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
              let shot else {
            throw ToolError("Shot-bound video compilation requires the active project and shot projection.")
        }
        let routing = try PipelineProductionRouting.requireCurrent(
            shotID: shotId,
            dataRoot: root
        )
        guard routing.modelID == modelId else {
            throw ToolError(
                "Shot '\(shotId)' is routed to '\(routing.modelID)', not '\(modelId)'. Resolve the current route before compiling."
            )
        }
        let modeID = try videoModeID(routing)
        let dialect = try PromptDialectRegistry.requireVideoDialect(
            modelID: routing.modelID,
            endpointID: routing.target.endpoint,
            modeID: modeID
        )
        guard routing.routeArtifactSHA256 == expectedBinding.routeArtifactSHA256,
              routing.route.requirementSHA256 == expectedBinding.requirementSHA256,
              routing.route.capabilitiesSHA256 == expectedBinding.capabilitiesSHA256,
              routing.route.routeSHA256 == expectedBinding.routeSHA256,
              routing.referencePlanSHA256 == expectedBinding.referencePlanSHA256,
              routing.orderedBindingsSHA256 == expectedBinding.orderedBindingsSHA256,
              dialect.id == expectedBinding.promptDialectID,
              dialect.version == expectedBinding.promptDialectVersion else {
            throw ToolError(
                "The shot route changed during prompt compilation. Compile the current shot again."
            )
        }
        let (graph, _, _) = try PipelineProductionInputsWriter.load(
            shotID: shotId,
            dataRoot: root
        )
        let assets = Dictionary(uniqueKeysWithValues: graph.assets.map { ($0.id, $0) })
        var modalityCounts: [VideoPromptReferenceModalityV1: Int] = [:]
        let references = try routing.referencePlan.bindings.enumerated().map { index, binding in
            guard let asset = assets[binding.assetID],
                  asset.version == binding.assetVersion,
                  asset.path == binding.path,
                  asset.sha256 == binding.sha256 else {
                throw ToolError("The current reference plan no longer resolves asset '\(binding.assetID)'.")
            }
            let modality = videoReferenceModality(binding.modality)
            let modalityIndex = (modalityCounts[modality] ?? 0) + 1
            modalityCounts[modality] = modalityIndex
            return VideoPromptReferenceV1(
                planIndex: index,
                modalityIndex: modalityIndex,
                modality: modality,
                role: videoReferenceRole(
                    binding: binding,
                    asset: asset,
                    shot: shot
                ),
                semanticJobID: binding.semanticJobID,
                assetID: binding.assetID,
                entityID: asset.entityID,
                stateID: asset.stateID,
                viewID: asset.viewID,
                preservationScopeIDs: binding.preservationScopeIDs
            )
        }
        let audioLabel = references.first { $0.role == .audioTiming }?.providerLabel
        let musicvideoDirectives = try audioLabel.map {
            try PipelineMusicvideoProductionWriter.promptDirectives(
                for: shotId,
                audioLabel: $0,
                dataRoot: root
            )
        } ?? []
        try PipelineExecutionPlanWriter.requireCurrent(dataRoot: root)
        try PipelineExecutionPlanWriter.requireCurrentShotlistBinding(dataRoot: root)
        let executionPlan = try PipelineExecutionPlanWriter.load(dataRoot: root).0
        guard let execution = executionPlan.shots.first(where: { $0.id == shotId }) else {
            throw ToolError("The current execution plan does not contain shot '\(shotId)'.")
        }
        let blocking = execution.blocking.map { item in
            [item.entityID, item.relation, item.performance]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ": ")
        }
        return PromptComposer.VideoContext(
            modeID: modeID,
            dialect: dialect,
            references: references,
            startState: execution.startState.summary,
            endState: execution.endState.summary,
            blocking: blocking,
            timedActionBeats: execution.timedActionBeats,
            continuityLocks: execution.continuityLocks + musicvideoDirectives,
            transitionIntent: execution.transitionIntent
        )
    }

    static func inferredFreeVideoModeID(_ modelId: String) -> String {
        let value = modelId.lowercased()
        if value.contains("reference-to-video") || value.contains("omni") { return "reference-to-video" }
        if value.contains("image-to-video") { return "image-to-video" }
        if value.contains("video-to-video") || value.contains("edit") { return "video-to-video" }
        if value.contains("extension") || value.contains("extend") { return "video-extension" }
        return "text-to-video"
    }

    private static func videoModeID(
        _ routing: PipelineProductionRouteSelection
    ) throws -> String {
        let modes = Array(Set(routing.referencePlan.bindings.map {
            ProductionIdentifierNormalizerV1.canonical($0.modeID)
        }.filter { !$0.isEmpty })).sorted()
        if modes.count == 1 { return modes[0] }
        if modes.count > 1 {
            throw ToolError("The current reference plan mixes incompatible video modes: \(modes.joined(separator: ", ")).")
        }
        let inferred = inferredFreeVideoModeID(
            routing.route.offering.endpointID + " " + routing.modelID
        )
        let required = Set(routing.requirement.modeIDs.map(
            ProductionIdentifierNormalizerV1.canonical
        ))
        guard required.isEmpty || required.contains(
            ProductionIdentifierNormalizerV1.canonical(inferred)
        ) else {
            throw ToolError("The selected route does not identify one executable prompt mode.")
        }
        return inferred
    }

    private static func videoReferenceModality(
        _ modality: AssetPhysicalModalityV1
    ) -> VideoPromptReferenceModalityV1 {
        switch modality {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .geometry: .geometry
        }
    }

    private static func videoReferenceRole(
        binding: ReferenceBindingV2,
        asset: AssetGraphNodeV1,
        shot: PromptComposer.ShotProjection
    ) -> VideoPromptReferenceRoleV1 {
        let semantic = ProductionIdentifierNormalizerV1.canonical(binding.semanticJobID)
        switch semantic {
        case ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.firstFrame),
             ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.predecessorLastFrame):
            return .startFrame
        case ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.lastFrame):
            return .endFrame
        case ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.sourceVideo):
            return .sourceVideo
        case ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.audioTiming):
            return .audioTiming
        default:
            break
        }
        let entity = ProductionIdentifierNormalizerV1.canonical(asset.entityID ?? "")
        if shot.ledgerReferences.characterRefs.map(ProductionIdentifierNormalizerV1.canonical).contains(entity) {
            return .character
        }
        if shot.ledgerReferences.locationRef.map(ProductionIdentifierNormalizerV1.canonical) == entity {
            return .location
        }
        if shot.ledgerReferences.propRefs.map(ProductionIdentifierNormalizerV1.canonical).contains(entity) {
            return .prop
        }
        if semantic.contains("voice") { return .voice }
        if semantic.contains("motion") || semantic.contains("pacing") { return .motion }
        if semantic.contains("light") { return .lighting }
        if semantic.contains("style") || semantic.contains("look") { return .style }
        return .other
    }

    @MainActor
    static func currentShotProjection(
        editor: EditorViewModel?,
        shotId: String
    ) throws -> PromptComposer.ShotProjection? {
        guard shotId != "none" else { return nil }
        guard let root = editor?.workingRoot.flatMap({
            DataRootResolver.dataRoot(of: $0)
        }), let shotlist = (try? loadShotlist(dataRoot: root)) ?? nil else {
            throw ToolError(
                "Shot-bound compilation requires an open project with a current shotlist."
            )
        }
        guard let shot = shotlist.shots.first(where: { $0.id == shotId }) else {
            throw ToolError(
                "No shot '\(shotId)' in the shotlist. Pass a real shot id from next_render_shot, or "
                    + "\"none\" if this prompt belongs to no shot."
            )
        }
        let forceHandles = (try? YAMLArtifactStore(dataRoot: root).load(
            Brief.self,
            at: PipelineLayout.briefFile
        ))?.cutHandlesMode == .withOverlap
        return PromptComposer.ShotProjection(shot, forceHandles: forceHandles)
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
    ) async throws {
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
        let binding = try await currentBinding(
            editor: editor,
            shotId: shotId,
            modality: modalityForModel(modelId),
            modelId: modelId
        )
        guard let token = args.string("compileToken"),
              let compiledBinding = rememberedBinding(
                  token: token,
                  text: prompt,
                  modelId: modelId
              ),
              binding.matchesCurrentState(of: compiledBinding) else {
            throw ToolError(
                "Uncompiled prompt. NGV never sends raw prompts to content models: call "
                + "compile_prompt(intent, model, shotId) first and pass its compiledPrompt, "
                + "compileToken, and shotId "
                + "here unchanged. If essential details are missing, ask the user BEFORE generating.")
        }
    }
}

extension PromptBinding {
    func withPromptIRSHA256(_ value: String) -> PromptBinding {
        PromptBinding(
            projectKey: projectKey,
            shotId: shotId,
            shotFingerprint: shotFingerprint,
            routeArtifactSHA256: routeArtifactSHA256,
            requirementSHA256: requirementSHA256,
            capabilitiesSHA256: capabilitiesSHA256,
            routeSHA256: routeSHA256,
            referencePlanSHA256: referencePlanSHA256,
            orderedBindingsSHA256: orderedBindingsSHA256,
            styleFingerprint: styleFingerprint,
            compilerInputsSHA256: compilerInputsSHA256,
            promptDialectID: promptDialectID,
            promptDialectVersion: promptDialectVersion,
            frameReferencePlanSHA256: frameReferencePlanSHA256,
            promptIRSHA256: value
        )
    }

    func matchesCurrentState(of compiled: PromptBinding) -> Bool {
        withPromptIRSHA256("none") == compiled.withPromptIRSHA256("none")
    }

    func hasSameShotPlan(as other: PromptBinding) -> Bool {
        projectKey == other.projectKey
            && shotId == other.shotId
            && shotFingerprint == other.shotFingerprint
    }
}
