import CryptoKit
import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// Deterministic hard-gate enforcement: the port of the predecessor's require-chain that physically
/// stops the agent from advancing a phase whose real artifact (measured beats/downbeats) is missing.
@Suite("Hard gates")
struct GateGuardTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: root.appendingPathComponent("audio").appendingPathComponent("song.wav"))
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .beat),
            to: PipelineLayout.projectFile
        )
        return root
    }

    private func writeAnalysis(_ root: URL, beats: [Double], downbeats: [Double], duration: Double,
                              sectionLabels: [[String: String]] = []) throws {
        let dir = root.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let song = root.appendingPathComponent("audio/song.wav")
        let songHash = SHA256.hash(data: try Data(contentsOf: song))
            .map { String(format: "%02x", $0) }
            .joined()
        var obj: [String: Any] = [
            "schema": analysisSchemaVersion,
            "project": "demo",
            "song_path": "audio/song.wav",
            "song_sha256": songHash,
            "beats": beats,
            "downbeats": downbeats,
            "bpm": 120,
            "duration_s": duration,
            "sections": [
                [
                    "index": 0,
                    "start": 0,
                    "end": duration,
                    "cluster": 0,
                ],
            ],
        ]
        if !sectionLabels.isEmpty {
            obj["tempo_multiplier"] = 1
            obj["interpretation"] = [
                "section_labels": sectionLabels,
                "anomalies": [],
                "overall_character": "Measured steady pulse with a compact arc.",
            ]
        }
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("song.json"))
    }

    private func writeGeneratedBibleProof(
        _ root: URL,
        path: String
    ) throws {
        let url = root.appendingPathComponent(path)
        try savePipelineAssetProof(
            PipelineAssetProof(
                project: "demo",
                scope: "bible",
                entries: [
                    path: PipelineAssetProofEntry(
                        path: path,
                        sha256: try FileDigest.sha256(of: url),
                        providerPrompt: "Compiled sheet prompt",
                        generationModel: "image-model",
                        sourceMediaId: "generated-sheet"
                    ),
                ]
            ),
            dataRoot: root
        )
    }

    private func shotlist(
        duration: Double = 12,
        keyframeStrategy: KeyframeStrategy = .start,
        sourceMode: SourceMode = .generated,
        productionPlan: ShotProductionPlan? = nil,
        generator: String = "test"
    ) throws -> Shotlist {
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: duration
        )
        let shot = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: duration,
            durationS: duration,
            type: .performance,
            sourceMode: sourceMode,
            description: "A complete shot",
            visualPrompt: "A performer holds the opening pose in a measured wide frame.",
            mood: "restrained",
            keyframeStrategy: keyframeStrategy,
            productionPlan: productionPlan
        )
        return try Shotlist(
            schema_: shotlistSchemaVersion,
            mode: .section,
            project: "demo",
            song: song,
            generated: "2026-07-26T00:00:00Z",
            generator: generator,
            shots: [shot]
        )
    }

    private func brief() throws -> Brief {
        try Brief(
            project: "demo",
            generated: "2026-07-26T00:00:00Z",
            mission: .demo,
            targetPlatform: "YouTube",
            aspectRatio: .landscape16x9,
            projectMode: "section",
            budgetEur: 50,
            conceptType: .narrative,
            visualMedium: .animation2d,
            visualMediumNotes: "restrained hand-drawn animation",
            tone: [.quiet],
            figures: .none,
            lyricsIntegration: .metaphorical
        )
    }

    private func storyboardSteps(
        locationView: String = "wide",
        firstBlocking: [[String: String]] = []
    ) throws -> [Step] {
        try (1...4).map { index in
            try Step(
                id: "intro.\(String(format: "%02d", index))",
                function: index == 1 ? .transition : .story,
                subject: "The performer holds opening pose \(index).",
                camera: "Wide static frame.",
                settingHint: "yard, from the gate",
                locationViewRequest: locationView,
                framing: "wide",
                cameraSetup: [
                    "height": "eye_level",
                    "angle": "frontal",
                    "lens_hint": "wide",
                ],
                characterBlocking: index == 1 ? firstBlocking : []
            )
        }
    }

    private func writePlanningStyle(_ root: URL) throws {
        try YAMLArtifactStore(dataRoot: root).save(
            try brief(),
            to: PipelineLayout.briefFile
        )
        try YAMLArtifactStore(dataRoot: root).save(
            try ProductionDesign(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                colorScript: ["intro": "Muted blue dawn."]
            ),
            to: "production_design/production_design.yaml"
        )
    }

    // MARK: - Fail-closed pack wiring (the triangle Engine↔Plugin↔Agent must be live)

    @Test("requireWiredPack: a generic project (no declared pack) is unaffected")
    func wiringGenericPasses() throws {
        try GateGuard.requireWiredPack(declared: nil, resolved: nil, registry: EngineRegistry())
    }

    @Test("requireWiredPack: a declared pack that didn't wire blocks EVERY approval (P0 fail-closed)")
    func wiringDeclaredButUnwiredBlocks() {
        // Package declares musicvideo but the runtime resolved nil / built an empty registry — no step
        // may be approved, or the pipeline would advance ungated masquerading as generic.
        #expect(throws: GateBlocked.self) {
            try GateGuard.requireWiredPack(declared: "musicvideo", resolved: nil, registry: EngineRegistry())
        }
        #expect(throws: GateBlocked.self) {
            try GateGuard.requireWiredPack(declared: "musicvideo", resolved: "musicvideo", registry: EngineRegistry())
        }
    }

    @Test("requireWiredPack: a genuinely wired pack passes")
    func wiringWiredPasses() throws {
        let registry = EngineRegistry()
        registry.registerWiringProbe { PackWiring.token(pack: "musicvideo", nonce: $0) }
        try GateGuard.requireWiredPack(declared: "musicvideo", resolved: "musicvideo", registry: registry)
    }

    @Test("analysis gate requires measured rhythm and A2 interpretation")
    func analysisRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let labels = [[
            "index": "0",
            "label": "intro",
            "confidence": "0.9",
        ]]

        // No artifact → blocked.
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Degenerate artifact (no beats/downbeats) → blocked.
        try writeAnalysis(root, beats: [], downbeats: [], duration: 0)
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Real rhythm data but NO interpretation yet (A2 not done) → still blocked.
        try writeAnalysis(root, beats: [0.5, 1.0, 1.5], downbeats: [0.5, 2.5], duration: 12.0)
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Lyrics and forced alignment are optional; measured rhythm plus interpretation is sufficient.
        try writeAnalysis(root, beats: [0.5, 1.0, 1.5], downbeats: [0.5, 2.5], duration: 12.0, sectionLabels: labels)
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)

        try Data("replacement".utf8).write(
            to: root.appendingPathComponent("audio/song.wav")
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
        }
    }

    @Test("project track discovery rejects a symlink outside the project")
    func projectTrackRejectsSymlinkEscape() throws {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "song-symlink-\(UUID().uuidString)",
                isDirectory: true
            )
        let root = cleanup.appendingPathComponent("project/pipeline")
        let outside = cleanup.appendingPathComponent("outside.wav")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("audio"),
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("audio/song.wav"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: cleanup) }

        #expect(AudioProjectLayout.songFiles(dataRoot: root).isEmpty)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireProjectTrack(dataRoot: root)
        }
    }

    @Test("musicvideo registers deterministic hard-gate requirements per phase")
    func requirementRegistered() {
        PackCatalog.register(MusicvideoPack())
        let registry = PackCatalog.registry(activePack: "musicvideo")
        // The per-phase acceptance harness: every content phase has a deterministic requirement.
        for phase in ["project_init", "analysis", "brief", "production_design", "treatment",
                      "storyboard", "bible", "shotlist", "sanity", "frames", "render", "cover"] {
            #expect(registry.gateRequirements[phase] != nil, "\(phase) must have a gate requirement")
        }
        for phase in MusicvideoPipelineLineage.phases {
            #expect(
                registry.phaseLineageProviders[phase] != nil,
                "\(phase) must have a lineage provider"
            )
        }
        // A generic project carries none.
        #expect(PackCatalog.registry(activePack: nil).gateRequirements["analysis"] == nil)
    }

    @Test("registered gates reject missing, changed, and stale phase lineage")
    func lineageRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let labels = [[
            "index": "0",
            "label": "intro",
            "confidence": "0.9",
        ]]
        try writeAnalysis(
            root,
            beats: [0, 0.5, 1],
            downbeats: [0, 2],
            duration: 12,
            sectionLabels: labels
        )
        PackCatalog.register(MusicvideoPack())
        let registry = PackCatalog.registry(activePack: "musicvideo")
        let analysisRequirement = try #require(
            registry.gateRequirements["analysis"]
        )
        #expect(throws: GateBlocked.self) {
            try analysisRequirement(root)
        }
        let analysisProvider = try #require(
            registry.phaseLineageProviders["analysis"]
        )
        try PipelineLineageStore.record(
            phase: "analysis",
            snapshot: try analysisProvider(root),
            dataRoot: root
        )
        try analysisRequirement(root)

        let analysisURL = root.appendingPathComponent("analysis/song.json")
        try Data(#"{"phase":"brief"}"#.utf8).write(
            to: root.appendingPathComponent("analysis/affect.json"),
            options: .atomic
        )
        try analysisRequirement(root)

        var object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: analysisURL)
            ) as? [String: Any]
        )
        var interpretation = try #require(
            object["interpretation"] as? [String: Any]
        )
        interpretation["overall_character"] = "Changed after the phase write."
        object["interpretation"] = interpretation
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: analysisURL, options: .atomic)
        #expect(throws: GateBlocked.self) {
            try analysisRequirement(root)
        }

        try YAMLArtifactStore(dataRoot: root).save(
            try brief(),
            to: PipelineLayout.briefFile
        )
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .section, budgetEur: 50),
            to: PipelineLayout.projectFile
        )
        let briefProvider = try #require(
            registry.phaseLineageProviders["brief"]
        )
        try PipelineLineageStore.record(
            phase: "brief",
            snapshot: try briefProvider(root),
            dataRoot: root
        )
        let briefRequirement = try #require(
            registry.gateRequirements["brief"]
        )
        try briefRequirement(root)

        interpretation["overall_character"] = "Changed again upstream."
        object["interpretation"] = interpretation
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: analysisURL, options: .atomic)
        #expect(throws: GateBlocked.self) {
            try briefRequirement(root)
        }
    }

    @Test("every release pipeline gate fails closed when its artifact is absent")
    func everyReleaseGateFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-gates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .beat),
            to: PipelineLayout.projectFile
        )
        PackCatalog.register(MusicvideoPack())
        let registry = PackCatalog.registry(activePack: "musicvideo")
        for phase in [
            "project_init", "analysis", "brief", "production_design",
            "treatment", "storyboard", "bible", "shotlist", "sanity",
            "frames", "render",
        ] {
            let requirement = try #require(registry.gateRequirements[phase])
            #expect(throws: GateBlocked.self, "\(phase) must fail closed") {
                try requirement(root)
            }
        }
    }

    @Test("sanity gate accepts only a current report without errors")
    func sanityRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SanityArtifactStore.save(
            report: SanityReport(project: "demo"),
            dataRoot: root
        )
        try MusicvideoGateChecks.requireCurrentSanity(dataRoot: root)

        try Data("changed".utf8).write(
            to: root.appendingPathComponent(PipelineLayout.briefFile)
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireCurrentSanity(dataRoot: root)
        }

        _ = try SanityArtifactStore.save(
            report: SanityReport(
                project: "demo",
                findings: [
                    Finding(
                        level: .error,
                        code: "BLOCKING",
                        message: "A blocking finding."
                    ),
                ]
            ),
            dataRoot: root
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireCurrentSanity(dataRoot: root)
        }
    }

    @Test("storyboard gate binds every section to the measured analysis timeline")
    func storyboardRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAnalysis(
            root,
            beats: [0, 0.5, 1],
            downbeats: [0, 2],
            duration: 12,
            sectionLabels: [[
                "index": "0",
                "label": "intro",
                "confidence": "0.9",
            ]]
        )
        let steps = try storyboardSteps()
        let valid = try Storyboard(
            meta: try StoryboardMeta(
                project: "demo",
                version: 1,
                generated: "2026-07-26T00:00:00Z",
                summaryOneline: "A measured opening."
            ),
            sections: [
                try Section(
                    id: "intro",
                    label: "intro",
                    timeStart: 0,
                    timeEnd: 12,
                    energy: "low",
                    function: "aufbau",
                    steps: steps
                ),
            ]
        )
        try StoryboardStore.save(valid, to: root)
        try MusicvideoGateChecks.requireRealStoryboard(dataRoot: root)

        let unanchored = try Storyboard(
            meta: try StoryboardMeta(
                project: "demo",
                version: 2,
                generated: "2026-07-26T00:00:00Z",
                summaryOneline: "An unanchored opening."
            ),
            sections: [
                try Section(
                    id: "intro",
                    label: "intro",
                    timeStart: 0,
                    timeEnd: 12,
                    energy: "low",
                    function: "aufbau",
                    steps: try storyboardSteps(firstBlocking: [[
                        "character_ref": "performer",
                        "position": "left third",
                        "pose": "standing",
                        "gaze": "toward the yard",
                        "relation_to_set": "screen-left",
                    ]])
                ),
            ]
        )
        try StoryboardStore.save(unanchored, to: root)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealStoryboard(dataRoot: root)
        }

        let truncated = try Storyboard(
            meta: try StoryboardMeta(
                project: "demo",
                version: 3,
                generated: "2026-07-26T00:00:00Z",
                summaryOneline: "An incomplete opening."
            ),
            sections: [
                try Section(
                    id: "intro",
                    label: "intro",
                    timeStart: 0,
                    timeEnd: 6,
                    energy: "low",
                    function: "aufbau",
                    steps: steps
                ),
            ]
        )
        try StoryboardStore.save(truncated, to: root)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealStoryboard(dataRoot: root)
        }
    }

    @Test("planning gates accept coherent artifacts and enforce shot plan ownership")
    func coherentPlanningArtifacts() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAnalysis(
            root,
            beats: [0, 0.5, 1],
            downbeats: [0, 2],
            duration: 12,
            sectionLabels: [[
                "index": "0",
                "label": "intro",
                "confidence": "0.9",
            ]]
        )

        try YAMLArtifactStore(dataRoot: root).save(
            try brief(),
            to: PipelineLayout.briefFile
        )
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .section, budgetEur: 50),
            to: PipelineLayout.projectFile
        )
        try MusicvideoGateChecks.requireRealBrief(dataRoot: root)

        try YAMLArtifactStore(dataRoot: root).save(
            try ProductionDesign(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                colorScript: ["intro": "Muted blue dawn."]
            ),
            to: "production_design/production_design.yaml"
        )
        try MusicvideoGateChecks.requireRealProductionDesign(dataRoot: root)

        try TreatmentStore.save(
            Treatment(
                meta: try TreatmentMeta(
                    project: "demo",
                    version: 1,
                    generated: "2026-07-26T00:00:00Z",
                    origin: .agentProposal,
                    generator: "test",
                    summaryOneline: "A restrained dawn resolves into motion."
                ),
                bodyMarkdown: "The restrained hand-drawn animation observes "
                    + "the empty yard before the day begins."
            ),
            to: root
        )
        try MusicvideoGateChecks.requireRealTreatment(dataRoot: root)

        let steps = try storyboardSteps()
        try StoryboardStore.save(
            try Storyboard(
                meta: try StoryboardMeta(
                    project: "demo",
                    version: 1,
                    generated: "2026-07-26T00:00:00Z",
                    summaryOneline: "A restrained dawn."
                ),
                sections: [
                    try Section(
                        id: "intro",
                        label: "intro",
                        timeStart: 0,
                        timeEnd: 12,
                        energy: "low",
                        function: "aufbau",
                        steps: steps
                    ),
                ]
            ),
            to: root
        )
        try MusicvideoGateChecks.requireRealStoryboard(dataRoot: root)

        let anchor = root.appendingPathComponent("bible/yard-wide.png")
        try FileManager.default.createDirectory(
            at: anchor.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("anchor".utf8).write(to: anchor)
        try YAMLArtifactStore(dataRoot: root).save(
            try Bible(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                look: LookGuide(style: "restrained hand-drawn animation"),
                locations: [
                    try Location(
                        id: "yard",
                        name: "Schoolyard",
                        visualPrompt: "A quiet schoolyard at blue hour.",
                        sheets: ["wide": "bible/yard-wide.png"]
                    ),
                ]
            ),
            to: PipelineLayout.bibleFile
        )
        try writeGeneratedBibleProof(
            root,
            path: "bible/yard-wide.png"
        )
        try MusicvideoGateChecks.requireRealBible(dataRoot: root)

        _ = try saveShotlist(try shotlist(), to: root)
        try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)

        _ = try saveShotlist(
            try shotlist(generator: "shotlist-agent@write_shotlist"),
            to: root
        )
        try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)

        _ = try saveShotlist(
            try shotlist(generator: Shotlist.agentWriterGenerator),
            to: root
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)
        }

        let plan = try ShotProductionPlan(
            primaryAction: "The performer holds the opening pose.",
            cameraMovement: .static,
            narrativeBeat: .establish,
            renderability: .green,
            continuityLocks: []
        )
        _ = try saveShotlist(
            try shotlist(
                keyframeStrategy: .none,
                sourceMode: .imported,
                productionPlan: plan,
                generator: Shotlist.agentWriterGenerator
            ),
            to: root
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)
        }

        _ = try saveShotlist(
            try shotlist(
                productionPlan: plan,
                generator: Shotlist.agentWriterGenerator
            ),
            to: root
        )
        try MusicvideoGateChecks.requireRealShotlist(dataRoot: root)
    }

    @Test("planning gates reject non-image reference files")
    func planningGateRejectsNonImageReference() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAnalysis(
            root,
            beats: [0, 0.5, 1],
            downbeats: [0, 2],
            duration: 12,
            sectionLabels: [[
                "index": "0",
                "label": "intro",
                "confidence": "0.9",
            ]]
        )
        try YAMLArtifactStore(dataRoot: root).save(
            try brief(),
            to: PipelineLayout.briefFile
        )
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .section, budgetEur: 50),
            to: PipelineLayout.projectFile
        )
        let reference = root.appendingPathComponent(
            "production_design/refs/style.txt"
        )
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not an image".utf8).write(to: reference)
        try YAMLArtifactStore(dataRoot: root).save(
            try ProductionDesign(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                refs: [
                    ProductionDesignReference(
                        path: "production_design/refs/style.txt"
                    ),
                ]
            ),
            to: "production_design/production_design.yaml"
        )

        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealProductionDesign(
                dataRoot: root
            )
        }
    }

    @Test("bible gate requires every view demanded by the storyboard")
    func bibleRequiresStoryboardViews() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlanningStyle(root)
        let steps = try storyboardSteps(locationView: "entrance")
        try StoryboardStore.save(
            try Storyboard(
                meta: try StoryboardMeta(
                    project: "demo",
                    version: 1,
                    generated: "2026-07-26T00:00:00Z",
                    summaryOneline: "The gate opens the film."
                ),
                sections: [
                    try Section(
                        id: "intro",
                        label: "intro",
                        timeStart: 0,
                        timeEnd: 12,
                        energy: "low",
                        function: "aufbau",
                        steps: steps
                    ),
                ]
            ),
            to: root
        )
        let anchor = root.appendingPathComponent("bible/wide.png")
        try FileManager.default.createDirectory(
            at: anchor.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("anchor".utf8).write(to: anchor)
        let missing = try Bible(
            project: "demo",
            generated: "2026-07-26T00:00:00Z",
            generator: "test",
            look: LookGuide(style: "restrained hand-drawn animation"),
            locations: [
                try Location(
                    id: "yard",
                    name: "Schoolyard",
                    visualPrompt: "A quiet schoolyard.",
                    sheets: ["wide": "bible/wide.png"]
                ),
            ]
        )
        try YAMLArtifactStore(dataRoot: root).save(
            missing,
            to: PipelineLayout.bibleFile
        )
        try writeGeneratedBibleProof(
            root,
            path: "bible/wide.png"
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealBible(dataRoot: root)
        }
    }

    @Test("frames gate requires every role, compiled prompt, complete current audit, and exact hash")
    func framesRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try saveShotlist(try shotlist(), to: root)
        let image = root.appendingPathComponent("media/s001-start.png")
        try FileManager.default.createDirectory(
            at: image.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("frame-v1".utf8).write(to: image)
        try saveFramesManifest(
            FramesManifest(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                shots: [
                    ShotFrames(
                        shotId: "s001",
                        keyframeStrategy: "start",
                        frames: [
                            FrameEntry(
                                role: "start",
                                path: "media/s001-start.png",
                                runwayModel: "image-model",
                                providerPrompt: "A compiled provider prompt."
                            ),
                        ]
                    ),
                ]
            ),
            dataRoot: root
        )
        let digest = SHA256.hash(data: try Data(contentsOf: image))
            .map { String(format: "%02x", $0) }
            .joined()
        let checks = Dictionary(uniqueKeysWithValues: standardAuditCheckKeys.map {
            ($0, AuditCheck(status: .clean))
        })
        try saveFrameAudit(
            try FrameAudit(
                shotId: "s001",
                renderPath: "media/s001-start.png",
                renderSha256: digest,
                generated: "2026-07-26T00:00:00Z",
                auditor: "test",
                checks: checks,
                overall: .clean
            ),
            dataRoot: root
        )
        try MusicvideoGateChecks.requireRealFrames(dataRoot: root)

        try Data("frame-v2".utf8).write(to: image)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealFrames(dataRoot: root)
        }
    }

    @Test("render gate requires a real project video for every generated shot")
    func renderRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try saveShotlist(
            try shotlist(keyframeStrategy: .none),
            to: root
        )
        let video = root.appendingPathComponent("media/s001.mp4")
        try FileManager.default.createDirectory(
            at: video.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: video)
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/s001.mp4",
            costEur: 1,
            phase: "final"
        )
        let proof = RenderProofManifest(
            project: "demo",
            phase: "final",
            entries: [
                "s001": RenderProofEntry(
                    shotId: "s001",
                    output: "media/s001.mp4",
                    outputSha256: try FileDigest.sha256(of: video),
                    providerPrompt: "Compiled provider prompt.",
                    generationModel: "video-model"
                ),
            ]
        )
        try saveRenderManifest(manifest, dataRoot: root)
        try saveRenderProofManifest(proof, dataRoot: root)
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try Data("replacement".utf8).write(to: video)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("render gate binds keyframe conditioning to the exact current frame")
    func renderConditioningRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try saveShotlist(try shotlist(), to: root)
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(
            at: media,
            withIntermediateDirectories: true
        )
        let frame = media.appendingPathComponent("s001-start.png")
        let video = media.appendingPathComponent("s001.mp4")
        try Data("frame-v1".utf8).write(to: frame)
        try Data("video".utf8).write(to: video)
        try saveFramesManifest(
            FramesManifest(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                shots: [
                    ShotFrames(
                        shotId: "s001",
                        keyframeStrategy: "start",
                        frames: [
                            FrameEntry(
                                role: "start",
                                path: "media/s001-start.png",
                                runwayModel: "image-model",
                                providerPrompt: "Compiled frame prompt."
                            ),
                        ]
                    ),
                ]
            ),
            dataRoot: root
        )
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/s001.mp4",
            costEur: 1,
            phase: "final"
        )
        try saveRenderManifest(manifest, dataRoot: root)
        try saveRenderProofManifest(
            RenderProofManifest(
                project: "demo",
                phase: "final",
                entries: [
                    "s001": RenderProofEntry(
                        shotId: "s001",
                        output: "media/s001.mp4",
                        outputSha256: try FileDigest.sha256(of: video),
                        providerPrompt: "Compiled provider prompt.",
                        generationModel: "video-model",
                        startFrame: RenderInputProof(
                            path: "media/s001-start.png",
                            sha256: try FileDigest.sha256(of: frame)
                        )
                    ),
                ]
            ),
            dataRoot: root
        )
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try Data("frame-v2".utf8).write(to: frame)
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("render gate binds a chained shot to the predecessor's exact last frame")
    func chainedRenderConditioningRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 8
        )
        let first = try Shot(
            id: "s001",
            section: "verse",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .performance,
            description: "The opening composition.",
            visualPrompt: "A measured opening composition.",
            mood: "restrained",
            keyframeStrategy: .none
        )
        let chained = try Shot(
            id: "s002",
            section: "verse",
            timeStart: 4,
            timeEnd: 8,
            durationS: 4,
            type: .performance,
            description: "Continue the composition.",
            visualPrompt: "The previous composition continues.",
            mood: "restrained",
            keyframeStrategy: .none,
            seedanceInputMode: .keyframe,
            chainWithPreviousEnd: true
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                shots: [first, chained]
            ),
            to: root
        )
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(
            at: media,
            withIntermediateDirectories: true
        )
        let firstVideo = media.appendingPathComponent("s001.mp4")
        let secondVideo = media.appendingPathComponent("s002.mp4")
        let predecessorFrame = media.appendingPathComponent(
            "s001-last.png"
        )
        try Data("first-video".utf8).write(to: firstVideo)
        try Data("second-video".utf8).write(to: secondVideo)
        try Data("predecessor-frame-v1".utf8).write(
            to: predecessorFrame
        )
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/s001.mp4",
            costEur: 1,
            phase: "final",
            lastFramePath: "media/s001-last.png"
        )
        record(
            &manifest,
            shotId: "s002",
            output: "media/s002.mp4",
            costEur: 1,
            phase: "final"
        )
        try saveRenderManifest(manifest, dataRoot: root)
        try saveRenderProofManifest(
            RenderProofManifest(
                project: "demo",
                phase: "final",
                entries: [
                    "s001": RenderProofEntry(
                        shotId: "s001",
                        output: "media/s001.mp4",
                        outputSha256: try FileDigest.sha256(
                            of: firstVideo
                        ),
                        providerPrompt: "Compiled first prompt.",
                        generationModel: "video-model"
                    ),
                    "s002": RenderProofEntry(
                        shotId: "s002",
                        output: "media/s002.mp4",
                        outputSha256: try FileDigest.sha256(
                            of: secondVideo
                        ),
                        providerPrompt: "Compiled chained prompt.",
                        generationModel: "video-model",
                        startFrame: RenderInputProof(
                            path: "media/s001-last.png",
                            sha256: try FileDigest.sha256(
                                of: predecessorFrame
                            )
                        )
                    ),
                ]
            ),
            dataRoot: root
        )

        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try Data("predecessor-frame-v2".utf8).write(
            to: predecessorFrame
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("render gate requires the exact deterministic reference plan")
    func renderReferencePlanRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try YAMLArtifactStore(dataRoot: root).save(
            try brief(),
            to: PipelineLayout.briefFile
        )
        let reference = root.appendingPathComponent("bible/hero-front.png")
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("reference".utf8).write(to: reference)
        try YAMLArtifactStore(dataRoot: root).save(
            try Bible(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                characters: [
                    try Character(
                        id: "hero",
                        name: "Hero",
                        visualPrompt: "A restrained hand-drawn performer.",
                        sheets: ["front": "bible/hero-front.png"]
                    ),
                ]
            ),
            to: PipelineLayout.bibleFile
        )
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 12
        )
        let shot = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: 12,
            durationS: 12,
            type: .performance,
            description: "A reference-bound shot.",
            visualPrompt: "@Image1 performs in a wide frame.",
            mood: "restrained",
            characterRefs: ["hero"],
            keyframeStrategy: .none,
            seedanceInputMode: .reference
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                shots: [shot]
            ),
            to: root
        )
        let video = root.appendingPathComponent("media/s001.mp4")
        try FileManager.default.createDirectory(
            at: video.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: video)
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/s001.mp4",
            costEur: 1,
            phase: "final"
        )
        try saveRenderManifest(manifest, dataRoot: root)
        func saveProof(referenceImages: [RenderInputProof]) throws {
            try saveRenderProofManifest(
                RenderProofManifest(
                    project: "demo",
                    phase: "final",
                    entries: [
                        "s001": RenderProofEntry(
                            shotId: "s001",
                            output: "media/s001.mp4",
                            outputSha256: try FileDigest.sha256(of: video),
                            providerPrompt: "Compiled provider prompt.",
                            generationModel: "video-model",
                            referenceImages: referenceImages
                        ),
                    ]
                ),
                dataRoot: root
            )
        }
        try saveProof(referenceImages: [
            RenderInputProof(
                path: "bible/hero-front.png",
                sha256: try FileDigest.sha256(of: reference)
            ),
        ])
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try saveProof(referenceImages: [])
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("render gate binds AI enhancement to its declared source video")
    func enhancedRenderSourceRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(
            at: media,
            withIntermediateDirectories: true
        )
        let source = media.appendingPathComponent("source.mp4")
        let substitute = media.appendingPathComponent("substitute.mp4")
        let output = media.appendingPathComponent("enhanced.mp4")
        try Data("source".utf8).write(to: source)
        try Data("substitute".utf8).write(to: substitute)
        try Data("enhanced".utf8).write(to: output)
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 12
        )
        let shot = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: 12,
            durationS: 12,
            type: .performance,
            sourceMode: .aiEnhanced,
            description: "Restyle the imported performance.",
            visualPrompt: "Preserve motion and restyle the surface.",
            mood: "restrained",
            keyframeStrategy: .none,
            sourcePath: "media/source.mp4"
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                shots: [shot]
            ),
            to: root
        )
        var manifest = RenderManifest(project: "demo", phase: "final")
        record(
            &manifest,
            shotId: "s001",
            output: "media/enhanced.mp4",
            costEur: 1,
            phase: "final"
        )
        try saveRenderManifest(manifest, dataRoot: root)
        func saveProof(sourcePath: String, sourceURL: URL) throws {
            try saveRenderProofManifest(
                RenderProofManifest(
                    project: "demo",
                    phase: "final",
                    entries: [
                        "s001": RenderProofEntry(
                            shotId: "s001",
                            output: "media/enhanced.mp4",
                            outputSha256: try FileDigest.sha256(of: output),
                            providerPrompt: "Compiled enhancement prompt.",
                            generationModel: "runway/aleph2",
                            sourceVideo: RenderInputProof(
                                path: sourcePath,
                                sha256: try FileDigest.sha256(of: sourceURL)
                            )
                        ),
                    ]
                ),
                dataRoot: root
            )
        }
        try saveProof(
            sourcePath: "media/source.mp4",
            sourceURL: source
        )
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)

        try saveProof(
            sourcePath: "media/substitute.mp4",
            sourceURL: substitute
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoGateChecks.requireRealRender(dataRoot: root)
        }
    }

    @Test("shotlist lineage binds referenced media to exact bytes")
    func shotlistReferenceLineage() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(
            at: media,
            withIntermediateDirectories: true
        )
        let source = media.appendingPathComponent("source.mp4")
        let reference = media.appendingPathComponent("reference.png")
        try Data("source-v1".utf8).write(to: source)
        try Data("reference-v1".utf8).write(to: reference)
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 12
        )
        let sourceShot = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: 6,
            durationS: 6,
            type: .performance,
            sourceMode: .aiEnhanced,
            description: "Enhance the source.",
            visualPrompt: "Preserve the motion.",
            mood: "restrained",
            keyframeStrategy: .none,
            sourcePath: "media/source.mp4"
        )
        let referencedShot = try Shot(
            id: "s002",
            section: "intro",
            timeStart: 6,
            timeEnd: 12,
            durationS: 6,
            type: .performance,
            description: "Generate from the approved reference.",
            visualPrompt: "Preserve the approved identity.",
            mood: "restrained",
            keyframeStrategy: .none,
            seedanceInputMode: .reference,
            referenceImageRefs: ["media/reference.png"]
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                shots: [sourceShot, referencedShot]
            ),
            to: root
        )

        let before = try MusicvideoPipelineLineage.snapshot(
            phase: "shotlist",
            dataRoot: root
        )
        try Data("source-v2".utf8).write(to: source)
        let afterSource = try MusicvideoPipelineLineage.snapshot(
            phase: "shotlist",
            dataRoot: root
        )
        #expect(before.artifactFingerprint != afterSource.artifactFingerprint)
        #expect(before.inputFingerprint != afterSource.inputFingerprint)

        try Data("reference-v2".utf8).write(to: reference)
        let afterReference = try MusicvideoPipelineLineage.snapshot(
            phase: "shotlist",
            dataRoot: root
        )
        #expect(
            afterSource.artifactFingerprint
                != afterReference.artifactFingerprint
        )
    }

    @Test("empty Frames and Render manifests are valid for an imported-only shot list")
    func importedOnlyPreparation() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 12
        )
        let imported = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: 12,
            durationS: 12,
            type: .performance,
            sourceMode: .imported,
            description: "An imported performance clip.",
            visualPrompt: "The imported performance.",
            mood: "restrained",
            keyframeStrategy: .none
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                shots: [imported]
            ),
            to: root
        )

        try MusicvideoPhasePreparation.frames(dataRoot: root)
        let frames = try loadFramesManifest(dataRoot: root)
        #expect(frames.shots.isEmpty)
        try MusicvideoGateChecks.requireRealFrames(dataRoot: root)

        try MusicvideoPhasePreparation.render(dataRoot: root)
        let render = try loadRenderManifest(dataRoot: root, phase: "final")
        let proof = try loadRenderProofManifest(
            dataRoot: root,
            phase: "final"
        )
        #expect(render.entries.isEmpty)
        #expect(proof.entries.isEmpty)
        try MusicvideoGateChecks.requireRealRender(dataRoot: root)
    }

    @Test("checkApprovable passes with no requirement and rethrows a blocked one")
    func checkApprovable() throws {
        let root = FileManager.default.temporaryDirectory
        try GateGuard.checkApprovable(phase: "brief", dataRoot: root, requirement: nil)
        #expect(throws: GateBlocked.self) {
            try GateGuard.checkApprovable(phase: "analysis", dataRoot: root, requirement: { _ in throw GateBlocked("nope") })
        }
    }

    @Test("requireChain blocks until every upstream gate is approved")
    func requireChainBlocks() throws {
        var gates = Gates(project: "p")
        GatesOperations.approve(&gates, phase: "project_init")
        #expect(throws: GateBlocked.self) {
            try GateGuard.requireChain(gates, order: coreGatePhases, through: "brief")
        }
        GatesOperations.approve(&gates, phase: "brief")
        try GateGuard.requireChain(gates, order: coreGatePhases, through: "brief")
    }

    @Test("requirePriorApproved enforces in-order approval")
    func priorApproved() throws {
        var gates = Gates(project: "p")
        // The first phase has no predecessors — always approvable.
        try GateGuard.requirePriorApproved(gates, order: coreGatePhases, phase: "project_init")
        // brief needs project_init first.
        #expect(throws: GateBlocked.self) {
            try GateGuard.requirePriorApproved(gates, order: coreGatePhases, phase: "brief")
        }
        GatesOperations.approve(&gates, phase: "project_init")
        try GateGuard.requirePriorApproved(gates, order: coreGatePhases, phase: "brief")
    }
}
