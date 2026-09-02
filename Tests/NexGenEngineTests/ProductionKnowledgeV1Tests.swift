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

        #expect(throws: ProductionKnowledgeErrorV1.invalidJSON(
            path: "profiles/invalid.json",
            reason: "unknown keys: modelID"
        )) {
            _ = try ProductionKnowledgeLoaderV1(rootURL: root).load()
        }
    }
}
