import Foundation

public struct PhaseApprovalValidity: Sendable, Equatable {
    public let historicallyApproved: Bool
    public let isCurrent: Bool
    public let diagnostic: String?
    public let lineageRecorded: Bool

    public init(historicallyApproved: Bool, isCurrent: Bool, diagnostic: String? = nil, lineageRecorded: Bool = false) {
        self.historicallyApproved = historicallyApproved
        self.isCurrent = isCurrent
        self.diagnostic = diagnostic
        self.lineageRecorded = lineageRecorded
    }
}

extension ProjectStateBuilder {
    public static func approvalValidity(dataRoot: URL, order: [String], registry: EngineRegistry) throws -> [String: PhaseApprovalValidity] {
        let snapshot = try buildSnapshot(dataRoot: dataRoot, order: order)
        let lineage = try PipelineLineageStore.loadIfPresent(dataRoot: dataRoot)
        var result: [String: PhaseApprovalValidity] = [:]
        var predecessorCurrent = true
        for phase in snapshot.phases {
            let lineageRecorded = lineage?.phases[phase.phase] != nil
            do {
                guard predecessorCurrent else { throw GateBlocked("An earlier phase is unapproved or stale.") }
                if let provider = registry.phaseLineageProviders[phase.phase] {
                    try PipelineLineageStore.requireCurrent(phase: phase.phase, snapshot: provider(dataRoot), dataRoot: dataRoot)
                }
                if let requirement = registry.gateRequirements[phase.phase] { try requirement(dataRoot) }
                result[phase.phase] = PhaseApprovalValidity(historicallyApproved: phase.approved, isCurrent: true, lineageRecorded: lineageRecorded)
                predecessorCurrent = phase.approved
            } catch {
                result[phase.phase] = PhaseApprovalValidity(historicallyApproved: phase.approved, isCurrent: false, diagnostic: error.localizedDescription, lineageRecorded: lineageRecorded)
                predecessorCurrent = false
            }
        }
        return result
    }
}
