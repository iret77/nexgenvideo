import Foundation
import MusicvideoPlugin
import NexGenEngine
import Testing

@testable import NexGenVideo

@Suite("Declarative pack pipeline contract")
struct PackPipelineManifestTests {
    private func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func extensionPhase(
        id: String,
        index: Int,
        after: String?,
        artifactPath: String? = nil,
        phaseBound: [ToolName] = [.writePhaseExtension],
        supporting: [ToolName] = [.compilePrompt],
        intake: Bool = false
    ) -> PackPipelineManifest.Phase {
        PackPipelineManifest.Phase(
            id: id,
            executionIndex: index,
            dependencies: after.map { [$0] } ?? [],
            roles: intake
                ? [.intake, .canonicalWriter, .reviewGate]
                : [.canonicalWriter, .reviewGate],
            selectors: .init(
                artifact: PhaseContractHostRegistry.genericSelector,
                writer: PhaseContractHostRegistry.genericSelector,
                gate: PhaseContractHostRegistry.genericSelector,
                lineage: PhaseContractHostRegistry.genericSelector
            ),
            capabilities: .init(
                phaseBound: phaseBound.map(\.rawValue),
                supporting: supporting.map(\.rawValue)
            ),
            instructions: "phases/\(id).md",
            display: .init(label: id.capitalized),
            extensionArtifact: .init(
                relativePath: artifactPath ?? "extensions/\(id).json",
                schemaResource: "schemas/\(id).schema.json"
            )
        )
    }

    private func extensionFixture() throws -> (
        root: URL,
        contract: ResolvedPhaseContract
    ) {
        let root = try temporaryDirectory("phase-contract-resources")
        let schema = """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "title": { "type": "string", "minLength": 1 },
            "count": { "type": "integer" }
          },
          "required": ["title", "count"]
        }
        """
        for phase in ["project_init", "brief", "plan", "review"] {
            try write("Instructions for \(phase).", to: root.appendingPathComponent("phases/\(phase).md"))
        }
        for phase in ["plan", "review"] {
            try write(schema, to: root.appendingPathComponent("schemas/\(phase).schema.json"))
        }
        let projectInit = PackPipelineManifest.Phase(
            id: "project_init",
            executionIndex: 0,
            dependencies: [],
            roles: [.intake, .canonicalWriter, .reviewGate],
            selectors: .init(
                artifact: "host.project_track",
                writer: "host.project_init_intake",
                gate: "registry.project_init"
            ),
            capabilities: .init(phaseBound: [], supporting: []),
            instructions: "phases/project_init.md"
        )
        let brief = PackPipelineManifest.Phase(
            id: "brief",
            executionIndex: 1,
            dependencies: ["project_init"],
            roles: [.canonicalWriter, .reviewGate],
            selectors: .init(
                artifact: "host.brief",
                writer: "host.brief_writer",
                gate: "registry.brief",
                lineage: "registry.brief"
            ),
            capabilities: .init(
                phaseBound: [ToolName.writeBrief.rawValue],
                supporting: []
            ),
            instructions: "phases/brief.md"
        )
        let manifest = PackPipelineManifest(
            contractID: "fixture.pipeline.v1",
            packID: "fixture",
            resourceRoot: root.lastPathComponent,
            hardStepsManifestID: "hardsteps/1.0",
            display: .init(title: "Fixture"),
            phases: [
                projectInit,
                brief,
                extensionPhase(id: "plan", index: 2, after: "brief", intake: true),
                extensionPhase(id: "review", index: 3, after: "plan"),
            ]
        )
        let hardSteps = try HardStepManifest.decode(Data(#"""
        {
          "schema": "hardsteps/1.0",
          "phases": [
            {
              "phase": "project_init",
              "steps": [
                {
                  "id": "project_init.script",
                  "attachAs": "script",
                  "title": "Script"
                }
              ]
            },
            {
              "phase": "plan",
              "steps": [
                {
                  "id": "plan.style",
                  "attachAs": "style",
                  "title": "Style"
                }
              ]
            }
          ]
        }
        """#.utf8))
        let registry = EngineRegistry()
        registry.registerGateRequirement("project_init") { _ in }
        registry.registerGateRequirement("brief") { _ in }
        registry.registerPhaseLineageProvider("brief") { dataRoot in
            PhaseLineageSnapshot(
                inputFingerprint: try FileDigest.sha256(
                    of: dataRoot.appendingPathComponent(PipelineLayout.projectFile)
                ),
                artifactFingerprint: try FileDigest.sha256(
                    of: dataRoot.appendingPathComponent("native/brief.txt")
                )
            )
        }
        let contract = try PhaseContractResolver.resolve(
            manifest: manifest,
            packVersion: "1.0.0",
            engineContract: EngineContract.current,
            resourceRoot: root,
            hardSteps: hardSteps,
            registry: registry
        )
        return (root, contract)
    }

    @Test("unknown manifest fields are rejected")
    func closedSchemaRejectsUnknownFields() {
        let data = Data(#"{"schema":"pipeline-contract/v1","unexpected":true}"#.utf8)
        #expect(throws: DecodingError.self) {
            try PackPipelineManifest.decode(data)
        }
    }

    @Test("duplicate phases and non-linear dependencies are rejected")
    func invalidGraphsFailClosed() throws {
        let root = try temporaryDirectory("phase-contract-invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        for phase in ["one", "two"] {
            try write("Instructions", to: root.appendingPathComponent("phases/\(phase).md"))
            try write(
                #"{"type":"object","additionalProperties":false,"properties":{},"required":[]}"#,
                to: root.appendingPathComponent("schemas/\(phase).schema.json")
            )
        }
        let duplicate = PackPipelineManifest(
            contractID: "fixture.pipeline.v1",
            packID: "fixture",
            resourceRoot: root.lastPathComponent,
            hardStepsManifestID: "hardsteps/1.0",
            display: .init(title: "Fixture"),
            phases: [
                extensionPhase(id: "one", index: 0, after: nil),
                extensionPhase(id: "one", index: 1, after: "one"),
            ]
        )
        #expect(throws: PhaseContractError.self) {
            try PhaseContractResolver.validateStructure(
                duplicate,
                resourceRoot: root,
                hardSteps: .empty
            )
        }
        let aliasedArtifacts = PackPipelineManifest(
            contractID: "fixture.pipeline.v1",
            packID: "fixture",
            resourceRoot: root.lastPathComponent,
            hardStepsManifestID: "hardsteps/1.0",
            display: .init(title: "Fixture"),
            phases: [
                extensionPhase(
                    id: "one",
                    index: 0,
                    after: nil,
                    artifactPath: "extensions/shared.json"
                ),
                extensionPhase(
                    id: "two",
                    index: 1,
                    after: "one",
                    artifactPath: "extensions/SHARED.json"
                ),
            ]
        )
        #expect(throws: PhaseContractError.self) {
            try PhaseContractResolver.validateStructure(
                aliasedArtifacts,
                resourceRoot: root,
                hardSteps: .empty
            )
        }
        let unguardedCapability = PackPipelineManifest(
            contractID: "fixture.pipeline.v1",
            packID: "fixture",
            resourceRoot: root.lastPathComponent,
            hardStepsManifestID: "hardsteps/1.0",
            display: .init(title: "Fixture"),
            phases: [
                extensionPhase(
                    id: "one",
                    index: 0,
                    after: nil,
                    phaseBound: [.writePhaseExtension, .generateImage]
                ),
            ]
        )
        #expect(throws: PhaseContractError.self) {
            try PhaseContractResolver.resolve(
                manifest: unguardedCapability,
                packVersion: "1.0.0",
                engineContract: EngineContract.current,
                resourceRoot: root,
                hardSteps: .empty,
                registry: EngineRegistry()
            )
        }
        let cycle = PackPipelineManifest(
            contractID: "fixture.pipeline.v1",
            packID: "fixture",
            resourceRoot: root.lastPathComponent,
            hardStepsManifestID: "hardsteps/1.0",
            display: .init(title: "Fixture"),
            phases: [
                extensionPhase(id: "one", index: 0, after: nil),
                extensionPhase(id: "two", index: 1, after: "two"),
            ]
        )
        #expect(throws: PhaseContractError.self) {
            try PhaseContractResolver.validateStructure(
                cycle,
                resourceRoot: root,
                hardSteps: .empty
            )
        }
    }

    @Test("manifest and runtime registry must agree")
    func registryMismatchBlocksResolution() throws {
        let root = try temporaryDirectory("phase-contract-registry")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Initialize.", to: root.appendingPathComponent("phases/init.md"))
        let phase = PackPipelineManifest.Phase(
            id: "project_init",
            executionIndex: 0,
            dependencies: [],
            roles: [.canonicalWriter, .reviewGate],
            selectors: .init(
                artifact: "host.project_track",
                writer: "host.project_init_intake",
                gate: "registry.project_init"
            ),
            capabilities: .init(phaseBound: [], supporting: []),
            instructions: "phases/init.md"
        )
        let manifest = PackPipelineManifest(
            contractID: "fixture.pipeline.v1",
            packID: "fixture",
            resourceRoot: root.lastPathComponent,
            hardStepsManifestID: "hardsteps/1.0",
            display: .init(title: "Fixture"),
            phases: [phase]
        )
        #expect(throws: PhaseContractError.self) {
            try PhaseContractResolver.resolve(
                manifest: manifest,
                packVersion: "1.0.0",
                engineContract: EngineContract.current,
                resourceRoot: root,
                hardSteps: .empty,
                registry: EngineRegistry()
            )
        }

        let wrongWriterPhase = PackPipelineManifest.Phase(
            id: "analysis",
            executionIndex: 0,
            dependencies: [],
            roles: [.canonicalWriter, .reviewGate],
            selectors: .init(
                artifact: "host.analysis",
                writer: "host.project_init_intake",
                gate: "registry.analysis"
            ),
            capabilities: .init(phaseBound: [], supporting: []),
            instructions: "phases/init.md"
        )
        let wrongWriterManifest = PackPipelineManifest(
            contractID: "fixture.pipeline.v1",
            packID: "fixture",
            resourceRoot: root.lastPathComponent,
            hardStepsManifestID: "hardsteps/1.0",
            display: .init(title: "Fixture"),
            phases: [wrongWriterPhase]
        )
        let wrongWriterRegistry = EngineRegistry()
        wrongWriterRegistry.registerGateRequirement("analysis") { _ in }
        #expect(throws: PhaseContractError.self) {
            try PhaseContractResolver.resolve(
                manifest: wrongWriterManifest,
                packVersion: "1.0.0",
                engineContract: EngineContract.current,
                resourceRoot: root,
                hardSteps: .empty,
                registry: wrongWriterRegistry
            )
        }
    }

    @Test("deterministic registry steps must match declaration order and multiplicity")
    func deterministicStepRegistryIsExact() throws {
        let root = try temporaryDirectory("phase-contract-step-order")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Analyze.", to: root.appendingPathComponent("phases/analysis.md"))
        let phase = PackPipelineManifest.Phase(
            id: "analysis",
            executionIndex: 0,
            dependencies: [],
            roles: [.deterministicRunner, .canonicalWriter, .reviewGate],
            selectors: .init(
                artifact: "host.analysis",
                writer: "host.analysis_writer",
                runner: "registry.analysis",
                gate: "registry.analysis",
                deterministicSteps: ["first", "second"]
            ),
            capabilities: .init(
                phaseBound: [
                    ToolName.runPhase.rawValue,
                    ToolName.writeAnalysisInterpretation.rawValue,
                ],
                supporting: []
            ),
            instructions: "phases/analysis.md"
        )
        let manifest = PackPipelineManifest(
            contractID: "fixture.pipeline.v1",
            packID: "fixture",
            resourceRoot: root.lastPathComponent,
            hardStepsManifestID: "hardsteps/1.0",
            display: .init(title: "Fixture"),
            phases: [phase]
        )

        for registeredIDs in [["second", "first"], ["first", "first"]] {
            let registry = EngineRegistry()
            registry.registerPhase("analysis") { _ in }
            registry.registerGateRequirement("analysis") { _ in }
            for id in registeredIDs {
                registry.registerDeterministicStep(
                    id,
                    phase: "analysis",
                    summary: id
                ) { _ in }
            }
            #expect(throws: PhaseContractError.self) {
                try PhaseContractResolver.resolve(
                    manifest: manifest,
                    packVersion: "1.0.0",
                    engineContract: EngineContract.current,
                    resourceRoot: root,
                    hardSteps: .empty,
                    registry: registry
                )
            }
        }
    }

    @Test("generic host writer validates, persists, gates, and chains exact lineage")
    func genericExtensionLifecycle() throws {
        let fixture = try extensionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ignoredRegistryGate = EngineRegistry()
        ignoredRegistryGate.registerGateRequirement("plan") { _ in }
        #expect(throws: PhaseContractError.self) {
            try PhaseContractResolver.resolve(
                manifest: fixture.contract.manifest,
                packVersion: "1.0.0",
                engineContract: EngineContract.current,
                resourceRoot: fixture.root,
                hardSteps: fixture.contract.hardSteps,
                registry: ignoredRegistryGate
            )
        }
        let home = try temporaryDirectory("phase-contract-project")
        defer { try? FileManager.default.removeItem(at: home) }
        let dataRoot = try ProjectScaffold.initProject(
            home: home.appendingPathComponent("project"),
            name: "fixture",
            mode: .section
        )
        let nativeBriefURL = dataRoot.appendingPathComponent("native/brief.txt")
        let initScriptURL = dataRoot.appendingPathComponent("import/script.md")
        let planStyleURL = dataRoot.appendingPathComponent("import/plan-style.png")
        try write("Native brief", to: nativeBriefURL)
        try write("Init script", to: initScriptURL)
        try write("Plan style", to: planStyleURL)
        let briefLineageProvider = try #require(
            fixture.contract.phase("brief")?.nativeLineageProvider
        )
        try PipelineLineageStore.record(
            phase: "brief",
            snapshot: try briefLineageProvider(dataRoot),
            dataRoot: dataRoot
        )

        _ = try GenericPhaseExtensionWriter.write(
            contract: fixture.contract,
            phase: "plan",
            payload: ["title": "Plan", "count": 1],
            dataRoot: dataRoot
        )
        let planLineage = try GenericPhaseExtensionWriter.lineageSnapshot(
            contract: fixture.contract,
            phase: "plan",
            dataRoot: dataRoot
        )
        try PipelineLineageStore.record(
            phase: "plan",
            snapshot: planLineage,
            dataRoot: dataRoot
        )
        try GenericPhaseExtensionWriter.requireCurrent(
            contract: fixture.contract,
            phase: "plan",
            dataRoot: dataRoot
        )

        _ = try GenericPhaseExtensionWriter.write(
            contract: fixture.contract,
            phase: "review",
            payload: ["title": "Review", "count": 2],
            dataRoot: dataRoot
        )
        let reviewLineage = try GenericPhaseExtensionWriter.lineageSnapshot(
            contract: fixture.contract,
            phase: "review",
            dataRoot: dataRoot
        )
        try PipelineLineageStore.record(
            phase: "review",
            snapshot: reviewLineage,
            dataRoot: dataRoot
        )
        try GenericPhaseExtensionWriter.requireCurrent(
            contract: fixture.contract,
            phase: "review",
            dataRoot: dataRoot
        )

        #expect(fixture.contract.allowsPhaseBound(.writePhaseExtension, phase: "plan"))
        #expect(!fixture.contract.allowsPhaseBound(.generateImage, phase: "plan"))
        #expect(fixture.contract.allowsSupporting(.compilePrompt, phase: "review"))
        #expect(!fixture.contract.allowsSupporting(.generateImage, phase: "review"))
        var gates = Gates(project: "fixture")
        GatesOperations.approve(&gates, phase: "plan")
        GatesOperations.approve(&gates, phase: "review")
        let reset = try GatesOperations.rewindTo(
            &gates,
            target: "plan",
            order: fixture.contract.order
        )
        #expect(reset == ["plan", "review"])

        #expect(throws: ToolError.self) {
            try GenericPhaseExtensionWriter.write(
                contract: fixture.contract,
                phase: "plan",
                payload: ["title": "Invalid", "count": 3, "unknown": true],
                dataRoot: dataRoot
            )
        }
        try IntakeLedger(declined: ["later.optional.step"]).save(dataRoot: dataRoot)
        try GenericPhaseExtensionWriter.requireCurrent(
            contract: fixture.contract,
            phase: "review",
            dataRoot: dataRoot
        )
        try write("Changed plan style", to: planStyleURL)
        #expect(throws: GateBlocked.self) {
            try GenericPhaseExtensionWriter.requireCurrent(
                contract: fixture.contract,
                phase: "review",
                dataRoot: dataRoot
            )
        }
        try write("Plan style", to: planStyleURL)
        try GenericPhaseExtensionWriter.requireCurrent(
            contract: fixture.contract,
            phase: "review",
            dataRoot: dataRoot
        )
        try write("Changed init script", to: initScriptURL)
        #expect(throws: GateBlocked.self) {
            try GenericPhaseExtensionWriter.requireCurrent(
                contract: fixture.contract,
                phase: "review",
                dataRoot: dataRoot
            )
        }
        try write("Init script", to: initScriptURL)
        try GenericPhaseExtensionWriter.requireCurrent(
            contract: fixture.contract,
            phase: "review",
            dataRoot: dataRoot
        )
        try write("Changed native brief", to: nativeBriefURL)
        #expect(throws: GateBlocked.self) {
            try GenericPhaseExtensionWriter.requireCurrent(
                contract: fixture.contract,
                phase: "review",
                dataRoot: dataRoot
            )
        }
    }

    @Test("historical compatibility is exact by id, version, engine, and resource layout")
    func historicalCompatibilityMapIsExact() throws {
        let nested = HistoricalPhaseContractCompatibility.Key(
            id: "musicvideo",
            version: "0.0.4",
            engineContract: 2
        )
        #expect(
            HistoricalPhaseContractCompatibility.resourceRoot(for: nested)
                == "NexGenVideo_MusicvideoPlugin.bundle/MusicvideoPack"
        )
        #expect(HistoricalPhaseContractCompatibility.intake(for: nested) == [
            .init(phase: "project_init", kinds: [.script, .character, .location, .style]),
            .init(phase: "analysis", kinds: [.song, .lyrics]),
        ])
        #expect(HistoricalPhaseContractCompatibility.detachedGatePhases(for: nested) == ["cover"])
        #expect(
            HistoricalPhaseContractCompatibility.missingGatePhases(for: nested)
                == ["project_init", "sanity"]
        )
        let legacyManifest = try #require(
            HistoricalPhaseContractCompatibility.manifest(for: nested)
        )
        let legacyHardSteps = try HardStepManifest.decode(Data(#"""
        {
          "schema": "hardsteps/1.0",
          "phases": [
            {
              "phase": "project_init",
              "steps": [
                {"id":"project_init.script","attachAs":"script","title":"Script"},
                {"id":"project_init.characters","attachAs":"character","title":"Characters"},
                {"id":"project_init.locations","attachAs":"location","title":"Locations"},
                {"id":"project_init.style","attachAs":"style","title":"Style"}
              ]
            },
            {
              "phase": "analysis",
              "steps": [
                {"id":"analysis.song","attachAs":"song","title":"Track"},
                {"id":"analysis.lyrics","attachAs":"lyrics","title":"Lyrics"}
              ]
            }
          ]
        }
        """#.utf8))
        let currentPack = MusicvideoPack()
        let resourceRoot = try #require(
            currentPack.manifest.badgeURL
        ).deletingLastPathComponent()
        let legacyRegistry = EngineRegistry()
        legacyRegistry.registerPhase("analysis", after: "project_init") { _ in }
        legacyRegistry.registerDeterministicStep(
            "one_song_contract",
            phase: "analysis",
            summary: "One track"
        ) { _ in }
        for phase in PipelineAgentContract.musicvideoPhases
            where phase != "project_init" && phase != "sanity" {
            legacyRegistry.registerGateRequirement(phase) { _ in }
        }
        legacyRegistry.registerGateRequirement("cover") { _ in }
        let legacyResolved = try PhaseContractResolver.resolve(
            manifest: legacyManifest,
            packVersion: nested.version,
            engineContract: nested.engineContract,
            resourceRoot: resourceRoot,
            hardSteps: legacyHardSteps,
            registry: legacyRegistry,
            historicalCompatibility: true
        )
        try PhaseContractRuntime.validateLockedMusicvideoIfNeeded(
            legacyResolved,
            registry: legacyRegistry
        )
        let flattened = HistoricalPhaseContractCompatibility.Key(
            id: "musicvideo",
            version: "0.4.5",
            engineContract: 8
        )
        #expect(
            HistoricalPhaseContractCompatibility.resourceRoot(for: flattened)
                == "MusicvideoPack"
        )
        #expect(HistoricalPhaseContractCompatibility.intake(for: flattened) == [
            .init(phase: "project_init", kinds: [.song, .lyrics]),
            .init(phase: "brief", kinds: [.script, .character, .location, .style]),
        ])
        #expect(HistoricalPhaseContractCompatibility.detachedGatePhases(for: .init(
            id: "musicvideo",
            version: "0.4.0",
            engineContract: 8
        )) == ["cover"])
        #expect(HistoricalPhaseContractCompatibility.detachedGatePhases(for: .init(
            id: "musicvideo",
            version: "0.4.1",
            engineContract: 8
        )) == [])
        #expect(HistoricalPhaseContractCompatibility.manifest(for: .init(
            id: "musicvideo",
            version: "0.4.6",
            engineContract: 8
        )) == nil)
        #expect(HistoricalPhaseContractCompatibility.manifest(for: .init(
            id: "musicvideo",
            version: "0.4.5",
            engineContract: 7
        )) == nil)
        #expect(HistoricalPhaseContractCompatibility.manifest(for: .init(
            id: "documentary",
            version: "0.4.5",
            engineContract: 8
        )) == nil)
    }

    @Test("new packs without their declared contract fail before code loading")
    func missingNewPackManifestFailsClosed() throws {
        let bundle = try temporaryDirectory("phase-contract-bundle")
            .appendingPathExtension("ngvpack")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources/FixturePack"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: bundle) }
        try write(
            #"{"schema":"hardsteps/1.0","phases":[]}"#,
            to: bundle.appendingPathComponent("Contents/Resources/FixturePack/hardsteps.json")
        )
        #expect(throws: PhaseContractError.self) {
            try PhaseContractBundleLoader.prepare(
                identity: PhaseContractBundleIdentity(
                    id: "fixture",
                    version: "1.0.0",
                    engineContract: EngineContract.current,
                    pipelineContractVersion: 1,
                    resourceRoot: "FixturePack"
                ),
                bundleURL: bundle
            )
        }
    }

    @Test("shipped Music Video contract preserves the locked graph and startup")
    func shippedMusicvideoContractIsExact() throws {
        let pack = MusicvideoPack()
        let prepared = try PhaseContractBundleLoader.prepareDirect(pack: pack)
        let registry = EngineRegistry()
        pack.register(registry)
        let resolved = try PhaseContractResolver.resolve(
            manifest: prepared.manifest,
            packVersion: pack.version,
            engineContract: EngineContract.current,
            resourceRoot: prepared.resourceRoot,
            hardSteps: prepared.hardSteps,
            registry: registry
        )
        try PhaseContractRuntime.validateLockedMusicvideoIfNeeded(
            resolved,
            registry: registry
        )

        #expect(resolved.order == PipelineAgentContract.musicvideoPhases)
        #expect(!resolved.order.contains("finish"))
        #expect(resolved.hardSteps.steps(for: "project_init").map(\.kind) == [.song, .lyrics])
        #expect(resolved.hardSteps.steps(for: "analysis").isEmpty)
    }
}
