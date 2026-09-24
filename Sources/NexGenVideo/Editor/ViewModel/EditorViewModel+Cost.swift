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
        providerRequestResumable: Bool? = nil,
        money: GenerationMoney? = nil,
        note: String? = nil
    ) throws {
        guard let transactionId = authorization.transactionId else { return }
        try authorization.projectMutationScope?.requireCurrent(editor: self)
        let previousLog = generationLog
        generationLog.version = 2
        let event = GenerationSpendEvent(
            transactionId: transactionId,
            kind: kind,
            model: authorization.target.modelId,
            provider: authorization.target.provider,
            transport: authorization.target.transport,
            endpoint: authorization.target.endpoint,
            providerRequestId: providerRequestId,
            providerRequestResumable: providerRequestResumable,
            money: money,
            note: note
        )
        generationLog.spendEvents.append(event)
        do {
            _ = try GenerationBudgetGuard.verifiedSpend(
                log: generationLog,
                generatedAssets: mediaAssets,
                requireCompleteMoney: false
            )
            if let batch = authorization.batchItem {
                try GenerationBatchStore.recordSpendEvent(event, authorization: batch, editor: self)
            }
            try persistGenerationLog()
        } catch {
            generationLog = previousLog
            throw error
        }
    }

    func releaseUnsubmittedSpendReservation(
        authorization: GenerationAuthorization,
        placeholders: [MediaAsset],
        preserveMireloExecutionIdentity: Bool = false,
        allowDetachedManifest: Bool = false,
        note: String?,
        projectWriter: ((String, Data, Data) throws -> Void)? = nil,
        batchWriter: ((GenerationSpendEvent, GenerationBatchAuthorization, EditorViewModel) throws -> Void)? = nil
    ) throws {
        guard let transactionID = authorization.transactionId else { return }
        guard
              workingRoot != nil,
              let workingCopyKey = openWorkingCopyKey else {
            throw GenerationRequestError.storage(
                "The unsubmitted generation has no live project spend identity."
            )
        }
        try authorization.projectMutationScope?.requireCurrent(editor: self)
        let existingEvents = generationLog.spendEvents.filter {
            $0.transactionId == transactionID
        }
        if existingEvents.last?.kind == .released {
            guard existingEvents.count == 2,
                  let reserved = existingEvents.first,
                  let released = existingEvents.last,
                  reserved.kind == .reserved,
                  reserved.model == authorization.target.modelId,
                  reserved.provider == authorization.target.provider,
                  reserved.transport == authorization.target.transport,
                  reserved.endpoint == authorization.target.endpoint,
                  released.model == reserved.model,
                  released.provider == reserved.provider,
                  released.transport == reserved.transport,
                  released.endpoint == reserved.endpoint,
                  generationLog.entries.allSatisfy {
                    $0.spendTransactionId != transactionID
                  },
                  mediaAssets.allSatisfy {
                    $0.generationInput?.spendTransactionId != transactionID
                  },
                  mediaManifest.entries.allSatisfy({
                    $0.generationInput?.spendTransactionId != transactionID
                  }) else {
                throw GenerationRequestError.storage(
                    "The released generation remains attached to project media or activity."
                )
            }
            if let batch = authorization.batchItem {
                if let batchWriter {
                    try batchWriter(released, batch, self)
                } else {
                    try GenerationBatchStore.recordSpendEvent(
                        released,
                        authorization: batch,
                        editor: self
                    )
                }
            }
            return
        }
        let matchingAssets = mediaAssets.filter {
            $0.generationInput?.spendTransactionId == transactionID
        }
        var expectedAssets: [ObjectIdentifier: MediaAsset] = [:]
        for placeholder in placeholders {
            guard expectedAssets.updateValue(
                placeholder,
                forKey: ObjectIdentifier(placeholder)
            ) == nil else {
                throw GenerationRequestError.storage(
                    "The unsubmitted reservation contains a duplicate placeholder."
                )
            }
        }
        guard placeholders.allSatisfy({ expected in
                  expected.generationInput?.spendTransactionId == transactionID
                      && !FileManager.default.fileExists(atPath: expected.url.path)
              }),
              matchingAssets.allSatisfy({ current in
                  expectedAssets[ObjectIdentifier(current)] != nil
                      && !FileManager.default.fileExists(atPath: current.url.path)
              }) else {
            throw GenerationRequestError.storage(
                "The unsubmitted reservation is attached to conflicting or existing project media."
            )
        }
        let matchingManifestIndices = mediaManifest.entries.indices.filter {
            mediaManifest.entries[$0].generationInput?.spendTransactionId == transactionID
        }
        let placeholderIDs = Set(placeholders.map(\.id))
        guard matchingManifestIndices.allSatisfy({ index in
            let entry = mediaManifest.entries[index]
            guard (placeholderIDs.contains(entry.id) || allowDetachedManifest),
                  let url = mediaResolver.expectedURL(for: entry.id) else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        }) else {
            throw GenerationRequestError.storage(
                "The unsubmitted reservation conflicts with existing project media."
            )
        }
        let transactionEvents = existingEvents
        guard transactionEvents.count == 1,
              let first = transactionEvents.first,
              transactionEvents.last?.kind == .reserved,
              first.model == authorization.target.modelId,
              first.provider == authorization.target.provider,
              first.transport == authorization.target.transport,
              first.endpoint == authorization.target.endpoint else {
            throw GenerationRequestError.storage(
                "The unsubmitted generation does not match its active spend reservation."
            )
        }

        var nextManifest = mediaManifest
        for index in matchingManifestIndices {
            nextManifest.entries[index].generationInput = nil
            if preserveMireloExecutionIdentity {
                nextManifest.entries[index].mireloExecutionTransactionId = transactionID
            }
        }
        var nextLog = generationLog
        nextLog.version = 2
        nextLog.entries.removeAll { $0.spendTransactionId == transactionID }
        let releaseEvent = GenerationSpendEvent(
            transactionId: transactionID,
            kind: .released,
            model: authorization.target.modelId,
            provider: authorization.target.provider,
            transport: authorization.target.transport,
            endpoint: authorization.target.endpoint,
            money: authorization.estimate,
            note: note
        )
        nextLog.spendEvents.append(releaseEvent)
        let projectedInputs = mediaAssets.compactMap { current -> GenerationInput? in
            current.generationInput?.spendTransactionId == transactionID
                ? nil
                : current.generationInput
        }
        _ = try GenerationBudgetGuard.spendSnapshot(
            log: nextLog,
            generatedInputs: projectedInputs
        )
        let manifestData = try JSONEncoder().encode(nextManifest)
        let logData = try JSONEncoder().encode(nextLog)
        if let projectWriter {
            try projectWriter(workingCopyKey, manifestData, logData)
        } else {
            try ProjectWorkingCopy.transact(key: workingCopyKey) { staging in
                try manifestData.write(
                    to: staging.appendingPathComponent(Project.manifestFilename),
                    options: .atomic
                )
                try logData.write(
                    to: staging.appendingPathComponent(Project.generationLogFilename),
                    options: .atomic
                )
            }
        }
        for asset in expectedAssets.values {
            asset.generationInput = nil
            if preserveMireloExecutionIdentity {
                asset.mireloExecutionTransactionId = transactionID
            }
        }
        mediaManifest = nextManifest
        generationLog = nextLog
        onPipelineChanged?()
        if let batch = authorization.batchItem {
            if let batchWriter {
                try batchWriter(releaseEvent, batch, self)
            } else {
                try GenerationBatchStore.recordSpendEvent(
                    releaseEvent,
                    authorization: batch,
                    editor: self
                )
            }
        }
    }

    func releaseUnsubmittedSpendReservation(
        authorization: GenerationAuthorization,
        preserveMireloExecutionIdentity: Bool,
        note: String?
    ) throws {
        guard let transactionID = authorization.transactionId else { return }
        let placeholders = mediaAssets.filter {
            $0.generationInput?.spendTransactionId == transactionID
        }
        try releaseUnsubmittedSpendReservation(
            authorization: authorization,
            placeholders: placeholders,
            preserveMireloExecutionIdentity: preserveMireloExecutionIdentity,
            allowDetachedManifest: true,
            note: note
        )
    }

    func releaseRejectedSpendReservation(
        authorization: GenerationAuthorization,
        asset: MediaAsset,
        executionTransactionID: String,
        note: String?
    ) throws {
        guard authorization.transactionId == executionTransactionID else {
            throw GenerationRequestError.storage(
                "The rejected generation has no matching project spend identity."
            )
        }
        try releaseUnsubmittedSpendReservation(
            authorization: authorization,
            placeholders: [asset],
            preserveMireloExecutionIdentity: true,
            note: note
        )
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
