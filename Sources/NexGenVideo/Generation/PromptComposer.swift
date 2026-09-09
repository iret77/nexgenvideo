import Foundation
import NexGenEngine

/// Engine-backed prompt composition (concept §5: "the Prompt Generator composes from the Intent
/// Ledger"). This is the COMPILE half of the loop; `PromptCompiler` is only the gate (token mint +
/// enforcement). Free visual intent receives only film/look directives; shot-bound visual intent also
/// receives the exact referenced objects. The result runs the engine's pre-generation
/// `PromptLinter` — a lint ERROR blocks before money is spent; warnings pass as notes.
///
/// Video/image compose through the real engine builders (`PromptGenerator`); audio has no engine
/// builder (Seedance/image only), so it keeps the deterministic intent path without visual directives.
enum PromptComposer {

    struct Composition: Sendable {
        let text: String
        let notes: [String]
        let sourceIRSHA256: String?
    }

    struct VideoContext: Sendable {
        let modeID: String
        let dialect: VideoPromptDialectV1
        let references: [VideoPromptReferenceV1]
        let startState: String
        let endState: String
        let blocking: [String]
        let timedActionBeats: [TimedActionBeatV1]
        let continuityLocks: [String]
        let transitionIntent: String?
    }

    struct ImageContext: Sendable {
        let references: [FrameReferenceBindingV1]
    }

    enum ComposeError: LocalizedError {
        case emptyIntent
        case lintBlocked(code: String, message: String)
        case tooLong(count: Int, cap: Int, modelId: String)

        var errorDescription: String? {
            switch self {
            case .emptyIntent:
                return "Empty intent — describe what to generate."
            case .lintBlocked(let code, let message):
                return "Prompt lint failed (\(code)): \(message)"
            case .tooLong(let count, let cap, let modelId):
                return "Compiled prompt is \(count) characters — \(modelId) accepts at most \(cap). Tighten the intent."
            }
        }
    }

    enum Modality: Sendable {
        case video, image, audio, music

        var usesVisualStyle: Bool {
            switch self {
            case .video, .image: true
            case .audio, .music: false
            }
        }
    }

    /// A shot's deterministic camera/framing projection plus the compliance read-surface, threaded into
    /// a per-shot compile so `PromptPayload.camera/composition` come from the SPEC (not reconstructed by
    /// the agent's intent) and the drift linter checks the built prompt against the shot. Port of the
    /// camera/composition projection in `frames/generate.py::_payload_from_shot` + the per-frame
    /// `lint_prompt_against_shot` call.
    struct ShotProjection: Sendable {
        let sourceMode: SourceMode
        let camera: String
        let cameraMovement: String
        let cameraMovementKind: CameraMovement?
        let cameraMovementDetail: String?
        let composition: String
        let videoSubject: String?
        let videoDirectives: [String]
        let imageDirectives: [String]
        let spec: ComplianceLinter.ShotSpec
        let ledgerReferences: LedgerDirectives.ShotRefs
        /// The deterministic cut-handle timing for this shot (#213), empty when it carries no handle.
        /// `forceHandles` is the project-wide override (brief.cut_handles_mode == with_overlap).
        let temporalStructure: String

        init(_ shot: Shot, forceHandles: Bool = false) {
            let productionPlan = shot.productionPlan
            sourceMode = shot.sourceMode
            camera = shot.cameraSetup?.promptProse() ?? ""
            cameraMovement = productionPlan?.cameraMovement.promptProse(
                detail: productionPlan?.cameraMovementDetail
            ) ?? ""
            cameraMovementKind = productionPlan?.cameraMovement
            cameraMovementDetail = productionPlan?.cameraMovementDetail
            composition = shot.framing?.compositionProse ?? ""
            videoSubject = productionPlan?.primaryAction
            videoDirectives = (productionPlan?.providerDirectives ?? [])
                + shot.productionBlockingDirectives
            imageDirectives = (productionPlan?.stillProviderDirectives ?? [])
                + shot.productionBlockingDirectives
            ledgerReferences = LedgerDirectives.ShotRefs(
                id: shot.id,
                characterRefs: shot.characterRefs,
                locationRef: shot.locationRef,
                propRefs: shot.propRefs
            )
            spec = ComplianceLinter.ShotSpec(
                framing: shot.framing?.rawValue,
                cameraHeight: shot.cameraSetup?.height.rawValue,
                blockingGazes: shot.characterBlocking.map(\.gaze),
                notes: shot.notes ?? "")
            temporalStructure = CutHandles.temporalStructure(for: shot, forceAll: forceHandles) ?? ""
        }
    }

    /// Compose one model-ready prompt from free intent + the project ledger, running the engine
    /// linter as the pre-generation gate. `projectDir` is the open project's URL (see
    /// `EditorViewModel.workingRoot`); when it isn't a project yet, composition proceeds with an
    /// empty ledger. When `shot` is set (a per-shot render/frame compile), the shot's structured
    /// camera + framing are projected into the payload and the compliance drift linter runs on the
    /// built prompt, its findings surfaced as notes (warn-level, non-blocking — as in Python).
    static func compose(
        intent: String,
        modality: Modality,
        modelId: String,
        aspectRatio: String = "",
        durationSeconds: Double? = nil,
        projectDir: URL?,
        setting: String = "",
        lighting: String = "",
        style: String = "",
        shot: ShotProjection? = nil,
        preserveComposition: Bool = false,
        videoContext: VideoContext? = nil,
        imageContext: ImageContext? = nil
    ) async throws -> Composition {
        let trimmed = normalize(intent)
        guard !trimmed.isEmpty else { throw ComposeError.emptyIntent }

        // #223: a composition-preserving pass (video-to-video restyle) is the OPPOSITE of a generation
        // — it must invent nothing. Refuse an intent that asks it to before any money is spent; the
        // model would otherwise either ignore the ask or silently break the one guarantee it makes.
        if preserveComposition, let violation = RestylePrompt.lintIntent(trimmed).first {
            throw ComposeError.lintBlocked(code: violation.code, message: violation.message)
        }

        var directives = await lockedProjectDirectives(
            projectDir: projectDir,
            modality: modality,
            shot: shot
        )
        // The preservation clause is COMPOSED IN, not asked for: it rides as a directive so it survives
        // into the built prompt deterministically, exactly like a locked ledger directive.
        if preserveComposition {
            directives = ProjectDirectives(
                all: directives.all + [RestylePrompt.preservationClause],
                locked: directives.locked + [RestylePrompt.preservationClause])
        }

        let composed: String
        var sourceIRSHA256: String?
        var notes: [String] = []
        let productionStyle = try projectDir.flatMap { project -> ResolvedProductionStyleV1? in
            guard modality.usesVisualStyle else { return nil }
            guard let root = DataRootResolver.dataRoot(of: project) else { return nil }
            let style = try ProductionStyleStoreV1.load(dataRoot: root)
            if style != nil {
                let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
                let isDesignStill: Bool
                if case .image = modality { isDesignStill = shot == nil } else { isDesignStill = false }
                guard gates.gates["production_design"]?.approved == true || isDesignStill else {
                    throw ComposeError.lintBlocked(code: "STYLE_NOT_APPROVED", message: "Approve Production Design before using its style for production shots.")
                }
                if gates.gates["production_design"]?.approved != true {
                    notes.append("Production Design style proposal; this still does not approve the style.")
                }
            }
            return style
        }
        switch modality {
        case .video:
            let videoContext = try videoContext ?? freeVideoContext(modelId: modelId)
            let acceptsFreeContext = shot == nil
            var payload = PromptPayload(
                subject: shot?.videoSubject ?? trimmed,
                setting: acceptsFreeContext ? normalize(setting) : "",
                style: acceptsFreeContext ? normalize(style) : "",
                light: acceptsFreeContext ? normalize(lighting) : "",
                durationS: durationSeconds,
                aspectRatio: aspectRatio,
                directives: directives.all + (shot?.videoDirectives ?? [])
                    + [shot?.cameraMovement ?? ""].filter { !$0.isEmpty }
            )
            if let shot {
                payload.camera = shot.camera
                payload.composition = shot.composition
                payload.temporalStructure = shot.temporalStructure
            }
            try apply(productionStyle, to: &payload, plannedCamera: shot != nil, still: false)
            let ir = VideoPromptIRV1(
                payload: payload,
                modeID: videoContext.modeID,
                references: videoContext.references,
                startState: videoContext.startState,
                endState: videoContext.endState,
                blocking: videoContext.blocking,
                timedActionBeats: videoContext.timedActionBeats,
                continuityLocks: videoContext.continuityLocks,
                transitionIntent: videoContext.transitionIntent
            )
            sourceIRSHA256 = FileDigest.sha256(
                of: try VideoPromptCanonicalCodecV1.encode(ir)
            )
            composed = try PromptGenerator.buildVideoPrompt(
                ir: ir,
                dialect: videoContext.dialect
            )
            if let shot,
               let violation = ProductionPromptPolicy.videoPromptViolations(
                   composed,
                   expectedMovement: shot.cameraMovementKind,
                   expectedMovementDetail: shot.cameraMovementDetail
               ).first {
                throw ComposeError.lintBlocked(code: "PRODUCTION_PLAN_CAMERA_CONFLICT", message: violation)
            }
            notes.append(contentsOf: try lint(composed, lockedDirectives: directives.locked))
        case .image:
            sourceIRSHA256 = nil
            let acceptsFreeContext = shot == nil
            var payload = PromptPayload(
                subject: trimmed,
                setting: acceptsFreeContext ? normalize(setting) : "",
                style: acceptsFreeContext ? normalize(style) : "",
                light: acceptsFreeContext ? normalize(lighting) : "",
                aspectRatio: aspectRatio,
                multiRefHints: imageContext.map {
                    frameReferenceHints($0.references)
                } ?? [],
                directives: directives.all + (shot?.imageDirectives ?? [])
            )
            if let shot { payload.camera = shot.camera; payload.composition = shot.composition }
            try apply(productionStyle, to: &payload, plannedCamera: shot != nil, still: true)
            composed = try PromptGenerator.buildImagePrompt(modelID: engineModelID(modelId), payload: payload)
            if shot != nil,
               let violation = ProductionPromptPolicy.stillPromptViolations(composed).first {
                throw ComposeError.lintBlocked(code: "STILL_PROMPT_CAMERA_MOTION", message: violation)
            }
            notes.append(contentsOf: try lint(composed, lockedDirectives: directives.locked))
        case .audio, .music:
            sourceIRSHA256 = nil
            // The ledger has no audio-typed directives, so audio keeps the caller's compiled intent.
            composed = composeAudio(intent: trimmed, directives: directives)
            let mergedCount = directives.locked.filter { !trimmed.localizedCaseInsensitiveContains($0) }.count
            if mergedCount > 0 {
                notes.append("merged \(mergedCount) locked ledger directive(s)")
            }
            try lintAudio(composed, lockedDirectives: directives.locked)
        }

        // Compliance drift: does the built prompt still match the shot's declared camera / framing /
        // gaze / setting? Warn-level, non-blocking — the safety net Python runs on every frame build.
        if let shot {
            for f in ComplianceLinter.lintPromptAgainstShot(composed, shot.spec) {
                notes.append("\(f.code): \(f.message)")
            }
        }

        let cap = PromptCompiler.lengthCap(modelId: modelId)
        guard composed.count <= cap else {
            throw ComposeError.tooLong(count: composed.count, cap: cap, modelId: modelId)
        }
        return Composition(
            text: composed,
            notes: notes,
            sourceIRSHA256: sourceIRSHA256
        )
    }

    static func frameReferenceHints(
        _ references: [FrameReferenceBindingV1]
    ) -> [String] {
        references.map { reference in
            let identity = reference.entityID.isEmpty
                ? reference.role
                : "<\(reference.entityID)>"
            let view = reference.viewID.isEmpty
                ? ""
                : ", view \(reference.viewID)"
            let purpose = reference.purpose.isEmpty
                ? ""
                : "; \(reference.purpose)"
            return "defines \(reference.role) \(identity)\(view)\(purpose)"
        }
    }

    private static func apply(_ style: ResolvedProductionStyleV1?, to payload: inout PromptPayload,
                              plannedCamera: Bool, still: Bool) throws {
        guard let style else { return }
        let resolvedStyle = [style.value(.character), style.value(.color)].compactMap { $0 }.joined(separator: " ")
        if !plannedCamera {
            for (requested, resolved, dimension) in [(payload.style, resolvedStyle, "style"), (payload.light, style.value(.lighting) ?? "", "lighting")] {
                guard requested.isEmpty || resolved.isEmpty || normalize(requested) == normalize(resolved) else {
                    throw ComposeError.lintBlocked(code: "PROJECT_STYLE_CONFLICT",
                        message: "The requested " + dimension + " conflicts with Production Design. Explicitly revise and approve that decision before compiling a different look.")
                }
            }
        }
        if !resolvedStyle.isEmpty { payload.style = resolvedStyle }
        if let light = style.value(.lighting) { payload.light = light }
        if !plannedCamera, let composition = style.value(.composition) { payload.composition = composition }
        if !plannedCamera, !still,
           let camera = style.selection.overrides.first(where: { $0.dimension == .camera })?.value {
            payload.camera = camera
        }
    }

    // MARK: - Ledger

    private struct ProjectDirectives: Sendable {
        let all: [String]
        let locked: [String]
    }

    private static func lockedProjectDirectives(
        projectDir: URL?,
        modality: Modality,
        shot: ShotProjection?
    ) async -> ProjectDirectives {
        guard modality.usesVisualStyle,
              let projectDir,
              let root = DataRootResolver.dataRoot(of: projectDir) else {
            return ProjectDirectives(all: [], locked: [])
        }
        let references = shot?.ledgerReferences ?? LedgerDirectives.ShotRefs(
            id: nil,
            characterRefs: [],
            locationRef: nil,
            propRefs: []
        )
        return await Task.detached {
            loadDirectives(dataRoot: root, references: references)
        }.value
    }

    static func inputFingerprint(projectDir: URL?) async throws -> String {
        guard let projectDir, let root = DataRootResolver.dataRoot(of: projectDir) else { return "none" }
        return try await Task.detached(priority: .utility) {
            struct Inputs: Encodable {
                let artifactHashes: [String: String]
                let directives: [String]
                let locked: [String]
            }
            var hashes: [String: String] = [:]
            for path in [PipelineLayout.ledgerFile, PipelineLayout.briefFile] {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
                    hashes[path] = try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: root))
                } else { hashes[path] = "absent" }
            }
            let values = loadDirectives(
                dataRoot: root,
                references: LedgerDirectives.ShotRefs(
                    id: nil,
                    characterRefs: [],
                    locationRef: nil,
                    propRefs: []
                )
            )
            return FileDigest.sha256(of: try GenerationPackageV1.encode(Inputs(artifactHashes: hashes,
                directives: values.all, locked: values.locked)))
        }.value
    }

    private static func loadDirectives(
        dataRoot root: URL,
        references: LedgerDirectives.ShotRefs
    ) -> ProjectDirectives {
        let store = YAMLArtifactStore(dataRoot: root)
        var all: [String] = []
        var locked: [String] = []
        var seen = Set<String>()
        func add(_ raw: String, locked isLocked: Bool) {
            let directive = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !directive.isEmpty, !seen.contains(directive.lowercased()) else { return }
            seen.insert(directive.lowercased())
            all.append(directive)
            if isLocked { locked.append(directive) }
        }
        if let ledger = try? store.load(Ledger.self, at: PipelineLayout.ledgerFile) {
            let selected = LedgerDirectives.directivesForShot(
                ledger: ledger,
                shot: references
            )
            let lockedSet = Set(selected.locked.map { $0.lowercased() })
            for directive in selected.directives {
                add(directive, locked: lockedSet.contains(directive.lowercased()))
            }
        }
        for token in patternLightingTokens(dataRoot: root, store: store) { add(token, locked: false) }
        return ProjectDirectives(all: all, locked: locked)
    }

    private static func patternLightingTokens(dataRoot root: URL, store: YAMLArtifactStore) -> [String] {
        guard let brief = try? store.load(Brief.self, at: PipelineLayout.briefFile),
            let id = brief.directorPattern?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return [] }
        let activePack = ProjectPluginSettings.activePlugin(projectURL: FrameInventory.projectHome(of: root))
        guard let provider = PackCatalog.registry(activePack: activePack).patternProvider,
            let data = try? provider.get(id: id),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        guard let lighting = object["lighting_signature"] as? String else { return [] }
        return [lighting]
    }

    // MARK: - Audio composition (no engine builder)

    private static func composeAudio(intent: String, directives: ProjectDirectives) -> String {
        var text = intent
        let missing = directives.locked.filter { !text.localizedCaseInsensitiveContains($0) }
        if !missing.isEmpty {
            let suffix = text.hasSuffix(".") ? " " : ". "
            text += suffix + missing.joined(separator: ". ")
        }
        return text
    }

    // MARK: - Linting

    /// Run the engine linter over a composed video/image prompt. Returns warning/info notes; a lint
    /// ERROR throws so the controller blocks before the render. Locked-directive survival is checked
    /// with the compliance linter (a lock is a promise — its absence is an ERROR).
    private static func lint(_ prompt: String, lockedDirectives: [String]) throws -> [String] {
        var findings = PromptLinter.lintPrompt(prompt)
        // Compliance: every locked directive must have survived into the final prompt.
        for f in ComplianceLinter.lintLockedDirectives(prompt, lockedDirectives: lockedDirectives) {
            findings.append(PromptLinter.LintFinding(
                severity: f.severity == "error" ? .error : .warn, code: f.code, message: f.message))
        }
        if let blocking = findings.first(where: { $0.severity == .error }) {
            throw ComposeError.lintBlocked(code: blocking.code, message: blocking.message)
        }
        return findings.filter { $0.severity != .error }.map { "\($0.code): \($0.message)" }
    }

    /// Audio has no builder-normalized prompt, so the full slop/format checks would over-fire on plain
    /// speech/music intent. Only the check that matters for a merged text prompt runs: a locked
    /// directive dropping out (ERROR).
    private static func lintAudio(_ prompt: String, lockedDirectives: [String]) throws {
        for f in ComplianceLinter.lintLockedDirectives(prompt, lockedDirectives: lockedDirectives)
        where f.severity == "error" {
            throw ComposeError.lintBlocked(code: f.code, message: f.message)
        }
    }

    // MARK: - Helpers

    static func normalize(_ intent: String) -> String {
        intent
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The engine builders split the model id on the first `:` to pick a provider. App model ids use
    /// `provider/model` (e.g. `runway/gen4.5`, `fal-ai/veo3`); normalize the first `/` to `:` so the
    /// builder's provider dispatch matches.
    private static func engineModelID(_ modelId: String) -> String {
        guard let slash = modelId.firstIndex(of: "/") else { return modelId }
        return modelId.replacingCharacters(in: slash...slash, with: ":")
    }

    private static func freeVideoContext(modelId: String) throws -> VideoContext {
        let modeID = PromptCompiler.inferredFreeVideoModeID(modelId)
        return VideoContext(
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
}
