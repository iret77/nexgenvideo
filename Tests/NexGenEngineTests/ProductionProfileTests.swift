import Testing
@testable import NexGenEngine

@Suite("Production profiles")
struct ProductionProfileTests {
    @Test("engine feature version reflects production profiles")
    func engineVersion() {
        #expect(NexGenEngine.version == "0.3.0")
        #expect(EngineContract.current == 8)
        #expect(EngineContract.minimumCompatible == 2)
    }

    @Test("profile activation is driven by generic project metadata")
    func profileActivation() {
        let registry = EngineRegistry()
        registry.registerProductionProfiles([
            StandardProductionProfiles.generativeFilm,
            StandardProductionProfiles.narrativeStorytelling,
        ])

        #expect(registry.activeProductionProfileIDs(metadata: [:]) == [.generativeFilm])
        #expect(
            registry.activeProductionProfileIDs(metadata: ["concept_type": "narrative"])
                == [.generativeFilm, .narrativeStorytelling]
        )
        #expect(
            registry.activeProductionProfileIDs(metadata: ["concept_type": " Hybrid "])
                == [.generativeFilm, .narrativeStorytelling]
        )
        #expect(
            registry.activeProductionProfileIDs(metadata: ["concept_type": "performance"])
                == [.generativeFilm]
        )
    }

    @Test("profile guidance keeps activation conditions and film doctrine in the engine")
    func reusableGuidance() {
        let guidance = ProductionProfileGuidance.instructions(
            for: "shotlist",
            profiles: [
                StandardProductionProfiles.generativeFilm,
                StandardProductionProfiles.narrativeStorytelling,
            ]
        )

        #expect(guidance.contains("production_plan"))
        #expect(guidance.contains("narrative_beat"))
        #expect(!guidance.contains("Apply this profile only when"))
    }

    @Test("phase guidance stays inside each canonical writer contract")
    func phaseGuidanceMatchesWriters() {
        let profiles = [StandardProductionProfiles.generativeFilm]
        let productionDesign = ProductionProfileGuidance.instructions(
            for: "production_design",
            profiles: profiles
        )
        let storyboard = ProductionProfileGuidance.instructions(
            for: "storyboard",
            profiles: profiles
        )
        let frames = ProductionProfileGuidance.instructions(
            for: "frames",
            profiles: profiles
        )

        #expect(productionDesign.contains("later Bible phase"))
        #expect(storyboard.contains("character_blocking.set_anchor"))
        #expect(!storyboard.contains("production_plan"))
        #expect(frames.contains("Skip imported and AI-enhanced shots"))
    }

    @Test("audit profile carrier preserves arbitrary metadata and exact identifiers")
    func auditProfileCarrier() throws {
        var context = AuditContext(
            shotlist: try ShotlistTests.shotlist(),
            extra: ["owner": "project"]
        )
        context.productionProfileIDs = [
            .generativeFilm,
            ProductionProfileID(rawValue: "studio,custom"),
        ]

        #expect(context.productionProfileIDs == [
            .generativeFilm,
            ProductionProfileID(rawValue: "studio,custom"),
        ])
        #expect(context.extra?["owner"] == "project")

        context.productionProfileIDs = []
        #expect(context.extra == ["owner": "project"])
    }
}
