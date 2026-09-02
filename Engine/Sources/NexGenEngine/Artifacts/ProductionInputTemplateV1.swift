import Foundation

public let productionInputTemplateV1Schema = "production-input-template/v1"

public struct ProductionCoreInputModesV1: Codable, Sendable, Equatable {
    public let firstFrameModeID: String?
    public let lastFrameModeID: String?
    public let predecessorLastFrameModeID: String?
    public let sourceVideoModeID: String?
    public let audioTimingModeID: String?

    private enum CodingKeys: String, CodingKey {
        case firstFrameModeID = "first_frame_mode_id"
        case lastFrameModeID = "last_frame_mode_id"
        case predecessorLastFrameModeID = "predecessor_last_frame_mode_id"
        case sourceVideoModeID = "source_video_mode_id"
        case audioTimingModeID = "audio_timing_mode_id"
    }

    public init(
        firstFrameModeID: String? = nil,
        lastFrameModeID: String? = nil,
        predecessorLastFrameModeID: String? = nil,
        sourceVideoModeID: String? = nil,
        audioTimingModeID: String? = nil
    ) {
        self.firstFrameModeID = firstFrameModeID
        self.lastFrameModeID = lastFrameModeID
        self.predecessorLastFrameModeID = predecessorLastFrameModeID
        self.sourceVideoModeID = sourceVideoModeID
        self.audioTimingModeID = audioTimingModeID
    }
}

public struct ProductionInputTemplateV1: Codable, Sendable, Equatable {
    public static let artifactRole = "core.production-input-template"

    public let schema: String
    public let id: String
    public let projectID: String
    public let shotID: String
    public let coreInputs: ProductionCoreInputModesV1

    private enum CodingKeys: String, CodingKey {
        case schema
        case id
        case projectID = "project_id"
        case shotID = "shot_id"
        case coreInputs = "core_inputs"
    }

    public init(
        schema: String = productionInputTemplateV1Schema,
        id: String,
        projectID: String,
        shotID: String,
        coreInputs: ProductionCoreInputModesV1
    ) {
        self.schema = schema
        self.id = id
        self.projectID = projectID
        self.shotID = shotID
        self.coreInputs = coreInputs
    }
}

public enum ProductionInputTemplateValidationErrorV1: Error, Sendable, Equatable {
    case unsupportedSchema(String)
    case invalidIdentity
    case invalidModeBinding
}

public enum ProductionInputTemplateValidatorV1 {
    public static func validate(
        _ template: ProductionInputTemplateV1,
        requirement: ProductionRequirementV1,
        chainedFromPredecessor: Bool
    ) throws {
        guard template.schema == productionInputTemplateV1Schema else {
            throw ProductionInputTemplateValidationErrorV1.unsupportedSchema(template.schema)
        }
        guard nonEmpty(template.id), nonEmpty(template.projectID), nonEmpty(template.shotID) else {
            throw ProductionInputTemplateValidationErrorV1.invalidIdentity
        }
        let inputs = template.coreInputs
        let declaredModes = Set(requirement.modeIDs.map(
            ProductionIdentifierNormalizerV1.canonical
        ))
        let modes = [
            inputs.firstFrameModeID,
            inputs.lastFrameModeID,
            inputs.predecessorLastFrameModeID,
            inputs.sourceVideoModeID,
            inputs.audioTimingModeID,
        ].compactMap { $0 }
        guard modes.allSatisfy({
            nonEmpty($0)
                && declaredModes.contains(ProductionIdentifierNormalizerV1.canonical($0))
        }),
              (inputs.firstFrameModeID == nil || inputs.predecessorLastFrameModeID == nil),
              requirement.requiresFirstFrame
                == (inputs.firstFrameModeID != nil || inputs.predecessorLastFrameModeID != nil),
              requirement.requiresLastFrame == (inputs.lastFrameModeID != nil),
              (requirement.sourceVideoAssetID != nil) == (inputs.sourceVideoModeID != nil),
              chainedFromPredecessor == (inputs.predecessorLastFrameModeID != nil) else {
            throw ProductionInputTemplateValidationErrorV1.invalidModeBinding
        }
    }

    private static func nonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
