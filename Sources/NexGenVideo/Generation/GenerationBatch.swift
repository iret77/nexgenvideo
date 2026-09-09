import Foundation
import NexGenEngine

struct GenerationBatch: Codable, Sendable, Equatable, Identifiable {
    struct Item: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let purpose: String
        let package: GenerationPackageV1
    }
    struct Payload: Codable, Sendable, Equatable {
        let nonce: UUID
        let projectKey: String
        let phase: String?
        let items: [Item]
        let requestSHA256: String?

        init(nonce: UUID, projectKey: String, phase: String?, items: [Item], requestSHA256: String? = nil) {
            self.nonce = nonce; self.projectKey = projectKey; self.phase = phase; self.items = items
            self.requestSHA256 = requestSHA256
        }
    }
    let schema: String
    let id: String
    let payload: Payload

    init(payload: Payload) throws {
        guard !payload.projectKey.isEmpty, payload.projectKey != "none", !payload.items.isEmpty,
              Set(payload.items.map(\.id)).count == payload.items.count else {
            throw GenerationRequestError.gate("A generation batch needs a project and distinct items.")
        }
        for item in payload.items {
            try item.package.validate()
            guard UUID(uuidString: item.id) != nil,
                  !item.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.package.payload.binding.projectKey == payload.projectKey else {
                throw GenerationRequestError.gate("Every batch item must describe a prepared request in the same project.")
            }
        }
        schema = "generation-batch/v1"
        id = FileDigest.sha256(of: try GenerationPackageV1.canonicalData(payload))
        self.payload = payload
    }

    func validate() throws {
        guard try self == Self(payload: payload) else { throw GenerationRequestError.gate("The generation batch changed after preparation.") }
    }

    var totalEUR: Double? {
        let amounts = payload.items.compactMap { $0.package.payload.estimate?.eurAmount }
        guard amounts.count == payload.items.count else { return nil }
        let total = amounts.reduce(0, +)
        return total.isFinite ? total : nil
    }

    func removing(itemIDs: Set<String>) throws -> Self {
        try validate()
        guard itemIDs.isSubset(of: Set(payload.items.map(\.id))) else {
            throw GenerationRequestError.gate("The removed item is not part of this batch.")
        }
        return try Self(payload: .init(nonce: payload.nonce, projectKey: payload.projectKey,
            phase: payload.phase, items: payload.items.filter { !itemIDs.contains($0.id) }, requestSHA256: payload.requestSHA256))
    }
}

struct GenerationBatchJournal: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case queued, submitting, running, complete, failed, canceled, blocked
    }
    struct Execution: Codable, Sendable, Equatable {
        let itemID: String
        var state: State
        var transactionID: String?
        var providerRequestID: String?
        var providerRequestResumable: Bool
        var placeholders: [MediaManifestEntry]
        var outputAssetIDs: [String]
        var detail: String?
    }
    let batchID: String
    let authorityID: String?
    let approvedAt: Date
    private(set) var revision: Int
    private(set) var executions: [Execution]

    init(approving batch: GenerationBatch, authorityID: String, at date: Date = Date()) throws {
        try batch.validate()
        guard batch.totalEUR != nil, !authorityID.isEmpty else {
            throw GenerationRequestError.gate("Every batch item needs a verified monetary ceiling before unattended generation can be approved.")
        }
        batchID = batch.id
        self.authorityID = authorityID
        approvedAt = date
        revision = 0
        executions = batch.payload.items.map {
            Execution(itemID: $0.id, state: .queued, transactionID: nil, providerRequestID: nil,
                providerRequestResumable: false, placeholders: [], outputAssetIDs: [], detail: nil)
        }
    }

    func validate(batch: GenerationBatch) throws {
        try batch.validate()
        guard batchID == batch.id, authorityID?.isEmpty != true, revision >= 0, batch.totalEUR != nil,
              approvedAt.timeIntervalSince1970.isFinite,
              executions.map(\.itemID) == batch.payload.items.map(\.id),
              Set(executions.compactMap(\.transactionID)).count == executions.compactMap(\.transactionID).count else {
            throw GenerationRequestError.gate("The batch execution journal does not match its approved manifest.")
        }
        for execution in executions {
            let item = batch.payload.items.first { $0.id == execution.itemID }!
            if let transaction = execution.transactionID, transaction.isEmpty { throw invalidState() }
            if let request = execution.providerRequestID, request.isEmpty { throw invalidState() }
            guard !execution.providerRequestResumable || execution.providerRequestID != nil else { throw invalidState() }
            if let transaction = execution.transactionID {
                guard execution.placeholders.count == item.package.payload.outputCount,
                      Set(execution.placeholders.map(\.id)).count == execution.placeholders.count else { throw invalidState() }
                for placeholder in execution.placeholders {
                    guard placeholder.generationInput?.spendTransactionId == transaction,
                          placeholder.generationInput?.generationPackageID == item.package.id,
                          placeholder.generationInput.map(GenerationPackageV1.normalized) == item.package.payload.generationInput,
                          placeholder.type.rawValue == item.package.payload.modality,
                          placeholder.duration.isFinite, placeholder.duration > 0,
                          case .project(let path) = placeholder.source,
                          path.hasPrefix(Project.mediaDirectoryName + "/"),
                          path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                        throw invalidState()
                    }
                }
            } else if !execution.placeholders.isEmpty { throw invalidState() }
            guard Set(execution.outputAssetIDs).count == execution.outputAssetIDs.count,
                  execution.outputAssetIDs.allSatisfy({ !$0.isEmpty }) else { throw invalidState() }
            switch execution.state {
            case .queued, .canceled:
                guard execution.transactionID == nil, execution.providerRequestID == nil,
                      execution.outputAssetIDs.isEmpty else { throw invalidState() }
            case .submitting:
                guard execution.transactionID != nil, execution.providerRequestID == nil,
                      execution.outputAssetIDs.isEmpty else { throw invalidState() }
            case .running:
                guard execution.transactionID != nil, execution.providerRequestID != nil,
                      execution.outputAssetIDs.isEmpty else { throw invalidState() }
            case .complete:
                guard execution.transactionID != nil, execution.providerRequestID != nil,
                      execution.outputAssetIDs.count == item.package.payload.outputCount,
                      Set(execution.outputAssetIDs) == Set(execution.placeholders.map(\.id)) else { throw invalidState() }
            case .failed, .blocked:
                guard execution.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      execution.providerRequestID == nil || execution.transactionID != nil,
                      execution.outputAssetIDs.isEmpty else { throw invalidState() }
            }
        }
    }

    mutating func beginSubmission(itemID: String, packageID: String, transactionID: String,
                                  placeholders: [MediaManifestEntry], batch: GenerationBatch) throws {
        try validate(batch: batch)
        let index = try index(of: itemID)
        guard executions[index].state == .queued,
              batch.payload.items[index].package.id == packageID, !transactionID.isEmpty,
              !executions.contains(where: { $0.transactionID == transactionID }),
              placeholders.count == batch.payload.items[index].package.payload.outputCount else {
            throw GenerationRequestError.gate("This batch item cannot consume another provider submission.")
        }
        var updated = self
        updated.executions[index].state = .submitting
        updated.executions[index].transactionID = transactionID
        updated.executions[index].placeholders = placeholders
        updated.revision += 1
        try updated.validate(batch: batch)
        self = updated
    }

    mutating func recordProviderRequest(itemID: String, transactionID: String, requestID: String, resumable: Bool = false) throws {
        let index = try index(of: itemID)
        let existing = executions[index]
        guard existing.transactionID == transactionID, !requestID.isEmpty else { throw invalidState() }
        if existing.providerRequestID == requestID, existing.providerRequestResumable == resumable { return }
        guard existing.state == .submitting, existing.providerRequestID == nil else { throw invalidState() }
        executions[index].providerRequestID = requestID
        executions[index].providerRequestResumable = resumable
        executions[index].state = .running
        revision += 1
    }

    mutating func finish(itemID: String, outputAssetIDs: [String], batch: GenerationBatch) throws {
        try validate(batch: batch)
        let index = try index(of: itemID)
        if executions[index].state == .complete, executions[index].outputAssetIDs == outputAssetIDs { return }
        guard [.running, .blocked].contains(executions[index].state),
              executions[index].transactionID != nil, executions[index].providerRequestID != nil,
              outputAssetIDs.count == batch.payload.items[index].package.payload.outputCount,
              Set(outputAssetIDs).count == outputAssetIDs.count,
              Set(outputAssetIDs) == Set(executions[index].placeholders.map(\.id)) else { throw invalidState() }
        executions[index].state = .complete
        executions[index].outputAssetIDs = outputAssetIDs
        executions[index].detail = nil
        revision += 1
    }

    mutating func resumeRecordedJob(itemID: String) throws {
        let index = try index(of: itemID)
        guard executions[index].providerRequestResumable, executions[index].providerRequestID != nil,
              executions[index].transactionID != nil, [.running, .blocked].contains(executions[index].state) else {
            throw invalidState()
        }
        guard executions[index].state != .running else { return }
        executions[index].state = .running
        executions[index].detail = nil
        revision += 1
    }

    mutating func stop(itemID: String, state: State, detail: String) throws {
        let index = try index(of: itemID)
        guard state == .failed || state == .blocked,
              [.queued, .submitting, .running].contains(executions[index].state),
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalidState() }
        executions[index].state = state
        executions[index].detail = detail
        revision += 1
    }

    mutating func cancelRemaining() {
        for index in executions.indices where executions[index].state == .queued {
            executions[index].state = .canceled
            revision += 1
        }
    }

    private func index(of itemID: String) throws -> Int {
        guard let index = executions.firstIndex(where: { $0.itemID == itemID }) else { throw invalidState() }
        return index
    }

    private func invalidState() -> GenerationRequestError {
        .gate("The generation batch has an invalid execution transition. Restore or reconcile the recorded job before proceeding.")
    }
}
