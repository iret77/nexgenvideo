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

    // MARK: - Gates (WRITES)

    func approveGateTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let phase = try args.requireString("phase")
        let notes = args.string("notes")
        try enforceGateRequirement(phase: phase, dataRoot: root)
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
            try enforceGateRequirement(phase: phase, dataRoot: root)
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
    private func enforceGateRequirement(phase: String, dataRoot: URL) throws {
        let registry = PackCatalog.registry(activePack: activePluginFor(dataRoot: dataRoot))
        let gates = (try? YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile))
            ?? Gates(project: "")
        do {
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
