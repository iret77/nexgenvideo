import Foundation
import NexGenEngine

/// Engine-backed prompt composition (concept §5: "the Prompt Generator composes from the Intent
/// Ledger"). This is the COMPILE half of the loop; `PromptCompiler` is only the gate (token mint +
/// enforcement). Free-intent surfaces (panel, music tab, agent, rerun) carry no shot, so the ledger's
/// project-wide directives are composed in and the whole thing runs the engine's pre-generation
/// `PromptLinter` — a lint ERROR blocks before money is spent; warnings pass as notes.
///
/// Video/image compose through the real engine builders (`PromptGenerator`); audio has no engine
/// builder (Seedance/image only), so it keeps the deterministic intent + locked-directive merge the
/// old `PromptCompiler.compile` did — see `composeAudio`.
enum PromptComposer {

    struct Composition: Sendable {
        let text: String
        let notes: [String]
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

    enum Modality: Sendable { case video, image, audio, music }

    /// A shot's deterministic camera/framing projection plus the compliance read-surface, threaded into
    /// a per-shot compile so `PromptPayload.camera/composition` come from the SPEC (not reconstructed by
    /// the agent's intent) and the drift linter checks the built prompt against the shot. Port of the
    /// camera/composition projection in `frames/generate.py::_payload_from_shot` + the per-frame
    /// `lint_prompt_against_shot` call.
    struct ShotProjection: Sendable {
        let camera: String
        let composition: String
        let spec: ComplianceLinter.ShotSpec

        init(_ shot: Shot) {
            camera = shot.cameraSetup?.promptProse() ?? ""
            composition = shot.framing?.compositionProse ?? ""
            spec = ComplianceLinter.ShotSpec(
                framing: shot.framing?.rawValue,
                cameraHeight: shot.cameraSetup?.height.rawValue,
                blockingGazes: shot.characterBlocking.map(\.gaze),
                notes: shot.notes ?? "")
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
        shot: ShotProjection? = nil
    ) async throws -> Composition {
        let trimmed = normalize(intent)
        guard !trimmed.isEmpty else { throw ComposeError.emptyIntent }

        let directives = await lockedProjectDirectives(projectDir: projectDir)

        let composed: String
        var notes: [String] = []
        switch modality {
        case .video:
            var payload = PromptPayload(
                subject: trimmed,
                durationS: durationSeconds,
                aspectRatio: aspectRatio,
                directives: directives.all
            )
            if let shot { payload.camera = shot.camera; payload.composition = shot.composition }
            composed = PromptGenerator.buildVideoPrompt(modelID: engineModelID(modelId), payload: payload)
            notes.append(contentsOf: try lint(composed, lockedDirectives: directives.locked))
        case .image:
            var payload = PromptPayload(
                subject: trimmed,
                aspectRatio: aspectRatio,
                directives: directives.all
            )
            if let shot { payload.camera = shot.camera; payload.composition = shot.composition }
            composed = try PromptGenerator.buildImagePrompt(modelID: engineModelID(modelId), payload: payload)
            notes.append(contentsOf: try lint(composed, lockedDirectives: directives.locked))
        case .audio, .music:
            // No engine audio builder — merge locked directives into the intent (the historical
            // deterministic path), then run the linter's text checks on the result.
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
        return Composition(text: composed, notes: notes)
    }

    // MARK: - Ledger

    private struct ProjectDirectives: Sendable {
        let all: [String]
        let locked: [String]
    }

    /// Every ledger directive in the project, with the locked subset kept apart — there is no shot to
    /// scope by here, so the whole ledger applies. Faithful to the old compiler, which merged every
    /// locked directive. A missing/invalid ledger is a normal empty state, not an error. The ledger
    /// YAML is read off the main thread — composition can run on a `submit` that started on `@MainActor`.
    private static func lockedProjectDirectives(projectDir: URL?) async -> ProjectDirectives {
        guard let projectDir, let root = DataRootResolver.dataRoot(of: projectDir) else {
            return ProjectDirectives(all: [], locked: [])
        }
        return await Task.detached {
            loadDirectives(dataRoot: root)
        }.value
    }

    private static func loadDirectives(dataRoot root: URL) -> ProjectDirectives {
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
            for objectKey in ledger.objects.keys.sorted() {
                guard let attributes = ledger.objects[objectKey] else { continue }
                for attrName in attributes.keys.sorted() {
                    let attribute = attributes[attrName]!
                    add(attribute.directive.isEmpty ? attribute.tag : attribute.directive, locked: attribute.locked)
                }
            }
        }
        // Director-pattern style injection (#185, the strongest lever): the chosen pattern's craft tokens
        // (lighting signature + camera vocabulary) flow into EVERY compiled prompt so each rendered frame
        // inherits the style, not just the storyboard. Additive, not locked; no pattern/brief = empty.
        for token in patternStyleTokens(dataRoot: root, store: store) { add(token, locked: false) }
        return ProjectDirectives(all: all, locked: locked)
    }

    /// The active director pattern's style tokens (lighting signature + camera vocabulary), resolved
    /// through the pack's `PatternProviding` seam from `brief.director_pattern`. Empty when no pattern is
    /// chosen, no provider is registered, or anything is unreadable — a normal state, never an error.
    private static func patternStyleTokens(dataRoot root: URL, store: YAMLArtifactStore) -> [String] {
        guard let brief = try? store.load(Brief.self, at: PipelineLayout.briefFile),
            let id = brief.directorPattern?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return [] }
        let activePack = ProjectPluginSettings.activePlugin(projectURL: FrameInventory.projectHome(of: root))
        guard let provider = PackCatalog.registry(activePack: activePack).patternProvider,
            let data = try? provider.get(id: id),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var tokens: [String] = []
        if let lighting = object["lighting_signature"] as? String { tokens.append(lighting) }
        if let camera = object["camera_vocabulary"] as? [Any] {
            tokens.append(contentsOf: camera.compactMap { $0 as? String })
        }
        return tokens
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
}
