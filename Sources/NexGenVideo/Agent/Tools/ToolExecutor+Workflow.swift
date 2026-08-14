import CryptoKit
import Foundation
import NexGenEngine

// Production-pipeline (engine) tools, native as of M7. These are the former Python `engine` MCP
// tools, now first-class `nexgen` tools backed by NexGenEngine + the app's native reader/writer.
// Arg names and return JSON shapes match the Python `mcp_server` functions field-for-field so the
// pack phase docs keep working. `project_dir` is accepted but defaults to the open project's pipeline
// dir; every function resolves it through DataRootResolver (accepts a project home OR its `pipeline`
// data root), mirroring the Python `data_root_of` precheck.

extension ToolExecutor {

    // MARK: - project_dir resolution

    /// The data root to operate on: the `project_dir` arg if given, else the open project's pipeline
    /// dir — resolved through DataRootResolver so either a home or a `pipeline` dir works. Throws a
    /// clear error when neither is available or the path isn't a project.
    func resolveDataRoot(_ args: [String: Any], editor: EditorViewModel) throws -> URL {
        let explicit = args.string("project_dir").map { URL(fileURLWithPath: $0) }
        let openRoot = editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        if editor.projectURL != nil, openRoot == nil {
            throw ToolError(
                "The project working copy is unavailable. Reopen the project before accessing its pipeline."
            )
        }
        guard explicit != nil || openRoot != nil else {
            throw ToolError("No project is open and no project_dir was given.")
        }
        guard let explicit else { return openRoot! }
        guard let explicitRoot = DataRootResolver.dataRoot(of: explicit) else {
            throw ToolError(
                "Not a project (no pipeline/project.yaml): \(explicit.path). Run init_project first."
            )
        }
        guard let openRoot else { return explicitRoot }
        let requested = explicitRoot.standardizedFileURL.resolvingSymlinksInPath()
        let live = openRoot.standardizedFileURL.resolvingSymlinksInPath()
        if requested == live {
            return openRoot
        }
        if let savedRoot = editor.projectURL.flatMap({ DataRootResolver.dataRoot(of: $0) }),
           requested == savedRoot.standardizedFileURL.resolvingSymlinksInPath() {
            return openRoot
        }
        throw ToolError("project_dir must name the open project's working copy.")
    }

    /// The active format pack for a project given its DATA ROOT. `ngv.json` lives in the project
    /// PACKAGE (parent of `pipeline`), so the data root must be lifted to its home before the lookup —
    /// reading `activePlugin(projectURL: dataRoot)` directly always resolves nil in the v2 layout.
    private func activePluginFor(dataRoot: URL) -> String? {
        ProjectPluginSettings.activePlugin(projectURL: FrameInventory.projectHome(of: dataRoot))
    }

    /// The merged pipeline order for a project — core phases with the active pack's declared gate
    /// phases (e.g. musicvideo's `analysis` right after `project_init`) merged in at their placement.
    /// Routes through `PhaseOrder.merged`, the single ordering helper every surface shares.
    private func mergedPhaseOrder(dataRoot: URL) -> [String] {
        let placements = PackCatalog.registry(activePack: activePluginFor(dataRoot: dataRoot)).phasePlacements
        return PhaseOrder.merged(packPlacements: placements)
    }

    private func readGates(dataRoot: URL) throws -> Gates {
        do {
            return try YAMLArtifactStore(dataRoot: dataRoot).load(
                Gates.self,
                at: PipelineLayout.gatesFile
            )
        } catch {
            throw ToolError(
                "Couldn't read gates.yaml. Repair or restore the project before continuing: \(error)"
            )
        }
    }

    private func readShotlist(dataRoot: URL) throws -> Shotlist? {
        do {
            return try loadShotlist(dataRoot: dataRoot)
        } catch {
            throw ToolError(
                "Couldn't read the shotlist. Repair or restore it before continuing: \(error)"
            )
        }
    }

    private func readRenderManifest(dataRoot: URL, phase: String) throws -> RenderManifest {
        do {
            return try loadRenderManifest(dataRoot: dataRoot, phase: phase)
        } catch {
            throw ToolError(
                "Couldn't read the \(phase) render manifest. Repair or restore it before continuing: \(error)"
            )
        }
    }

    private func readRenderProof(
        dataRoot: URL,
        phase: String
    ) throws -> RenderProofManifest {
        do {
            let proof = try loadRenderProofManifest(
                dataRoot: dataRoot,
                phase: phase
            )
            let project = try YAMLArtifactStore(dataRoot: dataRoot).load(
                ProjectMeta.self,
                at: PipelineLayout.projectFile
            )
            guard proof.schema == renderProofSchemaVersion,
                  proof.project == project.project,
                  proof.phase == phase else {
                throw ToolError(
                    "The \(phase) render provenance has invalid identity."
                )
            }
            return proof
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError(
                "Couldn't read the \(phase) render provenance. Repair or restore "
                    + "it before continuing: \(error)"
            )
        }
    }

    private func readFrameAudit(
        dataRoot: URL,
        shotId: String,
        role: String
    ) throws -> FrameAudit? {
        do {
            return try loadFrameAudit(dataRoot: dataRoot, shotId: shotId, role: role)
        } catch {
            throw ToolError(
                "Couldn't read the frame audit for \(shotId)-\(role). "
                    + "Repair or restore it before continuing: \(error)"
            )
        }
    }

    private func readBriefIfPresent(dataRoot: URL) throws -> Brief? {
        let url = PipelineLayout.url(PipelineLayout.briefFile, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try YAMLArtifactStore(dataRoot: dataRoot).load(
                Brief.self,
                at: PipelineLayout.briefFile
            )
        } catch {
            throw ToolError(
                "Couldn't read brief.yaml. Repair or restore it before continuing: \(error)"
            )
        }
    }

    /// JSON `.ok` result from a Foundation object graph.
    func jsonResult(_ object: Any) throws -> ToolResult {
        let data = try NativeCockpitReader.serialize(object)
        return .ok(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Read-only state

    func getProjectState(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let data = try NativeCockpitReader.stateJSON(dataRoot: root, activePack: activePluginFor(dataRoot: root))
        return .ok(String(decoding: data, as: UTF8.self))
    }

    func listPhasesTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        // An EXPLICIT project_dir must resolve or the error surfaces — silently answering with
        // the core order would hide the pack (and its analysis gate) behind a typo. Only the
        // truly projectless case (no arg, no open project) falls back to the bare core order.
        let order: [String]
        if args["project_dir"] != nil {
            order = mergedPhaseOrder(dataRoot: try resolveDataRoot(args, editor: editor))
        } else {
            order = (try? resolveDataRoot(args, editor: editor)).map { mergedPhaseOrder(dataRoot: $0) } ?? coreGatePhases
        }
        return try jsonResult(order)
    }

    func getBible(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let data = try NativeCockpitReader.bibleJSON(dataRoot: root)
        return .ok(String(decoding: data, as: UTF8.self))
    }

    func runSanityTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        guard let report = NativeCockpitReader.sanityReport(
            dataRoot: root,
            activePack: activePluginFor(dataRoot: root)
        ) else {
            throw ToolError("No shot list exists. Write and approve the shot list before running sanity.")
        }
        let artifact: SanityArtifact
        do {
            artifact = try SanityArtifactStore.save(report: report, dataRoot: root)
        } catch {
            throw ToolError("Couldn't persist the sanity report: \(error.localizedDescription)")
        }
        let data = try NativeCockpitReader.sanityJSON(report)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("The sanity report could not be encoded.")
        }
        object["schema"] = artifact.schema
        object["generated"] = artifact.generated
        object["input_fingerprint"] = artifact.inputFingerprint
        object["path"] = PipelineLayout.sanityReportFile
        let persisted = try NativeCockpitReader.serialize(object)
        return .ok(String(decoding: persisted, as: UTF8.self))
    }

    func estimateCostTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        return try jsonResult(NativeCockpitReader.costDictionary(dataRoot: root, activePack: activePluginFor(dataRoot: root)))
    }

    // MARK: - Director patterns (#185) — the agent-callable path to the pack's pattern library.

    func suggestPatternsTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let provider = try patternProvider(args, editor: editor)
        // The pack assembles the ProjectFitProfile from the persisted Brief; the host only forwards the
        // Brief plus the agent-supplied options (perceived BPM, match mode, exclusions). Fit weights and
        // the mapping live in the pack, behind the JSON seam.
        let brief = try? YAMLArtifactStore(dataRoot: root).load(Brief.self, at: PipelineLayout.briefFile)
        let briefJSON = (try? JSONEncoder().encode(brief)) ?? Data()
        var options: [String: Any] = [:]
        if let bpm = args["perceived_bpm"] as? Double { options["perceived_bpm"] = bpm }
        if let mode = args["match_mode"] as? String { options["match_mode"] = mode }
        if let excluded = args["excluded_pattern_ids"] as? [String] { options["excluded_pattern_ids"] = excluded }
        if let top = args["top"] as? Int { options["max_results"] = top }
        // #214: forward the recorded affect detection/override so the affect axis comes from audio +
        // lyrics, not the brief tone-tag map. Pure passthrough — the host never interprets the affect
        // vocabulary (a pack concern); it hands the pack the bytes it wrote. Absent → assembler falls back.
        if let affectData = try? Data(contentsOf: PipelineLayout.url(Self.affectFile, in: root)),
           let affectObj = try? JSONSerialization.jsonObject(with: affectData) {
            options["affect_profile"] = affectObj
        }
        let optionsJSON = try JSONSerialization.data(withJSONObject: options)
        let data = try provider.recommend(briefJSON: briefJSON, optionsJSON: optionsJSON)
        return .ok(String(decoding: data, as: UTF8.self))
    }

    /// The recorded affect detection/override — a pack artifact, but the host only reads/writes the
    /// bytes; the affect vocabulary and its validation live in the tool schema (enum-constrained) and
    /// the pack. Kept next to `analysis/` the pack owns.
    static let affectFile = "analysis/affect.json"

    /// #214 — persist the affect the agent read from the audio analysis + lyrics, so the pattern-fit
    /// `affect_energy` axis comes from the signal and the text, not the brief's tone-tag lookup. `detected`
    /// is the automatic read; `override` is the user's deliberate correction (kept alongside, never erasing
    /// the detection — a deliberately contrary mood is a legitimate directing choice). The agent does the
    /// inference; this tool only records it, schema-validated against the affect vocabulary.
    func recordAffectTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)

        // A tag carries signal only with a positive weight (the affect axis is a weighted mean), so a
        // zero/negative-weight entry is rejected rather than persisted — it would otherwise count as a
        // present-but-unscorable affect and shadow the tone-tag fallback.
        func weighted(_ key: String) throws -> [[String: Any]] {
            guard let raw = args[key] as? [[String: Any]] else { return [] }
            var out: [[String: Any]] = []
            for entry in raw {
                guard let tag = entry["tag"] as? String, !tag.isEmpty else {
                    throw ToolError("Each \(key) entry needs a 'tag' (an affect from the enum).")
                }
                let weight = (entry["weight"] as? Double) ?? (entry["weight"] as? Int).map(Double.init) ?? 1.0
                guard weight > 0 else {
                    throw ToolError("\(key) tag '\(tag)' has weight \(weight) — weights must be positive (they are relative strengths).")
                }
                out.append(["value": tag, "weight": weight])
            }
            return out
        }

        let detected = try weighted("detected")
        guard !detected.isEmpty else {
            throw ToolError("record_affect needs at least one 'detected' affect {tag, weight}.")
        }
        var profile: [String: Any] = [
            "detected": detected,
            "rationale": args.string("rationale") ?? "",
            "basis": args.string("basis") ?? "inferred",
        ]
        // An empty override is not a correction — omit it so it never reads as one.
        let override = try weighted("override")
        if !override.isEmpty { profile["override"] = override }

        let data = try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])
        let url = PipelineLayout.url(Self.affectFile, in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)

        let overrode = profile["override"] != nil
        return try jsonResult([
            "recorded": true,
            "overridden": overrode,
            "note": overrode
                ? "Override recorded — pattern-fit will use the set affect, not the detected one. Show the user 'detected X → set Y' so the choice stays legible."
                : "Detection recorded — it answers the affect_energy axis for suggest_patterns. The user can override it.",
        ])
    }

    /// #247 — write `brief.yaml` through the real engine `Brief` decoder + `validate()`, not freeform
    /// YAML. The agent supplies the brief fields (validated against `BriefWriteContract`); the host
    /// injects the server-owned fields, decodes `Brief.self` (which enforces every enum + validation
    /// rule), and only then persists. On any violation nothing is written and the exact field is named.
    func writeBriefTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        // `project_dir` is a control arg; every other key must be a known agent-facing brief field. The
        // server-owned fields are absent from allowedKeys, so passing one is rejected here.
        try validateUnknownKeys(args, allowed: BriefWriteContract.allowedKeys.union(["project_dir"]), path: "write_brief")

        var payload: [String: Any] = [:]
        for field in BriefWriteContract.fields where args[field.key] != nil {
            if let violation = briefEnumViolation(field, value: args[field.key]!) { throw ToolError(violation) }
            payload[field.key] = args[field.key]
        }
        payload["schema"] = briefSchemaVersion
        payload["project"] = FrameInventory.projectName(of: root) ?? FrameInventory.projectHome(of: root).lastPathComponent
        payload["generated"] = currentTimestamp()
        payload["generator"] = "brief-agent@write_brief"

        let brief: Brief
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            brief = try JSONDecoder().decode(Brief.self, from: data)
        } catch let e as DecodingError {
            throw ToolError("brief rejected — " + briefDecodeViolation(e, args: args) + ". Nothing was written; fix and re-call.")
        } catch let e as Brief.ValidationError {
            throw ToolError("brief rejected — " + briefValidationViolation(e) + " Nothing was written; fix and re-call.")
        }
        let mode: Mode
        guard let parsedMode = Mode(rawValue: brief.projectMode) else {
            throw ToolError(
                "brief rejected — project_mode '\(brief.projectMode)' is unsupported."
            )
        }
        mode = parsedMode
        let store = YAMLArtifactStore(dataRoot: root)
        let project: ProjectMeta
        do {
            project = try store.load(
                ProjectMeta.self,
                at: PipelineLayout.projectFile
            )
        } catch {
            throw ToolError(
                "Couldn't synchronize the brief with project.yaml: \(error)"
            )
        }
        guard project.project == brief.project else {
            throw ToolError(
                "brief rejected — project.yaml belongs to '\(project.project)', "
                    + "not '\(brief.project)'."
            )
        }
        let synchronizedProject = ProjectMeta(
            project: project.project,
            mode: mode,
            budgetEur: brief.budgetEur,
            created: project.created
        )
        do {
            try synchronizedProject.validate()
        } catch {
            throw ToolError(
                "brief rejected — project metadata would be invalid: \(error)"
            )
        }
        let briefURL = PipelineLayout.url(PipelineLayout.briefFile, in: root)
        let previousBrief = try? Data(contentsOf: briefURL)
        try archiveExisting(PipelineLayout.briefFile, dataRoot: root)
        do {
            try store.save(brief, to: PipelineLayout.briefFile)
            try store.save(synchronizedProject, to: PipelineLayout.projectFile)
        } catch {
            do {
                if let previousBrief {
                    try previousBrief.write(to: briefURL, options: .atomic)
                } else if FileManager.default.fileExists(atPath: briefURL.path) {
                    try FileManager.default.removeItem(at: briefURL)
                }
            } catch let rollbackError {
                throw ToolError(
                    "Couldn't synchronize brief.yaml and project.yaml "
                        + "(\(error.localizedDescription)); restoring the prior brief "
                        + "also failed (\(rollbackError.localizedDescription))."
                )
            }
            throw ToolError(
                "Couldn't synchronize brief.yaml and project.yaml: "
                    + error.localizedDescription
            )
        }
        return try jsonResult([
            "written": true,
            "project": brief.project,
            "path": PipelineLayout.briefFile,
            "summary": briefSummary(brief),
        ])
    }

    /// Compact one-line summary of the brief's key choices plus any non-default settings.
    private func briefSummary(_ b: Brief) -> String {
        let core = [
            "mission=\(b.mission.rawValue)",
            "platform=\(b.targetPlatform)",
            "aspect=\(b.aspectRatio.rawValue)",
            "mode=\(b.projectMode)",
            "concept=\(b.conceptType.rawValue)",
            "medium=\(b.visualMedium.rawValue)",
            "figures=\(b.figures.rawValue)",
            "lyrics=\(b.lyricsIntegration.rawValue)",
        ].joined(separator: ", ")
        var extra: [String] = []
        if b.budgetEur != 50.0 { extra.append("budget_eur=\(b.budgetEur)") }
        if let stop = b.budgetStopEur { extra.append("budget_stop_eur=\(stop)") }
        if b.finalResolution != .res1080p { extra.append("final_resolution=\(b.finalResolution.rawValue)") }
        if b.previewMode != .skip { extra.append("preview_mode=\(b.previewMode.rawValue)") }
        if b.cutHandlesMode != .withOverlap { extra.append("cut_handles_mode=\(b.cutHandlesMode.rawValue)") }
        if !b.tone.isEmpty { extra.append("tone=[\(b.tone.map(\.rawValue).joined(separator: ", "))]") }
        if let pattern = b.directorPattern { extra.append("director_pattern=\(pattern)") }
        return extra.isEmpty ? core : core + " · non-default: " + extra.joined(separator: ", ")
    }

    func getPatternTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let provider = try patternProvider(args, editor: editor)
        let id = try args.requireString("id")
        guard let data = try provider.get(id: id) else {
            throw ToolError("No director pattern with id \"\(id)\". Call suggest_patterns to discover valid ids.")
        }
        return .ok(String(decoding: data, as: UTF8.self))
    }

    /// The active pack's pattern provider, or an actionable error when this pack ships none.
    private func patternProvider(_ args: [String: Any], editor: EditorViewModel) throws -> any PatternProviding {
        let root = try resolveDataRoot(args, editor: editor)
        guard let provider = PackCatalog.registry(activePack: activePluginFor(dataRoot: root)).patternProvider else {
            throw ToolError("This project's format pack has no director patterns "
                + "(suggest_patterns/get_pattern are a musicvideo feature).")
        }
        return provider
    }

    func getLedgerTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let data = try NativeCockpitReader.ledgerJSON(dataRoot: root)
        return .ok(String(decoding: data, as: UTF8.self))
    }

    func getUIContractTool(_ editor: EditorViewModel) throws -> ToolResult {
        let registry = PackCatalog.registry(activePack: editor.activePluginName)
        let contract = UIContract.fullContract(packEntries: registry.uiContracts)
        var phases: [String: Any] = [:]
        for (phase, entry) in contract {
            var info: [String: Any] = ["surface": entry.surface, "task_class": entry.taskClass]
            // #174: engine-owned deterministic steps the host guarantees for this phase — the agent
            // orchestrates AROUND these (never re-runs or improvises a load-bearing step).
            let steps = registry.deterministicSteps(forPhase: phase)
            if !steps.isEmpty {
                info["engine_steps"] = steps.map { ["id": $0.id, "summary": $0.summary] }
            }
            phases[phase] = info
        }
        return try jsonResult(["surfaces": UIContract.surfaces, "phases": phases])
    }

    func showArtifactTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let gate = try args.requireString("gate")
        let markdown = ShowArtifact.gate(gate, dataRoot: root)
        return try jsonResult(["gate": gate, "markdown": markdown])
    }

    // MARK: - Scaffold (WRITES)

    func initProjectTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        // Default to the open project's working copy (⌘S syncs it into the package); an explicit
        // home_dir still works for out-of-band scaffolding.
        let home: URL
        if let hd = args.string("home_dir"), !hd.isEmpty {
            let explicit = URL(fileURLWithPath: hd)
            if let projectURL = editor.projectURL {
                guard let working = editor.workingRoot else {
                    throw ToolError(
                        "The project working copy is unavailable. Reopen the project before scaffolding."
                    )
                }
                let requested = explicit.standardizedFileURL.resolvingSymlinksInPath()
                let live = working.standardizedFileURL.resolvingSymlinksInPath()
                let saved = projectURL.standardizedFileURL.resolvingSymlinksInPath()
                guard requested == live || requested == saved else {
                    throw ToolError("home_dir must name the open project's working copy.")
                }
                home = working
            } else {
                home = explicit
            }
        } else if let working = editor.workingRoot {
            home = working
        } else {
            throw ToolError("No open project — pass home_dir to scaffold a project location.")
        }
        let name = try args.requireString("name")
        let modeRaw = args.string("mode") ?? "beat"
        guard let mode = Mode(rawValue: modeRaw) else {
            throw ToolError("Unknown mode '\(modeRaw)'. Expected beat/phrase/section/multicam.")
        }
        let budget = args.double("budget_eur") ?? 50.0
        let extraDirs = PackCatalog.projectDirs(activePack: editor.activePluginName)
        do {
            let dataRoot = try ProjectScaffold.initProject(
                home: home, name: name, mode: mode, budgetEur: budget, extraDirs: extraDirs
            )
            // Refresh engine state now (not just at turn end) so the cockpit sees the pipeline
            // immediately — the "Start production" affordances disable at once, no double-start window.
            Task { await editor.refreshEngineState() }
            return try jsonResult(["data_root": dataRoot.path, "project": name, "created": true])
        } catch let e as ProjectScaffold.ScaffoldError {
            throw ToolError("Couldn't scaffold project: \(e)")
        }
    }

    // MARK: - Project files (list / copy — replaces shell Glob/cp in pack docs)

    /// Resolve a data-root-relative path, refusing anything that escapes the project — both lexically
    /// (`../`) AND through a symlink. The symlink check resolves the deepest EXISTING ancestor (the
    /// destination itself may not exist yet) and confirms it still lives under the canonical root.
    private static func resolveInside(_ root: URL, _ rel: String) throws -> URL {
        let base = root.standardizedFileURL
        let target = base.appendingPathComponent(rel).standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            throw ToolError("Path escapes the project: '\(rel)'.")
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var probe = target
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let resolved = probe.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == canonicalRoot.path || resolved.path.hasPrefix(canonicalRoot.path + "/") else {
            throw ToolError("Path escapes the project via a link: '\(rel)'.")
        }
        return target
    }

    private static func requirePipelineAssetCopyPath(
        _ relativePath: String,
        source: Bool
    ) throws {
        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path == relativePath,
              !path.isEmpty,
              !NSString(string: path).isAbsolutePath,
              !path.hasSuffix("/"),
              !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ToolError("Pipeline asset paths must be normalized project-relative file paths.")
        }
        if source {
            guard path.hasPrefix("import/") else {
                throw ToolError(
                    "copy_project_file can stage uploaded files only from import/. "
                        + "Use `media` for a generated result."
                )
            }
        } else {
            let productionDesignAsset = path.hasPrefix(
                "production_design/refs/"
            ) || path == "production_design/lighting_anchor.png"
            let bibleAsset = path.hasPrefix("bible/")
                && path != PipelineLayout.bibleFile
                && path != PipelineLayout.assetProofFile(scope: "bible")
            guard productionDesignAsset || bibleAsset else {
                throw ToolError(
                    "copy_project_file writes only Production Design or Bible image assets; "
                        + "canonical pipeline artifacts are host-owned."
                )
            }
        }
        guard ClipType(fileExtension: URL(
            fileURLWithPath: path
        ).pathExtension.lowercased()) == .image else {
            throw ToolError("copy_project_file stages image assets only.")
        }
    }

    func listProjectFilesTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let subdir = try args.requireString("subdir")
        let dir = try Self.resolveInside(root, subdir)
        let prefix = root.standardizedFileURL.path + "/"
        let files = ((try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? [])
            .map { dir.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false }
            .map { $0.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "") }
            .sorted()
        return try jsonResult(["subdir": subdir, "files": files])
    }

    func copyProjectFileTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let fromRel = args.string("from")
        let mediaID = args.string("media")
        guard (fromRel == nil) != (mediaID == nil) else {
            throw ToolError("Pass exactly one source: `from` or `media`.")
        }
        let toRel = try args.requireString("to")
        try Self.requirePipelineAssetCopyPath(toRel, source: false)
        if let fromRel {
            try Self.requirePipelineAssetCopyPath(fromRel, source: true)
        }
        let to = try Self.resolveInside(root, toRel)
        let sourceAsset = try mediaID.map {
            try asset($0, editor: editor)
        }
        let from: URL
        if let sourceAsset {
            guard sourceAsset.type == .image else {
                throw ToolError("copy_project_file stages image assets only.")
            }
            let home = FrameInventory.projectHome(of: root)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            from = sourceAsset.url.standardizedFileURL
                .resolvingSymlinksInPath()
            guard from.path.hasPrefix(home.path + "/"),
                  (try? from.resourceValues(
                    forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true else {
                throw ToolError(
                    "Media '\(sourceAsset.id)' is not a ready regular file in the open project."
                )
            }
        } else {
            from = try Self.resolveInside(root, fromRel!)
            guard (try? from.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile) == true else {
                throw ToolError("Source not found or not a regular file: '\(fromRel!)'.")
            }
        }
        do {
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if from.standardizedFileURL != to.standardizedFileURL {
                if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
                try FileManager.default.copyItem(at: from, to: to)
            }
        } catch {
            throw ToolError(
                "Couldn't copy '\(fromRel ?? mediaID ?? "?")' → '\(toRel)': "
                    + error.localizedDescription
            )
        }
        let proofRecorded = try updatePipelineAssetProof(
            sourceAsset: sourceAsset,
            sourceRelativePath: fromRel,
            destinationRelativePath: toRel,
            destinationURL: to,
            dataRoot: root
        )
        return try jsonResult([
            "from": fromRel.map { $0 as Any } ?? NSNull(),
            "media": mediaID.map { $0 as Any } ?? NSNull(),
            "to": toRel,
            "generated_provenance": proofRecorded,
        ])
    }

    private func updatePipelineAssetProof(
        sourceAsset: MediaAsset?,
        sourceRelativePath: String?,
        destinationRelativePath: String,
        destinationURL: URL,
        dataRoot: URL
    ) throws -> Bool {
        guard let scope = ["production_design", "bible"].first(where: {
            destinationRelativePath == $0
                || destinationRelativePath.hasPrefix($0 + "/")
        }) else { return false }
        var proof: PipelineAssetProof
        do {
            proof = try loadPipelineAssetProof(
                dataRoot: dataRoot,
                scope: scope
            )
        } catch {
            throw ToolError(
                "Couldn't read \(scope) generation provenance: \(error)"
            )
        }
        guard proof.schema == pipelineAssetProofSchemaVersion,
              proof.scope == scope,
              proof.project == (FrameInventory.projectName(of: dataRoot)
                ?? dataRoot.lastPathComponent) else {
            throw ToolError(
                "\(scope) generation provenance has the wrong project, scope, or schema."
            )
        }
        let entry: PipelineAssetProofEntry?
        if let sourceAsset,
           let input = sourceAsset.generationInput {
            let prompt = input.prompt.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let model = input.model.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !prompt.isEmpty, !model.isEmpty else {
                throw ToolError(
                    "Generated media '\(sourceAsset.id)' has incomplete prompt provenance."
                )
            }
            entry = PipelineAssetProofEntry(
                path: destinationRelativePath,
                sha256: try FileDigest.sha256(of: destinationURL),
                providerPrompt: prompt,
                generationModel: model,
                sourceMediaId: sourceAsset.id
            )
        } else if let sourceRelativePath {
            entry = try pipelineAssetProofEntry(
                for: sourceRelativePath,
                copiedTo: destinationRelativePath,
                destinationURL: destinationURL,
                dataRoot: dataRoot
            )
        } else {
            entry = nil
        }
        if let entry {
            proof.entries[destinationRelativePath] = entry
        } else {
            proof.entries.removeValue(forKey: destinationRelativePath)
        }
        do {
            try savePipelineAssetProof(proof, dataRoot: dataRoot)
        } catch {
            throw ToolError(
                "Couldn't save \(scope) generation provenance: \(error)"
            )
        }
        return entry != nil
    }

    private func pipelineAssetProofEntry(
        for sourceRelativePath: String,
        copiedTo destinationRelativePath: String,
        destinationURL: URL,
        dataRoot: URL
    ) throws -> PipelineAssetProofEntry? {
        for sourceScope in ["production_design", "bible"] {
            let sourceProof = try loadPipelineAssetProof(
                dataRoot: dataRoot,
                scope: sourceScope
            )
            guard let source = sourceProof.entries[sourceRelativePath],
                  let sourceURL = try? Self.resolveInside(
                      dataRoot,
                      sourceRelativePath
                  ),
                  (try? FileDigest.sha256(of: sourceURL)) == source.sha256
            else { continue }
            return PipelineAssetProofEntry(
                path: destinationRelativePath,
                sha256: try FileDigest.sha256(of: destinationURL),
                providerPrompt: source.providerPrompt,
                generationModel: source.generationModel,
                sourceMediaId: source.sourceMediaId
            )
        }
        return nil
    }

    // MARK: - Gates (WRITES)

    func approveGateTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        let notes = args.string("notes")
        let declaredPack = editor.declaredPluginName
        try requirePhaseIdle(editor, dataRoot: root)
        // Hard preconditions FIRST — never ask the user to approve something that can't be approved.
        try await enforceGateRequirement(
            phase: phase,
            dataRoot: root,
            declaredPack: declaredPack,
            editor: editor
        )
        let request = editor.agentService.requestGateApproval(GateApproval(
            phase: phase,
            notes: notes,
            dataRoot: root,
            action: .approve,
            declaredPack: declaredPack
        ))
        return try gateApprovalPendingResult(request, requestedPhase: phase)
    }

    func setGateStateTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        let stateRaw = try args.requireString("state")
        guard let state = GateState(rawValue: stateRaw) else {
            throw ToolError("Unknown state '\(stateRaw)'. Expected approved/approved_with_notes/needs_revision/pending.")
        }
        let notes = args.string("notes")
        let declaredPack = editor.declaredPluginName
        try requirePhaseIdle(editor, dataRoot: root)
        let resolvedPack: String?
        do {
            resolvedPack = try ProjectPluginSettings.resolvedPlugin(
                projectURL: FrameInventory.projectHome(of: root),
                declaredPack: declaredPack
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let registry = PackCatalog.registry(activePack: resolvedPack)
        do {
            try GateGuard.requireWiredPack(
                declared: declaredPack,
                resolved: resolvedPack,
                registry: registry
            )
        } catch let blocked as GateBlocked {
            throw ToolError(blocked.message)
        }
        // Approving states defer their write to the durable user card.
        if GateApproval.isApproval(state) {
            try await enforceGateRequirement(
                phase: phase,
                dataRoot: root,
                declaredPack: declaredPack,
                editor: editor
            )
            let request = editor.agentService.requestGateApproval(GateApproval(
                phase: phase,
                notes: notes,
                dataRoot: root,
                action: .setState(state),
                declaredPack: declaredPack
            ))
            return try gateApprovalPendingResult(request, requestedPhase: phase)
        }
        let order = PhaseOrder.merged(
            packPlacements: registry.phasePlacements
        )
        let existing = try readGates(dataRoot: root)
        let current = order.first {
            !existing.get($0).approved
        }
        guard existing.get(phase).approved || current == phase else {
            throw ToolError(
                "Can't mark future phase \"\(phase)\" as \(state.rawValue). "
                    + "Reach it by completing the earlier phases first."
            )
        }
        if let key = editor.openWorkingCopyKey {
            try ProjectWorkingCopy.markDirty(key: key)
        }
        let gates = try mutateGates(dataRoot: root) {
            try GatesOperations.setStateAndInvalidateDownstream(
                &$0,
                phase: phase,
                state: state,
                order: order,
                notes: notes
            )
        }
        editor.onPipelineChanged?()
        let gate = gates.get(phase)
        return try jsonResult([
            "project": gates.project,
            "phase": phase,
            "state": gate.state.rawValue,
            "approved": gate.approved,
            "notes": gate.notes.map { $0 as Any } ?? NSNull(),
        ])
    }

    private func gateApprovalPendingResult(
        _ request: GateApprovalRequest,
        requestedPhase: String
    ) throws -> ToolResult {
        let pending = request.approval
        let message: String
        if request.isNew {
            message = "The approval card is open. End this turn and wait for the user's decision."
        } else if request.matchesRequestedApproval {
            message = "This approval is already pending. End this turn; do not retry while the card is open."
        } else {
            message = "Another approval is already pending for \(pending.phaseLabel). End this turn and wait for it."
        }
        return try jsonResult([
            "status": "approval_pending",
            "request_id": pending.id,
            "phase": pending.phase,
            "requested_phase": requestedPhase,
            "new_request": request.isNew,
            "message": message,
        ])
    }

    /// Revalidates and commits a durable approval after the user acts.
    func commitGateApproval(_ approval: GateApproval) async throws -> String {
        guard let editor else { throw ToolError("Editor not available") }
        guard let root = approval.dataRoot else {
            throw ToolError("The approval request no longer identifies its project data root.")
        }
        try requirePhaseIdle(editor, dataRoot: root)
        do {
            _ = try ProjectPluginSettings.resolvedPlugin(
                projectURL: FrameInventory.projectHome(of: root),
                declaredPack: approval.declaredPack
            )
        } catch {
            throw ToolError(
                "The project format changed while this approval was open: "
                    + error.localizedDescription
            )
        }
        try await enforceGateRequirement(
            phase: approval.phase,
            dataRoot: root,
            declaredPack: approval.declaredPack,
            editor: editor
        )
        if let key = editor.openWorkingCopyKey {
            try ProjectWorkingCopy.markDirty(key: key)
        }
        let gates = try mutateGates(dataRoot: root) { gates in
            switch approval.action {
            case .approve:
                GatesOperations.approve(&gates, phase: approval.phase, notes: approval.notes)
            case .setState(let state):
                GatesOperations.setState(
                    &gates,
                    phase: approval.phase,
                    state: state,
                    notes: approval.notes
                )
            }
        }
        editor.onPipelineChanged?()
        let gate = gates.get(approval.phase)
        guard let payload = Self.jsonString([
            "request_id": approval.id,
            "project": gates.project,
            "phase": approval.phase,
            "approved": gate.approved,
            "state": gate.state.rawValue,
            "approved_at": gate.approvedAt.map { $0 as Any } ?? NSNull(),
            "approved_by": gate.approvedBy.map { $0 as Any } ?? NSNull(),
            "notes": gate.notes.map { $0 as Any } ?? NSNull(),
        ]) else {
            throw ToolError("The updated gate could not be encoded.")
        }
        return payload
    }

    /// Deterministic hard-gate check shared by approve_gate and set_gate_state.
    private func enforceGateRequirement(
        phase: String,
        dataRoot: URL,
        declaredPack: String?,
        editor: EditorViewModel
    ) async throws {
        do {
            try await NativeGateWriter.requireApprovalReady(
                projectDir: FrameInventory.projectHome(of: dataRoot),
                phase: phase,
                declaredPack: declaredPack,
                executionCoordinator: editor.pipelinePhaseRunCoordinator
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
    }

    func rewindTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let target = try args.requireString("target_phase")
        try requirePhaseIdle(editor, dataRoot: root)
        let resolvedPack: String?
        do {
            resolvedPack = try ProjectPluginSettings.resolvedPlugin(
                projectURL: FrameInventory.projectHome(of: root),
                declaredPack: editor.declaredPluginName
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let registry = PackCatalog.registry(activePack: resolvedPack)
        do {
            try GateGuard.requireWiredPack(
                declared: editor.declaredPluginName,
                resolved: resolvedPack,
                registry: registry
            )
        } catch let blocked as GateBlocked {
            throw ToolError(blocked.message)
        }
        // Rewind over the merged order (core + pack, at declared placement) so a pack phase like
        // `analysis` is a valid target and resets its correct downstream span.
        let order = PhaseOrder.merged(
            packPlacements: registry.phasePlacements
        )
        var reset: [String] = []
        _ = try mutateGates(dataRoot: root) { reset = try GatesOperations.rewindTo(&$0, target: target, order: order) }
        return try jsonResult(["target": target, "reset_phases": reset])
    }

    /// Load gates.yaml, apply `body`, save, and return the mutated gates. Same store/layout the
    /// NativeGateWriter uses.
    private func mutateGates(dataRoot: URL, _ body: (inout Gates) throws -> Void) throws -> Gates {
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        do {
            var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
            try body(&gates)
            try store.save(gates, to: PipelineLayout.gatesFile)
            return gates
        } catch {
            throw ToolError("Couldn't update gates: \(error)")
        }
    }

    // MARK: - Ledger (WRITES)

    func setLedgerAttributeTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let kind = try ledgerKind(args)
        let key = try args.requireString("key")
        let tag = try args.requireString("tag")
        let objectId = args.string("object_id")
        let directive = args.string("directive") ?? ""
        let source = args.string("source") ?? ""
        let locked = args.bool("locked")
        let attribute = try mutateLedger(dataRoot: root) {
            try setAttribute(
                &$0, kind: kind, objectId: objectId, key: key, tag: tag,
                directive: directive, source: source, locked: locked
            )
        }
        return try jsonResult(attributeDict(attribute))
    }

    func lockLedgerAttributeTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let kind = try ledgerKind(args)
        let key = try args.requireString("key")
        let objectId = args.string("object_id")
        let locked = args.bool("locked") ?? true
        let attribute = try mutateLedger(dataRoot: root) {
            try setLocked(&$0, kind: kind, objectId: objectId, key: key, locked: locked)
        }
        return try jsonResult(attributeDict(attribute))
    }

    func removeLedgerAttributeTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let kind = try ledgerKind(args)
        let key = try args.requireString("key")
        let objectId = args.string("object_id")
        _ = try mutateLedger(dataRoot: root) {
            try removeAttribute(&$0, kind: kind, objectId: objectId, key: key)
        }
        return try jsonResult(["removed": true, "kind": kind.rawValue, "key": key])
    }

    private func ledgerKind(_ args: [String: Any]) throws -> LedgerObjectKind {
        let raw = try args.requireString("kind")
        guard let kind = LedgerObjectKind(rawValue: raw) else {
            throw ToolError("Unknown ledger kind '\(raw)'. Expected character/ensemble/prop/location/shot/look/film.")
        }
        return kind
    }

    private func attributeDict(_ a: Attribute) -> [String: Any] {
        ["tag": a.tag, "directive": a.directive, "source": a.source, "locked": a.locked, "updated": a.updated]
    }

    /// Load ledger.yaml (empty default when absent), apply `body`, save. Returns whatever `body`
    /// yields (the mutated attribute), surfacing LedgerError as a ToolError.
    private func mutateLedger<T>(dataRoot: URL, _ body: (inout Ledger) throws -> T) throws -> T {
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        let ledgerURL = PipelineLayout.url(PipelineLayout.ledgerFile, in: dataRoot)
        var ledger: Ledger
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            do {
                ledger = try store.load(Ledger.self, at: PipelineLayout.ledgerFile)
            } catch {
                throw ToolError(
                    "Couldn't read ledger.yaml. Nothing was written; repair or restore it first: \(error)"
                )
            }
        } else {
            ledger = Ledger()
        }
        do {
            let result = try body(&ledger)
            try store.save(ledger, to: PipelineLayout.ledgerFile)
            return result
        } catch let e as LedgerError {
            throw ToolError("Ledger update rejected: \(e)")
        } catch {
            throw ToolError("Couldn't update ledger: \(error)")
        }
    }

    // MARK: - Router

    func resolveModelTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let taskClass = try args.requireString("task_class")
        let escalate = args.bool("escalate") ?? false
        let dataRoot = try? resolveDataRoot(args, editor: editor)
        do {
            let r = try ModelRouter.resolve(taskClass, escalate: escalate, dataRoot: dataRoot)
            return try jsonResult([
                "task_class": r.taskClass,
                "tier": r.tier,
                "model": r.model,
                "effort": r.effort,
                "escalated": r.escalated,
            ])
        } catch is ModelRouter.UnknownTaskClass {
            throw ToolError("Unknown task_class '\(taskClass)'. Expected distill/classification/assembly/review/planning/interpretation.")
        }
    }

    // MARK: - Render manifest

    func nextRenderShotTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        guard let shotlist = try readShotlist(dataRoot: root) else {
            throw ToolError("No shotlist yet. Plan and approve the shots before rendering.")
        }
        let renderManifest = phase == "frames"
            ? nil
            : try readRenderManifest(dataRoot: root, phase: phase)
        let renderProof = phase == "frames"
            ? nil
            : try readRenderProof(dataRoot: root, phase: phase)
        let shot: Shot?
        let frameRole: String?
        if phase == "frames" {
            let framesURL = PipelineLayout.url(
                PipelineLayout.framesManifestFile,
                in: root
            )
            let frames: FramesManifest?
            if FileManager.default.fileExists(atPath: framesURL.path) {
                do {
                    frames = try loadFramesManifest(dataRoot: root)
                } catch {
                    throw ToolError(
                        "Couldn't read frames/manifest.json. Repair or restore it "
                            + "before continuing: \(error)"
                    )
                }
            } else {
                frames = nil
            }
            let pending = await nextFrameRole(
                shotlist: shotlist,
                manifest: frames,
                editor: editor,
                dataRoot: root
            )
            shot = pending?.shot
            frameRole = pending?.role
        } else {
            guard let renderManifest else {
                throw ToolError("The \(phase) render manifest is unavailable.")
            }
            let ordered = shotlist.shots
                .filter { $0.sourceMode != .imported }
            let frames = try? loadFramesManifest(dataRoot: root)
            let pending = ordered.first {
                !isCurrentVideoRender(
                    renderManifest.entries[$0.id],
                    proof: renderProof?.entries[$0.id],
                    shot: $0,
                    shotlist: shotlist,
                    manifest: renderManifest,
                    frames: frames,
                    dataRoot: root
                )
            }
            shot = pending
            frameRole = nil
        }
        guard let shot else {
            return try jsonResult(["phase": phase, "shot_id": NSNull(), "done": true])
        }
        let shotId = shot.id

        var body: [String: Any] = [
            "phase": phase,
            "shot_id": shotId,
            "done": false,
            "source_mode": shot.sourceMode.rawValue,
            "visual_prompt": shot.visualPrompt,
            "framing": shot.framing.map { $0.rawValue as Any } ?? NSNull(),
            "camera": shot.cameraSetup.map { $0.promptProse() as Any } ?? NSNull(),
            "chain_with_previous_end": shot.chainWithPreviousEnd,
        ]
        if let plan = shot.productionPlan {
            body["production_plan"] = [
                "primary_action": plan.primaryAction,
                "camera_movement": plan.cameraMovement.rawValue,
                "camera_movement_detail": plan.cameraMovementDetail.map { $0 as Any } ?? NSNull(),
                "narrative_beat": plan.narrativeBeat.map { $0.rawValue as Any } ?? NSNull(),
                "renderability": plan.renderability.rawValue,
                "risks": plan.risks.map(\.rawValue),
                "rescue_cut": plan.rescueCut.map { $0 as Any } ?? NSNull(),
                "match_action_cue": plan.matchActionCue.map { $0 as Any } ?? NSNull(),
                "continuity_locks": plan.continuityLocks,
                "blocking_anchors": plan.blockingAnchors.map {
                    [
                        "character_ref": $0.characterRef,
                        "set_anchor": $0.setAnchor,
                    ]
                },
            ]
        }
        if let frameRole { body["role"] = frameRole }
        if phase != "frames", shot.sourceMode == .aiEnhanced {
            guard let sourcePath = shot.sourcePath,
                  let source = await resolveRenderedAsset(
                      sourcePath,
                      editor: editor,
                      dataRoot: root
                  ) else {
                throw ToolError(
                    "\(shot.id) has no current project-local source video. "
                        + "Rewind to Shot List and assign source_path before rendering."
                )
            }
            body["source_video_media_ref"] = source.id
            body["source_video_path"] = sourcePath
        }
        // #213: cut handles as content. When the plan puts a fade/crossfade on a side (or the global
        // override forces it), the shot renders overlap material there — so the agent orders the GROSS
        // duration from the model and trims the timeline clip to the NET window. Hard-cut shots carry no
        // handle (gross == net) and are unchanged. The temporal structure is composed into the prompt by
        // compile_prompt(shotId); here the agent gets the durations to order and to place.
        if phase != "frames" {
            let forceHandles = (try? YAMLArtifactStore(dataRoot: root).load(
                Brief.self,
                at: PipelineLayout.briefFile
            ))?.cutHandlesMode == .withOverlap
            let h = CutHandles.handles(for: shot, forceAll: forceHandles)
            if h.pre > 0 || h.post > 0 {
                body["net_duration_s"] = shot.durationS
                body["render_duration_s"] = CutHandles.orderableGrossDuration(
                    for: shot,
                    forceAll: forceHandles
                )
                body["handle_pre_s"] = h.pre
                body["handle_post_s"] = h.post
                body["handle_note"] = "Order render_duration_s from the model exactly as given (it is "
                    + "already a whole second). The compiled prompt holds \(h.pre)s before and \(h.post)s "
                    + "after. Place the clip trimmed to net_duration_s (in-point at \(h.pre)s), so the "
                    + "handle material sits just off the visible cut for the fade."
            }
        }
        // #196: when this shot chains off its predecessor, hand the agent the predecessor's extracted
        // last frame (recorded by record_render) as the start-frame condition — pass it straight to the
        // generate tool's startFrameMediaRef. Absent until the predecessor has rendered.
        if phase != "frames",
           shot.chainWithPreviousEnd,
           let predId = ChainContinuity.chainPredecessor(shotlist, shotId: shotId),
           let lastFrame = renderManifest?.entries[predId]?.lastFramePath,
           let asset = await resolveRenderedAsset(lastFrame, editor: editor, dataRoot: root) {
            body["chain_start_frame_media_ref"] = asset.id
            body["chain_start_frame_path"] = lastFrame
        }
        // #195: the deterministic reference plan for this shot — bible sheets scored by view priority
        // plus inherited identity-anchor frames stacked on top (multi-shot character consistency). Each
        // planned ref is resolved to a media_ref the agent passes straight to the generate tool's
        // referenceImageMediaRefs, so the ported planner drives the render instead of the agent guessing.
        if shot.sourceMode == .generated,
           let plan = PackCatalog.registry(activePack: activePluginFor(dataRoot: root))
            .referencePlanProvider?.planReferences(dataRoot: root, shotId: shotId) {
            var refImages: [[String: Any]] = []
            for ref in plan.refs {
                guard let asset = await resolveRenderedAsset(
                    ref.path,
                    editor: editor,
                    dataRoot: root
                ) else { continue }
                refImages.append([
                    "media_ref": asset.id, "path": ref.path, "kind": ref.kind,
                    "view": ref.view, "score": ref.score, "purpose": ref.purpose,
                ])
            }
            if !refImages.isEmpty { body["reference_images"] = refImages }
            if !plan.warnings.isEmpty { body["reference_warnings"] = plan.warnings }
        }
        return try jsonResult(body)
    }

    private func isCurrentVideoRender(
        _ entry: RenderEntry?,
        proof: RenderProofEntry?,
        shot: Shot,
        shotlist: Shotlist,
        manifest: RenderManifest,
        frames: FramesManifest?,
        dataRoot: URL
    ) -> Bool {
        guard let entry,
              let proof,
              entry.status == .rendered,
              let output = entry.output,
              entry.shotId == proof.shotId,
              output == proof.output,
              let url = renderedFileURL(output, dataRoot: dataRoot),
              ProjectMediaExtensions.videos.contains(
                  url.pathExtension.lowercased()
              ),
              !proof.providerPrompt.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !proof.generationModel.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              ComplianceLinter.lintLockedDirectives(
                proof.providerPrompt,
                lockedDirectives: shot.videoProductionPromptRequirements
              ).isEmpty,
              ProductionPromptPolicy.videoPromptViolations(
                proof.providerPrompt,
                expectedMovement: shot.productionPlan?.cameraMovement,
                expectedMovementDetail: shot.productionPlan?.cameraMovementDetail
              ).isEmpty,
              (try? FileDigest.sha256(of: url)) == proof.outputSha256 else {
            return false
        }
        let inputsAreCurrent = [
            proof.sourceVideo,
            proof.startFrame,
            proof.endFrame,
        ].compactMap { $0 }.allSatisfy {
            isCurrentRenderInput($0, dataRoot: dataRoot)
        }
            && (
                proof.referenceImages
                    + proof.referenceVideos
                    + proof.referenceAudio
            ).allSatisfy {
                isCurrentRenderInput($0, dataRoot: dataRoot)
            }
        guard inputsAreCurrent,
              proof.referenceVideos.isEmpty,
              proof.referenceAudio.isEmpty else {
            return false
        }
        if shot.sourceMode == .aiEnhanced {
            guard let sourcePath = shot.sourcePath,
                  let source = proof.sourceVideo else {
                return false
            }
            return sameCurrentRenderInputPath(
                source.path,
                sourcePath,
                dataRoot: dataRoot
            )
                && proof.startFrame == nil
                && proof.endFrame == nil
                && proof.referenceImages.isEmpty
        }
        guard proof.sourceVideo == nil else { return false }
        if shot.seedanceInputMode == .reference {
            guard proof.startFrame == nil,
                  proof.endFrame == nil,
                  let plan = PackCatalog.registry(
                    activePack: activePluginFor(dataRoot: dataRoot)
                  ).referencePlanProvider?.planReferences(
                    dataRoot: dataRoot,
                    shotId: shot.id
                  ) else {
                return false
            }
            return exactCurrentRenderReferences(
                proof.referenceImages,
                expected: plan.refs.map(\.path),
                dataRoot: dataRoot
            )
        }
        guard proof.referenceImages.isEmpty else { return false }
        let expectedStart: String?
        if shot.chainWithPreviousEnd {
            guard let predecessor = ChainContinuity.chainPredecessor(
                shotlist,
                shotId: shot.id
            ) else {
                return false
            }
            expectedStart = manifest.entries[predecessor]?.lastFramePath
        } else {
            expectedStart = frames?.shot(shot.id)?.frames.first {
                $0.role == "start"
            }?.path
        }
        let expectedEnd = frames?.shot(shot.id)?.frames.first {
            $0.role == "end"
        }?.path
        switch shot.keyframeStrategy {
        case .none:
            if shot.chainWithPreviousEnd {
                guard let expectedStart,
                      let actualStart = proof.startFrame else {
                    return false
                }
                return sameCurrentRenderInputPath(
                    actualStart.path,
                    expectedStart,
                    dataRoot: dataRoot
                ) && proof.endFrame == nil
            }
            return proof.startFrame == nil && proof.endFrame == nil
        case .start:
            guard let expectedStart,
                  let actualStart = proof.startFrame else {
                return false
            }
            return sameCurrentRenderInputPath(
                actualStart.path,
                expectedStart,
                dataRoot: dataRoot
            ) && proof.endFrame == nil
        case .startEnd:
            guard let expectedStart,
                  let expectedEnd,
                  let actualStart = proof.startFrame,
                  let actualEnd = proof.endFrame else {
                return false
            }
            return sameCurrentRenderInputPath(
                actualStart.path,
                expectedStart,
                dataRoot: dataRoot
            ) && sameCurrentRenderInputPath(
                actualEnd.path,
                expectedEnd,
                dataRoot: dataRoot
            )
        }
    }

    private func isCurrentRenderInput(
        _ proof: RenderInputProof,
        dataRoot: URL
    ) -> Bool {
        let home = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !proof.path.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
        !NSString(string: proof.path).isAbsolutePath,
        !proof.path.split(separator: "/").contains("..") else {
            return false
        }
        for base in [dataRoot, home] {
            let url = base.appendingPathComponent(proof.path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard url.path.hasPrefix(home.path + "/") else { continue }
            if (try? FileDigest.sha256(of: url)) == proof.sha256 {
                return true
            }
        }
        return false
    }

    private func sameCurrentRenderInputPath(
        _ lhs: String,
        _ rhs: String,
        dataRoot: URL
    ) -> Bool {
        let home = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        func file(_ path: String) -> URL? {
            guard !path.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            !NSString(string: path).isAbsolutePath,
            !path.split(separator: "/").contains("..") else {
                return nil
            }
            for base in [dataRoot, home] {
                let url = base.appendingPathComponent(path)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                if url.path.hasPrefix(home.path + "/"),
                   FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
            return nil
        }
        guard let left = file(lhs), let right = file(rhs) else {
            return false
        }
        return left == right
    }

    private func exactCurrentRenderReferences(
        _ actual: [RenderInputProof],
        expected: [String],
        dataRoot: URL
    ) -> Bool {
        guard Set(actual.map(\.path)).count == actual.count,
              actual.count == expected.count else {
            return false
        }
        return expected.allSatisfy { expectedPath in
            actual.contains {
                sameCurrentRenderInputPath(
                    $0.path,
                    expectedPath,
                    dataRoot: dataRoot
                )
            }
        }
    }

    func recordRenderTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        let shotId = try args.requireString("shot_id")
        var output = args.string("output")
        let costEur = args.double("cost_eur") ?? 0.0
        let statusRaw = args.string("status") ?? "rendered"
        guard let status = RenderStatus(rawValue: statusRaw) else {
            throw ToolError("Unknown status '\(statusRaw)'. Expected rendered/pending/failed.")
        }
        guard let shotlist = try readShotlist(dataRoot: root),
              let shot = shotlist.shots.first(where: { $0.id == shotId }) else {
            throw ToolError(
                "No shot '\(shotId)' in the current shotlist. "
                    + "Use the shot id returned by next_render_shot."
            )
        }
        if phase != "frames", shot.sourceMode == .imported {
            throw ToolError(
                "\(shot.id) uses source_mode=imported and does not belong in a "
                    + "provider render manifest. Place its source footage on the timeline."
            )
        }
        var completedAsset: MediaAsset?
        var updatedFrames: FramesManifest?
        if status == .rendered {
            guard let submitted = output, !submitted.isEmpty else {
                throw ToolError(
                    "A rendered result needs output pointing to completed project media."
                )
            }
            guard let asset = await resolveRenderedAsset(
                submitted,
                editor: editor,
                dataRoot: root
            ), FileManager.default.fileExists(atPath: asset.url.path) else {
                throw ToolError(
                    "Rendered output '\(submitted)' is not completed media on disk. "
                        + "Wait for get_media to report it ready, then record it."
                )
            }
            guard asset.generationStatus == .none else {
                throw ToolError(
                    "Rendered output '\(submitted)' is not completed media on disk. "
                        + "Wait for get_media to report it ready, then record it."
                )
            }
            let projectHome = FrameInventory.projectHome(of: root)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let assetURL = asset.url.standardizedFileURL
                .resolvingSymlinksInPath()
            guard assetURL.path.hasPrefix(projectHome.path + "/"),
                  (try? assetURL.resourceValues(
                    forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true else {
                throw ToolError(
                    "Rendered output must be a regular file in the open project."
                )
            }
            let expectedType: ClipType = phase == "frames" ? .image : .video
            guard asset.type == expectedType else {
                throw ToolError(
                    "\(phase) output must be \(expectedType.rawValue) media, "
                        + "but '\(submitted)' is \(asset.type.rawValue)."
                )
            }
            completedAsset = asset
            output = FrameInventory.relativePath(
                of: assetURL,
                to: projectHome
            )
            if phase == "frames" {
                updatedFrames = try updatedFramesManifest(
                    shot: shot,
                    asset: asset,
                    role: args.string("role"),
                    shotlist: shotlist,
                    editor: editor,
                    dataRoot: root
                )
            }
        }
        var manifest = try readRenderManifest(dataRoot: root, phase: phase)
        var proof = phase == "frames"
            ? nil
            : try readRenderProof(dataRoot: root, phase: phase)
        record(&manifest, shotId: shotId, output: output, costEur: costEur, status: status, phase: phase)
        // #231: stamp what this render was ACTUALLY conditioned on, so `plan_adherence` can audit it
        // against what `next_render_shot` planned. Read off the submitted GenerationInput — the record
        // of the real submission — not off the agent's say-so.
        if status == .rendered, let output, !output.isEmpty {
            guard let completedAsset else {
                throw ToolError("The rendered output was not registered as project media.")
            }
            let entryProof = try stampRenderInputs(
                &manifest,
                shotId: shotId,
                output: output,
                asset: completedAsset,
                shot: shot,
                editor: editor,
                dataRoot: root
            )
            proof?.entries[shotId] = entryProof
        } else {
            proof?.entries.removeValue(forKey: shotId)
        }
        do {
            try saveRenderManifest(manifest, dataRoot: root)
        } catch {
            throw ToolError("Couldn't save render manifest: \(error)")
        }
        if let proof {
            do {
                try saveRenderProofManifest(proof, dataRoot: root)
            } catch {
                throw ToolError("Couldn't save render provenance: \(error)")
            }
        }
        if let updatedFrames {
            do {
                try saveFramesManifest(updatedFrames, dataRoot: root)
            } catch {
                try? await editor.pipelineAgentHarness.recordPhaseMutation(
                    phase: "frames",
                    dataRoot: root,
                    captureLineage: false,
                    declaredPack: editor.declaredPluginName
                )
                throw ToolError(
                    "The shot render was recorded, but the authoritative Frames "
                        + "manifest could not be saved: \(error)"
                )
            }
        }
        // #196: if the shot immediately after this one chains off it (`chain_with_previous_end`), extract
        // this clip's last frame now and record it on the entry — `next_render_shot` feeds it as the
        // successor's start frame. Best-effort — never fail the render record over it.
        if phase != "frames",
           status == .rendered,
           let output,
           !output.isEmpty {
            await recordChainLastFrame(
                shotId: shotId,
                output: completedAsset?.id ?? output,
                phase: phase,
                editor: editor,
                dataRoot: root
            )
        }
        let entry = manifest.entries[shotId]
        return try jsonResult([
            "phase": phase,
            "shot_id": shotId,
            "status": entry?.status.rawValue ?? statusRaw,
            "output": entry?.output.map { $0 as Any } ?? NSNull(),
            "cost_eur": entry?.costEur ?? costEur,
            "updated_at": entry?.updatedAt.map { $0 as Any } ?? NSNull(),
            "spent_eur": spent(manifest),
        ])
    }

    func getRenderManifestTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        let shotlist = try readShotlist(dataRoot: root)
        let ordered = shotlist?.shots
            .filter {
                phase == "frames"
                    ? $0.sourceMode == .generated
                        && $0.keyframeStrategy != .none
                    : $0.sourceMode != .imported
            }
            .map(\.id) ?? []
        let manifest = try readRenderManifest(dataRoot: root, phase: phase)
        let proof = phase == "frames"
            ? nil
            : try readRenderProof(dataRoot: root, phase: phase)
        let frames = phase == "frames"
            ? nil
            : try? loadFramesManifest(dataRoot: root)
        var entries: [String: Any] = [:]
        for (sid, e) in manifest.entries {
            let entryProof = proof?.entries[sid]
            let currentOutput = phase == "frames"
                ? e.status == .rendered
                : shotlist?.shots.first(where: { $0.id == sid }).map {
                    isCurrentVideoRender(
                        e,
                        proof: entryProof,
                        shot: $0,
                        shotlist: shotlist!,
                        manifest: manifest,
                        frames: frames,
                        dataRoot: root
                    )
                } ?? false
            entries[sid] = [
                "shot_id": e.shotId,
                "phase": e.phase,
                "status": e.status.rawValue,
                "output": e.output.map { $0 as Any } ?? NSNull(),
                "current_output": currentOutput,
                "cost_eur": e.costEur,
                "updated_at": e.updatedAt.map { $0 as Any } ?? NSNull(),
                "generation_model": entryProof
                    .map { $0.generationModel as Any } ?? NSNull(),
                "output_sha256": entryProof
                    .map { $0.outputSha256 as Any } ?? NSNull(),
            ]
        }
        var rendered = 0
        var failed = 0
        var pending = 0
        for shotID in ordered {
            let entry = manifest.entries[shotID]
            let currentOutput = phase == "frames"
                ? entry?.status == .rendered
                : shotlist?.shots.first(where: {
                    $0.id == shotID
                }).map {
                    isCurrentVideoRender(
                        entry,
                        proof: proof?.entries[shotID],
                        shot: $0,
                        shotlist: shotlist!,
                        manifest: manifest,
                        frames: frames,
                        dataRoot: root
                    )
                } ?? false
            if currentOutput {
                rendered += 1
            } else if entry?.status == .failed {
                failed += 1
            } else {
                pending += 1
            }
        }
        return try jsonResult([
            "project": manifest.project,
            "phase": phase,
            "entries": entries,
            "summary": [
                "total": ordered.count,
                "rendered": rendered,
                "pending": pending,
                "failed": failed,
                "spent_eur": spent(manifest),
            ],
        ])
    }

    func getFramesManifestTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let url = PipelineLayout.url(PipelineLayout.framesManifestFile, in: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return try jsonResult(["exists": false, "shots": []])
        }
        let manifest: FramesManifest
        do {
            manifest = try loadFramesManifest(dataRoot: root)
        } catch {
            throw ToolError(
                "Couldn't read frames/manifest.json. Repair or restore it before continuing: \(error)"
            )
        }
        let home = FrameInventory.projectHome(of: root)
        let shots: [[String: Any]] = try manifest.shots.map { shot in
            let frames: [[String: Any]] = try shot.frames.map { frame in
                let resolved = resolveAuditedFrame(
                    shotId: shot.shotId,
                    role: frame.role,
                    explicitPath: frame.path,
                    home: home,
                    dataRoot: root
                )
                let digest = resolved.flatMap { item -> String? in
                    guard let data = try? Data(contentsOf: item.fileURL) else { return nil }
                    return SHA256.hash(data: data)
                        .map { String(format: "%02x", $0) }
                        .joined()
                }
                let audit = try readFrameAudit(
                    dataRoot: root,
                    shotId: shot.shotId,
                    role: frame.role
                )
                let mediaRef = resolved.flatMap { item in
                    editor.mediaAssets.first {
                        $0.url.standardizedFileURL.resolvingSymlinksInPath()
                            == item.fileURL.standardizedFileURL
                                .resolvingSymlinksInPath()
                    }?.id
                }
                var body: [String: Any] = [
                    "role": frame.role,
                    "path": frame.path,
                    "media_ref": mediaRef.map { $0 as Any } ?? NSNull(),
                    "prompt": frame.prompt,
                    "provider_prompt": frame.providerPrompt,
                    "model": frame.runwayModel,
                ]
                if let audit {
                    var auditBody = frameAuditJSON(audit, exists: true)
                    auditBody["current_image"] = digest == audit.renderSha256
                        && resolved != nil
                    body["audit"] = auditBody
                } else {
                    body["audit"] = ["exists": false, "current_image": false]
                }
                return body
            }
            return [
                "shot_id": shot.shotId,
                "keyframe_strategy": shot.keyframeStrategy,
                "frames": frames,
            ]
        }
        return try jsonResult([
            "exists": true,
            "schema": manifest.schema,
            "project": manifest.project,
            "generated": manifest.generated,
            "approval_mode": manifest.approvalMode,
            "shots": shots,
        ])
    }

    // MARK: - Frame vision-audit

    /// Record a vision-audit for a rendered keyframe and return the routing verdict. The agent judges
    /// (`status`/`observed`/`note` per check + `overall`); the machine measures — `render_sha256`,
    /// `generated`, each `expected` (from the shot spec), and `auto_rerender_attempt` are computed
    /// here and any agent-supplied values for them are ignored. Strict: all 10 standard check keys
    /// required, statuses enum-constrained, and `FrameAudit.validate()` enforces overall/worst-status
    /// consistency — violations come back verbatim for a fix-and-re-call.
    func saveFrameAuditTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let shotId = try args.requireString("shot_id")
        let role = args.string("role") ?? "start"
        guard role == "start" || role == "end" else {
            throw ToolError("Unknown role '\(role)'. Expected 'start' or 'end'.")
        }
        let auditor = try args.requireString("auditor")
        let overallRaw = try args.requireString("overall")
        guard let overall = AuditStatus(rawValue: overallRaw), overall != .pending else {
            throw ToolError("Unknown overall '\(overallRaw)'. Expected clean/minor/blocking.")
        }

        // Resolve the audited image: explicit `path` wins, else the frames manifest entry for this
        // shot+role. `render_path` is stored project-home-relative (where the media library lives);
        // `render_sha256` binds the audit to the exact bytes on disk.
        let home = FrameInventory.projectHome(of: root)
        guard let (fileURL, renderPath) = resolveAuditedFrame(
            shotId: shotId, role: role, explicitPath: args.string("path"), home: home, dataRoot: root)
        else {
            throw ToolError("No rendered frame found for \(shotId)-\(role). record_render the keyframe "
                + "first, or pass an explicit `path` to the image.")
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw ToolError("Rendered frame not readable on disk: \(fileURL.path).")
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        // Expected per standard check comes from the shot spec, never the model.
        let shotlist = try readShotlist(dataRoot: root)
        let shot = shotlist?.shots.first { $0.id == shotId }
        let expected = frameAuditExpected(
            for: shot,
            brief: try readBriefIfPresent(dataRoot: root),
            bible: try loadBible(dataRoot: root)
        )

        guard let rawChecks = args["checks"] as? [String: Any] else {
            throw ToolError("`checks` must be an object mapping each audit key to {status, observed, note}.")
        }
        var checks: [String: AuditCheck] = [:]
        for (key, value) in rawChecks {
            guard let cd = value as? [String: Any] else {
                throw ToolError("check '\(key)' must be an object with a `status`.")
            }
            guard let statusRaw = cd.string("status") else {
                throw ToolError("check '\(key)' is missing `status`.")
            }
            guard let status = AuditStatus(rawValue: statusRaw), status != .pending else {
                throw ToolError("check '\(key)' has invalid status '\(statusRaw)'. Expected clean/minor/blocking/n/a.")
            }
            checks[key] = AuditCheck(
                status: status,
                expected: expected[key] ?? (cd.string("expected") ?? ""),
                observed: cd.string("observed") ?? "",
                note: cd.string("note") ?? "")
        }
        let missing = standardAuditCheckKeys.filter { checks[$0] == nil }
        guard missing.isEmpty else {
            throw ToolError("`checks` is missing required standard keys: \(missing.joined(separator: ", ")). "
                + "All 10 must be present (use status \"n/a\" where the spec doesn't constrain it).")
        }

        // auto_rerender_attempt is machine-owned: bump only when a PRIOR blocking audit is being
        // replaced by a genuinely different render (new sha). Same sha, or a non-blocking prior,
        // preserves the counter. The model never touches it.
        let prior = try readFrameAudit(dataRoot: root, shotId: shotId, role: role)
        let attempt: Int = {
            guard let prior else { return 0 }
            let reRendered = prior.hasBlocking && prior.renderSha256 != sha
            return prior.autoRerenderAttempt + (reRendered ? 1 : 0)
        }()

        let audit: FrameAudit
        do {
            audit = try FrameAudit(
                shotId: shotId, role: role, renderPath: renderPath, renderSha256: sha,
                generated: currentTimestamp(), auditor: auditor, checks: checks, overall: overall,
                autoRerenderAttempt: attempt, autoRerenderPatch: args.string("auto_rerender_patch") ?? "")
        } catch let e as FrameAudit.ValidationError {
            throw ToolError("Frame audit rejected: \(frameAuditViolation(e)). Fix and re-call.")
        }
        do {
            try saveFrameAudit(audit, dataRoot: root)
        } catch {
            throw ToolError("Couldn't save frame audit: \(error)")
        }
        return try jsonResult(frameAuditJSON(audit, exists: true))
    }

    func getFrameAuditTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let shotId = try args.requireString("shot_id")
        let role = args.string("role") ?? "start"
        guard let audit = try readFrameAudit(
            dataRoot: root,
            shotId: shotId,
            role: role
        ) else {
            return try jsonResult(["exists": false, "shot_id": shotId, "role": role])
        }
        return try jsonResult(frameAuditJSON(audit, exists: true))
    }

    /// #199: deterministic render-larger-then-crop. Resolves the source frame (explicit path or the
    /// shot's recorded frame), crops it to the target aspect via the pure `planCrop` geometry, writes
    /// the result into the durable media library, and imports it as a usable asset. This is the
    /// invocation surface the ported `CropPlanner`/`FrameRasterizer` lacked (they were test-only).
    /// #166: cut the location's camera views out of ONE panorama, so the layout survives an angle
    /// change. Deterministic and free — the geometry is the product here, not a model's guess.
    func extractScene3dPovsTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let locationId = try args.requireString("location_id")
        try requirePipelineIdentifier(locationId, label: "location_id")

        let panoramaPath = args.string("panorama")?.nilIfEmpty
            ?? recordedPanorama(locationId: locationId, dataRoot: root)
        guard let panoramaPath else {
            throw ToolError("No panorama for location '\(locationId)'. Generate one with a `marble/` "
                + "model from a style-neutral clay wide, then pass `panorama` or record it as the "
                + "location's `scene3d.panorama` in the Bible.")
        }
        let panorama = try projectPipelineImage(
            panoramaPath,
            dataRoot: root,
            label: "panorama"
        )

        let povs = try parsePovSpecs(args["povs"])
        let width = args.int("width") ?? defaultPovSize.width
        let height = args.int("height") ?? defaultPovSize.height
        guard (64...4096).contains(width), (64...4096).contains(height) else {
            throw ToolError("POV width and height must each be between 64 and 4096 pixels.")
        }
        let outDir = root
            .appendingPathComponent("bible/\(locationId)/scene3d/povs_clay", isDirectory: true)

        let written: [String: URL]
        do {
            written = try PovExtractor.extractSet(
                panorama: panorama, to: outDir, povs: povs, width: width, height: height)
        } catch {
            throw ToolError("extract_scene3d_povs failed: \(error.localizedDescription)")
        }
        // The geometry, not just the files: the POV set as data, ready to be recorded on the
        // location's `scene3d`. `scene3d_geometry` warns if it never gets there, so this can't quietly
        // stay filenames-on-disk the way the old free-form map did (#166).
        let specs = povs ?? defaultFourWallPovs
        let extracted = specs.filter { written[$0.name] != nil }
        let panoramaRel = FrameInventory.relativePath(of: panorama, to: root)

        // #223's profile, reused exactly as intended — built once, used twice. The clay POV is
        // style-neutral; restyling it into the project's look is a COMPOSITION-PRESERVING pass (the
        // room's geometry is the whole point of having cut it from one panorama), so the instruction is
        // composed here rather than left to the agent to phrase.
        let style = args.string("style")?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? bibleLookStyle(dataRoot: root)
        var body: [String: Any] = [
            "location_id": locationId,
            "panorama": panoramaRel,
            "povs": written.mapValues { FrameInventory.relativePath(of: $0, to: root) },
            "size": ["width": width, "height": height],
            // Record THIS verbatim as the location's scene3d in the bible.
            "scene3d": [
                "panorama": panoramaRel,
                "provider": "marble",
                "povs": extracted.map { [
                    "name": $0.name, "yaw": $0.yawDegrees,
                    "pitch": $0.pitchDegrees, "fov": $0.fovHorizontalDegrees,
                ] },
            ],
        ]
        if let style {
            body["restyle"] = [
                "style": style,
                "instruction": RestylePrompt.instruction(style: style),
                "note": "Each POV is a style-NEUTRAL clay view cut from one panorama — that shared origin "
                    + "is what keeps the room's geometry identical across angles. Restyle each one with "
                    + "this instruction as the intent (it already carries the preservation rule), passing "
                    + "the clay POV as the reference image, then record the result as "
                    + "Location.sheets[<pov name>]. Never regenerate a view from scratch: that throws the "
                    + "geometry away and the walls stop agreeing.",
            ]
        }
        return try jsonResult(body)
    }

    /// The project's look style — the restyle target for a clay POV. nil when there's no bible/look yet.
    private func bibleLookStyle(dataRoot: URL) -> String? {
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        guard let bible = try? store.load(Bible.self, at: PipelineLayout.bibleFile) else { return nil }
        return bible.look.style.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    /// The location's recorded `scene3d.panorama`, if the Bible carries one.
    private func recordedPanorama(locationId: String, dataRoot: URL) -> String? {
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        guard let bible = try? store.load(Bible.self, at: PipelineLayout.bibleFile),
              let location = bible.locations.first(where: { $0.id == locationId })
        else { return nil }
        return location.scene3d.panorama.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    /// Custom camera set from the tool args; nil → the four cardinal walls.
    private func parsePovSpecs(_ raw: Any?) throws -> [PovSpec]? {
        guard let entries = raw as? [[String: Any]], !entries.isEmpty else { return nil }
        var seen: Set<String> = []
        return try entries.map { entry in
            guard let name = entry["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw ToolError("Every pov needs a non-empty `name` — it becomes the sheet key.") }
            try requirePipelineIdentifier(name, label: "pov.name")
            guard seen.insert(name).inserted else {
                throw ToolError("POV names must be unique.")
            }
            guard let yaw = (entry["yaw"] as? NSNumber)?.doubleValue else {
                throw ToolError("pov '\(name)' needs a numeric `yaw`.")
            }
            let pitch = (entry["pitch"] as? NSNumber)?.doubleValue ?? -5
            let fov = (entry["fov_h"] as? NSNumber)?.doubleValue ?? 75
            guard yaw.isFinite,
                  pitch.isFinite,
                  (-89...89).contains(pitch),
                  fov.isFinite,
                  (1...179).contains(fov) else {
                throw ToolError(
                    "pov '\(name)' needs finite yaw, pitch from -89 to 89, "
                        + "and fov_h from 1 to 179."
                )
            }
            return PovSpec(
                name: name,
                yawDegrees: yaw,
                pitchDegrees: pitch,
                fovHorizontalDegrees: fov)
        }
    }

    private func requirePipelineIdentifier(
        _ value: String,
        label: String
    ) throws {
        let stripped = value.replacingOccurrences(of: "_", with: "")
        guard !value.isEmpty,
              !stripped.isEmpty,
              stripped.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw ToolError("\(label) must contain only letters, numbers, and underscores.")
        }
    }

    private func projectPipelineImage(
        _ relativePath: String,
        dataRoot: URL,
        label: String
    ) throws -> URL {
        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path == relativePath,
              !path.isEmpty,
              !NSString(string: path).isAbsolutePath,
              !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ToolError("\(label) must be a normalized pipeline-relative image path.")
        }
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = dataRoot.appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              (try? candidate.resourceValues(
                forKeys: [.isRegularFileKey]
              ).isRegularFile) == true,
              ClipType(
                fileExtension: candidate.pathExtension.lowercased()
              ) == .image else {
            throw ToolError("\(label) must be a regular image inside the pipeline data root.")
        }
        return candidate
    }

    func cropToAspectTool(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let aspect = try args.requireString("aspect")
        let shotId = try args.requireString("shot_id")
        let role = args.string("role") ?? "start"
        let anchor = CropAnchor(rawValue: args.string("anchor") ?? "center") ?? .center
        let home = FrameInventory.projectHome(of: root)
        guard let shotlist = try readShotlist(dataRoot: root),
              let shot = shotlist.shots.first(where: { $0.id == shotId }) else {
            throw ToolError("No current shot '\(shotId)' is available for crop provenance.")
        }
        guard shot.sourceMode == .generated, shot.keyframeStrategy != .none else {
            throw ToolError("\(shotId) does not accept a generated Frames crop.")
        }
        let roles = shot.keyframeStrategy == .startEnd
            ? ["start", "end"]
            : ["start"]
        guard roles.contains(role) else {
            throw ToolError(
                "\(shotId) uses keyframe_strategy=\(shot.keyframeStrategy.rawValue); "
                    + "role '\(role)' is not valid for it."
            )
        }
        guard let (masterURL, _) = resolveAuditedFrame(
            shotId: shotId, role: role,
            explicitPath: args.string("path"), home: home, dataRoot: root)
        else {
            throw ToolError("No source image for crop_to_aspect. Pass `path`, or record the target "
                + "shot's requested frame first.")
        }
        let canonicalMaster = masterURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let sourceAsset = editor.mediaAssets.reversed().first {
            $0.url.standardizedFileURL.resolvingSymlinksInPath()
                == canonicalMaster
        }
        let projectKey = editor.projectId ?? root.standardizedFileURL
            .resolvingSymlinksInPath().path
        let shotFingerprint = try PromptCompiler.shotFingerprint(shot)
        let sourceInput = sourceAsset?.generationInput
        let providerPrompt = sourceInput?.prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let generationModel = sourceInput?.model.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard let sourceInput,
              sourceInput.promptShotId == shot.id,
              sourceInput.promptProjectKey == projectKey,
              sourceInput.promptShotFingerprint == shotFingerprint,
              !providerPrompt.isEmpty,
              !generationModel.isEmpty,
              ProductionPromptPolicy.stillPromptViolations(
                providerPrompt
              ).isEmpty,
              ComplianceLinter.lintLockedDirectives(
                providerPrompt,
                lockedDirectives: shot.stillProductionPromptRequirements
              ).isEmpty else {
            throw ToolError(
                "crop_to_aspect requires a current shot-bound generated image. "
                    + "Generate the wider frame for this shot first; an unbound Bible "
                    + "master cannot enter Frames directly."
            )
        }
        let mediaDir = home.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        let dest = mediaDir.appendingPathComponent(
            "\(masterURL.deletingPathExtension().lastPathComponent)-crop-\(aspect.replacingOccurrences(of: ":", with: "x")).png")
        let plan: CropPlan
        do {
            plan = try FrameRasterizer.generateCrop(masterPath: masterURL, dest: dest, targetAspect: aspect, anchor: anchor)
        } catch {
            throw ToolError("crop_to_aspect failed: \(error)")
        }
        let asset = try await requiredDurableAsset(
            for: dest,
            editor: editor,
            context: "crop_to_aspect created the crop but couldn't register it"
        )
        asset.generationInput = sourceInput
        return try jsonResult([
            "asset_id": asset.id,
            "output": FrameInventory.relativePath(of: dest, to: home),
            "aspect": aspect,
            "anchor": anchor.rawValue,
            "target_size": ["width": plan.targetSize.width, "height": plan.targetSize.height],
            "box": ["left": plan.box.left, "top": plan.box.top, "right": plan.box.right, "bottom": plan.box.bottom],
        ])
    }

    /// Locate the frame image to audit and its project-home-relative render path. Explicit `path`
    /// (absolute or home-relative) wins; otherwise the frames manifest's entry for this shot+role.
    private func resolveAuditedFrame(
        shotId: String, role: String, explicitPath: String?, home: URL, dataRoot: URL
    ) -> (fileURL: URL, renderPath: String)? {
        let canonicalHome = home.standardizedFileURL.resolvingSymlinksInPath()
        func projectImage(_ rawPath: String) -> (fileURL: URL, renderPath: String)? {
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty,
                  !path.split(separator: "/").contains("..") else { return nil }
            let candidates = path.hasPrefix("/")
                ? [URL(fileURLWithPath: path)]
                : [
                    home.appendingPathComponent(path),
                    dataRoot.appendingPathComponent(path),
                ]
            for candidate in candidates {
                let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(canonicalHome.path + "/"),
                      FileManager.default.fileExists(atPath: resolved.path),
                      ClipType(fileExtension: resolved.pathExtension.lowercased()) == .image
                else { continue }
                return (
                    resolved,
                    FrameInventory.relativePath(of: resolved, to: canonicalHome)
                )
            }
            return nil
        }
        if let p = explicitPath {
            return projectImage(p)
        }
        guard let manifest = try? loadFramesManifest(dataRoot: dataRoot),
              let frame = manifest.shot(shotId)?.frames.first(where: { $0.role == role }),
              !frame.path.isEmpty else { return nil }
        return projectImage(frame.path)
    }

    /// Machine-derived `expected` per standard audit key, from the shot spec. Port of the Python
    /// audit-skeleton derivation (`frames/audit.py::skeleton`). Empty shot ⇒ empty expecteds.
    private func frameAuditExpected(for shot: Shot?, brief: Brief?, bible: Bible?) -> [String: String] {
        guard let shot else { return [:] }
        let productionPlan = shot.productionPlan
        let blocking = shot.characterBlocking
        let blockingExpected = blocking
            .map {
                "\($0.characterRef)@\($0.position) (\($0.pose), gaze=\($0.gaze), "
                    + "anchor=\(productionPlan?.setAnchor(for: $0.characterRef) ?? ""), "
                    + "relation=\($0.relationToSet))"
            }
            .joined(separator: "; ")
        let gazeExpected = blocking
            .map { "\($0.characterRef): \($0.gaze)" }
            .joined(separator: "; ")
        var forbidden: [String] = []
        if !(brief?.allowTextOverlays ?? false) { forbidden.append("no text overlays / title cards") }
        forbidden.append("no characters beyond declared character_refs")
        return [
            "character_count": "\(ProductionDiscipline.visibleCharacterCount(shot, bible: bible))",
            "framing": shot.framing?.rawValue ?? "",
            "camera_angle": shot.cameraSetup?.angle.rawValue ?? "",
            "camera_height": shot.cameraSetup?.height.rawValue ?? "",
            "character_position": blockingExpected,
            "gaze": gazeExpected,
            "forbidden_elements": forbidden.joined(separator: "; "),
            "visible_zones": shot.visibleZones.joined(separator: ", "),
            "anchor_at_t0": "exact t=0 state: subject in start pose, no objects from later in the shot already visible",
            "proportion_anchor_match": "match figure-to-set scale of proportion_anchor_shot if set",
        ]
    }

    private func frameAuditJSON(_ a: FrameAudit, exists: Bool) -> [String: Any] {
        var checks: [String: Any] = [:]
        for (key, c) in a.checks {
            checks[key] = [
                "status": c.status.rawValue,
                "expected": c.expected,
                "observed": c.observed,
                "note": c.note,
            ]
        }
        return [
            "exists": exists,
            "shot_id": a.shotId,
            "role": a.role,
            "overall": a.overall.rawValue,
            "verdict": a.verdict.rawValue,
            "has_blocking": a.hasBlocking,
            "has_minor": a.hasMinor,
            "auto_rerender_attempt": a.autoRerenderAttempt,
            "attempts_left": a.attemptsLeft,
            "auditor": a.auditor,
            "render_sha256": a.renderSha256,
            "render_path": a.renderPath,
            "auto_rerender_patch": a.autoRerenderPatch,
            "checks": checks,
        ]
    }

    private func frameAuditViolation(_ e: FrameAudit.ValidationError) -> String {
        switch e {
        case .schemaUnknown(let s): return "unknown schema '\(s)'"
        case .roleUnknown(let r): return "unknown role '\(r)'"
        case .attemptNegative: return "auto_rerender_attempt must be >= 0"
        case .overallPending: return "overall=pending is not a valid end state"
        case .checkPending: return "a check still has status=pending — fill or mark it n/a"
        case .blockingCheckOverallNotBlocking(let o):
            return "overall='\(o)' is inconsistent with a blocking check — overall must be blocking"
        case .minorCheckOverallNotMinor(let o):
            return "overall='\(o)' is inconsistent with a minor check — overall must be minor (or blocking)"
        }
    }

    // MARK: - Beat-synced assembly

    /// Lay the phase's rendered shots onto a dedicated assembly video track, each cut snapped to a
    /// beat (a downbeat at a section boundary, a regular beat otherwise), and put the song on an
    /// audio track at frame 0 as the sync anchor. Re-runnable: rebuilds the assembly track in place
    /// rather than duplicating. The beat math is the engine's pure `BeatAssembly.plan`; this handler
    /// resolves each shot's rendered file, drives the timeline, and reports what landed and what was
    /// skipped.
    func assembleTimelineTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = args.string("phase") ?? "final"

        // Hard gate (terminal backstop): no assembly on an unapproved plan. Every phase up to and
        // including shotlist — which, for musicvideo, includes the analysis gate that itself requires
        // real measured beats/downbeats — must be approved before rendered shots hit the timeline.
        let gates = try readGates(dataRoot: root)
        do {
            try GateGuard.requireChain(gates, order: mergedPhaseOrder(dataRoot: root), through: "shotlist")
        } catch let blocked as GateBlocked {
            throw ToolError(blocked.message)
        }

        guard let grid = BeatAssembly.loadBeatGrid(dataRoot: root), !grid.beats.isEmpty else {
            throw ToolError("Run analysis first: no beat analysis found (expected analysis/<song>.json with beats). Run run_phase(\"analysis\").")
        }
        guard let shotlist = try readShotlist(dataRoot: root) else {
            throw ToolError("No shotlist yet. Plan the shots before assembling.")
        }
        let manifest = try readRenderManifest(dataRoot: root, phase: phase)

        let fps = editor.timeline.fps
        let tolerance = grid.bpm > 0 ? (60.0 / grid.bpm) / 2.0 : 0.25

        // Filter to shots with a placeable rendered output; carry section flags from the full shotlist.
        let shots = shotlist.shots
        var planInputs: [BeatAssembly.ShotInput] = []
        var assetForShot: [String: MediaAsset] = [:]
        var skipped: [(id: String, reason: String)] = []
        for (i, shot) in shots.enumerated() {
            let startsSection = i == 0
                || shot.section != shots[i - 1].section
                || BeatAssembly.nearSectionBoundary(shot.timeStart, sectionStarts: grid.sectionStarts, tolerance: tolerance)
            let endsSection = i == shots.count - 1
                || shots[i + 1].section != shot.section
                || BeatAssembly.nearSectionBoundary(shot.timeEnd, sectionStarts: grid.sectionStarts, tolerance: tolerance)

            guard let entry = manifest.entries[shot.id], entry.status == .rendered,
                  let output = entry.output, !output.isEmpty else {
                skipped.append((shot.id, "not rendered yet"))
                continue
            }
            guard let asset = try await requiredRenderedAsset(
                output,
                editor: editor,
                dataRoot: root
            ) else {
                skipped.append((shot.id, "rendered output not found on disk: \(output)"))
                continue
            }
            assetForShot[shot.id] = asset
            planInputs.append(.init(
                id: shot.id, timeStart: shot.timeStart, timeEnd: shot.timeEnd,
                startsSection: startsSection, endsSection: endsSection
            ))
        }
        guard !planInputs.isEmpty else {
            throw ToolError("No rendered shots yet for phase \"\(phase)\". Render shots and record_render them first, then assemble.")
        }

        let placements = BeatAssembly.plan(beats: grid.beats, downbeats: grid.downbeats, fps: fps, shots: planInputs)
        let song = try await resolveSongAsset(dataRoot: root, editor: editor)
        var sidecar = try loadAssemblySidecar(dataRoot: root)

        var placedCount = 0
        var songPlacedNow = false
        var songAlreadyPresent = false
        try editor.withTimelineSwap(actionName: "Assemble Timeline (Agent)") {
            // Dedicated assembly video track — reused across runs, cleared before each rebuild.
            let videoTrackId = ensureAssemblyTrack(editor, existingId: sidecar.videoTrackId, type: .video)
            sidecar.videoTrackId = videoTrackId
            if let vi = editor.timeline.tracks.firstIndex(where: { $0.id == videoTrackId }) {
                editor.timeline.tracks[vi].clips = []
            }
            for placement in placements {
                guard let asset = assetForShot[placement.shotId],
                      let vi = editor.timeline.tracks.firstIndex(where: { $0.id == videoTrackId }) else { continue }
                _ = editor.placeClip(
                    asset: asset, trackIndex: vi, startFrame: placement.startFrame,
                    durationFrames: placement.durationFrames, addLinkedAudio: false
                )
                placedCount += 1
            }

            // Song is the sync anchor at frame 0 — placed only when not already on an audio track.
            if let song {
                let songClips = editor.timeline.tracks
                    .filter { $0.type == .audio }
                    .flatMap(\.clips)
                    .filter { $0.mediaRef == song.id }
                songAlreadyPresent = songClips.count == 1
                    && songClips[0].startFrame == 0
                if songAlreadyPresent {
                    sidecar.audioTrackId = editor.timeline.tracks.first {
                        $0.type == .audio
                            && $0.clips.contains { $0.mediaRef == song.id }
                    }?.id
                } else {
                    for index in editor.timeline.tracks.indices
                    where editor.timeline.tracks[index].type == .audio {
                        editor.timeline.tracks[index].clips.removeAll {
                            $0.mediaRef == song.id
                        }
                    }
                }
                if !songAlreadyPresent {
                    let audioTrackId = ensureAssemblyTrack(editor, existingId: sidecar.audioTrackId, type: .audio)
                    sidecar.audioTrackId = audioTrackId
                    if let ai = editor.timeline.tracks.firstIndex(where: { $0.id == audioTrackId }) {
                        let songFrames = max(1, BeatAssembly.frame(seconds: grid.durationS, fps: fps))
                        _ = editor.placeClip(
                            asset: song, trackIndex: ai, startFrame: 0,
                            durationFrames: songFrames, addLinkedAudio: false
                        )
                        songPlacedNow = true
                    }
                }
            }
            try saveAssemblySidecar(sidecar, dataRoot: root)
        }

        let videoTrackIndex = sidecar.videoTrackId.flatMap { id in
            editor.timeline.tracks.firstIndex(where: { $0.id == id })
        }
        let totalFrames = placements.map { $0.startFrame + $0.durationFrames }.max() ?? 0

        var songSummary: Any = NSNull()
        if song != nil {
            let audioIndex = sidecar.audioTrackId.flatMap { id in
                editor.timeline.tracks.firstIndex(where: { $0.id == id })
            }
            songSummary = [
                "track_index": audioIndex.map { $0 as Any } ?? NSNull(),
                "placed": songPlacedNow,
                "already_present": songAlreadyPresent,
            ] as [String: Any]
        }

        let placementRows: [[String: Any]] = placements.map {
            [
                "shot_id": $0.shotId,
                "start_frame": $0.startFrame,
                "duration_frames": $0.durationFrames,
                "on_downbeat": $0.onDownbeat,
                "at_section_boundary": $0.atSectionBoundary,
            ]
        }
        let skippedRows: [[String: String]] = skipped.map { ["shot_id": $0.id, "reason": $0.reason] }

        return try jsonResult([
            "phase": phase,
            "fps": fps,
            "bpm": grid.bpm,
            "shots_placed": placedCount,
            "total_frames": totalFrames,
            "video_track_index": videoTrackIndex.map { $0 as Any } ?? NSNull(),
            "song_track": songSummary,
            "song_missing": song == nil,
            "placements": placementRows,
            "skipped": skippedRows,
        ])
    }

    /// Find the dedicated assembly track by its stored id (reused across runs) or create a fresh one
    /// — video at the top, audio appended. Returns the track's id.
    private func ensureAssemblyTrack(_ editor: EditorViewModel, existingId: String?, type: ClipType) -> String {
        if let id = existingId, editor.timeline.tracks.contains(where: { $0.id == id && $0.type == type }) {
            return id
        }
        let index = type == .audio
            ? editor.insertTrack(at: editor.timeline.tracks.count, type: .audio)
            : editor.insertTrack(at: 0, type: .video)
        return editor.timeline.tracks[index].id
    }

    private func nextFrameRole(
        shotlist: Shotlist,
        manifest: FramesManifest?,
        editor: EditorViewModel,
        dataRoot: URL
    ) async -> (shot: Shot, role: String)? {
        for shot in shotlist.shots where shot.sourceMode == .generated {
            let roles: [String]
            switch shot.keyframeStrategy {
            case .none: continue
            case .start: roles = ["start"]
            case .startEnd: roles = ["start", "end"]
            }
            let recorded = manifest?.shot(shot.id)
            for role in roles {
                guard recorded?.keyframeStrategy == shot.keyframeStrategy.rawValue,
                      let frame = recorded?.frames.first(where: { $0.role == role }),
                      !frame.providerPrompt
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !frame.runwayModel
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      ComplianceLinter.lintLockedDirectives(
                        frame.providerPrompt,
                        lockedDirectives: shot.stillProductionPromptRequirements
                      ).isEmpty,
                      ProductionPromptPolicy.stillPromptViolations(
                        frame.providerPrompt
                      ).isEmpty,
                      await resolveRenderedAsset(
                          frame.path,
                          editor: editor,
                          dataRoot: dataRoot
                      ) != nil else {
                    return (shot, role)
                }
            }
        }
        return nil
    }

    private func updatedFramesManifest(
        shot: Shot,
        asset: MediaAsset,
        role requestedRole: String?,
        shotlist: Shotlist,
        editor: EditorViewModel,
        dataRoot: URL
    ) throws -> FramesManifest {
        guard shot.sourceMode == .generated,
              shot.keyframeStrategy != .none else {
            throw ToolError(
                "\(shot.id) does not require generated keyframes."
            )
        }
        let role = requestedRole ?? "start"
        let roles = shot.keyframeStrategy == .startEnd
            ? ["start", "end"]
            : ["start"]
        guard roles.contains(role) else {
            throw ToolError(
                "\(shot.id) uses keyframe_strategy=\(shot.keyframeStrategy.rawValue); "
                    + "role '\(role)' is not valid for it."
            )
        }
        guard let gi = asset.generationInput else {
            throw ToolError(
                "The frame has no generation provenance. Record the completed result "
                    + "returned by generate_image or crop_to_aspect."
            )
        }
        guard !gi.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError(
                "The frame has no exact generation instruction and cannot enter the "
                    + "authoritative Frames manifest."
            )
        }
        let home = FrameInventory.projectHome(of: dataRoot)
        let entry = FrameEntry(
            role: role,
            path: FrameInventory.relativePath(of: asset.url, to: home),
            prompt: gi.intent ?? "",
            runwayModel: gi.model,
            approved: false,
            providerPrompt: gi.prompt,
            multiRefHints: [])
        let manifestURL = PipelineLayout.url(PipelineLayout.framesManifestFile, in: dataRoot)
        var existing: FramesManifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            do {
                existing = try loadFramesManifest(dataRoot: dataRoot)
            } catch {
                throw ToolError(
                    "Couldn't read frames/manifest.json. Repair or restore it "
                        + "before recording another frame: \(error)"
                )
            }
        } else {
            existing = FramesManifest(
                project: FrameInventory.projectName(of: dataRoot)
                    ?? shotlist.project,
                generated: currentTimestamp()
            )
        }
        let reconciled: FramesManifest
        do {
            reconciled = try existing.reconciled(with: shotlist)
        } catch {
            throw ToolError(
                "Couldn't reconcile the Frames manifest with the current "
                    + "shot list: \(error)"
            )
        }
        return reconciled.upserting(
            shotId: shot.id,
            keyframeStrategy: shot.keyframeStrategy.rawValue,
            frame: entry
        )
    }

    /// #231 — record the render's actual conditioning (start frame + image references) on the manifest
    /// entry, as project-home-relative paths, so a pure file-level check can compare them against the
    /// deterministic plan. Read off the submitted `GenerationInput` — the record of the real submission.
    ///
    /// Semantic slots are authoritative; model lookup is only for older generated media.
    private func stampRenderInputs(
        _ manifest: inout RenderManifest, shotId: String, output: String,
        asset: MediaAsset, shot: Shot, editor: EditorViewModel,
        dataRoot: URL
    ) throws -> RenderProofEntry {
        guard var entry = manifest.entries[shotId],
              let gi = asset.generationInput else {
            throw ToolError(
                "The rendered video has no generation provenance. Record the completed "
                    + "result returned by a schema-validated generate_video call."
            )
        }
        guard gi.promptShotId == shotId else {
            throw ToolError(
                "The rendered media was not compiled for shot '\(shotId)'. "
                    + "Generate it with that shotId before recording it."
            )
        }
        let projectKey = editor.projectId ?? dataRoot.standardizedFileURL
            .resolvingSymlinksInPath().path
        let shotFingerprint = try PromptCompiler.shotFingerprint(shot)
        guard gi.promptProjectKey == projectKey,
              gi.promptShotFingerprint == shotFingerprint else {
            throw ToolError(
                "The rendered media was not compiled for this project's current "
                    + "shot production plan. Generate it again before recording it."
            )
        }
        let providerPrompt = gi.prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let generationModel = gi.model.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !providerPrompt.isEmpty, !generationModel.isEmpty else {
            throw ToolError(
                "The rendered video has no compiled provider prompt or generation model."
            )
        }
        let requirements = manifest.phase == "frames"
            ? shot.stillProductionPromptRequirements
            : shot.videoProductionPromptRequirements
        let policyViolations = manifest.phase == "frames"
            ? ProductionPromptPolicy.stillPromptViolations(providerPrompt)
            : ProductionPromptPolicy.videoPromptViolations(
                providerPrompt,
                expectedMovement: shot.productionPlan?.cameraMovement,
                expectedMovementDetail: shot.productionPlan?.cameraMovementDetail
            )
        guard policyViolations.isEmpty else {
            throw ToolError(
                "The rendered media's provider prompt violates shot '\(shotId)'s "
                    + "current production plan: \(policyViolations.joined(separator: "; "))."
            )
        }
        guard ComplianceLinter.lintLockedDirectives(
            providerPrompt,
            lockedDirectives: requirements
        ).isEmpty else {
            throw ToolError(
                "The rendered media's provider prompt does not match shot '\(shotId)'s "
                    + "current production plan."
            )
        }
        let outputDigest: String
        do {
            outputDigest = try FileDigest.sha256(of: asset.url)
        } catch {
            throw ToolError(
                "The rendered video could not be fingerprinted: \(error)"
            )
        }
        let home = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        func inputProofs(
            _ assetIds: [String],
            label: String
        ) throws -> [RenderInputProof] {
            try assetIds.map { id in
                guard let source = editor.mediaAssets.first(where: {
                    $0.id == id
                }) else {
                    throw ToolError(
                        "\(label) '\(id)' is no longer in the open project's media library."
                    )
                }
                let url = source.url.standardizedFileURL
                    .resolvingSymlinksInPath()
                guard url.path.hasPrefix(home.path + "/"),
                      (try? url.resourceValues(
                        forKeys: [.isRegularFileKey]
                      ).isRegularFile) == true else {
                    throw ToolError(
                        "\(label) '\(source.name)' must be a regular file in the open project."
                    )
                }
                let digest: String
                do {
                    digest = try FileDigest.sha256(of: url)
                } catch {
                    throw ToolError(
                        "\(label) '\(source.name)' could not be fingerprinted: \(error)"
                    )
                }
                return RenderInputProof(
                    path: FrameInventory.relativePath(of: url, to: home),
                    sha256: digest
                )
            }
        }
        let imageURLIds = gi.imageURLAssetIds ?? []
        var sourceVideo: RenderInputProof?
        var startFrame: RenderInputProof?
        var endFrame: RenderInputProof?
        var referenceImages: [RenderInputProof] = []
        let hasSemanticVideoSlots = gi.sourceVideoAssetId != nil
            || gi.startFrameAssetId != nil
            || gi.endFrameAssetId != nil
            || gi.referenceImageAssetIds != nil
            || gi.referenceVideoAssetIds != nil
            || gi.referenceAudioAssetIds != nil
        if hasSemanticVideoSlots {
            sourceVideo = try inputProofs(
                gi.sourceVideoAssetId.map { [$0] } ?? [],
                label: "Source video"
            ).first
            startFrame = try inputProofs(
                gi.startFrameAssetId.map { [$0] } ?? [],
                label: "Video start frame"
            ).first
            endFrame = try inputProofs(
                gi.endFrameAssetId.map { [$0] } ?? [],
                label: "Video end frame"
            ).first
            referenceImages = try inputProofs(
                gi.referenceImageAssetIds ?? [],
                label: "Video image reference"
            )
            entry.startFramePath = startFrame?.path
            entry.referencePaths = referenceImages.map(\.path)
        } else {
            switch VideoModelConfig.allModels.first(where: { $0.id == gi.model }) {
            case .some(let model) where model.requiresSourceVideo:
                entry.startFramePath = nil
                let inputs = try inputProofs(
                    imageURLIds,
                    label: "Video-edit input"
                )
                sourceVideo = inputs.first
                referenceImages = Array(inputs.dropFirst())
                entry.referencePaths = referenceImages.map(\.path)
            case .some:
                let frames = try inputProofs(
                    imageURLIds,
                    label: "Video frame input"
                )
                startFrame = frames.first
                endFrame = frames.dropFirst().first
                referenceImages = try inputProofs(
                    gi.referenceImageAssetIds ?? [],
                    label: "Video image reference"
                )
                entry.startFramePath = startFrame?.path
                entry.referencePaths = referenceImages.map(\.path)
            case .none:
                entry.startFramePath = nil
                referenceImages = try inputProofs(
                    imageURLIds,
                    label: "Image reference"
                )
                entry.referencePaths = referenceImages.map(\.path)
            }
        }
        let referenceVideos = try inputProofs(
            gi.referenceVideoAssetIds ?? [],
            label: "Video reference"
        )
        let referenceAudio = try inputProofs(
            gi.referenceAudioAssetIds ?? [],
            label: "Audio reference"
        )
        manifest.entries[shotId] = entry
        return RenderProofEntry(
            shotId: shotId,
            output: output,
            outputSha256: outputDigest,
            providerPrompt: providerPrompt,
            generationModel: generationModel,
            sourceVideo: sourceVideo,
            startFrame: startFrame,
            endFrame: endFrame,
            referenceImages: referenceImages,
            referenceVideos: referenceVideos,
            referenceAudio: referenceAudio
        )
    }

    /// #196 — when the next shot in render order chains off this one, extract this rendered clip's last
    /// frame to a durable PNG beside the clip and stamp its project-home-relative path onto the render
    /// entry (`last_frame_path`). `next_render_shot` then hands that frame to the successor as its start
    /// frame. Silent on any miss (no shotlist, no successor chain, non-video output, extraction failure):
    /// continuity is an enhancement, never a reason to fail a recorded render.
    private func recordChainLastFrame(shotId: String, output: String, phase: String, editor: EditorViewModel, dataRoot: URL) async {
        guard let shotlist = (try? loadShotlist(dataRoot: dataRoot)) ?? nil,
              ChainContinuity.needsLastFrame(shotlist, shotId: shotId),
              let asset = await resolveRenderedAsset(
                output,
                editor: editor,
                dataRoot: dataRoot
              ) else { return }
        let dest = asset.url.deletingPathExtension().appendingPathExtension("last_frame.png")
        do {
            try await LastFrameExtractor.extractLastFrame(video: asset.url, dest: dest)
        } catch {
            return
        }
        let home = FrameInventory.projectHome(of: dataRoot)
        let rel = FrameInventory.relativePath(of: dest, to: home)
        guard var manifest = try? loadRenderManifest(dataRoot: dataRoot, phase: phase),
              var entry = manifest.entries[shotId] else { return }
        entry.lastFramePath = rel
        manifest.entries[shotId] = entry
        try? saveRenderManifest(manifest, dataRoot: dataRoot)
    }

    func resolveRenderedAsset(
        _ output: String,
        editor: EditorViewModel,
        dataRoot: URL
    ) async -> MediaAsset? {
        if let asset = editor.mediaAssets.first(where: { $0.id == output }) {
            return projectLocalRegularURL(
                asset.url,
                dataRoot: dataRoot
            ) == nil ? nil : asset
        }
        guard let fileURL = renderedFileURL(output, dataRoot: dataRoot),
              let target = projectLocalRegularURL(
                  fileURL,
                  dataRoot: dataRoot
              ) else { return nil }
        if let asset = existingProjectAsset(at: target, editor: editor) {
            return asset
        }
        return await editor.addMediaAsset(from: target)
    }

    private func requiredRenderedAsset(
        _ output: String,
        editor: EditorViewModel,
        dataRoot: URL
    ) async throws -> MediaAsset? {
        if let asset = await resolveRenderedAsset(
            output,
            editor: editor,
            dataRoot: dataRoot
        ) {
            return asset
        }
        guard renderedFileURL(output, dataRoot: dataRoot) != nil else {
            return nil
        }
        throw ToolError(
            "assemble_timeline found \(output) but couldn't register it "
                + "as a regular file inside the project"
        )
    }

    private func renderedFileURL(_ output: String, dataRoot: URL) -> URL? {
        let home = FrameInventory.projectHome(of: dataRoot)
        let candidates = output.hasPrefix("/")
            ? [URL(fileURLWithPath: output)]
            : [
                home.appendingPathComponent(output),
                dataRoot.appendingPathComponent(output),
                home.appendingPathComponent(Project.mediaDirectoryName).appendingPathComponent(output),
            ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func projectLocalRegularURL(
        _ fileURL: URL,
        dataRoot: URL
    ) -> URL? {
        let home = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let target = fileURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard target.path.hasPrefix(home.path + "/"),
              (try? target.resourceValues(
                  forKeys: [.isRegularFileKey]
              ).isRegularFile) == true else {
            return nil
        }
        return target
    }

    private func existingProjectAsset(
        at fileURL: URL,
        editor: EditorViewModel
    ) -> MediaAsset? {
        let target = fileURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let matches = editor.mediaAssets.reversed().filter {
            $0.url.standardizedFileURL.resolvingSymlinksInPath()
                == target
        }
        return matches.first
    }

    /// The single song in `audio/` as a media asset (imported once, reused after), or nil when there
    /// isn't exactly one song to anchor to.
    private func resolveSongAsset(
        dataRoot: URL,
        editor: EditorViewModel
    ) async throws -> MediaAsset? {
        let songs = AudioProjectLayout.songFiles(dataRoot: dataRoot)
        guard songs.count == 1, let songURL = songs.first else { return nil }
        if let anchorId = editor.mediaManifest.songAnchorAssetId,
           let anchored = editor.mediaAssets.first(where: { $0.id == anchorId }) {
            return anchored
        }
        let idsBefore = Set(editor.mediaAssets.map(\.id))
        let asset = try await requiredDurableAsset(
            for: songURL,
            editor: editor,
            context: "assemble_timeline found the project song but couldn't register it"
        )
        editor.mediaManifest.songAnchorAssetId = asset.id
        editor.mediaManifest.songAnchorOwnsAsset = !idsBefore.contains(asset.id)
        editor.mediaManifest.intakeRoleByAssetID[asset.id] = "song"
        return asset
    }

    private func requiredDurableAsset(
        for fileURL: URL,
        editor: EditorViewModel,
        context: String
    ) async throws -> MediaAsset {
        guard let asset = await existingOrImportedAsset(fileURL, editor: editor) else {
            let reason = editor.mediaPanelToast?.message ?? "the copied media could not be imported"
            throw ToolError("\(context): \(reason)")
        }
        return asset
    }

    /// Reuse the library asset already backed by `fileURL`, else import it.
    private func existingOrImportedAsset(
        _ fileURL: URL,
        editor: EditorViewModel
    ) async -> MediaAsset? {
        let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = editor.mediaAssets.first(where: {
            $0.url.standardizedFileURL.resolvingSymlinksInPath() == target
        }) {
            return existing
        }
        return await editor.addMediaAsset(from: fileURL)
    }

    /// Re-run state: the ids of the assembly video/audio tracks, persisted next to the other pipeline
    /// artifacts so a later session rebuilds the same tracks instead of appending new ones.
    private struct AssemblySidecar {
        var videoTrackId: String? = nil
        var audioTrackId: String? = nil
    }

    private func assemblySidecarURL(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("assembly.json")
    }

    private func loadAssemblySidecar(dataRoot: URL) throws -> AssemblySidecar {
        let url = assemblySidecarURL(dataRoot: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AssemblySidecar()
        }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return AssemblySidecar(
            videoTrackId: obj["video_track_id"] as? String,
            audioTrackId: obj["audio_track_id"] as? String
        )
    }

    private func saveAssemblySidecar(_ sidecar: AssemblySidecar, dataRoot: URL) throws {
        var obj: [String: Any] = [:]
        if let v = sidecar.videoTrackId { obj["video_track_id"] = v }
        if let a = sidecar.audioTrackId { obj["audio_track_id"] = a }
        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: assemblySidecarURL(dataRoot: dataRoot), options: .atomic)
    }

    // MARK: - Phase runner

    /// Dispatch a pack-registered phase runner for the active pack. Planning phases have no code
    /// runner (agent-driven) → the verbatim "no code runner" shape. When a runner exists (e.g.
    /// musicvideo's `analysis`), it runs OFF the main actor — decode + DSP of a full song takes
    /// seconds and ToolExecutor is @MainActor — then the persisted artifact is re-read into a
    /// summary (bpm, beats, sections, duration, path) for the agent.
    func runPhaseTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let phase = try args.requireString("phase")
        let root = try resolveDataRoot(args, editor: editor)

        // The pack follows the TARGET project (an explicit project_dir may point elsewhere);
        // ngv.json is the write-through source the editor property mirrors anyway. It lives in the
        // project PACKAGE (parent of `pipeline`), not the data root — resolve the home first.
        let registry = PackCatalog.registry(activePack: activePluginFor(dataRoot: root))
        AudioAnalysisRuntime.configure(registry)

        // #174: run the phase's engine-pinned deterministic steps FIRST — load-bearing operations the
        // agent can neither skip nor improvise (file intake into the right dir, the one-song contract,
        // the assembly hand-off). A step that throws blocks the phase with its actionable message.
        let steps = registry.deterministicSteps(forPhase: phase)
        let runDeterministicSteps: @Sendable (URL) throws -> Void = { dataRoot in
            for step in steps {
                do {
                    try step.run(dataRoot)
                } catch {
                    throw PipelinePhaseBlocked(
                        "\(phase) blocked by deterministic step '\(step.id)': "
                            + error.localizedDescription
                    )
                }
            }
        }
        let engineSteps: [[String: Any]] = steps.map { ["id": $0.id, "summary": $0.summary] }

        let runner = registry.phases[phase]
        if runner == nil, steps.isEmpty {
            return try jsonResult([
                "phase": phase,
                "runner": NSNull(),
                "engine_steps": engineSteps,
                "note": "no code runner registered; this phase is agent-driven",
            ])
        }

        let sourceFilename = AudioProjectLayout.songFiles(dataRoot: root)
            .first?
            .lastPathComponent
        let coordinatedRunner: EngineRegistry.PhaseRunner = { dataRoot in
            try runDeterministicSteps(dataRoot)
            try runner?(dataRoot)
        }
        let coordinatedProgressRunner: EngineRegistry.ProgressPhaseRunner?
        if runner != nil,
           let progressRunner = registry.progressPhaseRunners[phase] {
            coordinatedProgressRunner = { dataRoot, progress in
                try runDeterministicSteps(dataRoot)
                try progressRunner(dataRoot, progress)
            }
        } else {
            coordinatedProgressRunner = nil
        }
        let outcome = await editor.pipelinePhaseRunCoordinator.run(
            projectRoot: root,
            phase: phase,
            sourceFilename: sourceFilename,
            runner: coordinatedRunner,
            progressRunner: coordinatedProgressRunner,
            state: editor.pipelinePhaseExecution,
            settleOnce: {
                try await editor.pipelineAgentHarness.recordPhaseMutation(
                    phase: phase,
                    dataRoot: root,
                    captureLineage: true,
                    declaredPack: editor.declaredPluginName
                )
                await editor.refreshEngineState()
            }
        )
        withExtendedLifetime(registry) {}

        switch outcome {
        case .completed:
            break
        case .blocked(let message):
            throw ToolError(message)
        case .failed(let failure):
            throw ToolError("\(phase) failed: \(failure)")
        case .refused(let activePhase):
            throw ToolError(
                "run_phase was refused without executing \(phase): "
                    + "\(activePhase) is already running. Wait for it to finish, then retry."
            )
        }
        if runner == nil {
            return try jsonResult([
                "phase": phase,
                "runner": NSNull(),
                "engine_steps": engineSteps,
                "note": "no code runner, but \(steps.count) engine-owned step(s) ran once inside the phase job — orchestrate around them, don't repeat them",
            ])
        }
        return try jsonResult([
            "phase": phase, "ok": true, "engine_steps": engineSteps,
            "result": analysisSummary(dataRoot: root, phase: phase),
        ])
    }

    /// Read back the artifact the run just wrote (derived via the runner's own song discovery —
    /// never "first json in the folder", which could be a stale sibling). Falls back to a minimal
    /// shape if it can't be parsed (the write still succeeded).
    private func analysisSummary(dataRoot: URL, phase: String) -> [String: Any] {
        guard let artifact = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot),
            let data = try? Data(contentsOf: artifact),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ["phase": phase, "artifact": NSNull()]
        }
        func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
        func numbers(_ any: Any?) -> [Double] { (any as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [] }
        func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

        var summary: [String: Any] = ["artifact": artifact.path]
        if let bpm = number(obj["bpm"]) { summary["bpm"] = bpm }
        if let duration = number(obj["duration_s"]) { summary["duration_s"] = duration }
        let beats = numbers(obj["beats"])
        let downbeats = numbers(obj["downbeats"])
        summary["beats_count"] = beats.count
        summary["downbeats_count"] = downbeats.count
        // The MEASURED structural grid, handed to the agent verbatim so it never has to invent timing:
        // the downbeat times (bar anchors) and the section table with real start/end boundaries. Rounded
        // to milliseconds to keep the payload compact without losing beat-accuracy.
        summary["downbeats"] = downbeats.map(ms)
        summary["sections"] = (obj["sections"] as? [[String: Any]] ?? []).map { s -> [String: Any] in
            var out: [String: Any] = [:]
            if let i = (s["index"] as? NSNumber)?.intValue { out["index"] = i }
            if let start = number(s["start"]) { out["start"] = ms(start) }
            if let end = number(s["end"]) { out["end"] = ms(end) }
            out["label"] = (s["label"] as? String).map { $0 as Any } ?? NSNull()
            if let src = s["source"] as? String { out["source"] = src }
            return out
        }
        if let resolution = obj["structure_resolution"] as? [String: Any] {
            summary["structure_resolution"] = resolution
        }
        let diagnostics = obj["stage_diagnostics"] as? [[String: Any]] ?? []
        summary["stage_diagnostics"] = diagnostics.filter {
            guard let status = $0["status"] as? String else { return true }
            return status != "succeeded" && status != "not_applicable"
        }
        if let source = obj["downbeat_source"] as? String { summary["downbeat_source"] = source }
        if let project = obj["project"] as? String { summary["project"] = project }
        return summary
    }

    // MARK: - Attach song (WRITES)

    /// Attaches one durable project song and synchronizes its timeline anchor.
    func attachSongTool(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)

        let mediaRef = args.string("media")
        let path = args.string("path")
        let sourceCount = [mediaRef, path].compactMap { $0 }.count
        guard sourceCount == 1 else {
            throw ToolError("Provide exactly one of 'media' (a media-library asset id) or 'path' (an absolute file path) — got \(sourceCount).")
        }

        let sourceURL: URL
        let originalFilename: String
        if let mediaRef {
            // Resolve the asset's backing file the way the other media tools do (id prefixes were
            // already expanded on input). A downloading/generating asset has no file on disk yet.
            let asset = try asset(mediaRef, editor: editor, label: "Song asset")
            guard asset.type == .audio else {
                throw ToolError("Asset \(asset.id) is \(asset.type.rawValue), not audio. The analysis runner needs an audio file.")
            }
            guard let url = editor.mediaResolver.resolveURL(for: asset.id) ?? (FileManager.default.fileExists(atPath: asset.url.path) ? asset.url : nil) else {
                throw ToolError("Asset \(asset.id) has no file on disk yet (still importing/generating?). Poll get_media and retry once its generationStatus is 'none'.")
            }
            sourceURL = url.resolvingSymlinksInPath()
            originalFilename = asset.userFacingFilename
        } else {
            sourceURL = URL(fileURLWithPath: path!).resolvingSymlinksInPath()
            originalFilename = sourceURL.lastPathComponent
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw ToolError("File not found: \(sourceURL.path)")
            }
        }
        guard (try? sourceURL.resourceValues(
            forKeys: [.isRegularFileKey]
        ).isRegularFile) == true else {
            throw ToolError("Song source is not a regular file: \(sourceURL.path)")
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard AudioProjectLayout.audioExtensions.contains(ext) else {
            let accepted = AudioProjectLayout.audioExtensions.sorted().map { ".\($0)" }.joined(separator: "/")
            throw ToolError("'\(originalFilename)' isn't an audio type the analysis runner accepts (\(accepted)).")
        }

        let replace = args.bool("replace") ?? false
        let attached: SongAnchorResult
        do {
            attached = try await editor.attachProjectSong(
                from: sourceURL,
                dataRoot: root,
                replace: replace,
                originalFilename: originalFilename
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        return try jsonResult([
            "filename": attached.filename,
            "audio_dir": root.appendingPathComponent("audio").path,
            "asset_id": attached.assetId,
            "replaced": attached.replaced,
        ])
    }
}

extension String {
    /// nil for an empty string — so an absent value and a blank one are the same absence.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Map a `Brief` decode failure to a message naming the offending wire field and — for enums — its
/// allowed values, resolving the field through `BriefWriteContract` (which spans arrays via the coding
/// path, e.g. a bad `tone` element).
private func briefDecodeViolation(_ error: DecodingError, args: [String: Any]) -> String {
    func fieldKey(_ ctx: DecodingError.Context) -> String {
        for key in ctx.codingPath.reversed() where BriefWriteContract.field(key.stringValue) != nil {
            return key.stringValue
        }
        return ctx.codingPath.last?.stringValue ?? "(unknown)"
    }
    func got(_ key: String) -> String {
        switch args[key] {
        case let s as String: return ", got `\(s)`"
        case let n as NSNumber: return ", got `\(n)`"
        default: return ""
        }
    }
    switch error {
    case .keyNotFound(let key, _):
        return "missing required field `\(key.stringValue)`"
    case .valueNotFound(_, let ctx):
        return "missing required field `\(fieldKey(ctx))`"
    case .typeMismatch(_, let ctx):
        let key = fieldKey(ctx)
        return "field `\(key)`: expected \(BriefWriteContract.field(key)?.kind.typeWord ?? "a different type")\(got(key))"
    case .dataCorrupted(let ctx):
        let key = fieldKey(ctx)
        if let options = BriefWriteContract.field(key)?.enumOptions {
            return "field `\(key)`: expected one of [\(options.joined(separator: ", "))]\(got(key))"
        }
        return "field `\(key)`: \(ctx.debugDescription)"
    @unknown default:
        return "\(error)"
    }
}

/// Enforce the contract's enum options in the EXECUTOR, not just in the advertised schema. The JSON
/// schema's `enum` only tells the model what to send — nothing rejects a bad value on arrival. For most
/// fields the `Brief` decoder catches it anyway (they decode into Swift enums), but `project_mode` and
/// any future contract enum over a plain `String` property would sail straight through: `phrase` (which
/// no phase can execute) and outright typos were persisted. Gate every enum field here so enforcement
/// never depends on what the underlying stored type happens to be.
private func briefEnumViolation(_ field: BriefWriteContract.Field, value: Any) -> String? {
    guard let options = field.enumOptions else { return nil }
    func bad(_ got: String) -> String {
        "brief rejected — field `\(field.key)`: expected one of [\(options.joined(separator: ", "))], got `\(got)`. "
            + "Nothing was written; fix and re-call."
    }
    switch value {
    case let s as String:
        return options.contains(s) ? nil : bad(s)
    case let array as [Any]:
        for element in array {
            guard let s = element as? String else { return bad("\(element)") }
            if !options.contains(s) { return bad(s) }
        }
        return nil
    default:
        return bad("\(value)")
    }
}

private func briefValidationViolation(_ error: Brief.ValidationError) -> String {
    switch error {
    case .budgetNotPositive(let value):
        return "field `budget_eur`: must be greater than 0 (got \(value))."
    case .budgetStopNotPositive(let value):
        return "field `budget_stop_eur`: must be greater than 0 when set (got \(value)); omit it for no hard stop."
    case .visualMediumNotesRequired(let medium):
        return "field `visual_medium_notes` is required when `visual_medium` is `\(medium.rawValue)` (a stylized medium — give a concrete style note)."
    }
}
