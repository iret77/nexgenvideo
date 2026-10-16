import Foundation

struct ProjectSpendSnapshot: Sendable, Equatable {
    struct ProviderCredits: Sendable, Equatable {
        let provider: GenerationProvider
        let unit: String
        let amount: Double
        let runs: Int
    }

    /// Money the provider billed for the exact request; never an estimate.
    let verifiedEur: Double
    /// Finished runs whose only known cost is in the provider's own unit.
    let providerCredits: [ProviderCredits]
    let unknownCostCount: Int
    let inFlightCount: Int
    let legacyGenerationCount: Int
    /// Open runs with no provider receipt NexGenVideo can query and no task still working on them.
    var unresolvedCount = 0

    var creditOnlyCount: Int { providerCredits.reduce(0) { $0 + $1.runs } }

    /// True only when every recorded run carries billed money; otherwise spend reads "at least".
    var isComplete: Bool {
        unknownCostCount == 0 && inFlightCount == 0 && unresolvedCount == 0 && creditOnlyCount == 0
            && legacyGenerationCount == 0
    }
}

struct GenerationSpendOutcome: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case inFlight
        /// Neither running in this session nor backed by a provider receipt that can be queried.
        case unresolved
        case finished
        case released
    }

    let transactionId: String
    let model: String
    let provider: GenerationProvider
    let status: Status
    let billedMoney: GenerationMoney?
    let estimate: GenerationMoney?
    let providerCost: GenerationProviderCost?
}

extension GenerationMoney {
    /// fal's billing-events record is the only per-request amount a provider bills in money.
    var isProviderBilled: Bool { pricingSource.contains("/v1/models/billing-events") }
}

enum GenerationSpendLedger {
    static let settledLogVersion = 3

    static func outcomes(
        log: GenerationLog,
        generatedInputs: [GenerationInput],
        completedTransactionIDs: Set<String> = [],
        activeTransactionIDs: Set<String> = []
    ) throws -> [GenerationSpendOutcome] {
        guard (1...settledLogVersion).contains(log.version) else {
            throw corrupt("generation-log.json uses unsupported version \(log.version)")
        }
        var states: [String: State] = [:]
        var order: [String] = []
        var eventIds: Set<String> = []
        for event in log.spendEvents {
            guard eventIds.insert(event.id).inserted else {
                throw corrupt("generation-log.json contains duplicate event \(event.id)")
            }
            guard !event.transactionId.isEmpty,
                  !event.model.isEmpty,
                  !event.endpoint.isEmpty else {
                throw corrupt("generation-log.json contains an incomplete spend event")
            }
            try validate(event.money)
            try validate(event.providerCost)
            if var state = states[event.transactionId] {
                guard state.model == event.model,
                      state.provider == event.provider,
                      state.transport == event.transport,
                      state.endpoint == event.endpoint else {
                    throw corrupt("transaction \(event.transactionId) changes provider or model")
                }
                try state.apply(event)
                states[event.transactionId] = state
            } else {
                guard event.kind == .reserved else {
                    throw corrupt("transaction \(event.transactionId) does not start with a reservation")
                }
                states[event.transactionId] = State(event)
                order.append(event.transactionId)
            }
        }

        for entry in log.entries {
            guard let transactionId = entry.spendTransactionId else { continue }
            guard let state = states[transactionId], state.kind != .released else {
                throw corrupt("activity entry \(entry.id) has no active spend transaction")
            }
        }
        for input in generatedInputs {
            guard let transactionId = input.spendTransactionId else { continue }
            guard let state = states[transactionId], state.kind != .released else {
                throw corrupt("generated media has no active spend transaction")
            }
        }

        // A run that delivered its output is finished even when no closing event was recorded.
        let completed = completedTransactionIDs.union(log.entries.compactMap(\.spendTransactionId))
        return order.compactMap { transactionId in
            guard let state = states[transactionId] else { return nil }
            let status: GenerationSpendOutcome.Status
            switch state.kind {
            case .released: status = .released
            case .charged, .settled: status = .finished
            case .reserved, .submitted:
                if completed.contains(transactionId) {
                    status = .finished
                } else if activeTransactionIDs.contains(transactionId) || state.hasQueryableReceipt {
                    status = .inFlight
                } else {
                    status = .unresolved
                }
            }
            let closing = state.chargedMoney ?? state.settledMoney
            let billed = closing.flatMap { $0.isProviderBilled ? $0 : nil }
            return GenerationSpendOutcome(
                transactionId: transactionId,
                model: state.model,
                provider: state.provider,
                status: status,
                billedMoney: billed,
                estimate: billed == nil ? (closing ?? state.reservedMoney) : nil,
                providerCost: state.providerCost
            )
        }
    }

    static func snapshot(
        log: GenerationLog,
        generatedInputs: [GenerationInput],
        completedTransactionIDs: Set<String> = [],
        activeTransactionIDs: Set<String> = []
    ) throws -> ProjectSpendSnapshot {
        let outcomes = try outcomes(
            log: log,
            generatedInputs: generatedInputs,
            completedTransactionIDs: completedTransactionIDs,
            activeTransactionIDs: activeTransactionIDs
        )
        var billed = 0.0
        var unknown = 0
        var inFlight = 0
        var unresolved = 0
        var credits: [String: ProjectSpendSnapshot.ProviderCredits] = [:]
        var creditOrder: [String] = []
        for outcome in outcomes {
            switch outcome.status {
            case .released:
                continue
            case .inFlight:
                inFlight += 1
            case .unresolved:
                unresolved += 1
            case .finished:
                if let money = outcome.billedMoney {
                    billed += money.eurAmount
                } else if let cost = outcome.providerCost {
                    let key = outcome.provider.rawValue + "|" + cost.unit
                    if let current = credits[key] {
                        credits[key] = ProjectSpendSnapshot.ProviderCredits(provider: current.provider, unit: current.unit,
                            amount: current.amount + cost.amount, runs: current.runs + 1)
                    } else {
                        credits[key] = ProjectSpendSnapshot.ProviderCredits(provider: outcome.provider, unit: cost.unit,
                            amount: cost.amount, runs: 1)
                        creditOrder.append(key)
                    }
                } else {
                    unknown += 1
                }
            }
        }
        guard billed.isFinite, billed >= 0 else {
            throw corrupt("project spend total is invalid")
        }
        let legacyTransactionIDs = Set(
            log.entries.compactMap { entry in
                entry.spendTransactionId == nil ? entry.id : nil
            }
        )
        let legacyAssetIDs = Set(
            generatedInputs.enumerated().compactMap { index, input in
                input.spendTransactionId == nil ? "asset:\(index)" : nil
            }
        )
        return ProjectSpendSnapshot(
            verifiedEur: billed,
            providerCredits: creditOrder.compactMap { credits[$0] },
            unknownCostCount: unknown,
            inFlightCount: inFlight,
            legacyGenerationCount: max(legacyTransactionIDs.count, legacyAssetIDs.count),
            unresolvedCount: unresolved
        )
    }

    static func validate(_ money: GenerationMoney?) throws {
        guard let money else { return }
        guard money.nativeAmount.isFinite, money.nativeAmount >= 0,
              money.eurAmount.isFinite, money.eurAmount >= 0,
              money.eurPerNativeUnit.isFinite, money.eurPerNativeUnit > 0,
              money.nativeCurrency.count == 3,
              !money.exchangeRateDate.isEmpty,
              !money.pricingSource.isEmpty,
              !money.exchangeRateSource.isEmpty else {
            throw corrupt("generation-log.json contains invalid monetary data")
        }
    }

    static func validate(_ cost: GenerationProviderCost?) throws {
        guard let cost else { return }
        guard cost.amount.isFinite, cost.amount >= 0,
              !cost.unit.isEmpty, !cost.source.isEmpty else {
            throw corrupt("generation-log.json contains an invalid provider cost")
        }
    }

    static func corrupt(_ detail: String) -> GenerationBudgetError {
        .blocked("The spend ledger could not be verified: \(detail). No provider request was sent.")
    }

    private struct State {
        let model: String
        let provider: GenerationProvider
        let transport: ProviderTransport
        let endpoint: String
        var kind: GenerationSpendEvent.Kind
        var reservedMoney: GenerationMoney?
        var chargedMoney: GenerationMoney?
        var settledMoney: GenerationMoney?
        var providerCost: GenerationProviderCost?
        var hasQueryableReceipt = false

        init(_ event: GenerationSpendEvent) {
            model = event.model
            provider = event.provider
            transport = event.transport
            endpoint = event.endpoint
            kind = event.kind
            reservedMoney = event.money
            chargedMoney = nil
            settledMoney = nil
            providerCost = event.providerCost
        }

        mutating func apply(_ event: GenerationSpendEvent) throws {
            switch (kind, event.kind) {
            case (_, .reserved):
                throw GenerationSpendLedger.corrupt(
                    "transaction \(event.transactionId) has multiple reservations"
                )
            case (.reserved, .submitted):
                guard event.providerRequestId?.isEmpty == false else {
                    throw GenerationSpendLedger.corrupt(
                        "transaction \(event.transactionId) has no provider request id"
                    )
                }
                guard event.money == reservedMoney else {
                    throw GenerationSpendLedger.corrupt(
                        "transaction \(event.transactionId) changes its submitted amount"
                    )
                }
                hasQueryableReceipt = event.providerRequestResumable == true
                kind = .submitted
            case (.submitted, .charged):
                guard let money = event.money else {
                    throw GenerationSpendLedger.corrupt(
                        "transaction \(event.transactionId) has an unpriced charge"
                    )
                }
                chargedMoney = money
                providerCost = event.providerCost ?? providerCost
                kind = .charged
            case (.submitted, .settled):
                settledMoney = event.money
                providerCost = event.providerCost ?? providerCost
                kind = .settled
            case (.settled, .charged) where settledMoney == nil:
                // A late provider bill replaces a settlement that recorded no money.
                guard let money = event.money else {
                    throw GenerationSpendLedger.corrupt(
                        "transaction \(event.transactionId) has an unpriced charge"
                    )
                }
                chargedMoney = money
                providerCost = event.providerCost ?? providerCost
                kind = .charged
            case (.reserved, .released):
                kind = .released
            default:
                throw GenerationSpendLedger.corrupt(
                    "transaction \(event.transactionId) has invalid \(kind.rawValue) → "
                    + event.kind.rawValue + " transition"
                )
            }
        }
    }
}
