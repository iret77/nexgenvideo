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
    private func resolveDataRoot(_ args: [String: Any], editor: EditorViewModel) throws -> URL {
        let dir: URL
        if let path = args.string("project_dir") {
            dir = URL(fileURLWithPath: path)
        } else if let open = editor.workingRoot {
            dir = open
        } else {
            throw ToolError("No project is open and no project_dir was given.")
        }
        guard let root = DataRootResolver.dataRoot(of: dir) else {
            throw ToolError("Not a project (no pipeline/project.yaml): \(dir.path). Run init_project first.")
        }
        return root
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

    /// JSON `.ok` result from a Foundation object graph.
    private func jsonResult(_ object: Any) throws -> ToolResult {
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
        let data = try NativeCockpitReader.sanityJSON(dataRoot: root, activePack: activePluginFor(dataRoot: root))
        return .ok(String(decoding: data, as: UTF8.self))
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
        do {
            try YAMLArtifactStore(dataRoot: root).save(brief, to: PipelineLayout.briefFile)
        } catch {
            throw ToolError("Couldn't write brief.yaml: \(error.localizedDescription)")
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
            home = URL(fileURLWithPath: hd)
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
        let fromRel = try args.requireString("from")
        let toRel = try args.requireString("to")
        let from = try Self.resolveInside(root, fromRel)
        let to = try Self.resolveInside(root, toRel)
        guard FileManager.default.fileExists(atPath: from.path) else {
            throw ToolError("Source not found: '\(fromRel)'.")
        }
        do {
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if from.standardizedFileURL != to.standardizedFileURL {
                if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
                try FileManager.default.copyItem(at: from, to: to)
            }
        } catch {
            throw ToolError("Couldn't copy '\(fromRel)' → '\(toRel)': \(error.localizedDescription)")
        }
        return try jsonResult(["from": fromRel, "to": toRel])
    }

    // MARK: - Gates (WRITES)

    func approveGateTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        let notes = args.string("notes")
        try enforceGateRequirement(phase: phase, dataRoot: root, declaredPack: editor.activePluginName)
        let gates = try mutateGates(dataRoot: root) { GatesOperations.approve(&$0, phase: phase, notes: notes) }
        let gate = gates.get(phase)
        return try jsonResult([
            "project": gates.project,
            "phase": phase,
            "approved": gate.approved,
            "state": gate.state.rawValue,
            "approved_at": gate.approvedAt.map { $0 as Any } ?? NSNull(),
            "approved_by": gate.approvedBy.map { $0 as Any } ?? NSNull(),
            "notes": gate.notes.map { $0 as Any } ?? NSNull(),
        ])
    }

    func setGateStateTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        let stateRaw = try args.requireString("state")
        guard let state = GateState(rawValue: stateRaw) else {
            throw ToolError("Unknown state '\(stateRaw)'. Expected approved/approved_with_notes/needs_revision/pending.")
        }
        let notes = args.string("notes")
        // set_gate_state is an approval path too — enforce the same hard-gate precondition when it
        // would mark the phase approved, so it can't be used to bypass approve_gate's guard.
        if state == .approved || state == .approvedWithNotes {
            try enforceGateRequirement(phase: phase, dataRoot: root, declaredPack: editor.activePluginName)
        }
        let gates = try mutateGates(dataRoot: root) { GatesOperations.setState(&$0, phase: phase, state: state, notes: notes) }
        let gate = gates.get(phase)
        return try jsonResult([
            "project": gates.project,
            "phase": phase,
            "state": gate.state.rawValue,
            "approved": gate.approved,
            "notes": gate.notes.map { $0 as Any } ?? NSNull(),
        ])
    }

    /// Deterministic hard-gate check shared by approve_gate and set_gate_state: consult the active
    /// pack's registered precondition for `phase` and surface a `GateBlocked` as an actionable tool
    /// error. No requirement registered (prose phases) ⇒ approvable on the user's judgement.
    private func enforceGateRequirement(phase: String, dataRoot: URL, declaredPack: String?) throws {
        let resolved = activePluginFor(dataRoot: dataRoot)
        let registry = PackCatalog.registry(activePack: resolved)
        let gates = (try? YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile))
            ?? Gates(project: "")
        do {
            // FAIL-CLOSED first: a project that declares a pack must have it wired, or NO step approves.
            try GateGuard.requireWiredPack(declared: declaredPack, resolved: resolved, registry: registry)
            // In order (no approving a phase before its predecessors), then the phase's own artifact.
            try GateGuard.requirePriorApproved(gates, order: mergedPhaseOrder(dataRoot: dataRoot), phase: phase)
            try GateGuard.checkApprovable(phase: phase, dataRoot: dataRoot, requirement: registry.gateRequirements[phase])
        } catch let blocked as GateBlocked {
            throw ToolError(blocked.message)
        }
    }

    func rewindTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let target = try args.requireString("target_phase")
        // Rewind over the merged order (core + pack, at declared placement) so a pack phase like
        // `analysis` is a valid target and resets its correct downstream span.
        let order = mergedPhaseOrder(dataRoot: root)
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
        var ledger = (try? store.load(Ledger.self, at: PipelineLayout.ledgerFile)) ?? Ledger()
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
        // Optional project override; resolve loosely (a missing/unopened project just means no override).
        let dataRoot: URL? = {
            if let path = args.string("project_dir") { return DataRootResolver.dataRoot(of: URL(fileURLWithPath: path)) }
            return editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        }()
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

    func nextRenderShotTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        let shotlist = (try? loadShotlist(dataRoot: root)) ?? nil
        // live_action shots are never provider-rendered — the user shoots and cuts them, so they're
        // excluded from the render queue. ai_enhanced shots ARE returned: they need a provider pass
        // (video-to-video) over the imported footage.
        let ordered = shotlist?.shots.filter { $0.sourceMode != .imported }.map(\.id) ?? []
        let manifest = (try? loadRenderManifest(dataRoot: root, phase: phase)) ?? RenderManifest(project: shotlist?.project ?? "", phase: phase)
        guard let shotId = nextUnrendered(orderedShotIds: ordered, manifest: manifest) else {
            return try jsonResult(["phase": phase, "shot_id": NSNull(), "done": true])
        }
        let shot = shotlist?.shots.first { $0.id == shotId }

        // #198 — the OPTIONAL hard spending stop. Enforced here, at the tool boundary that hands a
        // shot out for rendering: the last point before money is spent, and the same seam the
        // consistency machinery uses. No stop set → nothing is blocked, only reported.
        if let verdict = budgetStopVerdict(dataRoot: root, phase: phase, shotId: shotId, shotlist: shotlist),
           verdict.overBudget {
            throw ToolError(
                "Budget stop reached — render refused. This shot's estimated "
                + String(format: "€%.2f", verdict.newRunEur)
                + " would take the project to " + String(format: "€%.2f", verdict.projectTotalEur)
                + ", over the user's limit of " + String(format: "€%.2f", verdict.budgetEur)
                + " (already spent: " + String(format: "€%.2f", verdict.alreadySpentEur) + "). "
                + "Do NOT work around this: tell the user, and let them raise the limit, drop shots, "
                + "or pick a cheaper model.")
        }

        var body: [String: Any] = [
            "phase": phase,
            "shot_id": shotId,
            "done": false,
            "source_mode": shot.map { $0.sourceMode.rawValue as Any } ?? (NSNull() as Any),
            "visual_prompt": shot.map { $0.visualPrompt as Any } ?? (NSNull() as Any),
            "framing": shot?.framing.map { $0.rawValue as Any } ?? (NSNull() as Any),
            // #166: the structured camera triplet projected into ready prose, so the shot's declared
            // camera is compiled from the spec (deterministic), not reconstructed by the agent.
            "camera": shot?.cameraSetup.map { $0.promptProse() as Any } ?? (NSNull() as Any),
            "chain_with_previous_end": shot?.chainWithPreviousEnd ?? false,
        ]
        // #213: cut handles as content. When the plan puts a fade/crossfade on a side (or the global
        // override forces it), the shot renders overlap material there — so the agent orders the GROSS
        // duration from the model and trims the timeline clip to the NET window. Hard-cut shots carry no
        // handle (gross == net) and are unchanged. The temporal structure is composed into the prompt by
        // compile_prompt(shotId); here the agent gets the durations to order and to place.
        if let shot {
            let forceHandles = (try? YAMLArtifactStore(dataRoot: root).load(Brief.self, at: PipelineLayout.briefFile))?
                .cutHandlesMode == .withOverlap
            let h = CutHandles.handles(for: shot, forceAll: forceHandles)
            // Only a HANDLED shot gets a render_duration_s. A hard-cut shot is ordered exactly as it was
            // before this change — emitting a rounded duration for it too would tell the agent to order
            // a second the estimate doesn't price, re-opening the same under-estimation against the
            // pre-flight budget stop. Rounding a bare fractional net is an older question, not this one's.
            if h.pre > 0 || h.post > 0 {
                body["net_duration_s"] = shot.durationS
                // Already a whole second — ordered as-is. Rounding happens here, not as a prose plea:
                // a beat-derived net is often fractional and would otherwise be unorderable.
                body["render_duration_s"] = CutHandles.orderableGrossDuration(for: shot, forceAll: forceHandles)
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
        if let shotlist, let shot, shot.chainWithPreviousEnd,
           let predId = ChainContinuity.chainPredecessor(shotlist, shotId: shotId),
           let lastFrame = manifest.entries[predId]?.lastFramePath,
           let asset = resolveRenderedAsset(lastFrame, editor: editor, dataRoot: root) {
            body["chain_start_frame_media_ref"] = asset.id
            body["chain_start_frame_path"] = lastFrame
        }
        // #195: the deterministic reference plan for this shot — bible sheets scored by view priority
        // plus inherited identity-anchor frames stacked on top (multi-shot character consistency). Each
        // planned ref is resolved to a media_ref the agent passes straight to the generate tool's
        // referenceImageMediaRefs, so the ported planner drives the render instead of the agent guessing.
        if let plan = PackCatalog.registry(activePack: activePluginFor(dataRoot: root))
            .referencePlanProvider?.planReferences(dataRoot: root, shotId: shotId) {
            var refImages: [[String: Any]] = []
            for ref in plan.refs {
                guard let asset = resolveRenderedAsset(ref.path, editor: editor, dataRoot: root) else { continue }
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

    func recordRenderTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        let shotId = try args.requireString("shot_id")
        let output = args.string("output")
        let costEur = args.double("cost_eur") ?? 0.0
        let statusRaw = args.string("status") ?? "rendered"
        guard let status = RenderStatus(rawValue: statusRaw) else {
            throw ToolError("Unknown status '\(statusRaw)'. Expected rendered/pending/failed.")
        }
        var manifest = (try? loadRenderManifest(dataRoot: root, phase: phase)) ?? RenderManifest(project: "", phase: phase)
        record(&manifest, shotId: shotId, output: output, costEur: costEur, status: status, phase: phase)
        // #231: stamp what this render was ACTUALLY conditioned on, so `plan_adherence` can audit it
        // against what `next_render_shot` planned. Read off the submitted GenerationInput — the record
        // of the real submission — not off the agent's say-so.
        if status == .rendered, let output, !output.isEmpty {
            stampRenderInputs(&manifest, shotId: shotId, output: output, editor: editor, dataRoot: root)
        }
        do {
            try saveRenderManifest(manifest, dataRoot: root)
        } catch {
            throw ToolError("Couldn't save render manifest: \(error)")
        }
        // A recorded keyframe render also lands in the frames manifest with its exact
        // compiled provider prompt (for the frame_ratio / frame_size / builder_bypass
        // checks). Best-effort sidecar — never fail the render record over it.
        if phase == "frames", status == .rendered, let output, !output.isEmpty {
            recordFrameManifest(shotId: shotId, output: output, role: args.string("role"), editor: editor, dataRoot: root)
        }
        // #196: if the shot immediately after this one chains off it (`chain_with_previous_end`), extract
        // this clip's last frame now and record it on the entry — `next_render_shot` feeds it as the
        // successor's start frame. Best-effort — never fail the render record over it.
        if status == .rendered, let output, !output.isEmpty {
            await recordChainLastFrame(shotId: shotId, output: output, phase: phase, editor: editor, dataRoot: root)
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
        let shotlist = (try? loadShotlist(dataRoot: root)) ?? nil
        let ordered = shotlist?.shots.map(\.id) ?? []
        let manifest = (try? loadRenderManifest(dataRoot: root, phase: phase)) ?? RenderManifest(project: shotlist?.project ?? "", phase: phase)
        var entries: [String: Any] = [:]
        for (sid, e) in manifest.entries {
            entries[sid] = [
                "shot_id": e.shotId,
                "phase": e.phase,
                "status": e.status.rawValue,
                "output": e.output.map { $0 as Any } ?? NSNull(),
                "cost_eur": e.costEur,
                "updated_at": e.updatedAt.map { $0 as Any } ?? NSNull(),
            ]
        }
        let s = summary(orderedShotIds: ordered, manifest: manifest)
        return try jsonResult([
            "project": manifest.project,
            "phase": phase,
            "entries": entries,
            "summary": [
                "total": s.total,
                "rendered": s.rendered,
                "pending": s.pending,
                "failed": s.failed,
                "spent_eur": s.spentEur,
            ],
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
        let shotlist = (try? loadShotlist(dataRoot: root)) ?? nil
        let shot = shotlist?.shots.first { $0.id == shotId }
        let expected = frameAuditExpected(for: shot, brief: loadBriefIfAny(dataRoot: root))

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
        let prior = (try? loadFrameAudit(dataRoot: root, shotId: shotId, role: role)) ?? nil
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
        guard let audit = (try? loadFrameAudit(dataRoot: root, shotId: shotId, role: role)) ?? nil else {
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
        let home = FrameInventory.projectHome(of: root)

        // The panorama: explicit, else whatever the bible recorded for this location.
        let panorama: URL
        if let path = args.string("panorama"), !path.isEmpty {
            panorama = path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
        } else if let recorded = recordedPanorama(locationId: locationId, dataRoot: root) {
            panorama = recorded.hasPrefix("/")
                ? URL(fileURLWithPath: recorded) : home.appendingPathComponent(recorded)
        } else {
            throw ToolError("No panorama for location '\(locationId)'. Generate one with a `marble/` "
                + "model from a style-neutral clay wide, then pass `panorama` or record it as the "
                + "location's `scene3d.panorama` in the Bible.")
        }

        let povs = try parsePovSpecs(args["povs"])
        let width = args.int("width") ?? defaultPovSize.width
        let height = args.int("height") ?? defaultPovSize.height
        let outDir = home
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
        let panoramaRel = FrameInventory.relativePath(of: panorama, to: home)

        // #223's profile, reused exactly as intended — built once, used twice. The clay POV is
        // style-neutral; restyling it into the project's look is a COMPOSITION-PRESERVING pass (the
        // room's geometry is the whole point of having cut it from one panorama), so the instruction is
        // composed here rather than left to the agent to phrase.
        let style = args.string("style")?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? bibleLookStyle(dataRoot: root)
        var body: [String: Any] = [
            "location_id": locationId,
            "panorama": panoramaRel,
            "povs": written.mapValues { FrameInventory.relativePath(of: $0, to: home) },
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
        return try entries.map { entry in
            guard let name = entry["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw ToolError("Every pov needs a non-empty `name` — it becomes the sheet key.") }
            guard let yaw = (entry["yaw"] as? NSNumber)?.doubleValue else {
                throw ToolError("pov '\(name)' needs a numeric `yaw`.")
            }
            return PovSpec(
                name: name,
                yawDegrees: yaw,
                pitchDegrees: (entry["pitch"] as? NSNumber)?.doubleValue ?? -5,
                fovHorizontalDegrees: (entry["fov_h"] as? NSNumber)?.doubleValue ?? 75)
        }
    }

    /// The optional budget stop (#198), evaluated for the shot about to be handed out.
    ///
    /// `nil` when the user set no limit — the overwhelmingly common case, and deliberately the
    /// default: without an amount there is only cost INFO, never a block. `Brief.budgetEur` is NOT
    /// used for this; it defaults to 50 on every project, so gating on it would impose a limit
    /// nobody chose.
    ///
    /// The check is pre-flight: this shot's ESTIMATE plus what the project already spent, against
    /// the limit — so the stop lands before the money is gone rather than one shot after.
    private func budgetStopVerdict(
        dataRoot: URL, phase: String, shotId: String, shotlist: Shotlist?
    ) -> CostGuardVerdict? {
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        guard let brief = try? store.load(Brief.self, at: PipelineLayout.briefFile),
              let stop = brief.budgetStopEur, stop > 0,
              let shotlist, let phaseValue = Phase(rawValue: phase)
        else { return nil }
        // The bundled prices — the same source the rest of the cost machinery uses (Checks,
        // ExpandingCamera); there is no per-project costs.yaml in this port.
        let costs = CostsConfig.bundledDefault
        let projected = estimate(
            shotlist: shotlist, costs: costs, phase: phaseValue,
            finalResolution: brief.finalResolution.rawValue,
            forceHandles: brief.cutHandlesMode == .withOverlap)
        let shotEur = projected.shotEstimates.first { $0.shotId == shotId }?.eur ?? 0
        return costGuardCheck(
            dataRoot: dataRoot, estimateEur: shotEur, phase: phaseValue, budgetEur: stop,
            guard: costs.costGuard)
    }

    func cropToAspectTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let aspect = try args.requireString("aspect")
        let anchor = CropAnchor(rawValue: args.string("anchor") ?? "center") ?? .center
        let home = FrameInventory.projectHome(of: root)
        guard let (masterURL, _) = resolveAuditedFrame(
            shotId: args.string("shot_id") ?? "", role: args.string("role") ?? "start",
            explicitPath: args.string("path"), home: home, dataRoot: root)
        else {
            throw ToolError("No source image for crop_to_aspect. Pass `path`, or a `shot_id` whose frame "
                + "is recorded in the frames manifest.")
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
        let asset = existingOrImportedAsset(durableMediaURL(for: dest, editor: editor), editor: editor)
        return try jsonResult([
            "asset_id": asset.map { $0.id as Any } ?? NSNull(),
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
        if let p = explicitPath {
            if p.hasPrefix("/") {
                let url = URL(fileURLWithPath: p)
                return (url, FrameInventory.relativePath(of: url, to: home))
            }
            return (home.appendingPathComponent(p), p)
        }
        guard let manifest = try? loadFramesManifest(dataRoot: dataRoot),
              let frame = manifest.shot(shotId)?.frames.first(where: { $0.role == role }),
              !frame.path.isEmpty else { return nil }
        return (home.appendingPathComponent(frame.path), frame.path)
    }

    /// Machine-derived `expected` per standard audit key, from the shot spec. Port of the Python
    /// audit-skeleton derivation (`frames/audit.py::skeleton`). Empty shot ⇒ empty expecteds.
    private func frameAuditExpected(for shot: Shot?, brief: Brief?) -> [String: String] {
        guard let shot else { return [:] }
        let blocking = shot.characterBlocking
        let blockingExpected = blocking
            .map { "\($0.characterRef)@\($0.position) (\($0.pose), gaze=\($0.gaze))" }
            .joined(separator: "; ")
        let gazeExpected = blocking
            .map { "\($0.characterRef): \($0.gaze)" }
            .joined(separator: "; ")
        var forbidden: [String] = []
        if !(brief?.allowTextOverlays ?? false) { forbidden.append("no text overlays / title cards") }
        forbidden.append("no characters beyond declared character_refs")
        return [
            "character_count": "\(shot.characterRefs.count)",
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

    /// The brief if one is saved, else nil (audit works without it — forbidden_elements just assumes
    /// text overlays are disallowed).
    private func loadBriefIfAny(dataRoot: URL) -> Brief? {
        try? YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
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
    func assembleTimelineTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = args.string("phase") ?? "final"

        // Hard gate (terminal backstop): no assembly on an unapproved plan. Every phase up to and
        // including shotlist — which, for musicvideo, includes the analysis gate that itself requires
        // real measured beats/downbeats — must be approved before rendered shots hit the timeline.
        let gates = (try? YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile))
            ?? Gates(project: "")
        do {
            try GateGuard.requireChain(gates, order: mergedPhaseOrder(dataRoot: root), through: "shotlist")
        } catch let blocked as GateBlocked {
            throw ToolError(blocked.message)
        }

        guard let grid = BeatAssembly.loadBeatGrid(dataRoot: root), !grid.beats.isEmpty else {
            throw ToolError("Run analysis first: no beat analysis found (expected analysis/<song>.json with beats). Run run_phase(\"analysis\").")
        }
        guard let shotlist = (try? loadShotlist(dataRoot: root)) ?? nil else {
            throw ToolError("No shotlist yet. Plan the shots before assembling.")
        }
        let manifest = (try? loadRenderManifest(dataRoot: root, phase: phase))
            ?? RenderManifest(project: shotlist.project, phase: phase)

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
            guard let asset = resolveRenderedAsset(output, editor: editor, dataRoot: root) else {
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
        let song = resolveSongAsset(dataRoot: root, editor: editor)
        var sidecar = loadAssemblySidecar(dataRoot: root)

        var placedCount = 0
        var songPlacedNow = false
        var songAlreadyPresent = false
        editor.withTimelineSwap(actionName: "Assemble Timeline (Agent)") {
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
                songAlreadyPresent = editor.timeline.tracks.contains { track in
                    track.type == .audio && track.clips.contains { $0.mediaRef == song.id && $0.startFrame == 0 }
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
        }
        saveAssemblySidecar(sidecar, dataRoot: root)

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

    /// Resolve a render-manifest output into a placeable media asset. Accepts an in-library asset id,
    /// an absolute path, or a path relative to the project home / data root / media dir. Reuses an
    /// existing asset for the same file so re-runs don't pile up duplicate library entries. Returns
    /// nil for a remote URL or a file that isn't on disk (the caller skips that shot).
    /// Capture a recorded keyframe render in the frames manifest with the EXACT compiled
    /// provider prompt (pulled off the resolved asset's `GenerationInput`), so the frame
    /// sanity checks have real data. Frame `path` is project-home-relative (where the media
    /// library lives). `role` defaults to "start" — `record_render` is per-shot-per-phase,
    /// so a start_end shot's end frame only differentiates if the tool passes `role`.
    /// Silent on any miss: the audit sidecar must never break recording a render.
    private func recordFrameManifest(shotId: String, output: String, role: String?, editor: EditorViewModel, dataRoot: URL) {
        guard let asset = resolveRenderedAsset(output, editor: editor, dataRoot: dataRoot),
              let gi = asset.generationInput else { return }
        let home = FrameInventory.projectHome(of: dataRoot)
        let entry = FrameEntry(
            role: role ?? "start",
            path: FrameInventory.relativePath(of: asset.url, to: home),
            prompt: gi.intent ?? "",
            runwayModel: gi.model,
            approved: false,
            providerPrompt: gi.prompt,
            multiRefHints: [])
        let ks = ((try? loadShotlist(dataRoot: dataRoot)) ?? nil)?
            .shots.first { $0.id == shotId }?.keyframeStrategy.rawValue ?? "start"
        let manifest = ((try? loadFramesManifest(dataRoot: dataRoot))
            ?? FramesManifest(project: FrameInventory.projectName(of: dataRoot) ?? "", generated: currentTimestamp()))
            .upserting(shotId: shotId, keyframeStrategy: ks, frame: entry)
        try? saveFramesManifest(manifest, dataRoot: dataRoot)
    }

    /// #231 — record the render's actual conditioning (start frame + image references) on the manifest
    /// entry, as project-home-relative paths, so a pure file-level check can compare them against the
    /// deterministic plan. Read off the submitted `GenerationInput` — the record of the real submission.
    ///
    /// `imageURLAssetIds` is overloaded across the three submission shapes, so it cannot be read
    /// blindly: only text-to-video puts frame slots there. Getting this wrong doesn't lose the audit, it
    /// INVERTS it — a render that used every planned reference would be stamped as having used none and
    /// then reported as ignoring the plan. Silent on any miss: the audit trail must never break
    /// recording a render.
    private func stampRenderInputs(
        _ manifest: inout RenderManifest, shotId: String, output: String, editor: EditorViewModel,
        dataRoot: URL
    ) {
        guard var entry = manifest.entries[shotId],
              let asset = resolveRenderedAsset(output, editor: editor, dataRoot: dataRoot),
              let gi = asset.generationInput else { return }
        let home = FrameInventory.projectHome(of: dataRoot)
        func paths(_ assetIds: [String]) -> [String] {
            assetIds.compactMap { id in
                editor.mediaAssets.first { $0.id == id }
                    .map { FrameInventory.relativePath(of: $0.url, to: home) }
            }
        }
        let imageURLIds = gi.imageURLAssetIds ?? []
        // Branch on the MODEL, never on whether `referenceImageAssetIds` happens to be nil: it is nil
        // both for a source-video edit AND for a text-to-video render that simply had no refs, and those
        // two need opposite readings of `imageURLAssetIds`.
        switch VideoModelConfig.allModels.first(where: { $0.id == gi.model }) {
        case .some(let model) where model.requiresSourceVideo:
            // Edit / v2v: `imageURLAssetIds` is [sourceVideo] + imageRefs. The source video is not a
            // start frame — stamping it as one would mis-fire the chain check too.
            entry.startFramePath = nil
            entry.referencePaths = paths(Array(imageURLIds.dropFirst()))
        case .some:
            // Text-to-video / image-to-video: `imageURLAssetIds` is the frame slots, start frame first;
            // image refs are kept separate.
            entry.startFramePath = paths(Array(imageURLIds.prefix(1))).first
            entry.referencePaths = paths(gi.referenceImageAssetIds ?? [])
        case .none:
            // Not a video model → image generation (`ImageGenerationSubmission.make`), i.e. the `frames`
            // phase: every reference rides in `imageURLAssetIds`, and there is no start frame.
            entry.startFramePath = nil
            entry.referencePaths = paths(imageURLIds)
        }
        manifest.entries[shotId] = entry
    }

    /// #196 — when the next shot in render order chains off this one, extract this rendered clip's last
    /// frame to a durable PNG beside the clip and stamp its project-home-relative path onto the render
    /// entry (`last_frame_path`). `next_render_shot` then hands that frame to the successor as its start
    /// frame. Silent on any miss (no shotlist, no successor chain, non-video output, extraction failure):
    /// continuity is an enhancement, never a reason to fail a recorded render.
    private func recordChainLastFrame(shotId: String, output: String, phase: String, editor: EditorViewModel, dataRoot: URL) async {
        guard let shotlist = (try? loadShotlist(dataRoot: dataRoot)) ?? nil,
              ChainContinuity.needsLastFrame(shotlist, shotId: shotId),
              let asset = resolveRenderedAsset(output, editor: editor, dataRoot: dataRoot) else { return }
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

    private func resolveRenderedAsset(_ output: String, editor: EditorViewModel, dataRoot: URL) -> MediaAsset? {
        if let asset = editor.mediaAssets.first(where: { $0.id == output }) { return asset }
        let home = FrameInventory.projectHome(of: dataRoot)
        let candidates: [URL]
        if output.hasPrefix("/") {
            candidates = [URL(fileURLWithPath: output)]
        } else {
            candidates = [
                home.appendingPathComponent(output),
                dataRoot.appendingPathComponent(output),
                home.appendingPathComponent(Project.mediaDirectoryName).appendingPathComponent(output),
            ]
        }
        guard let fileURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        return existingOrImportedAsset(durableMediaURL(for: fileURL, editor: editor), editor: editor)
    }

    /// A render lives in the ephemeral working copy (Recovery), which is deleted on a clean close — a
    /// timeline clip referencing it there would go offline on reopen. Copy any file outside the package
    /// into the package's `media/` (the durable, self-contained media home) and reference that copy.
    private func durableMediaURL(for fileURL: URL, editor: EditorViewModel) -> URL {
        editor.durableProjectMediaURL(for: fileURL)
    }

    /// The single song in `audio/` as a media asset (imported once, reused after), or nil when there
    /// isn't exactly one song to anchor to.
    private func resolveSongAsset(dataRoot: URL, editor: EditorViewModel) -> MediaAsset? {
        let songs = AudioProjectLayout.songFiles(dataRoot: dataRoot)
        guard songs.count == 1, let songURL = songs.first else { return nil }
        return existingOrImportedAsset(durableMediaURL(for: songURL, editor: editor), editor: editor)
    }

    /// Reuse the library asset already backed by `fileURL`, else import it.
    private func existingOrImportedAsset(_ fileURL: URL, editor: EditorViewModel) -> MediaAsset? {
        let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = editor.mediaAssets.first(where: {
            $0.url.standardizedFileURL.resolvingSymlinksInPath() == target
        }) {
            return existing
        }
        return editor.addMediaAsset(from: fileURL)
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

    private func loadAssemblySidecar(dataRoot: URL) -> AssemblySidecar {
        guard let data = try? Data(contentsOf: assemblySidecarURL(dataRoot: dataRoot)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AssemblySidecar()
        }
        return AssemblySidecar(
            videoTrackId: obj["video_track_id"] as? String,
            audioTrackId: obj["audio_track_id"] as? String
        )
    }

    private func saveAssemblySidecar(_ sidecar: AssemblySidecar, dataRoot: URL) {
        var obj: [String: Any] = [:]
        if let v = sidecar.videoTrackId { obj["video_track_id"] = v }
        if let a = sidecar.audioTrackId { obj["audio_track_id"] = a }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: assemblySidecarURL(dataRoot: dataRoot), options: .atomic)
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
        registry.registerAudioDecoder(AVFoundationAudioDecoder())
        // On-device speech recognition (whisper.cpp) for forced lyric alignment. The pack's analysis
        // runner resolves it from the registry; the model downloads on demand on first use.
        registry.registerTranscriber(WhisperCppTranscriber())
        // On-device vocal isolation (HT-Demucs FT via ONNX Runtime) so transcription reads the clean
        // voice, not the full mix. Model downloads on demand on first use.
        registry.registerStemSeparator(DemucsStemSeparator())
        // On-device neural beat/downbeat tracking (Beat This! via ONNX Runtime) — supersedes the DSP
        // grid when it looks valid. Model downloads on demand on first use.
        registry.registerBeatDetector(BeatThisDetector())
        // On-device chord recognition (BTC via ONNX, CQT baked into the graph) → analysis.chord_progression.
        // Model downloads on demand on first use; absent/offline degrades to no chords.
        registry.registerChordRecognizer(ChordRecognizer())

        // #174: run the phase's engine-pinned deterministic steps FIRST — load-bearing operations the
        // agent can neither skip nor improvise (file intake into the right dir, the one-song contract,
        // the assembly hand-off). A step that throws blocks the phase with its actionable message.
        let steps = registry.deterministicSteps(forPhase: phase)
        for step in steps {
            do {
                try step.run(root)
            } catch {
                return try jsonResult([
                    "phase": phase, "error": "deterministic_step_failed",
                    "step": step.id, "detail": String(describing: error),
                ])
            }
        }
        let engineSteps: [[String: Any]] = steps.map { ["id": $0.id, "summary": $0.summary] }

        guard let runner = registry.phases[phase] else {
            return try jsonResult([
                "phase": phase,
                "runner": NSNull(),
                "engine_steps": engineSteps,
                "note": engineSteps.isEmpty
                    ? "no code runner registered; this phase is agent-driven"
                    : "no code runner, but \(steps.count) engine-owned step(s) already ran — orchestrate around them, don't repeat them",
            ])
        }

        // Run the heavy decode+DSP off the main actor. Keep `registry` alive across the await so
        // the runner's weak decoder reference stays valid for the whole run. The error is
        // stringified inside the task so nothing non-Sendable crosses the actor boundary.
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                try runner(root)
                return nil
            } catch {
                return String(describing: error)
            }
        }.value
        withExtendedLifetime(registry) {}

        if let failure {
            return try jsonResult(["phase": phase, "error": "phase_failed", "detail": failure])
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
        if let source = obj["downbeat_source"] as? String { summary["downbeat_source"] = source }
        if let project = obj["project"] as? String { summary["project"] = project }
        return summary
    }

    // MARK: - Attach song (WRITES)

    /// Copy the song into the project's `audio/` folder — the one place the musicvideo `analysis`
    /// runner reads from (import_media only reaches the media library). Source is either a
    /// media-library asset (`media`, resolved to its backing file like the other media tools) or an
    /// absolute `path`; exactly one. Enforces the runner's one-song contract: a different existing
    /// audio file is an error unless `replace` is set, in which case the existing audio is cleared
    /// first. Returns `{filename, audio_dir}`.
    func attachSongTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)

        let mediaRef = args.string("media")
        let path = args.string("path")
        let sourceCount = [mediaRef, path].compactMap { $0 }.count
        guard sourceCount == 1 else {
            throw ToolError("Provide exactly one of 'media' (a media-library asset id) or 'path' (an absolute file path) — got \(sourceCount).")
        }

        let sourceURL: URL
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
            sourceURL = url
        } else {
            sourceURL = URL(fileURLWithPath: path!)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw ToolError("File not found: \(sourceURL.path)")
            }
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard AudioProjectLayout.audioExtensions.contains(ext) else {
            let accepted = AudioProjectLayout.audioExtensions.sorted().map { ".\($0)" }.joined(separator: "/")
            throw ToolError("'\(sourceURL.lastPathComponent)' isn't an audio type the analysis runner accepts (\(accepted)).")
        }

        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        } catch {
            throw ToolError("Couldn't prepare audio/: \(error.localizedDescription)")
        }

        let destURL = audioDir.appendingPathComponent(sourceURL.lastPathComponent)
        let replace = args.bool("replace") ?? false

        // The song may ALREADY be the file in audio/ — never delete-then-copy onto the source.
        let alreadyInPlace = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
            == destURL.standardizedFileURL.resolvingSymlinksInPath()

        // The runner keeps exactly one song in audio/. A different existing audio file blocks unless
        // `replace` is set. VALIDATE up front (fail with no side effects), but don't delete the old
        // song yet — the new one is copied into place first, so a failed copy never leaves audio/ empty.
        let others = existingAudioFiles(in: audioDir)
            .filter { $0.lastPathComponent != destURL.lastPathComponent }
        if !others.isEmpty, !replace {
            let names = others.map(\.lastPathComponent).sorted().joined(separator: ", ")
            throw ToolError("audio/ already holds a different song (\(names)). Pass replace: true to swap it — the analysis runner keeps exactly one song.")
        }

        if !alreadyInPlace {
            // A same-NAMED file in audio/ is still a DIFFERENT song when the source is another
            // file — overwriting it without consent breaks the tool contract just like the
            // different-name case above.
            if !replace, FileManager.default.fileExists(atPath: destURL.path) {
                throw ToolError("audio/ already holds \(destURL.lastPathComponent). Pass replace: true to overwrite it — the analysis runner keeps exactly one song.")
            }
            // Stage next to the destination, then swap in — a failed copy never destroys an
            // existing same-named song. replaceItemAt requires an existing destination, so the
            // first attach into an empty audio/ is a plain move.
            let staging = audioDir.appendingPathComponent(".attach-\(UUID().uuidString).\(sourceURL.pathExtension)")
            do {
                try FileManager.default.copyItem(at: sourceURL, to: staging)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    _ = try FileManager.default.replaceItemAt(destURL, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: destURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw ToolError("Couldn't copy the song into audio/: \(error.localizedDescription)")
            }
        }

        // The new song is safely in place — now retire the other old songs (validated above). A
        // leftover would block analysis later while this call reported success.
        for url in others {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw ToolError("Couldn't remove \(url.lastPathComponent) from audio/: \(error.localizedDescription)") }
        }

        // Same anchor as the dialog path — how the song arrived must not decide whether the user can
        // hear it. Idempotent: assemble_timeline reuses this asset and skips its own placement.
        editor.agentService.anchorSongOnTimeline(destURL, editor: editor)
        return try jsonResult(["filename": destURL.lastPathComponent, "audio_dir": audioDir.path])
    }

    /// Audio files already sitting in `audioDir` (by the runner's accepted extensions).
    private func existingAudioFiles(in audioDir: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return entries.filter {
            let isFile = (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            return isFile && AudioProjectLayout.audioExtensions.contains($0.pathExtension.lowercased())
        }
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
