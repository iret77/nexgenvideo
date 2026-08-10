import Testing
@testable import NexGenEngine

@Suite("Production profiles")
struct ProductionProfileTests {
    @Test("engine feature version reflects production profiles")
    func engineVersion() {
        #expect(NexGenEngine.version == "0.2.0")
        #expect(EngineContract.current == 5)
        #expect(EngineContract.minimumCompatible == 5)
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
}
