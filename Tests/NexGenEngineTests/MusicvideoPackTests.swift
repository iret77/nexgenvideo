import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// Port of `plugins/musicvideo/tests/test_pack.py`.
@Suite("Musicvideo Pack", .serialized)
struct MusicvideoPackTests {
    @Test("pack registers music behavior")
    func packRegistersMusicBehavior() {
        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        #expect(reg.engine.durationPolicy != nil)
        #expect(reg.engine.projectDirs.contains("audio"))
        #expect(reg.engine.projectDirs.contains("analysis"))
        #expect(reg.engine.sanityChecks["tempo"] != nil)
        #expect(reg.engine.sanityChecks["pacing"] != nil)
        #expect(reg.engine.phases["analysis"] != nil)
        #expect(reg.engine.progressPhaseRunners["analysis"] != nil)
        #expect(reg.engine.gateRequirements["analysis"] != nil)
        #expect(reg.engine.artifactWriteRequirements["analysis"] != nil)
        #expect(Set(reg.engine.phaseArtifactProviders.keys) == Set(
            MusicvideoPipelineLineage.executionInputPhases
        ))
        #expect(reg.engine.productionProfiles.map(\.id) == [
            .generativeFilm,
            .narrativeStorytelling,
        ])
        #expect(reg.engine.productionKnowledgeConsumers.count == 1)
    }

    @Test("pack registers a format-neutral selective knowledge descriptor")
    func productionKnowledgeDescriptor() throws {
        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        let consumers = try ProductionKnowledgeConsumerRegistryV1(
            registrations: reg.engine.productionKnowledgeConsumers
        )
        try consumers.validateResources(
            in: EngineProductionKnowledgeResourcesV1.loadCatalog()
        )
        let registration = try #require(consumers.registration(for: "musicvideo"))
        let descriptor = registration.descriptor

        #expect(descriptor.profileResourceIDs == [
            "generative_film", "narrative_storytelling",
        ])
        #expect(descriptor.selection(for: "treatment")?.libraryIDs == [
            "film-craft-baseline", "story-containers",
        ])
        #expect(descriptor.selection(for: "sanity")?.knowledgePhase == "review")
        #expect(descriptor.selection(for: "review") == nil)
        #expect(descriptor.selection(for: "analysis") == nil)
        #expect(descriptor.budget.maximumUTF8Bytes == 16_384)
        #expect(descriptor.budget.maximumEstimatedTokens == 4_096)
    }

    @Test("musicvideo selections reach phase-relevant production knowledge")
    func productionKnowledgeSelectionsReachRelevantEntries() throws {
        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        let registration = try #require(
            reg.engine.productionKnowledgeConsumers.first
        )
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let assembler = ProductionKnowledgeContextAssemblerV1(
            catalog: catalog,
            predicates: try ProductionMachinePredicateRegistryV1.standard()
        )

        func entries(
            phase: String,
            metadataTags: Set<String>
        ) throws -> Set<String> {
            let selection = try #require(
                registration.descriptor.selection(for: phase)
            )
            return Set(try assembler.assemble(
                ProductionKnowledgeAssemblyQueryV1(
                    packID: registration.descriptor.packID,
                    phase: selection.knowledgePhase,
                    intentTags: metadataTags.union(selection.intentTags),
                    activeProfileIDs: [
                        "generative_film", "narrative_storytelling",
                    ],
                    activeLibraryIDs: Set(selection.libraryIDs),
                    budget: registration.descriptor.budget
                )
            ).libraryEntryIDs)
        }

        let productionDesign = try entries(
            phase: "production_design",
            metadataTags: ["live_action_realistic", "naturalism", "cinematography"]
        )
        #expect(productionDesign.isSuperset(of: [
            "film-craft-baseline/dominant-visual-device",
            "film-craft-baseline/motivated-light",
            "film-craft-baseline/color-as-arc",
            "production-sheet-templates/character-identity-sheet",
            "production-sheet-templates/location-and-prop-sheet",
            "production-sheet-templates/style-contract-sheet",
        ]))

        let treatment = try entries(
            phase: "treatment",
            metadataTags: ["narrative", "quiet", "poetic"]
        )
        #expect(treatment.isSuperset(of: [
            "film-craft-baseline/color-as-arc",
            "film-craft-baseline/pacing-through-duration",
            "story-containers/three-act-causal-arc",
            "story-containers/four-part-recontextualization",
            "story-containers/associative-mosaic",
            "story-containers/single-turn-short",
        ]))
        #expect(!productionDesign.contains { $0.hasPrefix("camera-recipes/") })
        #expect(!treatment.contains { $0.hasPrefix("genre-baselines/") })

        for (phase, metadataTags) in [
            ("production_design", Set(["stylized-3d", "animation", "shape-language"])),
            ("treatment", Set(["narrative", "quiet", "poetic"])),
            ("storyboard", Set(["stylized-3d", "animation", "shape-language"])),
            ("bible", Set(["stylized-3d", "animation", "shape-language"])),
            ("shotlist", Set<String>()),
            ("sanity", Set(["stylized-3d", "animation", "shape-language"])),
        ] {
            let selection = try #require(
                registration.descriptor.selection(for: phase)
            )
            for libraryID in selection.libraryIDs {
                let assembly = try assembler.assemble(
                    ProductionKnowledgeAssemblyQueryV1(
                        packID: registration.descriptor.packID,
                        phase: selection.knowledgePhase,
                        intentTags: metadataTags.union(selection.intentTags),
                        activeProfileIDs: [
                            "generative_film", "narrative_storytelling",
                        ],
                        activeLibraryIDs: [libraryID],
                        budget: registration.descriptor.budget
                    )
                )
                #expect(assembly.libraryEntryIDs.contains {
                    $0.hasPrefix("\(libraryID.rawValue)/")
                })
            }
        }
    }

    @Test("phase artifact inventory includes versioned creative truth")
    func phaseArtifactInventoryIncludesVersionedTruth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicvideo-lineage-inventory-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("treatment", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("storyboard", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("treatment".utf8).write(
            to: root.appendingPathComponent(PipelineLayout.treatmentCurrentFile)
        )
        try Data("treatment".utf8).write(
            to: root.appendingPathComponent(PipelineLayout.treatmentVersionFile(3))
        )
        try Data("storyboard".utf8).write(
            to: root.appendingPathComponent(PipelineLayout.storyboardCurrentFile)
        )
        try Data("storyboard".utf8).write(
            to: root.appendingPathComponent(PipelineLayout.storyboardVersionFile(4))
        )

        #expect(try MusicvideoPipelineLineage.artifactPaths(
            phase: "treatment",
            dataRoot: root
        ) == [
            PipelineLayout.treatmentCurrentFile,
            PipelineLayout.treatmentVersionFile(3),
        ])
        #expect(try MusicvideoPipelineLineage.artifactPaths(
            phase: "storyboard",
            dataRoot: root
        ) == [
            PipelineLayout.storyboardCurrentFile,
            PipelineLayout.storyboardVersionFile(4),
        ])
    }

    @Test("versioned creative artifact bytes participate in lineage")
    func versionedCreativeBytesParticipateInLineage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicvideo-versioned-lineage-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("treatment", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent(PipelineLayout.treatmentCurrentFile)
        let version = root.appendingPathComponent(PipelineLayout.treatmentVersionFile(1))
        try Data("same".utf8).write(to: current)
        try Data("v1".utf8).write(to: version)

        let before = try MusicvideoPipelineLineage.snapshot(
            phase: "treatment",
            dataRoot: root
        )
        try Data("v1 changed".utf8).write(to: version)
        let after = try MusicvideoPipelineLineage.snapshot(
            phase: "treatment",
            dataRoot: root
        )

        #expect(before.artifactFingerprint != after.artifactFingerprint)
    }

    @Test("render lineage binds immutable per-shot proofs and outputs")
    func renderLineageBindsImmutableShotProofsAndOutputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicvideo-render-lineage-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let outputPath = "outputs/shot-001.mov"
        let lastFramePath = "outputs/shot-001.last-frame.png"
        let inputPath = "inputs/shot-001-start.png"
        let outputData = Data("rendered-video".utf8)
        let lastFrameData = Data("last-frame".utf8)
        let inputData = Data("start-frame".utf8)
        for (path, data) in [
            (outputPath, outputData),
            (lastFramePath, lastFrameData),
            (inputPath, inputData),
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        let renderEntry = RenderEntry(
            shotId: "shot-001",
            phase: "final",
            status: .rendered,
            output: outputPath,
            costEur: 0.1,
            updatedAt: "2026-08-31T00:00:00Z",
            lastFramePath: lastFramePath
        )
        let renderProof = RenderProofEntry(
            shotId: "shot-001",
            output: outputPath,
            outputSha256: FileDigest.sha256(of: outputData),
            providerPrompt: "Compiled prompt.",
            generationModel: "fixture-model",
            startFrame: RenderInputProof(
                path: inputPath,
                sha256: FileDigest.sha256(of: inputData)
            )
        )
        let lastFrameProof = RenderLastFrameProofV1(
            shotID: "shot-001",
            phase: "final",
            path: lastFramePath,
            sha256: FileDigest.sha256(of: lastFrameData),
            sourceOutput: outputPath,
            sourceOutputSHA256: FileDigest.sha256(of: outputData),
            extractedAt: "2026-08-31T00:00:01Z"
        )
        let proof = RenderShotProvenanceProofV1(
            project: "project-001",
            phase: "final",
            shotID: "shot-001",
            renderEntry: renderEntry,
            renderProofEntry: renderProof,
            routingProofEntry: Data("routing-proof".utf8),
            frames: nil,
            lastFrame: lastFrameProof,
            outputs: [
                RenderPublishedArtifactV1(
                    path: lastFramePath,
                    sha256: FileDigest.sha256(of: lastFrameData)
                ),
                RenderPublishedArtifactV1(
                    path: outputPath,
                    sha256: FileDigest.sha256(of: outputData)
                ),
            ].sorted { $0.path < $1.path },
            dependencies: [RenderPublishedArtifactV1(
                path: inputPath,
                sha256: FileDigest.sha256(of: inputData)
            )]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let proofData = try encoder.encode(proof)
        let proofSHA256 = FileDigest.sha256(of: proofData)
        let proofPath = RenderShotProvenanceProofV1.artifactPath(
            phase: "final",
            shotID: "shot-001",
            sha256: proofSHA256
        )
        let proofURL = root.appendingPathComponent(proofPath)
        try FileManager.default.createDirectory(
            at: proofURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try proofData.write(to: proofURL, options: .atomic)
        let publication = RenderShotProvenancePublicationV1(
            transactionID: UUID().uuidString.lowercased(),
            project: "project-001",
            phase: "final",
            proofs: [
                "shot-001": RenderPublishedArtifactV1(
                    path: proofPath,
                    sha256: proofSHA256
                ),
            ]
        )
        let publicationPath = RenderShotProvenancePublicationV1.artifactPath(
            phase: "final"
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("renders"),
            withIntermediateDirectories: true
        )
        try encoder.encode(publication).write(
            to: root.appendingPathComponent(publicationPath),
            options: .atomic
        )
        for path in [
            PipelineLayout.renderManifestFile(phase: "final"),
            PipelineLayout.renderProofFile(phase: "final"),
            PipelineLayout.renderRoutingProofFile(phase: "final"),
            RenderRecordPublicationV1.artifactPath(phase: "final"),
        ] {
            try Data(path.utf8).write(
                to: root.appendingPathComponent(path),
                options: .atomic
            )
        }

        let paths = Set(try MusicvideoPipelineLineage.artifactPaths(
            phase: "render",
            dataRoot: root
        ))
        #expect(paths.contains(proofPath))
        #expect(paths.contains(publicationPath))
        #expect(paths.contains(outputPath))
        #expect(paths.contains(lastFramePath))
        #expect(paths.contains(inputPath))
        #expect(paths.contains(PipelineLayout.renderRoutingProofFile(phase: "final")))
        #expect(paths.contains(RenderRecordPublicationV1.artifactPath(phase: "final")))

        try Data("replaced-output".utf8).write(
            to: root.appendingPathComponent(outputPath),
            options: .atomic
        )
        #expect(throws: MusicvideoPipelineLineage.LineageError.self) {
            _ = try MusicvideoPipelineLineage.artifactPaths(
                phase: "render",
                dataRoot: root
            )
        }
    }

    @Test("music duration bands")
    func musicDurationBands() {
        let policy = MusicDurationPolicy()
        let band = policy.band(for: .section, context: [:])
        #expect((band.minS, band.maxS) == (6.0, 60.0))
    }

    @Test("all mode duration bands carried over exactly")
    func allModeDurationBandsExact() {
        let policy = MusicDurationPolicy()
        #expect((policy.band(for: .beat, context: [:]).minS, policy.band(for: .beat, context: [:]).maxS) == (4.0, 15.0))
        #expect(
            (policy.band(for: .phrase, context: [:]).minS, policy.band(for: .phrase, context: [:]).maxS) == (4.0, 15.0)
        )
        #expect(
            (policy.band(for: .section, context: [:]).minS, policy.band(for: .section, context: [:]).maxS)
                == (6.0, 60.0)
        )
        #expect(
            (policy.band(for: .multicam, context: [:]).minS, policy.band(for: .multicam, context: [:]).maxS)
                == (30.0, 600.0)
        )
    }

    @Test("pack satisfies the Pack contract")
    func packSatisfiesContract() {
        let pack: Pack = MusicvideoPack()
        #expect(pack.name == "musicvideo")
        #expect(pack.version == "0.5.1")
        #expect(pack.manifest.minAppVersion == "1.5.1")
    }

    @Test("pack exposes gallery manifest and a starter")
    func packExposesManifestAndStarters() throws {
        let pack: Pack = MusicvideoPack()
        // Mirrors plugins/musicvideo.json.
        #expect(pack.manifest.displayName == "Music Video")
        #expect(pack.manifest.tagline.isEmpty == false)
        // Badge ships inside the pack's own resource bundle (self-contained).
        let badge = try #require(pack.manifest.badgeURL)
        #expect(FileManager.default.fileExists(atPath: badge.path))
        #expect(pack.starters.isEmpty == false)
    }

    @Test("pack leaves project-specific production profiles to the host")
    func packDoesNotGuessProductionProfiles() throws {
        let starter = try #require(
            MusicvideoPack().starters(for: PackProgress(
                nextPhase: "shotlist",
                approvedPhases: 7,
                totalPhases: 11
            )).first
        )
        #expect(!starter.prompt.contains("Core production profile:"))
        #expect(!starter.prompt.contains("Apply this profile only when `concept_type`"))
    }

    @Test("pack registers the analysis UI contract entry")
    func packRegistersUIContract() {
        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        let entry = reg.engine.uiContracts["analysis"]
        #expect(entry?.surface == "choice")
        #expect(entry?.taskClass == "classification")
    }

    @Test("pack registers every declared project-schema migration")
    func packRegistersProjectMigrations() {
        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        let migrations = reg.engine.projectSchemaMigrations
        #expect(migrations.contains {
            $0.from == "musicvideo/legacy" && $0.to == "musicvideo/2.0.0"
        })
        #expect(migrations.contains {
            $0.from == "musicvideo/1.0.0" && $0.to == "musicvideo/2.0.0"
        })
        #expect(migrations.count == 2)
    }

    @Test("measured-structure migration rewinds analysis and downstream approvals")
    func measuredStructureMigrationRewindsPipeline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicvideo-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = try ProjectScaffold.initProject(home: root, name: "Migration")
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        for phase in MusicvideoPipelineLineage.phases {
            GatesOperations.approve(&gates, phase: phase)
        }
        try store.save(gates, to: PipelineLayout.gatesFile)
        let analysis = dataRoot.appendingPathComponent("analysis/legacy.json")
        try FileManager.default.createDirectory(
            at: analysis.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let before = Data("{\"schema\":\"analysis/v2\"}\n".utf8)
        try before.write(to: analysis)

        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        let migration = try #require(
            reg.engine.projectSchemaMigrations.first {
                $0.from == "musicvideo/1.0.0"
            }
        )
        try migration.migrate(root)

        let migrated = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        #expect(MusicvideoPipelineLineage.phases.allSatisfy {
            !migrated.get($0).approved
        })
        #expect(try Data(contentsOf: analysis) == before)
    }
}
