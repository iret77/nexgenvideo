import Foundation

// Mirrors the engine's `ProjectState.model_dump()` JSON (engine/nexgen_engine/state.py, via
// mcp_server.project_state → read.py "state"). Dumped WITHOUT by_alias, so every key is the raw
// Python snake_case name plus the native host's authoritative money-journal fields. Decoding remains
// compatible with project state written before those fields existed.

struct ProjectStateData: Codable, Sendable, Equatable {
    var project: String
    var mode: String
    var budgetEur: Double
    var budgetStopEur: Double?
    var budgetSpentEur: Double
    var budgetRemainingEur: Double?
    var hardStopRemainingEur: Double?
    var spendComplete: Bool
    var activeReservations: Int
    var unpricedTransactions: Int
    var legacyGenerations: Int
    var phases: [ProjectPhase]
    var nextPhase: String?

    enum CodingKeys: String, CodingKey {
        case project, mode, phases
        case budgetEur = "budget_eur"
        case budgetStopEur = "budget_stop_eur"
        case budgetSpentEur = "budget_spent_eur"
        case budgetRemainingEur = "budget_remaining_eur"
        case hardStopRemainingEur = "hard_stop_remaining_eur"
        case spendComplete = "spend_complete"
        case activeReservations = "active_reservations"
        case unpricedTransactions = "unpriced_transactions"
        case legacyGenerations = "legacy_generations"
        case nextPhase = "next_phase"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        budgetEur = try c.decodeIfPresent(Double.self, forKey: .budgetEur) ?? 0
        budgetStopEur = try c.decodeIfPresent(Double.self, forKey: .budgetStopEur)
        budgetSpentEur = try c.decodeIfPresent(Double.self, forKey: .budgetSpentEur) ?? 0
        budgetRemainingEur = try c.decodeIfPresent(Double.self, forKey: .budgetRemainingEur)
        hardStopRemainingEur = try c.decodeIfPresent(Double.self, forKey: .hardStopRemainingEur)
        spendComplete = try c.decodeIfPresent(Bool.self, forKey: .spendComplete) ?? true
        activeReservations = try c.decodeIfPresent(Int.self, forKey: .activeReservations) ?? 0
        unpricedTransactions = try c.decodeIfPresent(Int.self, forKey: .unpricedTransactions) ?? 0
        legacyGenerations = try c.decodeIfPresent(Int.self, forKey: .legacyGenerations) ?? 0
        phases = try c.decodeIfPresent([ProjectPhase].self, forKey: .phases) ?? []
        nextPhase = try c.decodeIfPresent(String.self, forKey: .nextPhase)
    }

    /// Host-reported executable phase; missing state never falls back to a UI-derived phase.
    var nextPhaseName: String? {
        guard let nextPhase,
              !nextPhase.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return nextPhase
    }

    var isComplete: Bool { !phases.isEmpty && phases.allSatisfy(\.approved) }

    /// Fraction of phases approved, 0…1, for a progress readout.
    var progress: Double {
        guard !phases.isEmpty else { return 0 }
        return Double(phases.filter(\.approved).count) / Double(phases.count)
    }

    /// True when the budget is exhausted or spending has crossed into the last 10% of the budget.
    var budgetWarning: Bool {
        guard spendComplete else { return true }
        guard budgetEur > 0 else { return budgetSpentEur > 0 }
        guard let budgetRemainingEur else { return true }
        return budgetRemainingEur <= 0 || budgetRemainingEur < budgetEur * 0.1
    }

    var spendWarning: String? {
        let incomplete = !spendComplete
        if let stop = budgetStopEur, stop.isFinite, stop > 0,
           budgetSpentEur >= stop {
            return incomplete ? "Hard stop reached · Spend incomplete" : "Hard stop reached"
        }
        if budgetEur.isFinite, budgetEur > 0, budgetSpentEur >= budgetEur {
            return incomplete ? "Over budget · Spend incomplete" : "Over budget"
        }
        if incomplete { return "Spend incomplete" }
        guard budgetEur.isFinite, budgetEur > 0, budgetWarning else { return nil }
        return "Low budget"
    }

    /// Spent as a fraction of budget, clamped to 0…1 for a bar fill.
    var spentFraction: Double {
        guard budgetEur > 0 else { return budgetSpentEur > 0 ? 1 : 0 }
        return min(1, max(0, budgetSpentEur / budgetEur))
    }
}

struct ProductionNavigationData: Sendable, Equatable {
    let contract: ContractData
    let state: ProjectStateData?

    static func validated(
        contract: ContractData,
        state: ProjectStateData?
    ) throws -> ProductionNavigationData {
        let order = contract.phaseOrder
        guard !order.isEmpty,
              Set(order).count == order.count,
              Set(contract.phases.keys) == Set(order),
              order.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              order.allSatisfy({ phase in
                  guard let entry = contract.phases[phase],
                        let selector = entry.artifactSelector else { return false }
                  return !entry.surface.trimmingCharacters(in: .whitespaces).isEmpty
                      && !entry.taskClass.trimmingCharacters(in: .whitespaces).isEmpty
                      && !selector.trimmingCharacters(in: .whitespaces).isEmpty
              }) else {
            throw ValidationError.invalidContract
        }
        guard let state else {
            return ProductionNavigationData(contract: contract, state: nil)
        }
        let stateOrder = state.phases.map(\.phase)
        guard stateOrder == order else { throw ValidationError.phaseOrderMismatch }
        let expectedNext = state.phases.first { !$0.approved }?.phase
        guard state.nextPhaseName == expectedNext else {
            throw ValidationError.nextPhaseMismatch
        }
        return ProductionNavigationData(contract: contract, state: state)
    }

    enum ValidationError: Error, Equatable {
        case invalidContract
        case phaseOrderMismatch
        case nextPhaseMismatch
    }
}

enum PipelineNavigationSelection {
    static func normalized(
        requestedPhase: String?,
        requestedTab: CockpitTab,
        requestedPackSurfaceID: String?,
        state: ProjectStateData,
        contract: ContractData,
        availablePackSurfaces: [CockpitSurfaceData]
    ) -> String? {
        let ids = Set(state.phases.map(\.phase))
        if let requestedPhase, ids.contains(requestedPhase) { return requestedPhase }
        if requestedTab != .pipeline || requestedPackSurfaceID != nil {
            if let match = state.phases.first(where: { phase in
                guard let route = PipelineSurfaceRouting.route(
                    for: phase.phase,
                    contract: contract,
                    availablePackSurfaces: availablePackSurfaces
                ) else { return false }
                if let requestedPackSurfaceID {
                    return route.destination == .pack(requestedPackSurfaceID)
                }
                return route.legacyTab == requestedTab
            }) {
                return match.phase
            }
        }
        return state.nextPhaseName ?? state.phases.last?.phase
    }
}

/// One pipeline phase and whether its gate has been approved.
struct ProjectPhase: Codable, Sendable, Equatable, Identifiable {
    var phase: String
    var approved: Bool
    var state: String
    var notes: String?

    var id: String { phase }

    enum CodingKeys: String, CodingKey {
        case phase, approved, state, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved) ?? false
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? (approved ? "approved" : "pending")
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}
