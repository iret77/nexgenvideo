import Foundation

/// Append-only record of every AI generation in the project. Persisted as `generation-log.json`
struct GenerationLog: Codable, Sendable, Equatable {
    var version: Int = 2
    var entries: [GenerationLogEntry] = []
    var spendEvents: [GenerationSpendEvent] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([GenerationLogEntry].self, forKey: .entries) ?? []
        spendEvents = try c.decodeIfPresent([GenerationSpendEvent].self, forKey: .spendEvents) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case entries
        case spendEvents
    }
}

/// One row in the Project Activity log.
struct GenerationLogEntry: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    let model: String
    let costCredits: Int?
    let createdAt: Date?
    let spendTransactionId: String?

    init(
        id: String = UUID().uuidString,
        model: String,
        costCredits: Int?,
        createdAt: Date?,
        spendTransactionId: String? = nil
    ) {
        self.id = id
        self.model = model
        self.costCredits = costCredits
        self.createdAt = createdAt
        self.spendTransactionId = spendTransactionId
    }

    private enum LegacyKeys: String, CodingKey { case cost }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.model = try c.decode(String.self, forKey: .model)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.spendTransactionId = try c.decodeIfPresent(String.self, forKey: .spendTransactionId)
        if let credits = try c.decodeIfPresent(Int.self, forKey: .costCredits) {
            self.costCredits = credits
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if let dollars = try legacy.decodeIfPresent(Double.self, forKey: .cost) {
                self.costCredits = Int((dollars * 100).rounded(.up))
            } else {
                self.costCredits = nil
            }
        }
    }
}

@MainActor
extension GenerationLogEntry {
    var modelDisplayName: String {
        ModelRegistry.displayName(for: model)
    }

    var sfSymbolName: String {
        switch ModelRegistry.byId[model] {
        case .video?:   "video.fill"
        case .image?:   "photo.fill"
        case .audio?:   "music.note"
        case .upscale?: "arrow.up.right.square.fill"
        case nil:       "sparkles"
        }
    }
}

extension EditorViewModel {

    var generationLogEntries: [GenerationLogEntry] {
        generationLog.entries.sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.id < rhs.id
            }
        }
    }

    var totalGenerationCost: Int {
        generationLog.entries.reduce(0) { $0 + ($1.costCredits ?? 0) }
    }

    func appendGenerationLog(for asset: MediaAsset) {
        guard let gen = asset.generationInput else { return }
        generationLog.entries.append(GenerationLogEntry(
            model: gen.model,
            costCredits: CostEstimator.cost(for: gen),
            createdAt: gen.createdAt,
            spendTransactionId: gen.spendTransactionId
        ))
        try? persistGenerationLog()
    }

    /// For old projects saved before the persistent log existed:
    func seedGenerationLogFromAssets() {
        guard generationLog.entries.isEmpty else { return }
        generationLog.entries = mediaAssets.compactMap { asset in
            guard let gen = asset.generationInput else { return nil }
            return GenerationLogEntry(
                model: gen.model,
                costCredits: CostEstimator.cost(for: gen),
                createdAt: gen.createdAt
            )
        }
    }

    func recordSpendEvent(
        authorization: GenerationAuthorization,
        kind: GenerationSpendEvent.Kind,
        providerRequestId: String? = nil,
        money: GenerationMoney? = nil,
        note: String? = nil
    ) throws {
        guard let transactionId = authorization.transactionId else { return }
        let previousLog = generationLog
        generationLog.version = 2
        generationLog.spendEvents.append(GenerationSpendEvent(
            transactionId: transactionId,
            kind: kind,
            model: authorization.target.modelId,
            provider: authorization.target.provider,
            transport: authorization.target.transport,
            endpoint: authorization.target.endpoint,
            providerRequestId: providerRequestId,
            money: money,
            note: note
        ))
        do {
            _ = try GenerationBudgetGuard.verifiedSpend(
                log: generationLog,
                generatedAssets: mediaAssets,
                requireCompleteMoney: false
            )
            try persistGenerationLog()
        } catch {
            generationLog = previousLog
            throw error
        }
    }

    func persistGenerationLog() throws {
        guard let workingRoot else { return }
        guard let key = openWorkingCopyKey else {
            throw CocoaError(.fileWriteUnknown)
        }
        try ProjectWorkingCopy.markDirty(key: key)
        let data = try JSONEncoder().encode(generationLog)
        try data.write(
            to: workingRoot.appendingPathComponent(Project.generationLogFilename),
            options: .atomic
        )
        onPipelineChanged?()
    }
}
