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

    func replacingPackages(_ packages: [GenerationPackageV1]) throws -> Self {
        try validate()
        guard packages.count == payload.items.count else { throw GenerationPricingFailure.unsupportedOption }
        let items = try zip(payload.items, packages).map { item, package in
            guard try item.package.replacingEstimate(package.payload.estimate) == package,
                  item.package.payload.estimate == nil || item.package == package else {
                throw GenerationRequestError.gate("Pricing retry cannot change a prepared request or its existing monetary ceiling.")
            }
            return Item(id: item.id, purpose: item.purpose, package: package)
        }
        return try Self(payload: .init(nonce: payload.nonce, projectKey: payload.projectKey, phase: payload.phase,
            items: items, requestSHA256: payload.requestSHA256))
    }
}

struct GenerationRouteContinuation: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable {
        let itemID: String
        let packageID: String
        let failure: GenerationPricingFailure
    }

    let kind = "generation_route_change/v1"
    let batchID: String
    let requestID: UUID
    let items: [Item]
    let retainedPackageIDs: [String]

    static var schema: [String: Any] {
        let hash: [String: Any] = ["type": "string", "pattern": "^[a-f0-9]{64}$"]
        let uuid: [String: Any] = ["type": "string", "pattern": "^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$"]
        return ["type": "object", "additionalProperties": false,
            "required": ["kind", "batchID", "requestID", "items", "retainedPackageIDs"],
            "properties": [
                "kind": ["type": "string", "enum": ["generation_route_change/v1"]],
                "batchID": hash, "requestID": uuid,
                "items": ["type": "array", "minItems": 1, "maxItems": 50,
                    "items": ["type": "object", "additionalProperties": false,
                        "required": ["itemID", "packageID", "failure"],
                        "properties": ["itemID": uuid, "packageID": hash,
                            "failure": ["type": "string", "enum": GenerationPricingFailure.allCases.map(\.rawValue)]]]],
                "retainedPackageIDs": ["type": "array", "maxItems": 50, "items": hash]
            ]]
    }

    func validatedData() throws -> Data {
        let bytes = try GenerationPackageV1.canonicalData(self)
        try validateToolInput(in: JSONSerialization.jsonObject(with: bytes), against: Self.schema,
            path: "host_generation_route_change")
        guard Set(items.map(\.itemID)).count == items.count else {
            throw GenerationRequestError.gate("The route change repeats a generation item.")
        }
        return bytes
    }

    func hostText() throws -> String {
        "The pending batch was retired without approval or submission. Re-prepare the selected items in the recorded order "
            + "with alternative executable routes using prepare_generation_batch and this requestID. The host retains the other "
            + "packages and will present one complete replacement batch for fresh native approval. This event grants no spend authority. "
            + "Read get_generation_batches with this batchID to recover the original item purposes and exact packages. "
            + String(decoding: try validatedData(), as: UTF8.self)
    }
}

struct GenerationBatchRetirement: Codable, Sendable, Equatable {
    let batch: GenerationBatch
    let continuation: GenerationRouteContinuation

    func validate() throws {
        try batch.validate()
        _ = try continuation.validatedData()
        let selected = Set(continuation.items.map(\.itemID))
        guard batch.totalEUR == nil, continuation.batchID == batch.id,
              continuation.requestID != batch.payload.nonce,
              selected.isSubset(of: Set(batch.payload.items.map(\.id))),
              continuation.items.map(\.itemID) == batch.payload.items.filter({ selected.contains($0.id) }).map(\.id),
              continuation.retainedPackageIDs == batch.payload.items.filter({ !selected.contains($0.id) }).map(\.package.id) else {
            throw GenerationRequestError.gate("The route change does not match the pending batch.")
        }
        for item in continuation.items {
            guard let original = batch.payload.items.first(where: { $0.id == item.itemID }),
                  original.package.id == item.packageID, original.package.payload.estimate == nil else {
                throw GenerationRequestError.gate("Only unpriced pending items can change route here.")
            }
        }
    }

    func replacing(packages: [GenerationPackageV1], requestSHA256: String) throws -> GenerationBatch {
        try validate()
        guard packages.count == continuation.items.count else {
            throw GenerationRequestError.gate("Re-prepare exactly the selected route-change items in their recorded order.")
        }
        let replacements = Dictionary(uniqueKeysWithValues: zip(continuation.items.map(\.itemID), packages))
        let items = batch.payload.items.map { original in
            GenerationBatch.Item(id: original.id, purpose: original.purpose, package: replacements[original.id] ?? original.package)
        }
        return try GenerationBatch(payload: .init(nonce: continuation.requestID, projectKey: batch.payload.projectKey,
            phase: batch.payload.phase, items: items, requestSHA256: requestSHA256))
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
