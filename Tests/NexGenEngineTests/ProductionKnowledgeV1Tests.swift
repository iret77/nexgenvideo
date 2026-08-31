import Foundation
import Testing
@testable import NexGenEngine

@Suite("Production knowledge V1")
struct ProductionKnowledgeV1Tests {
    @Test("bundled catalog loads every initial profile and library")
    func bundledCatalog() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()

        #expect(catalog.profiles.map(\.id.rawValue) == [
            "generative_film",
            "narrative_storytelling",
        ])
        #expect(catalog.libraries.map(\.id.rawValue) == [
            "camera-recipes",
            "continuity-and-coverage",
            "film-craft-baseline",
            "genre-baselines",
            "production-sheet-templates",
            "story-containers",
            "stylized-3d-animation",
        ])
        #expect(catalog.profiles.allSatisfy {
            $0.provenance.sourceCommit == "d07a1ce5c54b899b7c565d3e3cc4aac40b8363e2"
        })
        #expect(catalog.libraries.allSatisfy {
            $0.provenance.sourceCommit == "d07a1ce5c54b899b7c565d3e3cc4aac40b8363e2"
        })
    }

    @Test("effective profile composition is deterministic")
    func effectiveProfileComposition() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let reversed = try EffectiveProductionProfileV1(
            descriptors: Array(catalog.profiles.reversed())
        )

        #expect(reversed.descriptors == catalog.profiles)
        #expect(reversed.phaseGuidance == catalog.profiles.flatMap(\.phaseGuidance))
        #expect(reversed.machineRules == catalog.profiles.flatMap(\.machineRules))
    }

    @Test("duplicate resource identity fails closed")
    func duplicateIdentity() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let profile = try #require(catalog.profiles.first)
        let library = try #require(catalog.libraries.first)

        #expect(throws: ProductionKnowledgeErrorV1.conflictingResource(
            kind: "profile",
            id: profile.id.rawValue,
            versions: [profile.version.rawValue, profile.version.rawValue]
        )) {
            _ = try ProductionKnowledgeCatalogV1(
                profiles: [profile, profile],
                libraries: []
            )
        }
        #expect(throws: ProductionKnowledgeErrorV1.conflictingResource(
            kind: "library",
            id: library.id.rawValue,
            versions: [library.version.rawValue, library.version.rawValue]
        )) {
            _ = try EffectiveCreativeKnowledgeLibrariesV1(
                libraries: [library, library]
            )
        }
    }

    @Test("closed schema rejects typed model fields")
    func rejectsTypedModelField() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("production-knowledge-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        try fileManager.createDirectory(at: profiles, withIntermediateDirectories: true)
        let bundledRoot = try EngineProductionKnowledgeResourcesV1.rootURL()
        let source = bundledRoot.appendingPathComponent(
            "profiles/generative-film.v1.json",
            isDirectory: false
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any]
        )
        object["modelID"] = "must-not-enter-creative-knowledge"
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let profileURL = profiles.appendingPathComponent("invalid.json", isDirectory: false)
        try data.write(to: profileURL, options: [.atomic])

        let manifest = ProductionKnowledgeManifestV1(
            schemaVersion: "production-knowledge-manifest.v1",
            resources: [
                ProductionKnowledgeResourceReferenceV1(
                    kind: .profile,
                    id: "generative_film",
                    version: "1.0.0",
                    path: "profiles/invalid.json",
                    sha256: try FileDigest.sha256(of: profileURL)
                ),
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent("manifest.json", isDirectory: false),
            options: [.atomic]
        )

        #expect(throws: ProductionKnowledgeErrorV1.invalidValue(
            path: "profiles/invalid.json.modelID",
            reason: "forbidden structural production-knowledge field modelID"
        )) {
            _ = try ProductionKnowledgeLoaderV1(rootURL: root).load()
        }
    }

    @Test("selective assembly is deterministic, bounded, and keeps predicates out of prose")
    func selectiveAssembly() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let assembler = ProductionKnowledgeContextAssemblerV1(
            catalog: catalog,
            predicates: try ProductionMachinePredicateRegistryV1.standard()
        )
        let query = ProductionKnowledgeAssemblyQueryV1(
            packID: "fixture-film",
            phase: "shotlist",
            intentTags: ["camera", "continuity", "craft", "narrative"],
            activeProfileIDs: ["generative_film", "narrative_storytelling"],
            activeLibraryIDs: [
                "camera-recipes", "continuity-and-coverage", "film-craft-baseline",
            ],
            budget: ProductionKnowledgeBudgetV1(
                maximumUTF8Bytes: 12_000,
                maximumEstimatedTokens: 3_000
            )
        )

        let first = try assembler.assemble(query)
        let second = try assembler.assemble(query)

        #expect(first == second)
        #expect(first.utf8Bytes <= query.budget.maximumUTF8Bytes)
        #expect(first.estimatedTokens <= query.budget.maximumEstimatedTokens)
        #expect(!first.libraryEntryIDs.isEmpty)
        #expect(first.libraryEntryIDs.count < catalog.libraries.flatMap(\.entries).count)
        #expect(first.machineRules.count == 6)
        #expect(!first.prompt.contains("execution_plan.has_start_end_states"))
        #expect(!first.prompt.contains("The execution plan must identify one primary action."))
    }

    @Test("required guidance fails closed while optional entries respect a smaller budget")
    func assemblyBudget() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let assembler = ProductionKnowledgeContextAssemblerV1(
            catalog: catalog,
            predicates: try ProductionMachinePredicateRegistryV1.standard()
        )
        let profileOnly = try assembler.assemble(
            ProductionKnowledgeAssemblyQueryV1(
                packID: "fixture-film",
                phase: "shotlist",
                intentTags: ["camera"],
                activeProfileIDs: ["generative_film"],
                activeLibraryIDs: [],
                budget: ProductionKnowledgeBudgetV1(
                    maximumUTF8Bytes: 20_000,
                    maximumEstimatedTokens: 5_000
                )
            )
        )
        let exactBudget = ProductionKnowledgeBudgetV1(
            maximumUTF8Bytes: profileOnly.utf8Bytes,
            maximumEstimatedTokens: profileOnly.estimatedTokens
        )
        let bounded = try assembler.assemble(
            ProductionKnowledgeAssemblyQueryV1(
                packID: "fixture-film",
                phase: "shotlist",
                intentTags: ["camera"],
                activeProfileIDs: ["generative_film"],
                activeLibraryIDs: ["camera-recipes"],
                budget: exactBudget
            )
        )

        #expect(bounded.libraryEntryIDs.isEmpty)
        #expect(!bounded.omittedLibraryEntryIDs.isEmpty)
        #expect(throws: ProductionKnowledgeErrorV1.self) {
            _ = try assembler.assemble(
                ProductionKnowledgeAssemblyQueryV1(
                    packID: "fixture-film",
                    phase: "shotlist",
                    intentTags: [],
                    activeProfileIDs: ["generative_film"],
                    activeLibraryIDs: [],
                    budget: ProductionKnowledgeBudgetV1(
                        maximumUTF8Bytes: max(profileOnly.utf8Bytes - 1, 1),
                        maximumEstimatedTokens: max(profileOnly.estimatedTokens - 1, 1)
                    )
                )
            )
        }
    }

    @Test("the assembler refuses a whole-corpus prompt")
    func wholeCorpusAssemblyIsForbidden() throws {
        let bundled = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let profile = try #require(bundled.profile(id: "narrative_storytelling"))
        let library = try #require(bundled.library(id: "camera-recipes"))
        let catalog = try ProductionKnowledgeCatalogV1(
            profiles: [profile],
            libraries: [library]
        )
        let assembler = ProductionKnowledgeContextAssemblerV1(
            catalog: catalog,
            predicates: try ProductionMachinePredicateRegistryV1.standard()
        )
        let intents = Set(library.applicability.intentTags).union(
            library.entries.flatMap { $0.applicability.intentTags }
        )

        #expect(throws: ProductionKnowledgeErrorV1.invalidValue(
            path: "assembly.selection",
            reason: "whole-corpus prompt assembly is forbidden"
        )) {
            _ = try assembler.assemble(
                ProductionKnowledgeAssemblyQueryV1(
                    packID: "fixture-film",
                    phase: "storyboard",
                    intentTags: intents,
                    activeProfileIDs: ["narrative_storytelling"],
                    activeLibraryIDs: ["camera-recipes"],
                    budget: ProductionKnowledgeBudgetV1(
                        maximumUTF8Bytes: 100_000,
                        maximumEstimatedTokens: 25_000
                    )
                )
            )
        }
    }

    @Test("consumer descriptors compose independently and conflicts fail closed")
    func consumerDescriptors() throws {
        let descriptor = ProductionKnowledgeConsumerDescriptorV1(
            id: "fixture-production-knowledge",
            version: "1.0.0",
            packID: "fixture-film",
            profileResourceIDs: ["generative_film"],
            phaseSelections: [
                ProductionKnowledgePhaseSelectionV1(
                    phase: "shotlist",
                    libraryIDs: ["camera-recipes"],
                    intentTags: ["camera"]
                ),
            ],
            budget: ProductionKnowledgeBudgetV1(
                maximumUTF8Bytes: 8_000,
                maximumEstimatedTokens: 2_000
            )
        )
        let registration = ProductionKnowledgeConsumerRegistrationV1(
            descriptor: descriptor
        ) { _, _ in
            ProductionKnowledgeActivationMetadataV1(
                values: ["story_kind": "observational"],
                intentTags: ["observational"]
            )
        }
        let registry = try ProductionKnowledgeConsumerRegistryV1(
            registrations: [registration]
        )
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        try registry.validateResources(in: catalog)
        let resolved = try #require(registry.registration(for: "fixture-film"))
        let metadata = try resolved.metadataProvider(
            URL(fileURLWithPath: "/fixture", isDirectory: true),
            "shotlist"
        )
        let selection = try #require(descriptor.selection(for: "shotlist"))
        let assembly = try ProductionKnowledgeContextAssemblerV1(
            catalog: catalog,
            predicates: ProductionMachinePredicateRegistryV1.standard()
        ).assemble(
            ProductionKnowledgeAssemblyQueryV1(
                packID: descriptor.packID,
                phase: selection.knowledgePhase,
                intentTags: metadata.intentTags.union(selection.intentTags),
                activeProfileIDs: descriptor.profileResourceIDs,
                activeLibraryIDs: Set(selection.libraryIDs),
                budget: descriptor.budget
            )
        )

        #expect(resolved.descriptor == descriptor)
        #expect(assembly.prompt.contains("Core production profile: generative_film"))
        #expect(assembly.prompt.contains("Production library: camera-recipes/"))
        #expect(throws: ProductionKnowledgeErrorV1.conflictingResource(
            kind: "consumer",
            id: "fixture-film",
            versions: ["1.0.0", "1.0.0"]
        )) {
            _ = try ProductionKnowledgeConsumerRegistryV1(
                registrations: [registration, registration]
            )
        }
        let missingDescriptor = ProductionKnowledgeConsumerDescriptorV1(
            id: "missing-production-knowledge",
            version: "1.0.0",
            packID: "missing-fixture",
            profileResourceIDs: ["missing_profile"],
            phaseSelections: [],
            budget: descriptor.budget
        )
        let missingRegistry = try ProductionKnowledgeConsumerRegistryV1(
            registrations: [
                ProductionKnowledgeConsumerRegistrationV1(
                    descriptor: missingDescriptor,
                    metadataProvider: { _, _ in ProductionKnowledgeActivationMetadataV1() }
                ),
            ]
        )
        #expect(throws: ProductionKnowledgeErrorV1.missingResource(
            "consumer:missing-production-knowledge:profile:missing_profile"
        )) {
            try missingRegistry.validateResources(in: catalog)
        }
    }

    @Test("schema lint is structural and does not reject prose keywords")
    func structuralLintHasNoKeywordFalsePositives() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let prose = catalog.libraries.flatMap(\.entries).flatMap {
            $0.guidance + $0.verifyCriteria + $0.incompatibilities
        }.joined(separator: " ")

        #expect(prose.contains("Provider-specific request syntax"))
        #expect(prose.contains("model"))
    }

    @Test("schema lint rejects capability, request, and project-canon structures")
    func structuralLintRejectsForbiddenStructures() throws {
        for key in ["capabilityLimits", "requestParameters", "projectAssetIDs"] {
            #expect(throws: ProductionKnowledgeErrorV1.invalidValue(
                path: "profiles/invalid.json.\(key)",
                reason: "forbidden structural production-knowledge field \(key)"
            )) {
                _ = try loadMutatedResource(
                    kind: .profile,
                    id: "generative_film",
                    sourcePath: "profiles/generative-film.v1.json"
                ) { object in
                    object[key] = ["typed-value"]
                }
            }
        }
    }

    @Test("project and provider identities cannot masquerade as creative inputs")
    func structuralLintRejectsTypedInputs() throws {
        for role in [
            "model_id", "capability_limit", "video.duration_maximum_seconds",
            "project_asset_id",
        ] {
            #expect(throws: ProductionKnowledgeErrorV1.self) {
                _ = try loadMutatedResource(
                    kind: .library,
                    id: "camera-recipes",
                    sourcePath: "libraries/camera-recipes.v1.json"
                ) { object in
                    var entries = object["entries"] as! [[String: Any]]
                    var entry = entries[0]
                    var inputs = entry["inputs"] as! [[String: Any]]
                    var input = inputs[0]
                    input["role"] = role
                    inputs[0] = input
                    entry["inputs"] = inputs
                    entries[0] = entry
                    object["entries"] = entries
                }
            }
        }
    }

    @Test("source inventory classifies every pinned file and section group")
    func sourceInventoryCoverage() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "docs/migrations/ai-film-production-d07a1ce5.inventory.json"
        ))
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let files = try #require(root["files"] as? [[String: Any]])
        let coverage = try #require(root["coverage"] as? [String: Any])
        let sectionCount = files.reduce(0) {
            $0 + (($1["sections"] as? [[String: Any]])?.count ?? 0)
        }

        #expect(files.count == 20)
        #expect(coverage["trackedFileCount"] as? Int == files.count)
        #expect(coverage["classifiedFileCount"] as? Int == files.count)
        #expect(coverage["classifiedSectionGroupCount"] as? Int == sectionCount)
        #expect((coverage["unclassifiedFiles"] as? [Any])?.isEmpty == true)
        #expect((coverage["unclassifiedSections"] as? [Any])?.isEmpty == true)
    }

    private func loadMutatedResource(
        kind: ProductionKnowledgeResourceKindV1,
        id: String,
        sourcePath: String,
        mutate: (inout [String: Any]) -> Void
    ) throws -> ProductionKnowledgeCatalogV1 {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("production-knowledge-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let folderName = kind == .profile ? "profiles" : "libraries"
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try EngineProductionKnowledgeResourcesV1.rootURL()
            .appendingPathComponent(sourcePath, isDirectory: false)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any]
        )
        mutate(&object)
        let resourceURL = folder.appendingPathComponent("invalid.json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
            to: resourceURL,
            options: [.atomic]
        )
        let relativePath = "\(folderName)/invalid.json"
        let manifest = ProductionKnowledgeManifestV1(
            schemaVersion: "production-knowledge-manifest.v1",
            resources: [
                ProductionKnowledgeResourceReferenceV1(
                    kind: kind,
                    id: id,
                    version: "1.0.0",
                    path: relativePath,
                    sha256: try FileDigest.sha256(of: resourceURL)
                ),
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent("manifest.json", isDirectory: false),
            options: [.atomic]
        )
        return try ProductionKnowledgeLoaderV1(rootURL: root).load()
    }
}
