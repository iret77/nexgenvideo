import Testing
@testable import NexGenEngine

@Suite("Production input templates")
struct ProductionInputTemplateV1Tests {
    @Test("core modes bind exactly to dedicated requirement fields")
    func exactCoreModes() throws {
        let requirement = ProductionRequirementV1(
            modalityID: "video",
            modeIDs: ["image-to-video"],
            visibleEntityCount: 1,
            requiresFirstFrame: true,
            requiresLastFrame: true
        )
        let template = ProductionInputTemplateV1(
            id: "template-shot-001",
            projectID: "project-001",
            shotID: "shot-001",
            coreInputs: ProductionCoreInputModesV1(
                firstFrameModeID: "image-to-video",
                lastFrameModeID: "image-to-video"
            )
        )

        try ProductionInputTemplateValidatorV1.validate(
            template,
            requirement: requirement,
            chainedFromPredecessor: false
        )
    }

    @Test("mode identifiers canonicalize underscores and hyphens identically")
    func canonicalModeIdentifiers() throws {
        let requirement = ProductionRequirementV1(
            modalityID: "video",
            modeIDs: [" IMAGE_TO_VIDEO "],
            visibleEntityCount: 1,
            requiresFirstFrame: true
        )
        let template = ProductionInputTemplateV1(
            id: "template-shot-001",
            projectID: "project-001",
            shotID: "shot-001",
            coreInputs: ProductionCoreInputModesV1(
                firstFrameModeID: "image-to-video"
            )
        )

        #expect(
            ProductionIdentifierNormalizerV1.canonical(" IMAGE_TO_VIDEO ")
                == "image-to-video"
        )
        try ProductionInputTemplateValidatorV1.validate(
            template,
            requirement: requirement,
            chainedFromPredecessor: false
        )
    }

    @Test("a chained shot accepts only its predecessor mode")
    func chainedSoleInput() throws {
        let requirement = ProductionRequirementV1(
            modalityID: "video",
            modeIDs: ["image-to-video"],
            visibleEntityCount: 1,
            requiresFirstFrame: true
        )
        let valid = ProductionInputTemplateV1(
            id: "template-shot-002",
            projectID: "project-001",
            shotID: "shot-002",
            coreInputs: ProductionCoreInputModesV1(
                predecessorLastFrameModeID: "image-to-video"
            )
        )
        try ProductionInputTemplateValidatorV1.validate(
            valid,
            requirement: requirement,
            chainedFromPredecessor: true
        )

        let invalid = ProductionInputTemplateV1(
            id: valid.id,
            projectID: valid.projectID,
            shotID: valid.shotID,
            coreInputs: ProductionCoreInputModesV1(
                firstFrameModeID: "image-to-video",
                predecessorLastFrameModeID: "image-to-video"
            )
        )
        #expect(throws: ProductionInputTemplateValidationErrorV1.invalidModeBinding) {
            try ProductionInputTemplateValidatorV1.validate(
                invalid,
                requirement: requirement,
                chainedFromPredecessor: true
            )
        }
    }
}
