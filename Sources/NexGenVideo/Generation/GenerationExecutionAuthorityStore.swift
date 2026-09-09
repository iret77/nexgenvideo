import Foundation
import NexGenEngine

struct GenerationExecutionAuthorityStore: Sendable {
    struct RetainedFile: Codable, Sendable, Equatable, Hashable {
        let relativePath: String
        let sha256: String
    }

    struct Record: Codable, Sendable, Equatable {
        let schema: String
        let authorityID: String
        let projectKey: String
        let batch: GenerationBatch
        var journal: GenerationBatchJournal
        var spendEvents: [GenerationSpendEvent]
        let retainedFiles: [RetainedFile]
    }

    struct OutputArchive: Codable, Sendable, Equatable {
        let schema: String
        let receipt: GenerationBatchOutput
        let dataFilename: String
    }

    private struct HostIdentity: Codable, Sendable, Equatable {
        let schema: String
        let id: String
    }

    let root: URL
    let hostID: String

    init(root: URL, hostID: String) throws {
        guard UUID(uuidString: hostID) != nil else {
            throw GenerationRequestError.storage("The generation execution host identity is invalid.")
        }
        self.root = root.standardizedFileURL
        self.hostID = hostID.uppercased()
    }

    static func live() throws -> Self {
        let support = AppPaths.ensure(AppPaths.applicationSupport)
        let identityURL = AppPaths.executionHostIdentity
        let identity: HostIdentity
        if FileManager.default.fileExists(atPath: identityURL.path) {
            let bytes = try Data(contentsOf: identityURL)
            identity = try JSONDecoder().decode(HostIdentity.self, from: bytes)
            guard identity.schema == "generation-execution-host/v1",
                  UUID(uuidString: identity.id) != nil,
                  try GenerationPackageV1.canonicalData(identity) == bytes else {
                throw GenerationRequestError.storage("The generation execution host identity is unreadable.")
            }
        } else {
            let candidate = HostIdentity(schema: "generation-execution-host/v1", id: UUID().uuidString)
            let bytes = try GenerationPackageV1.canonicalData(candidate)
            do {
                try bytes.write(to: identityURL, options: .withoutOverwriting)
                identity = candidate
            } catch {
                guard FileManager.default.fileExists(atPath: identityURL.path) else { throw error }
                let existing = try Data(contentsOf: identityURL)
                identity = try JSONDecoder().decode(HostIdentity.self, from: existing)
                guard identity.schema == "generation-execution-host/v1",
                      UUID(uuidString: identity.id) != nil,
                      try GenerationPackageV1.canonicalData(identity) == existing else {
                    throw GenerationRequestError.storage("The generation execution host identity is unreadable.")
                }
            }
        }
        _ = support
        return try Self(root: AppPaths.approvedGenerationExecutions, hostID: identity.id)
    }

    func authorityID(projectKey: String, batchID: String) throws -> String {
        try requireProjectKey(projectKey)
        try requireBatchID(batchID)
        return FileDigest.sha256(of: Data("generation-execution-authority/v1\n\(hostID)\n\(projectKey)\n\(batchID)".utf8))
    }

    func create(batch: GenerationBatch, journal: GenerationBatchJournal, home: URL) throws -> Record {
        try batch.validate()
        let expectedID = try authorityID(projectKey: batch.payload.projectKey, batchID: batch.id)
        guard journal.authorityID == expectedID else {
            throw GenerationRequestError.storage("The generation batch was approved for another execution authority.")
        }
        let folder = try batchFolder(projectKey: batch.payload.projectKey, batchID: batch.id)
        if FileManager.default.fileExists(atPath: folder.path) {
            let existing = try load(projectKey: batch.payload.projectKey, batchID: batch.id)
            guard existing.batch == batch else {
                throw GenerationRequestError.storage("This execution authority belongs to another batch manifest.")
            }
            return existing
        }

        let parent = folder.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(batch.id)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)

        var retained: [RetainedFile] = []
        for item in batch.payload.items {
            let packagePath = "generation-packages/\(item.package.id).json"
            let packageBytes = try Data(contentsOf: ProjectLocalFile.resolve(packagePath, dataRoot: home))
            guard packageBytes == (try GenerationPackageV1.canonicalData(item.package)) else {
                throw GenerationRequestError.storage("The reviewed generation package changed before batch approval.")
            }
            try retain(packageBytes, path: packagePath, staging: staging, files: &retained)

            let inputManifestPath = "generation-packages/\(item.package.id).inputs.json"
            let inputManifestBytes = try Data(contentsOf: ProjectLocalFile.resolve(inputManifestPath, dataRoot: home))
            let inputManifest = try JSONDecoder().decode(GenerationPackageInputs.self, from: inputManifestBytes)
            guard inputManifest.packageID == item.package.id,
                  inputManifest.paths.count == item.package.payload.references.count,
                  inputManifestBytes == (try GenerationPackageV1.canonicalData(inputManifest)) else {
                throw GenerationRequestError.storage("The reviewed generation input archive is incomplete.")
            }
            try retain(inputManifestBytes, path: inputManifestPath, staging: staging, files: &retained)
            for (index, path) in inputManifest.paths.enumerated() {
                let source = try ProjectLocalFile.resolve(path, dataRoot: home)
                let digest = try FileDigest.sha256(of: source)
                guard digest == item.package.payload.references[index].submittedSHA256 else {
                    throw GenerationRequestError.storage("A reviewed generation input changed before batch approval.")
                }
                try retain(Data(contentsOf: source), path: path, staging: staging, files: &retained)
            }
        }
        retained = Array(Set(retained)).sorted { $0.relativePath < $1.relativePath }
        let record = Record(schema: "generation-execution-authority/v1", authorityID: expectedID,
            projectKey: batch.payload.projectKey, batch: batch, journal: journal, spendEvents: [],
            retainedFiles: retained)
        try validate(record)
        try GenerationPackageV1.canonicalData(record).write(to: staging.appendingPathComponent("record.json"), options: .withoutOverwriting)
        try FileManager.default.moveItem(at: staging, to: folder)
        return record
    }

    func load(projectKey: String, batchID: String) throws -> Record {
        let folder = try batchFolder(projectKey: projectKey, batchID: batchID)
        let file = folder.appendingPathComponent("record.json")
        let bytes = try Data(contentsOf: file)
        let record = try JSONDecoder().decode(Record.self, from: bytes)
        try validate(record)
        guard record.projectKey == projectKey, record.batch.id == batchID,
              try GenerationPackageV1.canonicalData(record) == bytes else {
            throw GenerationRequestError.storage("The approved generation execution record changed.")
        }
        for retained in record.retainedFiles {
            let file = try safeResolve("retained/" + retained.relativePath, under: folder)
            guard try FileDigest.sha256(of: file) == retained.sha256 else {
                throw GenerationRequestError.storage("A retained generation input changed after approval.")
            }
        }
        return record
    }

    func loadIfPresent(projectKey: String, batchID: String) throws -> Record? {
        let folder = try batchFolder(projectKey: projectKey, batchID: batchID)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("record.json").path) else { return nil }
        return try load(projectKey: projectKey, batchID: batchID)
    }

    func all(projectKey: String) throws -> [Record] {
        try requireProjectKey(projectKey)
        let folder = try projectFolder(projectKey)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { try load(projectKey: projectKey, batchID: $0.lastPathComponent) }
            .sorted { $0.journal.approvedAt < $1.journal.approvedAt }
    }

    func update(expected: Record, journal: GenerationBatchJournal,
                adding spendEvents: [GenerationSpendEvent] = []) throws -> Record {
        let current = try load(projectKey: expected.projectKey, batchID: expected.batch.id)
        guard current == expected else {
            throw GenerationRequestError.gate("The approved generation execution advanced in another operation.")
        }
        var updated = current
        updated.journal = journal
        for event in spendEvents where !updated.spendEvents.contains(where: { $0.id == event.id }) {
            updated.spendEvents.append(event)
        }
        try validate(updated)
        guard updated.journal.approvedAt == current.journal.approvedAt,
              updated.journal.revision >= current.journal.revision,
              updated.journal.revision > current.journal.revision || updated.spendEvents.count > current.spendEvents.count else {
            throw GenerationRequestError.gate("The approved generation execution cannot rewind or replace its history.")
        }
        try write(updated)
        return updated
    }

    func recordSpendEvent(_ event: GenerationSpendEvent, authorization: GenerationBatchAuthorization) throws {
        var current = try recordForAuthority(authorization)
        guard let execution = current.journal.executions.first(where: { $0.itemID == authorization.itemID }) else {
            throw GenerationRequestError.gate("The spend event does not belong to this approved batch item.")
        }
        guard execution.transactionID == event.transactionId else {
            if event.kind == .released, execution.transactionID == nil { return }
            throw GenerationRequestError.gate("The spend event does not belong to this approved batch item.")
        }
        guard let item = current.batch.payload.items.first(where: { $0.id == authorization.itemID }),
              event.model == item.package.payload.target.modelId,
              event.provider == item.package.payload.target.provider,
              event.transport == item.package.payload.target.transport,
              event.endpoint == item.package.payload.target.endpoint else {
            throw GenerationRequestError.gate("The spend event does not belong to this approved batch item.")
        }
        if let money = event.money, let ceiling = item.package.payload.estimate,
           [.reserved, .submitted, .charged].contains(event.kind), money.eurAmount > ceiling.eurAmount {
            throw GenerationRequestError.gate("The provider spend exceeds the approved batch ceiling.")
        }
        if let existing = current.spendEvents.first(where: { $0.id == event.id }) {
            guard existing == event else { throw GenerationRequestError.storage("A generation spend event changed after recording.") }
            return
        }
        current.spendEvents.append(event)
        try validate(current)
        try write(current)
    }

    func archiveOutput(_ receipt: GenerationBatchOutput, home: URL) throws {
        let authorization = GenerationBatchAuthorization(batchID: receipt.batchID, itemID: receipt.itemID)
        let current = try recordForAuthority(authorization)
        try GenerationBatchOutput.validate(receipt, snapshot: .init(record: current), home: home)
        guard case .project(let path) = receipt.asset.source else {
            throw GenerationRequestError.storage("The completed generation output is not project-local.")
        }
        let source = try ProjectLocalFile.resolve(path, dataRoot: home)
        guard try FileDigest.sha256(of: source) == receipt.sha256 else {
            throw GenerationRequestError.storage("The completed generation output changed before it was archived.")
        }
        let folder = try batchFolder(projectKey: current.projectKey, batchID: current.batch.id)
        let outputFolder = folder.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let key = GenerationBatchOutput.receiptKey(authorization: authorization, assetID: receipt.asset.id)
        let extensionPart = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        let dataName = "\(key).\(extensionPart)"
        let archive = OutputArchive(schema: "generation-execution-output/v1", receipt: receipt, dataFilename: dataName)
        let archiveURL = outputFolder.appendingPathComponent(key + ".json")
        let dataURL = outputFolder.appendingPathComponent(dataName)
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            let existingBytes = try Data(contentsOf: archiveURL)
            let existing = try JSONDecoder().decode(OutputArchive.self, from: existingBytes)
            guard existing == archive, existingBytes == (try GenerationPackageV1.canonicalData(existing)),
                  try FileDigest.sha256(of: dataURL) == receipt.sha256 else {
                throw GenerationRequestError.storage("A completed generation output cannot replace its durable archive.")
            }
            return
        }
        try FileManager.default.copyItem(at: source, to: dataURL)
        do {
            try GenerationPackageV1.canonicalData(archive).write(to: archiveURL, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: dataURL)
            throw error
        }
    }

    @discardableResult
    func hydrate(_ record: Record, into home: URL) throws -> [GenerationBatchOutput] {
        let folder = try batchFolder(projectKey: record.projectKey, batchID: record.batch.id)
        for retained in record.retainedFiles {
            let source = try safeResolve("retained/" + retained.relativePath, under: folder)
            let destination = try safeResolve(retained.relativePath, under: home)
            try copyImmutable(source: source, destination: destination, sha256: retained.sha256)
        }
        let outputFolder = folder.appendingPathComponent("outputs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: outputFolder.path) else { return [] }
        var receipts: [GenerationBatchOutput] = []
        for archiveURL in try FileManager.default.contentsOfDirectory(at: outputFolder, includingPropertiesForKeys: nil)
            where archiveURL.pathExtension == "json" {
            let bytes = try Data(contentsOf: archiveURL)
            let archive = try JSONDecoder().decode(OutputArchive.self, from: bytes)
            guard archive.schema == "generation-execution-output/v1",
                  bytes == (try GenerationPackageV1.canonicalData(archive)),
                  !archive.dataFilename.contains("/"), !archive.dataFilename.hasPrefix(".") else {
                throw GenerationRequestError.storage("A durable generation output record is unreadable.")
            }
            let source = outputFolder.appendingPathComponent(archive.dataFilename)
            guard try FileDigest.sha256(of: source) == archive.receipt.sha256,
                  case .project(let path) = archive.receipt.asset.source else {
                throw GenerationRequestError.storage("A durable generation output changed after recording.")
            }
            let destination = try safeResolve(path, under: home)
            try copyImmutable(source: source, destination: destination, sha256: archive.receipt.sha256)
            let authorization = GenerationBatchAuthorization(batchID: archive.receipt.batchID, itemID: archive.receipt.itemID)
            let receiptDestination = try safeResolve(
                GenerationBatchOutput.receiptPath(authorization: authorization, assetID: archive.receipt.asset.id), under: home)
            try writeImmutable(try GenerationPackageV1.canonicalData(archive.receipt), destination: receiptDestination)
            receipts.append(archive.receipt)
        }
        return receipts
    }

    func removeForTesting(projectKey: String, batchID: String) throws {
        let folder = try batchFolder(projectKey: projectKey, batchID: batchID)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private func validate(_ record: Record) throws {
        try record.batch.validate()
        try record.journal.validate(batch: record.batch)
        let expectedID = try authorityID(projectKey: record.projectKey, batchID: record.batch.id)
        guard record.schema == "generation-execution-authority/v1", record.authorityID == expectedID,
              record.journal.authorityID == expectedID,
              record.batch.payload.projectKey == record.projectKey,
              Set(record.retainedFiles.map(\.relativePath)).count == record.retainedFiles.count,
              Set(record.spendEvents.map(\.id)).count == record.spendEvents.count else {
            throw GenerationRequestError.storage("The approved generation execution record is invalid.")
        }
        for event in record.spendEvents {
            guard let execution = record.journal.executions.first(where: { $0.transactionID == event.transactionId }),
                  let item = record.batch.payload.items.first(where: { $0.id == execution.itemID }),
                  event.model == item.package.payload.target.modelId,
                  event.provider == item.package.payload.target.provider,
                  event.transport == item.package.payload.target.transport,
                  event.endpoint == item.package.payload.target.endpoint else {
                throw GenerationRequestError.storage("The approved generation spend history is invalid.")
            }
            if let money = event.money, let ceiling = item.package.payload.estimate,
               [.reserved, .submitted, .charged].contains(event.kind), money.eurAmount > ceiling.eurAmount {
                throw GenerationRequestError.storage("The approved generation spend exceeds its ceiling.")
            }
        }
        for retained in record.retainedFiles { _ = try safeRelativePath(retained.relativePath) }
    }

    private func recordForAuthority(_ authorization: GenerationBatchAuthorization) throws -> Record {
        let hostFolder = root.appendingPathComponent(hostID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: hostFolder.path) else {
            throw GenerationRequestError.storage("This host has no approved generation execution authority.")
        }
        for projectFolder in try FileManager.default.contentsOfDirectory(at: hostFolder, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: projectFolder.lastPathComponent) != nil else { continue }
            if let record = try loadIfPresent(projectKey: projectFolder.lastPathComponent, batchID: authorization.batchID) {
                guard record.journal.authorityID == (try authorityID(projectKey: record.projectKey, batchID: record.batch.id)) else {
                    throw GenerationRequestError.storage("The generation execution authority does not match this host.")
                }
                return record
            }
        }
        throw GenerationRequestError.storage("This host cannot authorize the recorded generation batch.")
    }

    private func write(_ record: Record) throws {
        let file = try batchFolder(projectKey: record.projectKey, batchID: record.batch.id).appendingPathComponent("record.json")
        try GenerationPackageV1.canonicalData(record).write(to: file, options: .atomic)
    }

    private func retain(_ bytes: Data, path: String, staging: URL, files: inout [RetainedFile]) throws {
        let destination = try safeResolve("retained/" + path, under: staging)
        let digest = FileDigest.sha256(of: bytes)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == bytes else {
                throw GenerationRequestError.storage("Two approved generation inputs claim the same retained path.")
            }
        } else {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination, options: .withoutOverwriting)
        }
        files.append(.init(relativePath: path, sha256: digest))
    }

    private func copyImmutable(source: URL, destination: URL, sha256: String) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try FileDigest.sha256(of: destination) == sha256 else {
                throw GenerationRequestError.storage("Project data conflicts with its approved generation execution archive.")
            }
            return
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        guard try FileDigest.sha256(of: destination) == sha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw GenerationRequestError.storage("A generation execution file changed while it was restored.")
        }
    }

    private func writeImmutable(_ bytes: Data, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == bytes else {
                throw GenerationRequestError.storage("Project history conflicts with its approved generation execution archive.")
            }
            return
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination, options: .withoutOverwriting)
    }

    private func batchFolder(projectKey: String, batchID: String) throws -> URL {
        try requireBatchID(batchID)
        return try projectFolder(projectKey).appendingPathComponent(batchID, isDirectory: true)
    }

    private func projectFolder(_ projectKey: String) throws -> URL {
        try requireProjectKey(projectKey)
        return root.appendingPathComponent(hostID, isDirectory: true).appendingPathComponent(projectKey, isDirectory: true)
    }

    private func requireProjectKey(_ value: String) throws {
        guard UUID(uuidString: value) != nil else { throw GenerationRequestError.storage("Invalid generation project identity.") }
    }

    private func requireBatchID(_ value: String) throws {
        guard value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GenerationRequestError.storage("Invalid generation batch identity.")
        }
    }

    private func safeRelativePath(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GenerationRequestError.storage("A generation execution path is unsafe.")
        }
        return path
    }

    private func safeResolve(_ path: String, under root: URL) throws -> URL {
        let relative = try safeRelativePath(path)
        let standardizedRoot = root.standardizedFileURL
        let candidate = standardizedRoot.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(standardizedRoot.path + "/") else {
            throw GenerationRequestError.storage("A generation execution path escapes its store.")
        }
        var cursor = candidate.deletingLastPathComponent()
        while cursor.path.hasPrefix(standardizedRoot.path), cursor != standardizedRoot {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: cursor.path, isDirectory: &isDirectory),
               (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil {
                throw GenerationRequestError.storage("A generation execution path traverses a symbolic link.")
            }
            cursor.deleteLastPathComponent()
        }
        return candidate
    }
}
