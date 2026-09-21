import Foundation

public let treatmentBrainstormRunSchemaV1 = "treatment-brainstorm-run/v1"
public let treatmentBrainstormProvenanceSchemaV1 = "treatment-brainstorm-provenance/v1"

public enum TreatmentBrainstormRoleV1: String, Codable, Sendable, Equatable {
    case idea
    case synthesis
}

public enum TreatmentBrainstormRelationshipV1: String, Codable, Sendable, Equatable, CaseIterable {
    case exact
    case influenced
}

public struct TreatmentBrainstormInputProofV1: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

public struct TreatmentBrainstormUsageV1: Codable, Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }

    public init(inputTokens: Int?, outputTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct TreatmentBrainstormApprovedCallV1: Codable, Sendable, Equatable {
    public let role: TreatmentBrainstormRoleV1
    public let providerID: String
    public let modelID: String

    private enum CodingKeys: String, CodingKey {
        case role
        case providerID = "provider_id"
        case modelID = "model_id"
    }

    public init(role: TreatmentBrainstormRoleV1, providerID: String, modelID: String) {
        self.role = role
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct TreatmentBrainstormApprovalV1: Codable, Sendable, Equatable {
    public let authorizationSHA256: String
    public let approvedAt: String
    public let calls: [TreatmentBrainstormApprovedCallV1]

    private enum CodingKeys: String, CodingKey {
        case authorizationSHA256 = "authorization_sha256"
        case approvedAt = "approved_at"
        case calls
    }

    public init(
        authorizationSHA256: String,
        approvedAt: String,
        calls: [TreatmentBrainstormApprovedCallV1]
    ) {
        self.authorizationSHA256 = authorizationSHA256
        self.approvedAt = approvedAt
        self.calls = calls
    }
}

public enum TreatmentBrainstormCallStatusV1: String, Codable, Sendable, Equatable {
    case succeeded
    case failed
    case notAttempted = "not_attempted"
}

public struct TreatmentBrainstormCallExecutionV1: Codable, Sendable, Equatable {
    public let role: TreatmentBrainstormRoleV1
    public let providerID: String
    public let modelID: String
    public let status: TreatmentBrainstormCallStatusV1
    public let variantID: String?
    public let error: String?

    private enum CodingKeys: String, CodingKey {
        case role
        case providerID = "provider_id"
        case modelID = "model_id"
        case status
        case variantID = "variant_id"
        case error
    }

    public init(
        role: TreatmentBrainstormRoleV1,
        providerID: String,
        modelID: String,
        status: TreatmentBrainstormCallStatusV1,
        variantID: String? = nil,
        error: String? = nil
    ) {
        self.role = role
        self.providerID = providerID
        self.modelID = modelID
        self.status = status
        self.variantID = variantID
        self.error = error
    }
}

public struct TreatmentBrainstormVariantV1: Codable, Sendable, Equatable {
    public let id: String
    public let role: TreatmentBrainstormRoleV1
    public let providerID: String
    public let modelID: String
    public let title: String
    public let summary: String
    public let bodyMarkdown: String
    public let sourceVariantIDs: [String]
    public let requestSHA256: String
    public let providerResponseID: String?
    public let responseJSON: String
    public let responseSHA256: String
    public let usage: TreatmentBrainstormUsageV1

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case providerID = "provider_id"
        case modelID = "model_id"
        case title
        case summary
        case bodyMarkdown = "body_markdown"
        case sourceVariantIDs = "source_variant_ids"
        case requestSHA256 = "request_sha256"
        case providerResponseID = "provider_response_id"
        case responseJSON = "response_json"
        case responseSHA256 = "response_sha256"
        case usage
    }

    public init(
        id: String,
        role: TreatmentBrainstormRoleV1,
        providerID: String,
        modelID: String,
        title: String,
        summary: String,
        bodyMarkdown: String,
        sourceVariantIDs: [String] = [],
        requestSHA256: String,
        providerResponseID: String?,
        responseJSON: String,
        responseSHA256: String,
        usage: TreatmentBrainstormUsageV1
    ) {
        self.id = id
        self.role = role
        self.providerID = providerID
        self.modelID = modelID
        self.title = title
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
        self.sourceVariantIDs = sourceVariantIDs
        self.requestSHA256 = requestSHA256
        self.providerResponseID = providerResponseID
        self.responseJSON = responseJSON
        self.responseSHA256 = responseSHA256
        self.usage = usage
    }
}

public struct TreatmentBrainstormRunV1: Codable, Sendable, Equatable {
    public let schema: String
    public let id: String
    public let createdAt: String
    public let inputFingerprint: String
    public let inputs: [TreatmentBrainstormInputProofV1]
    public let approval: TreatmentBrainstormApprovalV1
    public let executions: [TreatmentBrainstormCallExecutionV1]
    public let variants: [TreatmentBrainstormVariantV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case id
        case createdAt = "created_at"
        case inputFingerprint = "input_fingerprint"
        case inputs
        case approval
        case executions
        case variants
    }

    public init(
        schema: String = treatmentBrainstormRunSchemaV1,
        id: String,
        createdAt: String,
        inputFingerprint: String,
        inputs: [TreatmentBrainstormInputProofV1],
        approval: TreatmentBrainstormApprovalV1,
        executions: [TreatmentBrainstormCallExecutionV1],
        variants: [TreatmentBrainstormVariantV1]
    ) {
        self.schema = schema
        self.id = id
        self.createdAt = createdAt
        self.inputFingerprint = inputFingerprint
        self.inputs = inputs
        self.approval = approval
        self.executions = executions
        self.variants = variants
    }
}

public struct TreatmentBrainstormSourceV1: Codable, Sendable, Equatable {
    public let variantID: String
    public let role: TreatmentBrainstormRoleV1
    public let providerID: String
    public let modelID: String
    public let responseSHA256: String

    private enum CodingKeys: String, CodingKey {
        case variantID = "variant_id"
        case role
        case providerID = "provider_id"
        case modelID = "model_id"
        case responseSHA256 = "response_sha256"
    }

    public init(variant: TreatmentBrainstormVariantV1) {
        variantID = variant.id
        role = variant.role
        providerID = variant.providerID
        modelID = variant.modelID
        responseSHA256 = variant.responseSHA256
    }
}

public struct TreatmentBrainstormProvenanceV1: Codable, Sendable, Equatable {
    public let schema: String
    public let treatmentVersion: Int
    public let treatmentSHA256: String
    public let runID: String
    public let runSHA256: String
    public let relationship: TreatmentBrainstormRelationshipV1
    public let sources: [TreatmentBrainstormSourceV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case treatmentVersion = "treatment_version"
        case treatmentSHA256 = "treatment_sha256"
        case runID = "run_id"
        case runSHA256 = "run_sha256"
        case relationship
        case sources
    }

    public init(
        schema: String = treatmentBrainstormProvenanceSchemaV1,
        treatmentVersion: Int,
        treatmentSHA256: String,
        runID: String,
        runSHA256: String,
        relationship: TreatmentBrainstormRelationshipV1,
        sources: [TreatmentBrainstormSourceV1]
    ) {
        self.schema = schema
        self.treatmentVersion = treatmentVersion
        self.treatmentSHA256 = treatmentSHA256
        self.runID = runID
        self.runSHA256 = runSHA256
        self.relationship = relationship
        self.sources = sources
    }
}

public enum TreatmentBrainstormStoreV1 {
    public enum ValidationError: Error, Sendable, Equatable {
        case invalid(String)
        case stale
    }

    public static func runPath(_ id: String) -> String {
        "treatment/brainstorm/\(id).v1.json"
    }

    public static func provenancePath(_ version: Int) -> String {
        "treatment/v\(version).provenance.v1.json"
    }

    public static func inputFingerprint(_ inputs: [TreatmentBrainstormInputProofV1]) -> String {
        let identity = inputs.sorted { $0.path < $1.path }
            .map { "\($0.path):\($0.sha256)" }
            .joined(separator: "\n")
        return FileDigest.sha256(of: Data(identity.utf8))
    }

    public static func loadRun(id: String, dataRoot: URL) throws -> (TreatmentBrainstormRunV1, Data) {
        guard UUID(uuidString: id) != nil else { throw ValidationError.invalid("run_id") }
        let url = try ProjectLocalFile.resolve(runPath(id), dataRoot: dataRoot)
        let data = try Data(contentsOf: url)
        let run = try JSONDecoder().decode(TreatmentBrainstormRunV1.self, from: data)
        try validate(run, dataRoot: dataRoot)
        return (run, data)
    }

    public static func validate(_ run: TreatmentBrainstormRunV1, dataRoot: URL) throws {
        guard run.schema == treatmentBrainstormRunSchemaV1,
              UUID(uuidString: run.id) != nil,
              validTimestamp(run.createdAt),
              !run.inputs.isEmpty,
              Set(run.inputs.map(\.path)).count == run.inputs.count,
              Set(run.variants.map(\.id)).count == run.variants.count,
              validHash(run.approval.authorizationSHA256),
              validTimestamp(run.approval.approvedAt),
              run.inputFingerprint == inputFingerprint(run.inputs)
        else { throw ValidationError.invalid("run") }
        let approvedCalls = run.approval.calls.map {
            "\($0.role.rawValue):\($0.providerID):\($0.modelID)"
        }.sorted()
        let executedCalls = run.executions.map {
            "\($0.role.rawValue):\($0.providerID):\($0.modelID)"
        }.sorted()
        guard approvedCalls == executedCalls else {
            throw ValidationError.invalid("approval_calls")
        }
        let byVariantID = Dictionary(uniqueKeysWithValues: run.variants.map { ($0.id, $0) })
        let successfulIDs = run.executions.compactMap { execution -> String? in
            guard execution.status == .succeeded,
                  let id = execution.variantID,
                  execution.error == nil,
                  let variant = byVariantID[id],
                  execution.role == variant.role,
                  execution.providerID == variant.providerID,
                  execution.modelID == variant.modelID else { return nil }
            return id
        }
        guard successfulIDs.count == run.executions.filter({ $0.status == .succeeded }).count,
              Set(successfulIDs).count == successfulIDs.count,
              Set(successfulIDs) == Set(run.variants.map(\.id)),
              run.executions.filter({ $0.status != .succeeded }).allSatisfy({
                  $0.variantID == nil && $0.error.map { nonEmpty($0) } == true
              }) else {
            throw ValidationError.invalid("executions")
        }
        for input in run.inputs {
            guard validHash(input.sha256),
                  try FileDigest.sha256(of: ProjectLocalFile.resolve(input.path, dataRoot: dataRoot)) == input.sha256
            else { throw ValidationError.stale }
        }
        let ideaIDs = Set(run.variants.filter { $0.role == .idea }.map(\.id))
        for variant in run.variants {
            guard UUID(uuidString: variant.id) != nil,
                  nonEmpty(variant.providerID), nonEmpty(variant.modelID),
                  nonEmpty(variant.title), nonEmpty(variant.summary), nonEmpty(variant.bodyMarkdown),
                  validHash(variant.requestSHA256), validHash(variant.responseSHA256),
                  FileDigest.sha256(of: Data(variant.responseJSON.utf8)) == variant.responseSHA256,
                  variant.providerResponseID.map { nonEmpty($0) } != false,
                  variant.usage.inputTokens.map({ $0 >= 0 }) != false,
                  variant.usage.outputTokens.map({ $0 >= 0 }) != false
            else { throw ValidationError.invalid("variant") }
            guard let object = try? JSONSerialization.jsonObject(with: Data(variant.responseJSON.utf8)) as? [String: Any],
                  Set(object.keys) == Set(["title", "summary", "body_markdown"]),
                  object["title"] as? String == variant.title,
                  object["summary"] as? String == variant.summary,
                  object["body_markdown"] as? String == variant.bodyMarkdown else {
                throw ValidationError.invalid("response_json")
            }
            if variant.role == .idea {
                guard variant.sourceVariantIDs.isEmpty else { throw ValidationError.invalid("idea_sources") }
            } else {
                guard variant.sourceVariantIDs.count >= 2,
                      Set(variant.sourceVariantIDs).count == variant.sourceVariantIDs.count,
                      Set(variant.sourceVariantIDs).isSubset(of: ideaIDs)
                else { throw ValidationError.invalid("synthesis_sources") }
            }
        }
    }

    public static func encodeRun(_ run: TreatmentBrainstormRunV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(run)
    }

    public static func writeRun(_ run: TreatmentBrainstormRunV1, dataRoot: URL) throws -> URL {
        guard run.schema == treatmentBrainstormRunSchemaV1,
              UUID(uuidString: run.id) != nil,
              run.inputFingerprint == inputFingerprint(run.inputs)
        else { throw ValidationError.invalid("run") }
        try validate(run, dataRoot: dataRoot)
        let url = dataRoot.appendingPathComponent(runPath(run.id))
        guard !FileManager.default.fileExists(atPath: url.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil
        else { throw ValidationError.invalid("immutable_run") }
        let data = try encodeRun(run)
        try ArtifactTransaction.perform(paths: [url], dataRoot: dataRoot) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    public static func makeProvenance(
        treatment: Treatment,
        runID: String,
        variantIDs: [String],
        relationship: TreatmentBrainstormRelationshipV1,
        dataRoot: URL
    ) throws -> (TreatmentBrainstormProvenanceV1, Data, TreatmentOrigin) {
        let (run, runData) = try loadRun(id: runID, dataRoot: dataRoot)
        guard !variantIDs.isEmpty,
              Set(variantIDs).count == variantIDs.count
        else { throw ValidationError.invalid("variant_ids") }
        let byID = Dictionary(uniqueKeysWithValues: run.variants.map { ($0.id, $0) })
        let selected = try variantIDs.map { id in
            guard let variant = byID[id] else { throw ValidationError.invalid("variant_id") }
            return variant
        }
        let origin: TreatmentOrigin
        switch relationship {
        case .exact:
            guard selected.count == 1,
                  treatment.bodyMarkdown == selected[0].bodyMarkdown
            else { throw ValidationError.invalid("exact_body") }
            origin = origin(forExact: selected[0])
        case .influenced:
            guard treatment.meta.origin == .agentProposal || treatment.meta.origin == .agentRevision
            else { throw ValidationError.invalid("influenced_origin") }
            origin = treatment.meta.origin
        }
        let resolvedMeta = try TreatmentMeta(
            project: treatment.meta.project,
            version: treatment.meta.version,
            generated: treatment.meta.generated,
            origin: origin,
            generator: treatment.meta.generator,
            summaryOneline: treatment.meta.summaryOneline,
            title: treatment.meta.title,
            notes: treatment.meta.notes
        )
        let resolved = Treatment(meta: resolvedMeta, bodyMarkdown: treatment.bodyMarkdown)
        let treatmentData = Data(try resolved.serialized().utf8)
        let value = TreatmentBrainstormProvenanceV1(
            treatmentVersion: resolved.meta.version,
            treatmentSHA256: FileDigest.sha256(of: treatmentData),
            runID: run.id,
            runSHA256: FileDigest.sha256(of: runData),
            relationship: relationship,
            sources: selected.map(TreatmentBrainstormSourceV1.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (value, try encoder.encode(value), origin)
    }

    public static func requireCurrent(version: Int, dataRoot: URL) throws -> TreatmentBrainstormProvenanceV1? {
        let path = provenancePath(version)
        let unresolved = dataRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: unresolved.path) else {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: unresolved.path)) == nil else {
                throw ValidationError.invalid("provenance_symlink")
            }
            return nil
        }
        let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(TreatmentBrainstormProvenanceV1.self, from: data)
        let treatmentURL = try ProjectLocalFile.resolve(
            PipelineLayout.treatmentVersionFile(version), dataRoot: dataRoot
        )
        let treatmentData = try Data(contentsOf: treatmentURL)
        let treatment = try Treatment.parsing(String(decoding: treatmentData, as: UTF8.self))
        let (run, runData) = try loadRun(id: value.runID, dataRoot: dataRoot)
        let byID = Dictionary(uniqueKeysWithValues: run.variants.map { ($0.id, $0) })
        guard value.schema == treatmentBrainstormProvenanceSchemaV1,
              value.treatmentVersion == version,
              value.treatmentSHA256 == FileDigest.sha256(of: treatmentData),
              value.runSHA256 == FileDigest.sha256(of: runData),
              !value.sources.isEmpty,
              Set(value.sources.map(\.variantID)).count == value.sources.count,
              value.sources.allSatisfy { source in
                  guard let variant = byID[source.variantID] else { return false }
                  return source == TreatmentBrainstormSourceV1(variant: variant)
              }
        else { throw ValidationError.stale }
        switch value.relationship {
        case .exact:
            guard value.sources.count == 1,
                  treatment.meta.origin == origin(forExact: value.sources[0]),
                  byID[value.sources[0].variantID]?.bodyMarkdown == treatment.bodyMarkdown else {
                throw ValidationError.invalid("exact_origin")
            }
        case .influenced:
            guard treatment.meta.origin == .agentProposal || treatment.meta.origin == .agentRevision else {
                throw ValidationError.invalid("influenced_origin")
            }
        }
        return value
    }

    public static func origin(forExact variant: TreatmentBrainstormVariantV1) -> TreatmentOrigin {
        if variant.role == .synthesis { return .brainstormSynthesis }
        switch variant.providerID.lowercased() {
        case "anthropic": return .brainstormClaude
        case "openai": return .brainstormOpenai
        case "google": return .brainstormGemini
        default: return .brainstormModel
        }
    }

    public static func origin(forExact source: TreatmentBrainstormSourceV1) -> TreatmentOrigin {
        if source.role == .synthesis { return .brainstormSynthesis }
        switch source.providerID.lowercased() {
        case "anthropic": return .brainstormClaude
        case "openai": return .brainstormOpenai
        case "google": return .brainstormGemini
        default: return .brainstormModel
        }
    }

    private static func nonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func validTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}
