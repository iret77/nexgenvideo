import Foundation
import Testing

@testable import FixtureFictionPlugin
@testable import NexGenEngine

@Suite("Fixture fiction pack wiring")
struct FixtureFictionEngineTests {
    @Test("fixture registers only shared production capabilities")
    func registryContributions() throws {
        let registry = PackRegistry()
        registry.load(FixtureFictionPack())

        #expect(registry.packs.map(\.name) == ["fixture-fiction"])
        #expect(Set(registry.engine.projectDirs) == ["extensions", "import"])
        #expect(registry.engine.durationPolicy == nil)
        #expect(registry.engine.phases.isEmpty)
        #expect(registry.engine.sanityChecks.isEmpty)
        #expect(registry.engine.productionProfiles.map(\.id) == [
            .generativeFilm, .narrativeStorytelling,
        ])

        let consumers = try ProductionKnowledgeConsumerRegistryV1(
            registrations: registry.engine.productionKnowledgeConsumers
        )
        try consumers.validateResources(in: EngineProductionKnowledgeResourcesV1.loadCatalog())
        let descriptor = try #require(
            consumers.registration(for: "fixture-fiction")?.descriptor
        )
        #expect(descriptor.phaseSelections.map(\.phase) == [
            "project_init", "screenplay", "scene_plan", "production_design", "bible",
            "shotlist", "sanity", "frames", "render",
        ])
        #expect(descriptor.profileResourceIDs == [
            "generative_film", "narrative_storytelling",
        ])
        #expect(descriptor.selection(for: "screenplay")?.libraryIDs.contains(
            "film-production-story-structures"
        ) == true)
        #expect(descriptor.selection(for: "scene_plan")?.libraryIDs.contains(
            "continuity-and-coverage"
        ) == true)
        #expect(descriptor.selection(for: "render")?.libraryIDs.contains(
            "film-production-video-prompting"
        ) == true)
    }

    @Test("fixture resources and packaged instructions load without presentation art")
    func resourcesLoad() throws {
        let pack = FixtureFictionPack()
        let root = try #require(pack.packResourceRootURL)
        #expect(pack.manifest.badgeURL == nil)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("pipeline-contract.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("hardsteps.json").path
        ))
        #expect(pack.starters.first?.prompt.contains(
            "Follow these packaged instructions for the current phase"
        ) == true)
        let continuation = try #require(pack.starters(for: PackProgress(
            nextPhase: "scene_plan",
            approvedPhases: 2,
            totalPhases: 9
        )).first)
        #expect(continuation.title.contains("Scene Plan"))
        #expect(continuation.prompt.contains("continuity"))
    }
}
