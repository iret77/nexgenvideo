import Foundation
import FixtureFictionPlugin
import NexGenEngine
import Testing

@testable import NexGenVideo

@Suite("Fixture fiction pack acceptance")
struct FixtureFictionPackTests {
    private func contract() throws -> ResolvedPhaseContract {
        let pack = FixtureFictionPack()
        let prepared = try PhaseContractBundleLoader.prepareDirect(pack: pack)
        let registry = EngineRegistry()
        pack.register(registry)
        return try PhaseContractResolver.resolve(
            manifest: prepared.manifest,
            packVersion: pack.version,
            engineContract: EngineContract.current,
            resourceRoot: prepared.resourceRoot,
            hardSteps: prepared.hardSteps,
            registry: registry
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-fiction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(
        _ data: Data,
        to relativePath: String,
        dataRoot: URL
    ) throws -> String {
        let url = dataRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return FileDigest.sha256(of: data)
    }

    private func persist(
        _ entries: [(String, [String: Any])],
        contract: ResolvedPhaseContract,
        dataRoot: URL
    ) throws {
        for (phase, payload) in entries {
            _ = try GenericPhaseExtensionWriter.write(
                contract: contract,
                phase: phase,
                payload: payload,
                dataRoot: dataRoot
            )
            let snapshot = try GenericPhaseExtensionWriter.lineageSnapshot(
                contract: contract,
                phase: phase,
                dataRoot: dataRoot
            )
            try PipelineLineageStore.record(phase: phase, snapshot: snapshot, dataRoot: dataRoot)
            try GenericPhaseExtensionWriter.requireCurrent(
                contract: contract,
                phase: phase,
                dataRoot: dataRoot
            )
        }
    }

    private func payloads() -> [(String, [String: Any])] {
        [
            ("project_init", [
                "source": "greenfield",
                "premise": "A courier must return a lost memory before dawn.",
                "constraints": ["One night", "Two locations"],
            ]),
            ("screenplay", [
                "logline": "A courier crosses a flooded city to return a memory.",
                "structure": "three_act",
                "acts": [[
                    "id": "act-1",
                    "purpose": "Commit to the crossing.",
                    "turning_point": "The bridge disappears.",
                ]],
                "scenes": [[
                    "id": "scene-1",
                    "act_id": "act-1",
                    "location": "Flooded station",
                    "time": "Night",
                    "objective": "Reach the last ferry.",
                    "conflict": "The route is submerged.",
                    "outcome": "The courier takes the roof path.",
                    "dialogue_beats": ["You kept it safe."],
                ]],
                "source_preserved": false,
            ]),
            ("scene_plan", [
                "setups": [
                    ["id": "setup-wide", "scene_id": "scene-1", "space": "Station concourse", "screen_direction": "Courier moves left to right."],
                    ["id": "setup-close", "scene_id": "scene-1", "space": "Ticket booth", "screen_direction": "Courier faces camera left."],
                ],
                "beats": [
                    ["id": "beat-1", "scene_id": "scene-1", "setup_id": "setup-wide", "function": "establish", "visible_change": "Water enters the concourse.", "continuity_in": [], "continuity_out": ["water rising"]],
                    ["id": "beat-2", "scene_id": "scene-1", "setup_id": "setup-close", "function": "action", "visible_change": "The courier protects the memory case.", "continuity_in": ["water rising"], "continuity_out": ["case under coat"]],
                    ["id": "beat-3", "scene_id": "scene-1", "setup_id": "setup-wide", "function": "transition", "visible_change": "The courier climbs to the roof.", "continuity_in": ["case under coat"], "continuity_out": ["roof route"]],
                ],
                "causal_chain": ["Flooding closes the bridge, so the courier takes the roof."],
                "dialogue_coverage": ["Close setup covers the single line."],
            ]),
            ("production_design", [
                "visual_contract": "Wet black stone, practical amber light, restrained handheld camera.",
                "characters": [],
                "locations": [["id": "station", "description": "Flooded stone station", "continuity_locks": ["ankle-deep water"]]],
                "props": [["id": "memory-case", "description": "Sealed metal case", "continuity_locks": ["carried under coat"]]],
                "lighting_arc": ["Amber practicals fail from rear to front."],
            ]),
            ("bible", [
                "canon": ["The case remains sealed."],
                "assets": [],
                "continuity_states": ["Water rises throughout the scene."],
            ]),
            ("shotlist", [
                "generated_shots": [],
                "ai_enhanced_shots": [],
                "imported_shots": [[
                    "id": "shot-1",
                    "scene_id": "scene-1",
                    "primary_action": "Courier crosses the flooded concourse.",
                    "narrative_function": "establish",
                    "start_state": "Courier enters frame left.",
                    "end_state": "Courier reaches the booth.",
                    "continuity_locks": ["case under coat"],
                    "source_mode": "imported",
                    "source_path": "import/concourse.mov",
                ]],
                "sequence_order": ["shot-1"],
            ]),
            ("sanity", [
                "passed": true,
                "findings": [],
                "checked_shot_ids": ["shot-1"],
            ]),
            ("frames", [
                "generated_frames": [],
                "imported_and_enhanced_skipped": ["shot-1"],
            ]),
            ("render", [
                "generated_requests": [],
                "ai_enhanced_requests": [],
                "imported_shots_skipped": ["shot-1"],
                "provider_outputs": [],
            ]),
        ]
    }

    @Test("pack owns a fiction graph and omits music workflow concepts")
    func formatNeutralGraph() throws {
        let resolved = try contract()
        #expect(resolved.order == [
            "project_init", "screenplay", "scene_plan", "production_design", "bible",
            "shotlist", "sanity", "frames", "render",
        ])
        #expect(resolved.hardSteps.steps(for: "project_init").count == 1)
        #expect(resolved.hardSteps.steps(for: "project_init").first?.required == false)
        for phase in resolved.order {
            let declaration = try #require(resolved.phase(phase)?.declaration)
            #expect(declaration.selectors.writer == PhaseContractHostRegistry.genericSelector)
            #expect(resolved.allowsPhaseBound(.writePhaseExtension, phase: phase))
            #expect(declaration.extensionArtifact != nil)
            let instructions = try String(
                contentsOf: resolved.resourceRoot.appendingPathComponent(declaration.instructions),
                encoding: .utf8
            ).lowercased()
            for forbidden in ["song", "lyrics", "bpm", "musicvideo", "seedance"] {
                #expect(!instructions.contains(forbidden))
            }
        }
    }

    @Test("greenfield imported-only project survives reopen with exact cumulative lineage")
    func greenfieldLifecycleAndReopen() throws {
        let resolved = try contract()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = try ProjectScaffold.initProject(
            home: root.appendingPathComponent("project"),
            name: "Fiction Fixture",
            mode: .section,
            extraDirs: ["extensions", "import"]
        )
        try write(Data("imported video".utf8), to: "import/concourse.mov", dataRoot: dataRoot)
        try persist(payloads(), contract: resolved, dataRoot: dataRoot)

        let reopened = try contract()
        try GenericPhaseExtensionWriter.requireCurrent(
            contract: reopened,
            phase: "render",
            dataRoot: dataRoot
        )
        let frames = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dataRoot.appendingPathComponent("extensions/fixture-fiction/frames.v1.json"))
        ) as? [String: Any]
        let render = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dataRoot.appendingPathComponent("extensions/fixture-fiction/render.v1.json"))
        ) as? [String: Any]
        #expect((frames?["generated_frames"] as? [Any])?.isEmpty == true)
        #expect((render?["provider_outputs"] as? [Any])?.isEmpty == true)

        var gates = Gates(project: "Fiction Fixture")
        for phase in reopened.order { GatesOperations.approve(&gates, phase: phase) }
        let rewound = try GatesOperations.rewindTo(
            &gates,
            target: "scene_plan",
            order: reopened.order
        )
        #expect(gates.get("screenplay").approved)
        #expect(!gates.get("scene_plan").approved)
        #expect(rewound.last == "render")

        _ = try GenericPhaseExtensionWriter.write(
            contract: reopened,
            phase: "screenplay",
            payload: payloads()[1].1.merging(["logline": "Changed upstream truth."]) { _, new in new },
            dataRoot: dataRoot
        )
        #expect(throws: GateBlocked.self) {
            try GenericPhaseExtensionWriter.requireCurrent(
                contract: reopened,
                phase: "render",
                dataRoot: dataRoot
            )
        }
    }

    @Test("screenplay intake and source modes remain schema constrained")
    func intakeAndSourceModes() throws {
        let resolved = try contract()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = try ProjectScaffold.initProject(
            home: root.appendingPathComponent("project"),
            name: "Source Modes",
            extraDirs: ["extensions", "import"]
        )
        try write(Data("INT. STATION - NIGHT".utf8), to: "import/script.md", dataRoot: dataRoot)
        try write(Data("{}".utf8), to: "extensions/fixture-fiction/requirements/shot-1.json", dataRoot: dataRoot)
        try write(Data("{}".utf8), to: "extensions/fixture-fiction/requirements/shot-2.json", dataRoot: dataRoot)
        try write(Data("enhanced".utf8), to: "import/shot-2.mov", dataRoot: dataRoot)
        try write(Data("imported".utf8), to: "import/shot-3.mov", dataRoot: dataRoot)
        let projectInit = try #require(resolved.phase("project_init")?.declaration.extensionArtifact)
        let projectInitSchema = try PhaseExtensionSchema.load(
            from: resolved.resourceRoot.appendingPathComponent(projectInit.schemaResource)
        )
        try projectInitSchema.validate([
            "source": "screenplay",
            "premise": "Preserve the supplied screenplay.",
            "constraints": [],
            "screenplay_path": "import/script.md",
        ], dataRoot: dataRoot)
        #expect(throws: ToolError.self) {
            try projectInitSchema.validate([
                "source": "screenplay",
                "constraints": [],
                "screenplay_path": "import/script.md",
            ], dataRoot: dataRoot)
        }

        let shotlist = try #require(resolved.phase("shotlist")?.declaration.extensionArtifact)
        let shotlistSchema = try PhaseExtensionSchema.load(
            from: resolved.resourceRoot.appendingPathComponent(shotlist.schemaResource)
        )
        let common: [String: Any] = [
            "id": "shot-1",
            "scene_id": "scene-1",
            "primary_action": "Cross the room.",
            "narrative_function": "action",
            "start_state": "At the door.",
            "end_state": "At the window.",
            "continuity_locks": [],
        ]
        try shotlistSchema.validate([
            "generated_shots": [common.merging([
                "source_mode": "generated",
                "keyframe_strategy": "start_end",
                "generation_requirement_path": "extensions/fixture-fiction/requirements/shot-1.json",
            ]) { _, new in new }],
            "ai_enhanced_shots": [common.merging([
                "source_mode": "ai_enhanced",
                "source_path": "import/shot-2.mov",
                "generation_requirement_path": "extensions/fixture-fiction/requirements/shot-2.json",
            ]) { _, new in new }],
            "imported_shots": [common.merging([
                "source_mode": "imported",
                "source_path": "import/shot-3.mov",
            ]) { _, new in new }],
            "sequence_order": ["shot-1", "shot-2", "shot-3"],
        ], dataRoot: dataRoot)
        #expect(throws: ToolError.self) {
            try shotlistSchema.validate([
                "generated_shots": [common.merging([
                    "source_mode": "imported",
                    "keyframe_strategy": "start",
                    "generation_requirement_path": "extensions/fixture-fiction/requirements/shot-1.json",
                ]) { _, new in new }],
                "ai_enhanced_shots": [],
                "imported_shots": [],
                "sequence_order": ["shot-1"],
            ], dataRoot: dataRoot)
        }
        #expect(throws: ToolError.self) {
            try shotlistSchema.validate([
                "generated_shots": [],
                "ai_enhanced_shots": [],
                "imported_shots": [common.merging([
                    "source_mode": "imported",
                    "source_path": "../outside.mov",
                ]) { _, new in new }],
                "sequence_order": ["shot-1"],
            ], dataRoot: dataRoot)
        }
    }

    @Test("existing screenplay bytes stay intact and participate in lineage")
    func screenplayInputIsPreserved() throws {
        let resolved = try contract()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = try ProjectScaffold.initProject(
            home: root.appendingPathComponent("project"),
            name: "Screenplay Fixture",
            extraDirs: ["extensions", "import"]
        )
        let original = Data("INT. STATION - NIGHT\nThe courier enters.\n".utf8)
        try write(original, to: "import/script.md", dataRoot: dataRoot)
        let entries: [(String, [String: Any])] = [
            ("project_init", [
                "source": "screenplay",
                "premise": "Preserve and plan the supplied screenplay.",
                "constraints": [],
                "screenplay_path": "import/script.md",
            ]),
            ("screenplay", payloads()[1].1.merging(["source_preserved": true]) { _, new in new }),
        ]
        try persist(entries, contract: resolved, dataRoot: dataRoot)
        #expect(try Data(contentsOf: dataRoot.appendingPathComponent("import/script.md")) == original)

        try write(Data("changed".utf8), to: "import/script.md", dataRoot: dataRoot)
        #expect(throws: GateBlocked.self) {
            try GenericPhaseExtensionWriter.requireCurrent(
                contract: resolved,
                phase: "screenplay",
                dataRoot: dataRoot
            )
        }
    }

    @Test("generated project reaches an exact provider envelope without dispatch")
    func generatedPlanningStopsBeforeSpend() throws {
        let resolved = try contract()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = try ProjectScaffold.initProject(
            home: root.appendingPathComponent("project"),
            name: "Generated Fixture",
            extraDirs: ["extensions", "import"]
        )
        let requirementPath = "extensions/fixture-fiction/requirements/shot-1.json"
        let framePath = "extensions/fixture-fiction/frames/shot-1-start.png"
        let envelopePath = "extensions/fixture-fiction/requests/shot-1.json"
        let promptPath = "extensions/fixture-fiction/prompts/shot-1.txt"
        try write(Data("{\"modality\":\"video\"}\n".utf8), to: requirementPath, dataRoot: dataRoot)
        let frameHash = try write(Data("approved frame bytes".utf8), to: framePath, dataRoot: dataRoot)
        let envelope = Data("{\"provider\":\"fixture\",\"model\":\"offline\",\"submit\":false}\n".utf8)
        let envelopeHash = try write(envelope, to: envelopePath, dataRoot: dataRoot)
        let promptHash = try write(
            Data("A courier crosses a flooded station.\n".utf8),
            to: promptPath,
            dataRoot: dataRoot
        )
        let generatedShot: [String: Any] = [
            "id": "shot-1",
            "scene_id": "scene-1",
            "primary_action": "Courier crosses the flooded concourse.",
            "narrative_function": "action",
            "start_state": "Courier enters frame left.",
            "end_state": "Courier reaches the booth.",
            "continuity_locks": ["case under coat"],
            "source_mode": "generated",
            "keyframe_strategy": "start",
            "generation_requirement_path": requirementPath,
        ]
        let entries = Array(payloads().prefix(5)) + [
            ("shotlist", [
                "generated_shots": [generatedShot],
                "ai_enhanced_shots": [],
                "imported_shots": [],
                "sequence_order": ["shot-1"],
            ]),
            ("sanity", [
                "passed": true,
                "findings": [],
                "checked_shot_ids": ["shot-1"],
            ]),
            ("frames", [
                "generated_frames": [[
                    "shot_id": "shot-1",
                    "role": "start",
                    "path": framePath,
                    "sha256": frameHash,
                    "approved": true,
                ]],
                "imported_and_enhanced_skipped": [],
            ]),
            ("render", [
                "generated_requests": [[
                    "shot_id": "shot-1",
                    "request_envelope_path": envelopePath,
                    "request_envelope_sha256": envelopeHash,
                    "compiled_prompt_path": promptPath,
                    "compiled_prompt_sha256": promptHash,
                ]],
                "ai_enhanced_requests": [],
                "imported_shots_skipped": [],
                "provider_outputs": [],
            ]),
        ]
        try persist(entries, contract: resolved, dataRoot: dataRoot)
        #expect(try Data(contentsOf: dataRoot.appendingPathComponent(envelopePath)) == envelope)

        try write(Data("drift".utf8), to: promptPath, dataRoot: dataRoot)
        #expect(throws: ToolError.self) {
            try GenericPhaseExtensionWriter.requireCurrent(
                contract: resolved,
                phase: "render",
                dataRoot: dataRoot
            )
        }
    }

    @Test("unknown pipeline schema fails closed")
    func unknownSchemaFailsClosed() throws {
        let root = try #require(FixtureFictionPack.resourceRootURL())
        var text = try String(
            contentsOf: root.appendingPathComponent("pipeline-contract.json"),
            encoding: .utf8
        )
        text = text.replacingOccurrences(
            of: "\"schema\": \"pipeline-contract/v1\"",
            with: "\"schema\": \"pipeline-contract/v99\""
        )
        #expect(throws: PhaseContractError.self) {
            try PackPipelineManifest.decode(Data(text.utf8))
        }
    }
}
