import Foundation
import NexGenEngine

enum PipelineProductionPlanReadStore {
    struct Inventory: Sendable, Equatable {
        let projection: ProductionPlanProjectionV1
        let shots: [Shot]
        let problems: [String]
    }

    struct Shot: Sendable, Equatable {
        let shotID: String
        let route: ProductionRouteV1?
        let inputTemplate: ProductionInputTemplateV1?
        let plannedInputs: [PlannedInput]
        let problems: [String]
    }

    struct PlannedInput: Identifiable, Sendable, Equatable {
        let id: String
        let label: String
        let modeID: String
        let materializationDeferred: Bool
    }

    static func inventory(dataRoot: URL) throws -> Inventory {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let shots = projection.shots.map { shot -> Shot in
            guard let requirement = shot.generationRequirement else {
                return Shot(shotID: shot.id, route: nil, inputTemplate: nil, plannedInputs: [], problems: [])
            }
            var problems: [String] = []
            let route: ProductionRouteV1?
            do {
                let value = try read(ProductionRouteV1.self, path: PipelineLayout.productionRouteFile(shotID: shot.id), dataRoot: dataRoot)
                let candidate = ProductionRouteCandidateV1(capabilities: value.capabilitySnapshot.capabilities,
                    providerActivated: true, liveAvailable: true, qualityScore: value.qualityScore,
                    preferenceScore: value.preferenceScore, qualityTargetIDs: value.capabilitySnapshot.qualityTargetIDs,
                    satisfiedProductionProfileRequirementIDs: value.capabilitySnapshot.satisfiedProductionProfileRequirementIDs,
                    inputSlots: value.capabilitySnapshot.inputSlots, estimatedCost: value.estimatedCost,
                    estimatedLatencySeconds: value.estimatedLatencySeconds)
                let hashes = try ProductionRequirementResolverV1.fingerprints(requirement: requirement, candidate: candidate)
                guard value.schema == productionRouteV1Schema, value.projectID == projection.header.projectID,
                      value.shotID == shot.id, value.offering == candidate.capabilities.offering,
                      value.capabilitySnapshot == ProductionRouteCapabilitySnapshotV1(candidate: candidate),
                      value.requirementSHA256 == hashes.requirementSHA256,
                      value.capabilitiesSHA256 == hashes.capabilitiesSHA256, value.routeSHA256 == hashes.routeSHA256 else {
                    throw ProductionPlanningError.stale("production route")
                }
                route = value
            } catch {
                route = nil
                problems.append("Production route missing or stale: \(error.localizedDescription)")
            }
            let template: ProductionInputTemplateV1?
            do {
                let value = try read(ProductionInputTemplateV1.self,
                    path: PipelineLayout.productionInputTemplateFile(shotID: shot.id), dataRoot: dataRoot)
                guard value.projectID == projection.header.projectID, value.shotID == shot.id else {
                    throw ProductionPlanningError.stale("production input template")
                }
                try ProductionInputTemplateValidatorV1.validate(value, requirement: requirement,
                    chainedFromPredecessor: projection.chains.contains { $0.shotID == shot.id && $0.kind == .frameContinuation })
                template = value
            } catch {
                template = nil
                problems.append("Planned inputs missing or stale: \(error.localizedDescription)")
            }
            let modes = template?.coreInputs
            let declarations: [(String, String, String?, Bool)] = [
                ("first-frame", "First frame", modes?.firstFrameModeID, true),
                ("last-frame", "Last frame", modes?.lastFrameModeID, true),
                ("predecessor-frame", "Predecessor last frame", modes?.predecessorLastFrameModeID, true),
                ("source-video", "Source video", modes?.sourceVideoModeID,
                    projection.chains.contains { $0.shotID == shot.id && $0.kind == .nativeExtension }),
                ("audio-timing", "Audio timing", modes?.audioTimingModeID, false),
            ]
            let inputs = declarations.compactMap { id, label, mode, deferred -> PlannedInput? in
                guard let mode else { return nil }
                return PlannedInput(id: id, label: label, modeID: mode, materializationDeferred: deferred)
            }
            return Shot(shotID: shot.id, route: route, inputTemplate: template, plannedInputs: inputs, problems: problems)
        }
        return Inventory(projection: projection, shots: shots, problems: shots.flatMap { shot in
            shot.problems.map { "\(shot.shotID): \($0)" }
        })
    }

    private static func read<T: Decodable>(_ type: T.Type, path: String, dataRoot: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
    }
}
