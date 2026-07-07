import Foundation
import NexGenEngine

// Production-pipeline (engine) tools, native as of M7. These are the former Python `engine` MCP
// tools, now first-class `nexgen` tools backed by NexGenEngine + the app's native reader/writer.
// Arg names and return JSON shapes match the Python `mcp_server` functions field-for-field so the
// pack phase docs keep working. `project_dir` is accepted but defaults to the open project's studio
// dir; every function resolves it through DataRootResolver (accepts a project home OR its `_studio`
// data root), mirroring the Python `data_root_of` precheck.

extension ToolExecutor {

    // MARK: - project_dir resolution

    /// The data root to operate on: the `project_dir` arg if given, else the open project's studio
    /// dir — resolved through DataRootResolver so either a home or a `_studio` dir works. Throws a
    /// clear error when neither is available or the path isn't a project.
    private func resolveDataRoot(_ args: [String: Any], editor: EditorViewModel) throws -> URL {
        let dir: URL
        if let path = args.string("project_dir") {
            dir = URL(fileURLWithPath: path)
        } else if let open = editor.studioProjectDir {
            dir = open
        } else {
            throw ToolError("No project is open and no project_dir was given.")
        }
        guard let root = DataRootResolver.dataRoot(of: dir) else {
            throw ToolError("Not a project (no _studio/project.yaml): \(dir.path). Run init_project first.")
        }
        return root
    }

    /// The active format pack for a project given its DATA ROOT. `ngv.json` lives in the project
    /// PACKAGE (parent of `_studio`), so the data root must be lifted to its home before the lookup —
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
        // Projectless when no project_dir/open project — then the core order alone (no pack context).
        let order = (try? resolveDataRoot(args, editor: editor)).map { mergedPhaseOrder(dataRoot: $0) } ?? coreGatePhases
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

    func getLedgerTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let data = try NativeCockpitReader.ledgerJSON(dataRoot: root)
        return .ok(String(decoding: data, as: UTF8.self))
    }

    func getUIContractTool(_ editor: EditorViewModel) throws -> ToolResult {
        let packEntries = PackCatalog.registry(activePack: editor.activePluginName).uiContracts
        let contract = UIContract.fullContract(packEntries: packEntries)
        var phases: [String: Any] = [:]
        for (phase, entry) in contract {
            phases[phase] = ["surface": entry.surface, "task_class": entry.taskClass]
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
        let home = URL(fileURLWithPath: try args.requireString("home_dir"))
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
            return try jsonResult(["data_root": dataRoot.path, "project": name, "created": true])
        } catch let e as ProjectScaffold.ScaffoldError {
            throw ToolError("Couldn't scaffold project: \(e)")
        }
    }

    // MARK: - Gates (WRITES)

    func approveGateTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        let notes = args.string("notes")
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
            var gates = try store.load(Gates.self, at: StudioLayout.gatesFile)
            try body(&gates)
            try store.save(gates, to: StudioLayout.gatesFile)
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
        var ledger = (try? store.load(Ledger.self, at: StudioLayout.ledgerFile)) ?? Ledger()
        do {
            let result = try body(&ledger)
            try store.save(ledger, to: StudioLayout.ledgerFile)
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
            return editor.studioProjectDir.flatMap { DataRootResolver.dataRoot(of: $0) }
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
        return try jsonResult([
            "phase": phase,
            "shot_id": shotId,
            "done": false,
            "source_mode": shot.map { $0.sourceMode.rawValue as Any } ?? (NSNull() as Any),
            "visual_prompt": shot.map { $0.visualPrompt as Any } ?? (NSNull() as Any),
            "framing": shot?.framing.map { $0.rawValue as Any } ?? (NSNull() as Any),
        ])
    }

    func recordRenderTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
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
        do {
            try saveRenderManifest(manifest, dataRoot: root)
        } catch {
            throw ToolError("Couldn't save render manifest: \(error)")
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
        // project PACKAGE (parent of `_studio`), not the data root — resolve the home first.
        let registry = PackCatalog.registry(activePack: activePluginFor(dataRoot: root))
        registry.registerAudioDecoder(AVFoundationAudioDecoder())
        guard let runner = registry.phases[phase] else {
            return try jsonResult([
                "phase": phase,
                "runner": NSNull(),
                "note": "no code runner registered; this phase is agent-driven",
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
        return try jsonResult(["phase": phase, "ok": true, "result": analysisSummary(dataRoot: root, phase: phase)])
    }

    /// Read back the artifact the run just wrote (derived via the runner's own song discovery —
    /// never "first json in the folder", which could be a stale sibling). Falls back to a minimal
    /// shape if it can't be parsed (the write still succeeded).
    private func analysisSummary(dataRoot: URL, phase: String) -> [String: Any] {
        guard let artifact = try? MusicvideoAnalysisRunner.expectedArtifactURL(dataRoot: dataRoot),
            let data = try? Data(contentsOf: artifact),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ["phase": phase, "artifact": NSNull()]
        }
        var summary: [String: Any] = ["artifact": artifact.path]
        if let bpm = obj["bpm"] as? Double { summary["bpm"] = bpm }
        if let duration = obj["duration_s"] as? Double { summary["duration_s"] = duration }
        summary["beats"] = (obj["beats"] as? [Any])?.count ?? 0
        summary["downbeats"] = (obj["downbeats"] as? [Any])?.count ?? 0
        summary["sections"] = (obj["sections"] as? [Any])?.count ?? 0
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
        guard MusicvideoAnalysisRunner.audioExtensions.contains(ext) else {
            let accepted = MusicvideoAnalysisRunner.audioExtensions.sorted().map { ".\($0)" }.joined(separator: "/")
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

        // The runner keeps exactly one song in audio/. A different existing audio file blocks unless
        // `replace` is set; a same-named copy is idempotently overwritten either way.
        let existing = existingAudioFiles(in: audioDir)
        let others = existing.filter { $0.lastPathComponent != destURL.lastPathComponent }
        if !others.isEmpty {
            guard replace else {
                let names = others.map(\.lastPathComponent).sorted().joined(separator: ", ")
                throw ToolError("audio/ already holds a different song (\(names)). Pass replace: true to swap it — the analysis runner keeps exactly one song.")
            }
            for url in others { try? FileManager.default.removeItem(at: url) }
        }

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ToolError("Couldn't copy the song into audio/: \(error.localizedDescription)")
        }

        return try jsonResult(["filename": destURL.lastPathComponent, "audio_dir": audioDir.path])
    }

    /// Audio files already sitting in `audioDir` (by the runner's accepted extensions).
    private func existingAudioFiles(in audioDir: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return entries.filter {
            let isFile = (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            return isFile && MusicvideoAnalysisRunner.audioExtensions.contains($0.pathExtension.lowercased())
        }
    }
}
