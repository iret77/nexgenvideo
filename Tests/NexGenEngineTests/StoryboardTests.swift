import Foundation
import Testing
@testable import NexGenEngine

@Suite("Storyboard")
struct StoryboardTests {
    @Test("schema version constant matches Python")
    func schemaVersionConstant() {
        #expect(storyboardSchemaVersion == "storyboard/v1")
    }

    @Test("structuralAnchor raw value matches Python's replacement for REFRAIN_ANCHOR")
    func structuralAnchorRawValue() {
        #expect(StepFunction.structuralAnchor.rawValue == "structural-anchor")
    }

    @Test("round trip: step, section, storyboard survive encode/decode")
    func roundTrip() throws {
        let step = try Step(
            id: "verse1.01",
            function: .structuralAnchor,
            subject: "Alex steht im Schultor",
            camera: "low-angle ~1.5 m"
        )
        let section = try Section(id: "verse1", steps: [step])
        let storyboard = try Storyboard(
            meta: StoryboardMeta(project: "proj", version: 1, generated: "2026-01-01"),
            sections: [section]
        )

        let yaml = try YAMLCoding.encode(storyboard)
        let decoded = try YAMLCoding.decode(Storyboard.self, from: yaml)

        #expect(decoded.sections[0].steps[0].id == "verse1.01")
        #expect(decoded.sections[0].steps[0].function == .structuralAnchor)
        #expect(decoded.schema == "storyboard/v1")
        #expect(decoded == storyboard)
    }

    // MARK: - Step.source_mode (hybrid production, issue #129)

    @Test("Step.sourceMode defaults to .generated and round-trips per mode",
          arguments: [SourceMode.generated, .liveAction, .aiEnhanced])
    func stepSourceModeRoundTrips(_ mode: SourceMode) throws {
        let step = try Step(id: "verse1.01", function: .story, sourceMode: mode, subject: "s", camera: "c")
        #expect(step.sourceMode == mode)
        let decoded = try YAMLCoding.decode(Step.self, from: try YAMLCoding.encode(step))
        #expect(decoded.sourceMode == mode)
    }

    @Test("a step YAML without source_mode decodes as .generated (default)")
    func stepSourceModeAbsentDefaultsToGenerated() throws {
        let yaml = """
            id: verse1.01
            function: story
            subject: s
            camera: c
            """
        let step = try YAMLCoding.decode(Step.self, from: yaml)
        #expect(step.sourceMode == .generated)
    }

    // MARK: - Step.id pattern validator

    @Test(
        "valid step IDs are accepted",
        arguments: ["verse1.03", "chorus2.07", "section_a.00", "a.99"]
    )
    func validStepIDsAccepted(_ id: String) throws {
        let step = try Step(id: id, function: .story, subject: "s", camera: "c")
        #expect(step.id == id)
    }

    @Test(
        "invalid step IDs are rejected",
        arguments: ["verse1-3", "VERSE1.03", "verse1.3", "verse1.003", "verse1", "verse1."]
    )
    func invalidStepIDsRejected(_ id: String) {
        #expect(throws: Step.ValidationError.self) {
            _ = try Step(id: id, function: .story, subject: "s", camera: "c")
        }
    }

    // MARK: - Step subject/camera non-empty validator

    @Test("empty subject throws")
    func emptySubjectThrows() {
        #expect(throws: Step.ValidationError.self) {
            _ = try Step(id: "verse1.01", function: .story, subject: "", camera: "c")
        }
    }

    @Test("whitespace-only subject throws")
    func whitespaceOnlySubjectThrows() {
        #expect(throws: Step.ValidationError.self) {
            _ = try Step(id: "verse1.01", function: .story, subject: "   ", camera: "c")
        }
    }

    @Test("empty camera throws")
    func emptyCameraThrows() {
        #expect(throws: Step.ValidationError.self) {
            _ = try Step(id: "verse1.01", function: .story, subject: "s", camera: "")
        }
    }

    // MARK: - Section step-prefix validator

    @Test("section with steps sharing the same prefix is accepted")
    func sharedPrefixAccepted() throws {
        let steps = try [
            Step(id: "verse1.01", function: .story, subject: "s1", camera: "c1"),
            Step(id: "verse1.02", function: .story, subject: "s2", camera: "c2"),
        ]
        let section = try Section(id: "verse1", steps: steps)
        #expect(section.steps.count == 2)
    }

    @Test("section with mixed step prefixes throws")
    func mixedPrefixesThrow() {
        #expect(throws: Section.ValidationError.self) {
            let steps = try [
                Step(id: "verse1.01", function: .story, subject: "s1", camera: "c1"),
                Step(id: "chorus1.01", function: .story, subject: "s2", camera: "c2"),
            ]
            _ = try Section(id: "verse1", steps: steps)
        }
    }

    @Test("section with empty steps is a no-op for the prefix validator")
    func emptyStepsNoOp() throws {
        let section = try Section(id: "verse1", steps: [])
        #expect(section.steps.isEmpty)
    }

    // MARK: - Storyboard step-id uniqueness validator

    @Test("duplicate step id across sections throws")
    func duplicateStepIDAcrossSectionsThrows() {
        #expect(throws: Storyboard.ValidationError.self) {
            let stepA = try Step(id: "verse1.01", function: .story, subject: "s1", camera: "c1")
            let stepB = try Step(id: "verse1.01", function: .story, subject: "s2", camera: "c2")
            let sectionA = try Section(id: "verse1", steps: [stepA])
            let sectionB = try Section(id: "verse1", steps: [stepB])
            _ = try Storyboard(
                meta: StoryboardMeta(project: "proj", version: 1, generated: "2026-01-01"),
                sections: [sectionA, sectionB]
            )
        }
    }

    @Test("duplicate step id across sections throws on decode too")
    func duplicateStepIDThrowsOnDecode() throws {
        let yaml = """
        schema: storyboard/v1
        meta:
          project: proj
          version: 1
          generated: '2026-01-01'
        sections:
          - id: verse1
            steps:
              - id: verse1.01
                function: story
                subject: s1
                camera: c1
          - id: verse1b
            steps:
              - id: verse1.01
                function: story
                subject: s2
                camera: c2
        """
        #expect(throws: (any Error).self) {
            _ = try YAMLCoding.decode(Storyboard.self, from: yaml)
        }
    }

    @Test("wrong schema constant throws")
    func wrongSchemaThrows() {
        #expect(throws: Storyboard.ValidationError.self) {
            _ = try Storyboard(
                schema: "storyboard/v99",
                meta: try StoryboardMeta(project: "proj", version: 1, generated: "2026-01-01"),
                sections: []
            )
        }
    }

    // MARK: - version >= 1 validator

    @Test("storyboard meta version below 1 throws")
    func versionMustBePositive() {
        #expect(throws: StoryboardMeta.ValidationError.self) {
            _ = try StoryboardMeta(project: "proj", version: 0, generated: "2026-01-01")
        }
    }

    // MARK: - locationViewDemand()

    @Test("locationViewDemand groups by normalized setting_hint head")
    func locationViewDemandGroupsCorrectly() throws {
        let steps = try [
            Step(
                id: "verse1.01", function: .story, subject: "s1", camera: "c1",
                settingHint: "Schulhof, vom Tor", locationViewRequest: "entrance"
            ),
            Step(
                id: "verse1.02", function: .story, subject: "s2", camera: "c2",
                settingHint: "Schulhof, Mitte", locationViewRequest: "wide.morning"
            ),
            Step(
                id: "verse1.03", function: .story, subject: "s3", camera: "c3",
                settingHint: "Klassenzimmer", locationViewRequest: "detail.chalkboard"
            ),
            // Empty location_view_request must be excluded entirely.
            Step(
                id: "verse1.04", function: .story, subject: "s4", camera: "c4",
                settingHint: "Schulhof, Ecke", locationViewRequest: ""
            ),
        ]
        let section = try Section(id: "verse1", steps: steps)
        let storyboard = try Storyboard(
            meta: StoryboardMeta(project: "proj", version: 1, generated: "2026-01-01"),
            sections: [section]
        )

        let demand = storyboard.locationViewDemand()

        #expect(demand["schulhof"] == ["entrance", "wide.morning"])
        #expect(demand["klassenzimmer"] == ["detail.chalkboard"])
        #expect(demand.count == 2)
    }

    @Test("locationViewDemand excludes steps with empty setting_hint")
    func locationViewDemandExcludesEmptySettingHint() throws {
        let step = try Step(
            id: "verse1.01", function: .story, subject: "s1", camera: "c1",
            settingHint: "", locationViewRequest: "entrance"
        )
        let section = try Section(id: "verse1", steps: [step])
        let storyboard = try Storyboard(
            meta: StoryboardMeta(project: "proj", version: 1, generated: "2026-01-01"),
            sections: [section]
        )
        #expect(storyboard.locationViewDemand().isEmpty)
    }

    @Test("allSteps flattens all sections")
    func allStepsFlattens() throws {
        let stepA = try Step(id: "verse1.01", function: .story, subject: "s1", camera: "c1")
        let stepB = try Step(id: "chorus1.01", function: .story, subject: "s2", camera: "c2")
        let sectionA = try Section(id: "verse1", steps: [stepA])
        let sectionB = try Section(id: "chorus1", steps: [stepB])
        let storyboard = try Storyboard(
            meta: StoryboardMeta(project: "proj", version: 1, generated: "2026-01-01"),
            sections: [sectionA, sectionB]
        )
        #expect(storyboard.allSteps().map(\.id) == ["verse1.01", "chorus1.01"])
    }
}
