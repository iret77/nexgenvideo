import Foundation
import NexGenEngine

// In-process native reader for every cockpit read kind — no venv, no Python, no subprocess. Each
// function returns raw JSON bytes in the SAME shape the former Python read CLI emitted, so the Cockpit
// panel decoders consume it unchanged.
//
// Parity is proven in NexGenEngineTests: the `state` bytes here match the committed state.json golden
// (a frozen fixture from the Python oracle; see Tests/NexGenEngineTests/Goldens/README.md).
enum NativeCockpitReader {

    /// True for the kinds served natively — which, after M7, is every cockpit read kind. Retained as
    /// the CockpitDataService entry gate; there is no non-native path.
    static func servesNatively(_ kind: String) -> Bool {
        [
            "state", "phases", "contract", "router", "brief", "treatment",
            "bible", "shotlist", "sanity", "frames", "ledger", "cost",
        ].contains(kind)
    }

    /// The project's data root (`<projectDir>/_studio` in the v2 layout, or the flat dir), or nil
    /// when `projectDir` is not a project yet — mirrors `read.py`'s `data_root_of` precheck.
    static func dataRoot(of projectDir: URL) -> URL? {
        DataRootResolver.dataRoot(of: projectDir)
    }

    enum NativeError: Error, Sendable, Equatable {
        case notInitialized
        case encode(String)
        case load(String)
    }

    // MARK: - Projectless kinds

    /// `read.py` "phases": the ordered pipeline (JSON array of strings) — the core order with the
    /// active pack's declared gate phases merged in at their placement (e.g. musicvideo's `analysis`
    /// right after `project_init`). Deliberately deviates from the retired Python `mcp_server.phases()`
    /// append-order; see `PhaseOrder.merged`.
    static func phasesJSON(activePack: String? = nil) throws -> Data {
        try serialize(mergedPhaseOrder(activePack: activePack))
    }

    /// The merged pipeline order for a project's active pack — the single ordering helper every
    /// cockpit surface (phases, state, cost, rewind) routes through.
    static func mergedPhaseOrder(activePack: String?) -> [String] {
        PhaseOrder.merged(packPlacements: packPlacements(activePack: activePack))
    }

    /// The active pack's declared phase placements (position included), for the merged order.
    static func packPlacements(activePack: String?) -> [PhasePlacement] {
        PackCatalog.registry(activePack: activePack).phasePlacements
    }

    /// `read.py` "contract": `{surfaces:[...], phases:{phase:{surface, task_class}}}`.
    /// `core.ui_contract.full_contract()` overlaid with the active pack's entries.
    static func contractJSON(activePack: String? = nil) throws -> Data {
        let packEntries = PackCatalog.registry(activePack: activePack).uiContracts
        let contract = UIContract.fullContract(packEntries: packEntries)
        var phases: [String: Any] = [:]
        for (phase, entry) in contract {
            phases[phase] = ["surface": entry.surface, "task_class": entry.taskClass]
        }
        return try serialize(["surfaces": UIContract.surfaces, "phases": phases])
    }

    /// `read.py` "router": `core.router.describe()` — `{tiers:{...}, task_classes:{name:{tier, effort}}}`.
    static func routerJSON(dataRoot: URL? = nil) throws -> Data {
        var taskClasses: [String: Any] = [:]
        for tc in ModelRouter.taskClasses {
            taskClasses[tc.name] = ["tier": tc.tier, "effort": tc.effort]
        }
        return try serialize(["tiers": ModelRouter.manifest(dataRoot: dataRoot), "task_classes": taskClasses])
    }

    // MARK: - Project kinds

    /// `read.py` "state": `mcp_server.project_state()` → `ProjectState.model_dump()` (snake_case, no
    /// aliasing). Phase order is the core order with the active pack's phases merged in at their
    /// declared placement (see `PhaseOrder.merged`).
    static func stateJSON(dataRoot: URL, activePack: String? = nil) throws -> Data {
        let snapshot: ProjectStateBuilder.ProjectState
        do {
            snapshot = try ProjectStateBuilder.buildSnapshot(
                dataRoot: dataRoot, packPlacements: packPlacements(activePack: activePack)
            )
        } catch {
            throw NativeError.notInitialized
        }
        return try serialize(stateDictionary(snapshot))
    }

    /// The `ProjectState.model_dump()` dictionary shape — extracted so the parity test can build the
    /// same bytes the CLI/golden carry. Keys and gate-state raw strings match `state.py` exactly.
    static func stateDictionary(_ s: ProjectStateBuilder.ProjectState) -> [String: Any] {
        let phases: [[String: Any]] = s.phases.map { p in
            [
                "phase": p.phase,
                "approved": p.approved,
                "state": p.state.rawValue,
                "notes": p.notes.map { $0 as Any } ?? NSNull(),
            ]
        }
        return [
            "project": s.project,
            "mode": s.mode,
            "budget_eur": s.budgetEur,
            "budget_spent_eur": s.budgetSpentEur,
            "budget_remaining_eur": s.budgetRemainingEur,
            "phases": phases,
            "next_phase": s.nextPhase.map { $0 as Any } ?? NSNull(),
        ]
    }

    /// `read.py` "brief": the Brief loaded via the engine, re-encoded to the CLI's
    /// `model_dump(by_alias=True, mode="json")` shape (schema alias, snake_case). Literal `null` when
    /// no brief exists yet (mirrors read.py's `FileNotFoundError → None`).
    static func briefJSON(dataRoot: URL) throws -> Data {
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        let brief: Brief
        do {
            brief = try store.load(Brief.self, at: StudioLayout.briefFile)
        } catch {
            // A missing brief.yaml is the not-yet-drafted state → literal null (like read.py).
            let url = StudioLayout.url(StudioLayout.briefFile, in: dataRoot)
            if !FileManager.default.fileExists(atPath: url.path) {
                return Data("null".utf8)
            }
            throw NativeError.load("brief")
        }
        // The engine Brief is JSON-encodable in the by-alias shape already (CodingKeys carry the
        // Python names); a standard encoder omits nil optionals, which the tolerant BriefData decoder
        // accepts. Emit sorted keys for stable output.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(brief)
    }

    /// `read.py` "treatment": `{meta:{...}, body_markdown:...}` — the latest treatment, or literal
    /// `null` when none exists (read.py's `glob("treatment/v*.md")` precheck).
    static func treatmentJSON(dataRoot: URL) throws -> Data {
        let treatment: Treatment
        do {
            treatment = try TreatmentStore.load(dataRoot: dataRoot)
        } catch {
            return Data("null".utf8)
        }
        // meta re-encoded via its Codable (by-alias CodingKeys), wrapped with body_markdown.
        let metaData = try JSONEncoder().encode(treatment.meta)
        let metaObject = try JSONSerialization.jsonObject(with: metaData)
        return try serialize(["meta": metaObject, "body_markdown": treatment.bodyMarkdown])
    }

    /// `read.py` "bible": `mcp_server.bible` → `Bible.model_dump(by_alias=True)` or literal `null`.
    /// The engine Bible's CodingKeys carry the Python snake_case names, so a standard encoder emits
    /// the by-alias shape the BibleData decoder expects.
    static func bibleJSON(dataRoot: URL) throws -> Data {
        guard let bible = try? loadBible(dataRoot: dataRoot) else {
            return Data("null".utf8)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(bible)
    }

    /// `read.py` "shotlist": the latest shotlist `model_dump(by_alias=True, mode="json")`, or literal
    /// `null` when none exists yet.
    static func shotlistJSON(dataRoot: URL) throws -> Data {
        guard let shotlist = try? loadShotlist(dataRoot: dataRoot) else {
            return Data("null".utf8)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(shotlist)
    }

    /// `read.py` "ledger": `ledger.schema.load(...).model_dump(by_alias=True, mode="json")` —
    /// `{schema, objects}`. Missing ledger.yaml loads the empty default (never null).
    static func ledgerJSON(dataRoot: URL) throws -> Data {
        let ledger = loadLedger(dataRoot: dataRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ledger)
    }

    /// `read.py` "frames": `frames.inventory.inventory(...)` → `{project, shots:[{shot_id, frames:
    /// [{name, path}], audit}]}`. The audit passthrough is a YAML mapping (or null).
    static func framesJSON(dataRoot: URL) throws -> Data {
        let inventory = try FrameInventory.inventory(projectDir: dataRoot)
        let shots: [[String: Any]] = inventory.shots.map { shot in
            [
                "shot_id": shot.shotId,
                "frames": shot.frames.map { ["name": $0.name, "path": $0.path] },
                "audit": shot.audit.map { yamlToJSONObject($0) } ?? NSNull(),
            ]
        }
        return try serialize(["project": inventory.project, "shots": shots])
    }

    /// `read.py` "sanity": `mcp_server.run_sanity` → `{project, findings:[{level, code, shot_id,
    /// message}]}`, or `{error:"no shotlist", project_dir}` when there's no shotlist yet.
    static func sanityJSON(dataRoot: URL, activePack: String? = nil) throws -> Data {
        guard let shotlist = try? loadShotlist(dataRoot: dataRoot) else {
            return try serialize(["error": "no shotlist", "project_dir": dataRoot.path])
        }
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        let brief = try? store.load(Brief.self, at: StudioLayout.briefFile)
        let bible = (try? loadBible(dataRoot: dataRoot)) ?? nil
        // Core checks plus the active pack's checks (e.g. music tempo/pacing), mirroring the Python
        // core-checks + discover_packs() gather.
        let checks = PackCatalog.registry(activePack: activePack).sanityChecks
        let report = audit(
            AuditContext(shotlist: shotlist, brief: brief, bible: bible),
            checks: checks
        )
        let findings: [[String: Any]] = report.findings.map { f in
            [
                "level": f.level.rawValue,
                "code": f.code,
                "shot_id": f.shotId.map { $0 as Any } ?? NSNull(),
                "message": f.message,
            ]
        }
        return try serialize(["project": report.project, "findings": findings])
    }

    /// `read.py` "cost": `mcp_server.estimate_cost` → the spent/remaining budget picture (NOT the
    /// forward per-shot estimate). `{project, budget_eur, spent_eur, remaining_eur, over_budget,
    /// next_phase}`.
    static func costJSON(dataRoot: URL, activePack: String? = nil) throws -> Data {
        return try serialize(costDictionary(dataRoot: dataRoot, activePack: activePack))
    }

    /// The `estimate_cost` return dict — shared by the cost read kind and the `estimate_cost` tool.
    /// `next_phase` walks the merged phase order (core + pack), so a musicvideo project's open
    /// `analysis` gate is honored rather than hidden.
    static func costDictionary(dataRoot: URL, activePack: String? = nil) throws -> [String: Any] {
        let snapshot: ProjectStateBuilder.ProjectState
        do {
            snapshot = try ProjectStateBuilder.buildSnapshot(
                dataRoot: dataRoot, packPlacements: packPlacements(activePack: activePack)
            )
        } catch {
            throw NativeError.notInitialized
        }
        let spent = alreadySpentInProject(dataRoot: dataRoot)
        return [
            "project": snapshot.project,
            "budget_eur": snapshot.budgetEur,
            "spent_eur": spent,
            "remaining_eur": max(0.0, snapshot.budgetEur - spent),
            "over_budget": spent > snapshot.budgetEur,
            "next_phase": snapshot.nextPhase.map { $0 as Any } ?? NSNull(),
        ]
    }

    /// The Intent Ledger loaded from `ledger.yaml`, or the empty default when the file is missing —
    /// mirrors `ledger.schema.load` (never raises for an absent file).
    static func loadLedger(dataRoot: URL) -> Ledger {
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        return (try? store.load(Ledger.self, at: StudioLayout.ledgerFile)) ?? Ledger()
    }

    /// A YAMLValue passthrough (the frame-audit mapping) as a Foundation JSON object graph.
    static func yamlToJSONObject(_ value: YAMLValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d
        case .string(let s): return s
        case .sequence(let arr): return arr.map { yamlToJSONObject($0) }
        case .mapping(let map):
            var out: [String: Any] = [:]
            for (k, v) in map { out[k] = yamlToJSONObject(v) }
            return out
        }
    }

    // MARK: - Serialization

    /// JSON bytes for a Foundation object graph. `.sortedKeys` for deterministic output; key SPELLING
    /// (not order) is what the decoders and goldens care about.
    static func serialize(_ object: Any) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        } catch {
            throw NativeError.encode(String(describing: error))
        }
    }
}
