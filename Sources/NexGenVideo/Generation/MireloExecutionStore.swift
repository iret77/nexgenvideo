import Foundation

struct MireloSourceReceipt: Codable, Sendable, Equatable {
    let mediaAssetID: String
    let projectPath: String
    let sha256: String
    let type: ClipType
}

struct MireloArtifact: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case audio
        case midi
        case musicXML = "musicxml"
        case noteJSON = "note_json"
        case scorePDF = "score_pdf"
        case scoreBundle = "score_bundle"
        case scoreManifest = "score_manifest"
    }

    let kind: Kind
    let projectPath: String
    let sha256: String
    let mediaAssetID: String?
    let sourceURLExpiresAt: String?
}

struct MireloExecutionRecord: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case prepared
        case submitting
        case accepted
        case acceptanceUnknown = "acceptance_unknown"
        case pollingInterrupted = "polling_interrupted"
        case providerSucceeded = "provider_succeeded"
        case completed
        case failed
    }

    let schema: String
    let authorityID: String
    let projectKey: String
    let logicalJobID: String
    let operation: MireloOperation
    let requestSHA256: String
    let requestBody: Data
    let idempotencyKey: String?
    let sources: [MireloSourceReceipt]
    var preflight: MireloPreflight
    let createdAt: Date
    var updatedAt: Date
    var approvedAt: Date?
    var spendTransactionID: String?
    var state: State
    var providerJobID: String?
    var providerStatusURL: String?
    var lastProviderStatus: String?
    var lastError: String?
    var terminalResponse: Data?
    var artifacts: [MireloArtifact]
}

struct MireloExecutionStore: Sendable {
    private let authority: GenerationExecutionAuthorityStore

    init(authority: GenerationExecutionAuthorityStore) {
        self.authority = authority
    }

    static func live() throws -> Self {
        try Self(authority: .live())
    }

    func authorityID(projectKey: String, logicalJobID: String) throws -> String {
        try validateComponent(projectKey, label: "project")
        try validateComponent(logicalJobID, label: "logical job")
        return FileDigest.sha256(of: Data(
            "mirelo-execution-authority/v1\n\(authority.hostID)\n\(projectKey)\n\(logicalJobID)".utf8
        ))
    }

    func load(projectKey: String, logicalJobID: String) throws -> MireloExecutionRecord? {
        let file = try recordURL(projectKey: projectKey, logicalJobID: logicalJobID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes = try Data(contentsOf: file)
        let value = try JSONDecoder().decode(MireloExecutionRecord.self, from: bytes)
        guard value.schema == "mirelo-execution-authority/v1",
              value.projectKey == projectKey,
              value.logicalJobID == logicalJobID,
              value.authorityID == (try authorityID(projectKey: projectKey, logicalJobID: logicalJobID)),
              bytes == (try GenerationPackageV1.canonicalData(value)) else {
            throw GenerationRequestError.storage("The Mirelo execution authority is unreadable.")
        }
        try validate(value)
        return value
    }

    func create(_ candidate: MireloExecutionRecord) throws -> MireloExecutionRecord {
        if let existing = try load(
            projectKey: candidate.projectKey,
            logicalJobID: candidate.logicalJobID
        ) {
            guard existing.requestSHA256 == candidate.requestSHA256,
                  existing.requestBody == candidate.requestBody,
                  existing.operation == candidate.operation,
                  existing.sources == candidate.sources else {
                throw GenerationRequestError.gate(
                    "Logical Mirelo job '\(candidate.logicalJobID)' already identifies a different request. Use a new UUID for changed inputs."
                )
            }
            return existing
        }
        guard candidate.schema == "mirelo-execution-authority/v1",
              candidate.authorityID == (try authorityID(
                projectKey: candidate.projectKey,
                logicalJobID: candidate.logicalJobID
              )), candidate.state == .prepared,
              (candidate.idempotencyKey != nil) == candidate.operation.usesIdempotencyKey,
              candidate.providerJobID == nil,
              candidate.terminalResponse == nil,
              candidate.approvedAt == nil,
              candidate.spendTransactionID == nil,
              candidate.artifacts.isEmpty else {
            throw GenerationRequestError.storage("The Mirelo execution authority is invalid.")
        }
        try validate(candidate)
        let folder = try jobFolder(
            projectKey: candidate.projectKey,
            logicalJobID: candidate.logicalJobID
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try recordURL(
            projectKey: candidate.projectKey,
            logicalJobID: candidate.logicalJobID
        )
        do {
            try GenerationPackageV1.canonicalData(candidate).write(
                to: file,
                options: .withoutOverwriting
            )
        } catch {
            if let existing = try load(
                projectKey: candidate.projectKey,
                logicalJobID: candidate.logicalJobID
            ) {
                guard existing.requestSHA256 == candidate.requestSHA256,
                      existing.requestBody == candidate.requestBody,
                      existing.operation == candidate.operation,
                      existing.sources == candidate.sources else {
                    throw GenerationRequestError.gate(
                        "Logical Mirelo job '\(candidate.logicalJobID)' already identifies a different request. Use a new UUID for changed inputs."
                    )
                }
                return existing
            }
            throw error
        }
        return candidate
    }

    func update(
        _ expected: MireloExecutionRecord,
        allowPreflightRefresh: Bool = false,
        mutate: (inout MireloExecutionRecord) throws -> Void
    ) throws -> MireloExecutionRecord {
        guard var current = try load(
            projectKey: expected.projectKey,
            logicalJobID: expected.logicalJobID
        ), current == expected else {
            throw GenerationRequestError.gate(
                "The Mirelo job advanced in another operation. Read its current state before continuing."
            )
        }
        try mutate(&current)
        current.updatedAt = Date()
        guard current.schema == expected.schema,
              current.authorityID == expected.authorityID,
              current.projectKey == expected.projectKey,
              current.logicalJobID == expected.logicalJobID,
              current.requestSHA256 == expected.requestSHA256,
              current.requestBody == expected.requestBody,
              current.idempotencyKey == expected.idempotencyKey,
              current.operation == expected.operation,
              current.sources == expected.sources,
              (current.preflight == expected.preflight
                || (allowPreflightRefresh
                    && expected.state == .prepared
                    && current.state == .prepared
                    && expected.approvedAt == nil
                    && current.approvedAt == nil)),
              current.createdAt == expected.createdAt,
              (expected.approvedAt == nil || current.approvedAt == expected.approvedAt),
              (expected.spendTransactionID == nil
                || current.spendTransactionID == expected.spendTransactionID),
              (current.approvedAt == nil) == (current.spendTransactionID == nil),
              (expected.providerJobID == nil
                || current.providerJobID == expected.providerJobID),
              Self.canTransition(from: expected.state, to: current.state) else {
            throw GenerationRequestError.storage("Immutable Mirelo execution evidence changed.")
        }
        try validate(current)
        try write(current)
        return current
    }

    func refreshPreflight(
        _ expected: MireloExecutionRecord,
        with preflight: MireloPreflight
    ) throws -> MireloExecutionRecord {
        guard expected.state == .prepared,
              expected.approvedAt == nil,
              expected.providerJobID == nil else {
            throw GenerationRequestError.gate(
                "Only an unapproved Mirelo request can refresh its preflight."
            )
        }
        return try update(expected, allowPreflightRefresh: true) {
            $0.preflight = preflight
        }
    }

    private func write(_ record: MireloExecutionRecord) throws {
        try validate(record)
        let file = try recordURL(
            projectKey: record.projectKey,
            logicalJobID: record.logicalJobID
        )
        try GenerationPackageV1.canonicalData(record).write(to: file, options: .atomic)
    }

    private func recordURL(projectKey: String, logicalJobID: String) throws -> URL {
        try jobFolder(projectKey: projectKey, logicalJobID: logicalJobID)
            .appendingPathComponent("record.json", isDirectory: false)
    }

    private func jobFolder(projectKey: String, logicalJobID: String) throws -> URL {
        try validateComponent(projectKey, label: "project")
        try validateComponent(logicalJobID, label: "logical job")
        return authority.root
            .appendingPathComponent(authority.hostID, isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
            .appendingPathComponent("mirelo", isDirectory: true)
            .appendingPathComponent(logicalJobID, isDirectory: true)
    }

    private func validateComponent(_ value: String, label: String) throws {
        guard !value.isEmpty,
              value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              value.utf8.count <= 160 else {
            throw GenerationRequestError.storage("The \(label) identity is invalid.")
        }
    }

    private func validate(_ value: MireloExecutionRecord) throws {
        let requiresProviderJob: Set<MireloExecutionRecord.State> = [
            .accepted, .pollingInterrupted, .providerSucceeded, .completed,
        ]
        let terminalStates: Set<MireloExecutionRecord.State> = [
            .providerSucceeded, .completed,
        ]
        guard value.preflight.credits >= 0,
              value.requestSHA256 == FileDigest.sha256(of: value.requestBody),
              (value.idempotencyKey != nil) == value.operation.usesIdempotencyKey,
              !value.operation.usesIdempotencyKey
                || value.idempotencyKey == value.authorityID,
              (value.approvedAt == nil) == (value.spendTransactionID == nil),
              !requiresProviderJob.contains(value.state)
                || value.providerJobID?.isEmpty == false,
              !terminalStates.contains(value.state)
                || value.terminalResponse != nil,
              value.state == .completed || value.artifacts.isEmpty,
              value.state != .completed || !value.artifacts.isEmpty,
              Set(value.sources.map { $0.projectPath }).count == value.sources.count,
              Set(value.artifacts.map { $0.projectPath }).count == value.artifacts.count else {
            throw GenerationRequestError.storage("The Mirelo execution authority is inconsistent.")
        }
    }

    private static func canTransition(
        from: MireloExecutionRecord.State,
        to: MireloExecutionRecord.State
    ) -> Bool {
        switch (from, to) {
        case (.prepared, .prepared),
             (.prepared, .submitting),
             (.submitting, .accepted),
             (.submitting, .acceptanceUnknown),
             (.submitting, .failed),
             (.acceptanceUnknown, .submitting),
             (.accepted, .accepted),
             (.accepted, .pollingInterrupted),
             (.accepted, .providerSucceeded),
             (.accepted, .failed),
             (.pollingInterrupted, .accepted),
             (.pollingInterrupted, .pollingInterrupted),
             (.pollingInterrupted, .providerSucceeded),
             (.pollingInterrupted, .failed),
             (.providerSucceeded, .providerSucceeded),
             (.providerSucceeded, .completed),
             (.completed, .completed),
             (.failed, .failed):
            true
        default:
            false
        }
    }
}
