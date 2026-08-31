import Foundation
import NexGenEngine

let modelCapabilityResearchStoreV1Schema = "model-capability-research-store/v1"
private let modelCapabilityResearchStoreV0Schema = "model-capability-research-store/v0"

enum ModelCapabilityResearchOverlayStatusV1: String, Codable, Sendable, Equatable {
    case active
    case disabled
    case archived
    case superseded
}

struct ModelCapabilityResearchOverlayRecordV1: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let binding: ModelCapabilityResearchBindingV1
    let scope: ModelCapabilityResearchScopeV1
    let fields: CapabilityFieldsV1
    let allowedSourceHosts: [String]
    let acceptedAt: String
    var status: ModelCapabilityResearchOverlayStatusV1
    var supersedesRecordID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case binding
        case scope
        case fields
        case allowedSourceHosts = "allowed_source_hosts"
        case acceptedAt = "accepted_at"
        case status
        case supersedesRecordID = "supersedes_record_id"
    }

    var canonicalKey: String { binding.canonicalKey(scope: scope) }

    var fieldIDs: [String] {
        Array(
            Set(fields.integers.keys)
                .union(fields.decimals.keys)
                .union(fields.booleans.keys)
                .union(fields.strings.keys)
                .union(fields.integerLists.keys)
        ).sorted()
    }

    var allEvidence: [CapabilityEvidenceV1] {
        fields.researchEvidence
    }

    init(
        id: String,
        binding: ModelCapabilityResearchBindingV1,
        scope: ModelCapabilityResearchScopeV1,
        fields: CapabilityFieldsV1,
        allowedSourceHosts: [String],
        acceptedAt: String,
        status: ModelCapabilityResearchOverlayStatusV1,
        supersedesRecordID: String? = nil
    ) {
        self.id = id
        self.binding = binding
        self.scope = scope
        self.fields = fields
        self.allowedSourceHosts = allowedSourceHosts
        self.acceptedAt = acceptedAt
        self.status = status
        self.supersedesRecordID = supersedesRecordID
    }
}

struct ModelCapabilityResearchStoreDocumentV1: Codable, Sendable, Equatable {
    let schema: String
    var revision: Int
    var records: [ModelCapabilityResearchOverlayRecordV1]

    init(
        schema: String = modelCapabilityResearchStoreV1Schema,
        revision: Int = 0,
        records: [ModelCapabilityResearchOverlayRecordV1] = []
    ) {
        self.schema = schema
        self.revision = revision
        self.records = records
    }
}

enum ModelCapabilityResearchStoreError: Error, Sendable, Equatable {
    case unsupportedSchema(String)
    case malformedStore
    case duplicateRecordID(String)
    case duplicateActiveKey(String)
    case invalidRecord(String)
    case invalidSelection
    case recordNotFound(String)
    case forbiddenLocation
}

enum ModelCapabilityResearchStoreCodec {
    static func decode(_ data: Data) throws -> ModelCapabilityResearchStoreDocumentV1 {
        let root = try rootObject(data)
        guard let schema = root["schema"] as? String else {
            throw ModelCapabilityResearchStoreError.malformedStore
        }
        let document: ModelCapabilityResearchStoreDocumentV1
        switch schema {
        case modelCapabilityResearchStoreV1Schema:
            try validateRootKeys(root, recordKeys: v1RecordKeys)
            do {
                document = try JSONDecoder().decode(ModelCapabilityResearchStoreDocumentV1.self, from: data)
            } catch {
                throw ModelCapabilityResearchStoreError.malformedStore
            }
        case modelCapabilityResearchStoreV0Schema:
            try validateRootKeys(root, recordKeys: v0RecordKeys)
            let legacy: StoreDocumentV0
            do {
                legacy = try JSONDecoder().decode(StoreDocumentV0.self, from: data)
            } catch {
                throw ModelCapabilityResearchStoreError.malformedStore
            }
            document = ModelCapabilityResearchStoreDocumentV1(
                revision: legacy.revision,
                records: legacy.records.map {
                    ModelCapabilityResearchOverlayRecordV1(
                        id: $0.id,
                        binding: $0.binding,
                        scope: $0.scope,
                        fields: $0.fields,
                        allowedSourceHosts: $0.allowedSourceHosts,
                        acceptedAt: $0.acceptedAt,
                        status: .active
                    )
                }
            )
        default:
            throw ModelCapabilityResearchStoreError.unsupportedSchema(schema)
        }
        try validate(document)
        return document
    }

    static func encode(_ document: ModelCapabilityResearchStoreDocumentV1) throws -> Data {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    static func validate(_ document: ModelCapabilityResearchStoreDocumentV1) throws {
        guard document.schema == modelCapabilityResearchStoreV1Schema else {
            throw ModelCapabilityResearchStoreError.unsupportedSchema(document.schema)
        }
        guard document.revision >= 0 else {
            throw ModelCapabilityResearchStoreError.malformedStore
        }
        var ids = Set<String>()
        var activeKeys = Set<String>()
        for record in document.records {
            guard UUID(uuidString: record.id) != nil, ids.insert(record.id).inserted else {
                throw ModelCapabilityResearchStoreError.duplicateRecordID(record.id)
            }
            if let supersedes = record.supersedesRecordID {
                guard UUID(uuidString: supersedes) != nil, supersedes != record.id else {
                    throw ModelCapabilityResearchStoreError.invalidRecord(record.id)
                }
            }
            guard let acceptedDate = ModelCapabilityResearchDatePolicy.date(record.acceptedAt) else {
                throw ModelCapabilityResearchStoreError.invalidRecord(record.id)
            }
            guard let observedAt = record.allEvidence.first?.observedAt,
                  let observedDate = ModelCapabilityResearchDatePolicy.date(observedAt),
                  observedDate <= acceptedDate else {
                throw ModelCapabilityResearchStoreError.invalidRecord(record.id)
            }
            let request = ModelCapabilityResearchRequestV1(
                binding: record.binding,
                scope: record.scope,
                trigger: .staleEvidence,
                fallbackResolution: .exact,
                fallbackProfileID: "local-overlay-validation",
                allowedSourceHosts: record.allowedSourceHosts,
                observedAt: observedDate
            )
            let candidate = ModelCapabilityResearchCandidateV1(
                binding: record.binding,
                scope: record.scope,
                fields: record.fields
            )
            do {
                try ModelCapabilityResearchValidator.validate(
                    candidate,
                    for: request,
                    allowEmpirical: true
                )
            } catch {
                throw ModelCapabilityResearchStoreError.invalidRecord(record.id)
            }
            if record.status == .active, !activeKeys.insert(record.canonicalKey).inserted {
                throw ModelCapabilityResearchStoreError.duplicateActiveKey(record.canonicalKey)
            }
        }
        let recordsByID = Dictionary(uniqueKeysWithValues: document.records.map { ($0.id, $0) })
        for record in document.records {
            var seen = Set([record.id])
            var cursor = record
            while let supersedes = cursor.supersedesRecordID {
                guard let prior = recordsByID[supersedes],
                      prior.canonicalKey == record.canonicalKey,
                      seen.insert(supersedes).inserted else {
                    throw ModelCapabilityResearchStoreError.invalidRecord(record.id)
                }
                cursor = prior
            }
        }
    }

    static func storedSchema(_ data: Data) -> String? {
        guard let root = try? rootObject(data) else { return nil }
        return root["schema"] as? String
    }

    private static let v1RecordKeys: Set<String> = [
        "id", "binding", "scope", "fields", "allowed_source_hosts", "accepted_at",
        "status", "supersedes_record_id",
    ]
    private static let v0RecordKeys: Set<String> = [
        "id", "binding", "scope", "fields", "allowed_source_hosts", "accepted_at",
    ]

    private struct StoreDocumentV0: Codable {
        let schema: String
        let revision: Int
        let records: [RecordV0]
    }

    private struct RecordV0: Codable {
        let id: String
        let binding: ModelCapabilityResearchBindingV1
        let scope: ModelCapabilityResearchScopeV1
        let fields: CapabilityFieldsV1
        let allowedSourceHosts: [String]
        let acceptedAt: String

        private enum CodingKeys: String, CodingKey {
            case id
            case binding
            case scope
            case fields
            case allowedSourceHosts = "allowed_source_hosts"
            case acceptedAt = "accepted_at"
        }
    }

    private static func rootObject(_ data: Data) throws -> [String: Any] {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ModelCapabilityResearchStoreError.malformedStore
        }
        guard let root = decoded as? [String: Any] else {
            throw ModelCapabilityResearchStoreError.malformedStore
        }
        return root
    }

    private static func validateRootKeys(
        _ root: [String: Any],
        recordKeys: Set<String>
    ) throws {
        let rootKeys: Set<String> = ["schema", "revision", "records"]
        guard Set(root.keys) == rootKeys,
              let rawRecords = root["records"] as? [Any] else {
            throw ModelCapabilityResearchStoreError.malformedStore
        }
        for rawRecord in rawRecords {
            guard let record = rawRecord as? [String: Any],
                  Set(record.keys).isSubset(of: recordKeys),
                  Set(["id", "binding", "scope", "fields", "allowed_source_hosts", "accepted_at"])
                    .isSubset(of: Set(record.keys)) else {
                throw ModelCapabilityResearchStoreError.malformedStore
            }
            if recordKeys == v1RecordKeys, record["status"] == nil {
                throw ModelCapabilityResearchStoreError.malformedStore
            }
            let candidate: [String: Any] = [
                "schema": modelCapabilityResearchCandidateV1Schema,
                "binding": record["binding"] as Any,
                "scope": record["scope"] as Any,
                "fields": record["fields"] as Any,
            ]
            guard let candidateData = try? JSONSerialization.data(withJSONObject: candidate),
                  let decodedCandidate = try? JSONDecoder().decode(
                    ModelCapabilityResearchCandidateV1.self,
                    from: candidateData
                  ),
                  let hosts = record["allowed_source_hosts"] as? [String] else {
                throw ModelCapabilityResearchStoreError.malformedStore
            }
            guard let observedAt = decodedCandidate.fields.researchEvidence.first?.observedAt,
                  let observedDate = ModelCapabilityResearchDatePolicy.date(observedAt) else {
                throw ModelCapabilityResearchStoreError.malformedStore
            }
            let request = ModelCapabilityResearchRequestV1(
                binding: decodedCandidate.binding,
                scope: decodedCandidate.scope,
                trigger: .staleEvidence,
                fallbackResolution: .exact,
                fallbackProfileID: "closed-store-validation",
                allowedSourceHosts: hosts,
                observedAt: observedDate
            )
            do {
                _ = try ModelCapabilityResearchValidator.decodeCandidate(
                    candidateData,
                    for: request
                )
            } catch ModelCapabilityResearchValidationError.invalidEvidence(_) {
                // Existing accepted records may contain separately approved empirical evidence.
                do {
                    try ModelCapabilityResearchValidator.validate(
                        decodedCandidate,
                        for: request,
                        allowEmpirical: true
                    )
                } catch {
                    throw ModelCapabilityResearchStoreError.malformedStore
                }
            } catch {
                throw ModelCapabilityResearchStoreError.malformedStore
            }
        }
    }
}

actor ModelCapabilityResearchStore {
    static var defaultURL: URL {
        AppPaths.applicationSupport
            .appendingPathComponent("ModelCapabilityResearch", isDirectory: true)
            .appendingPathComponent("overlays-v1.json")
    }

    private let fileURL: URL

    init(fileURL: URL = ModelCapabilityResearchStore.defaultURL) {
        self.fileURL = fileURL
    }

    func snapshot() throws -> ModelCapabilityResearchStoreDocumentV1 {
        try load()
    }

    @discardableResult
    func accept(
        _ review: ModelCapabilityResearchReviewV1,
        fieldIDs: Set<String>? = nil,
        recordID: UUID = UUID(),
        acceptedAt: Date = Date()
    ) throws -> ModelCapabilityResearchOverlayRecordV1 {
        try ModelCapabilityResearchValidator.validate(
            review.candidate,
            for: review.request,
            allowEmpirical: false
        )
        let applicable = review.acceptableFieldIDs
        let selected = fieldIDs ?? applicable
        guard !selected.isEmpty, selected.isSubset(of: applicable) else {
            throw ModelCapabilityResearchStoreError.invalidSelection
        }
        let acceptedFields = review.candidate.fields.selecting(selected)
        var document = try load()
        let key = review.candidate.binding.canonicalKey(scope: review.candidate.scope)
        let superseded = document.records.first {
            $0.status == .active && $0.canonicalKey == key
        }?.id
        for index in document.records.indices
        where document.records[index].status == .active
                && document.records[index].canonicalKey == key {
            document.records[index].status = .superseded
        }
        let record = ModelCapabilityResearchOverlayRecordV1(
            id: recordID.uuidString.lowercased(),
            binding: review.candidate.binding,
            scope: review.candidate.scope,
            fields: acceptedFields,
            allowedSourceHosts: review.request.allowedSourceHosts,
            acceptedAt: ModelCapabilityResearchDatePolicy.string(acceptedAt),
            status: .active,
            supersedesRecordID: superseded
        )
        document.records.append(record)
        document.revision += 1
        try save(document)
        return record
    }

    func disable(_ recordID: String) throws {
        try setStatus(.disabled, recordID: recordID)
    }

    func archive(_ recordID: String) throws {
        try setStatus(.archived, recordID: recordID)
    }

    func enable(_ recordID: String) throws {
        var document = try load()
        guard let target = document.records.firstIndex(where: { $0.id == recordID }) else {
            throw ModelCapabilityResearchStoreError.recordNotFound(recordID)
        }
        if document.records[target].status == .active {
            return
        }
        let targetID = document.records[target].id
        let targetPriorID = document.records[target].supersedesRecordID
        let key = document.records[target].canonicalKey
        let displacedID = document.records.first {
            $0.status == .active && $0.canonicalKey == key
        }?.id
        for index in document.records.indices
        where index != target && document.records[index].supersedesRecordID == targetID {
            document.records[index].supersedesRecordID = targetPriorID
        }
        for index in document.records.indices
        where document.records[index].status == .active
                && document.records[index].canonicalKey == key {
            document.records[index].status = .superseded
        }
        document.records[target].status = .active
        if let displacedID {
            document.records[target].supersedesRecordID = displacedID
        }
        document.revision += 1
        try save(document)
    }

    func delete(_ recordID: String) throws {
        var document = try load()
        guard let deleted = document.records.first(where: { $0.id == recordID }) else {
            throw ModelCapabilityResearchStoreError.recordNotFound(recordID)
        }
        document.records.removeAll { $0.id == recordID }
        if deleted.status == .active,
           let priorID = deleted.supersedesRecordID,
           let priorIndex = document.records.firstIndex(where: {
               $0.id == priorID && $0.status == .superseded
           }) {
            let key = document.records[priorIndex].canonicalKey
            for index in document.records.indices
            where document.records[index].status == .active
                    && document.records[index].canonicalKey == key {
                document.records[index].status = .superseded
            }
            document.records[priorIndex].status = .active
        }
        for index in document.records.indices
        where document.records[index].supersedesRecordID == recordID {
            document.records[index].supersedesRecordID = deleted.supersedesRecordID
        }
        document.revision += 1
        try save(document)
    }

    private func setStatus(
        _ status: ModelCapabilityResearchOverlayStatusV1,
        recordID: String
    ) throws {
        var document = try load()
        guard let index = document.records.firstIndex(where: { $0.id == recordID }) else {
            throw ModelCapabilityResearchStoreError.recordNotFound(recordID)
        }
        document.records[index].status = status
        document.revision += 1
        try save(document)
    }

    private func load() throws -> ModelCapabilityResearchStoreDocumentV1 {
        try validateLocation()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ModelCapabilityResearchStoreDocumentV1()
        }
        let data = try Data(contentsOf: fileURL)
        let sourceSchema = ModelCapabilityResearchStoreCodec.storedSchema(data)
        let document = try ModelCapabilityResearchStoreCodec.decode(data)
        if sourceSchema == modelCapabilityResearchStoreV0Schema {
            try save(document)
        }
        return document
    }

    private func save(_ document: ModelCapabilityResearchStoreDocumentV1) throws {
        try validateLocation()
        let data = try ModelCapabilityResearchStoreCodec.encode(document)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func validateLocation() throws {
        let resolved = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let components = resolved.pathComponents
        let applicationSupport = AppPaths.applicationSupport.standardizedFileURL
            .resolvingSymlinksInPath()
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        guard !components.contains(where: { $0.lowercased().hasSuffix(".ngv") }),
              isDescendant(resolved, of: applicationSupport)
                || isDescendant(resolved, of: temporaryDirectory) else {
            throw ModelCapabilityResearchStoreError.forbiddenLocation
        }
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

private extension CapabilityFieldsV1 {
    var researchEvidence: [CapabilityEvidenceV1] {
        integers.values.flatMap(\.evidence)
            + decimals.values.flatMap(\.evidence)
            + booleans.values.flatMap(\.evidence)
            + strings.values.flatMap(\.evidence)
            + integerLists.values.flatMap(\.evidence)
    }

    func selecting(_ fieldIDs: Set<String>) -> CapabilityFieldsV1 {
        CapabilityFieldsV1(
            integers: integers.filter { fieldIDs.contains($0.key) },
            decimals: decimals.filter { fieldIDs.contains($0.key) },
            booleans: booleans.filter { fieldIDs.contains($0.key) },
            strings: strings.filter { fieldIDs.contains($0.key) },
            integerLists: integerLists.filter { fieldIDs.contains($0.key) }
        )
    }
}
