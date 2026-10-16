import Foundation
import NexGenEngine

enum PipelineReferenceRouteContract {
    enum Check: Sendable {
        case activatedRoutes([ProductionRouteCandidateV1], discoveryComplete: Bool)
        /// Native edits carry stored demands over unchanged; the write that introduced them validated them.
        case storedDemands
    }

    private struct RoutedDemand {
        let slotField: String
        let demand: ReferenceDemandV1
    }

    static func requiresRoute(_ input: PipelineExecutionShotInput) -> Bool {
        input.sourceMode != .imported
            && input.generationRequirement?.modalityID == .video
            && !input.referenceDemands.isEmpty
    }

    static func validate(
        _ executionInputs: [PipelineExecutionShotInput],
        check: Check
    ) throws {
        guard case .activatedRoutes(let routes, let discoveryComplete) = check else { return }
        try validate(executionInputs, routes: routes, discoveryComplete: discoveryComplete)
    }

    static func validate(
        _ executionInputs: [PipelineExecutionShotInput],
        routes: [ProductionRouteCandidateV1],
        discoveryComplete: Bool = true
    ) throws {
        for input in executionInputs {
            for (index, demand) in input.referenceDemands.enumerated() {
                let path = "execution_shot[\(input.id)].reference_demands[\(index)]"
                try validateRole(demand, path: path)
                try validateCurrentSlot(demand, path: path)
            }
            if requiresRoute(input) {
                try validateRoute(input, routes: routes, discoveryComplete: discoveryComplete)
            }
        }
    }

    static func catalogPending(shotID: String) -> ToolError {
        ToolError(
            "Provider catalog discovery has not finished, so it is not yet known which activated "
                + "video routes can bind execution_shot[\(shotID)]. Nothing was written. Call "
                + "write_shotlist again with the same arguments; if no route fits then, the error "
                + "names the field and rule. Nothing is missing on the user's side: do not ask the "
                + "user to change providers and do not edit reference demands because of this message.",
            kind: .hostBusy
        )
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

    private static func validateCurrentSlot(
        _ demand: PipelineReferenceDemandInput,
        path: String
    ) throws {
        guard ProductionInputSlotAliasV1.isRetired(demand.inputSlotID) else { return }
        throw PipelineExecutionShotInputValidationError.violation(
            field: "\(path).input_slot_id",
            rule: "\(demand.inputSlotID) is a retired input slot that no production route offers. "
                + "Use \(ProductionInputSlotAliasV1.routedSlotID(demand.inputSlotID)) "
                + "(get_project_state.execution_input_contract.reference_anchor) with a mode_id "
                + "from list_models.production_routes."
        )
    }

    private static func validateRoute(
        _ input: PipelineExecutionShotInput,
        routes: [ProductionRouteCandidateV1],
        discoveryComplete: Bool
    ) throws {
        guard let supplied = input.generationRequirement else { return }
        let requirement = ProductionRequirementV1(
            modalityID: supplied.modalityID.rawValue,
            modeIDs: supplied.modeIDs,
            visibleEntityCount: 0
        )
        let candidates = routes.filter {
            $0.capabilities.offering.modality.rawValue == requirement.modalityID
        }
        let demands = routedDemands(input)
        // Render picks the route from required inputs alone and drops optional ones it cannot place.
        let required = demands.map(\.demand).filter(\.isRequired)
        let unoffered = demands.first {
            !offered($0.demand, modalityID: requirement.modalityID, by: candidates)
        }
        if unoffered == nil, bindable(requirement, required, on: candidates) { return }
        guard discoveryComplete else { throw catalogPending(shotID: input.id) }
        let shot = "execution_shot[\(input.id)]"
        guard !candidates.isEmpty else {
            let modality = input.referenceDemands[0].modality.rawValue
            throw PipelineExecutionShotInputValidationError.violation(
                field: "\(shot).reference_demands[0].input_slot_id",
                rule: "No activated video route accepts \(modality) references; ask the user to "
                    + "activate a provider that does, or remove the demand."
            )
        }
        guard bindable(requirement, [], on: candidates) else {
            throw PipelineExecutionShotInputValidationError.violation(
                field: "\(shot).generation_requirement.mode_ids",
                rule: "no activated video route supports \(supplied.modeIDs.joined(separator: ", ")). "
                    + "Activated routes support: \(offeredModes(candidates))."
            )
        }
        if let item = unoffered {
            throw PipelineExecutionShotInputValidationError.violation(
                field: item.slotField,
                rule: "no activated video route offers \(item.demand.inputSlotID) for "
                    + "\(item.demand.modality.rawValue) in mode \(item.demand.modeID). "
                    + offeredSlots(candidates, modality: item.demand.modality)
            )
        }
        let evaluations = ProductionRequirementResolverV1.requiredInputEvaluations(
            requirement: requirement,
            demands: required,
            candidates: candidates
        ).sorted { $0.deficits.count < $1.deficits.count }
        let perRoute = evaluations.prefix(5).map { evaluation in
            evaluation.candidate.capabilities.offering.offeringID + ": "
                + evaluation.deficits.map { deficit in
                    "\(deficit.code.rawValue)"
                        + (deficit.capabilityFieldID.map { " \($0)" } ?? "")
                        + " required \(deficit.requiredValue)"
                        + (deficit.availableValue.map { ", available \($0)" } ?? "")
                }.joined(separator: "; ")
        }
        throw PipelineExecutionShotInputValidationError.violation(
            field: shot,
            rule: "no single activated video route binds all required reference demands, core_inputs "
                + "and generation_requirement.mode_ids of this shot together within its reference "
                + "limits. "
                + perRoute.joined(separator: " | ")
                + ". Choose one route from list_models.production_routes and keep every required "
                + "input of this shot within its input_slots, mode_ids and reference limits. Render "
                + "drops an is_required=false reference the chosen route cannot take."
        )
    }

    private static func offered(
        _ demand: ReferenceDemandV1,
        modalityID: String,
        by candidates: [ProductionRouteCandidateV1]
    ) -> Bool {
        let alone = ProductionRequirementV1(
            modalityID: modalityID,
            modeIDs: [demand.modeID],
            visibleEntityCount: 0
        )
        return ProductionRequirementResolverV1.slotAndModeEvaluations(
            requirement: alone,
            demands: [demand],
            candidates: candidates
        ).contains { $0.deficits.isEmpty }
    }

    private static func routedDemands(_ input: PipelineExecutionShotInput) -> [RoutedDemand] {
        var result: [RoutedDemand] = []
        for (index, demand) in input.referenceDemands.enumerated() {
            let path = "execution_shot[\(input.id)].reference_demands[\(index)]"
            result.append(RoutedDemand(
                slotField: "\(path).input_slot_id",
                demand: ReferenceDemandV1(
                    id: demand.id,
                    assetID: demand.id,
                    modality: demand.modality,
                    semanticJobID: demand.semanticJobID,
                    isRequired: demand.isRequired,
                    priority: demand.priority,
                    preservationScopeIDs: demand.preservationScopeIDs,
                    exclusionDemandIDs: demand.exclusionDemandIDs,
                    inputSlotID: demand.inputSlotID,
                    modeID: demand.modeID
                )
            ))
        }
        guard let core = input.coreInputs else { return result }
        let modes = ProductionCoreInputModesV1(
            firstFrameModeID: core.firstFrameModeID,
            lastFrameModeID: core.lastFrameModeID,
            predecessorLastFrameModeID: core.predecessorLastFrameModeID,
            sourceVideoModeID: core.sourceVideoModeID,
            audioTimingModeID: core.audioTimingModeID
        )
        for job in PipelineProductionInputsWriter.CoreInputJob.allCases {
            guard let modeID = job.modeID(in: modes) else { continue }
            let field = "execution_shot[\(input.id)].core_inputs.\(coreInputField(job))"
            result.append(RoutedDemand(
                slotField: field,
                demand: PipelineProductionInputsWriter.coreDemand(
                    job,
                    shotID: input.id,
                    assetID: job.demandID(shotID: input.id),
                    modeID: modeID
                )
            ))
        }
        return result
    }

    private static func bindable(
        _ requirement: ProductionRequirementV1,
        _ demands: [ReferenceDemandV1],
        on candidates: [ProductionRouteCandidateV1]
    ) -> Bool {
        ProductionRequirementResolverV1.requiredInputEvaluations(
            requirement: requirement,
            demands: demands,
            candidates: candidates
        ).contains { $0.deficits.isEmpty }
    }

    private static func coreInputField(
        _ job: PipelineProductionInputsWriter.CoreInputJob
    ) -> String {
        switch job {
        case .firstFrame: "first_frame_mode_id"
        case .lastFrame: "last_frame_mode_id"
        case .predecessorLastFrame: "predecessor_last_frame_mode_id"
        case .sourceVideo: "source_video_mode_id"
        case .audioTiming: "audio_timing_mode_id"
        }
    }

    private static func offeredModes(_ candidates: [ProductionRouteCandidateV1]) -> String {
        Set(candidates.map { candidate in
            let modes = candidate.capabilities.effective.fields
                .strings[CapabilityFieldIDV1.modes]?.value ?? []
            return "\(candidate.capabilities.offering.offeringID) [\(modes.sorted().joined(separator: ", "))]"
        }).sorted().prefix(5).joined(separator: "; ")
    }

    private static func offeredSlots(
        _ candidates: [ProductionRouteCandidateV1],
        modality: AssetPhysicalModalityV1
    ) -> String {
        let slots = candidates.flatMap(\.inputSlots).filter { $0.modality == modality }
        guard !slots.isEmpty else {
            return "No activated video route accepts \(modality.rawValue) references; ask the user "
                + "to activate a provider that does, or remove the demand."
        }
        return "Activated routes offer: " + Set(slots.map {
            "\($0.id) [\($0.modeIDs.sorted().joined(separator: ", "))]"
        }).sorted().joined(separator: "; ") + "."
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
