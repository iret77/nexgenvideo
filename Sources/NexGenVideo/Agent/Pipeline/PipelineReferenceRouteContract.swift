import Foundation
import NexGenEngine

enum PipelineReferenceRouteContract {
    static func validate(
        _ executionInputs: [PipelineExecutionShotInput],
        routes: [ProductionRouteCandidateV1]
    ) throws {
        let videoSlots = routes
            .filter { $0.capabilities.offering.modality == .video }
            .flatMap(\.inputSlots)
        for input in executionInputs {
            let routed = input.sourceMode != .imported
                && input.generationRequirement?.modalityID == .video
            for (index, demand) in input.referenceDemands.enumerated() {
                let path = "execution_shot[\(input.id)].reference_demands[\(index)]"
                try validateRole(demand, path: path)
                if routed {
                    try validateSlot(demand, path: path, offered: videoSlots)
                }
            }
        }
    }

    private static func validateRole(
        _ demand: PipelineReferenceDemandInput,
        path: String
    ) throws {
        guard let modalities = ProductionReferenceDemandSemanticsV1.modalities(
            forSelectableRole: demand.semanticJobID
        ) else {
            throw PipelineExecutionShotInputValidationError.violation(
                field: "\(path).semantic_job_id",
                rule: "\(demand.semanticJobID) is not a reference role. Use one of \(roleList); "
                    + "character, location and prop anchors use \(CoreReferenceSemanticJobIDV1.referenceAnchor) with entity_id."
            )
        }
        guard modalities.contains(demand.modality) else {
            throw PipelineExecutionShotInputValidationError.violation(
                field: "\(path).modality",
                rule: "\(demand.semanticJobID) accepts \(names(modalities)), not \(demand.modality.rawValue)."
            )
        }
    }

    private static func validateSlot(
        _ demand: PipelineReferenceDemandInput,
        path: String,
        offered: [ProductionInputSlotCapabilityV1]
    ) throws {
        let mode = ProductionIdentifierNormalizerV1.canonical(demand.modeID)
        let supported = offered.contains { slot in
            ProductionIdentifierNormalizerV1.matches(slot.id, demand.inputSlotID)
                && slot.modality == demand.modality
                && slot.modeIDs.map(ProductionIdentifierNormalizerV1.canonical).contains(mode)
        }
        guard !supported else { return }
        let candidates = offered.filter { $0.modality == demand.modality }
        let available = candidates.isEmpty
            ? "No activated video route accepts \(demand.modality.rawValue) references; ask the user to activate a provider that does, or remove the demand."
            : "Activated routes offer: " + Set(candidates.map {
                "\($0.id) [\($0.modeIDs.sorted().joined(separator: ", "))]"
            }).sorted().joined(separator: "; ") + "."
        throw PipelineExecutionShotInputValidationError.violation(
            field: "\(path).input_slot_id",
            rule: "no activated video route offers \(demand.inputSlotID) for \(demand.modality.rawValue) in mode \(demand.modeID). \(available)"
        )
    }

    private static var roleList: String {
        ProductionReferenceDemandSemanticsV1.selectableModalities
            .sorted { $0.key < $1.key }
            .map { "\($0.key) (\(names($0.value)))" }
            .joined(separator: ", ")
    }

    private static func names(_ modalities: Set<AssetPhysicalModalityV1>) -> String {
        modalities.map(\.rawValue).sorted().joined(separator: "/")
    }
}
