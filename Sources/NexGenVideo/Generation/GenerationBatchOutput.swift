import Foundation
import NexGenEngine

struct GenerationBatchOutput: Codable, Sendable, Equatable {
    let schema: String
    let batchID: String
    let itemID: String
    let packageID: String
    let transactionID: String
    let asset: MediaManifestEntry
    let sha256: String

    nonisolated static func load(authorization: GenerationBatchAuthorization, assetID: String,
                                 home: URL) throws -> Self? {
        let path = try receiptPath(authorization: authorization, assetID: assetID)
        let candidate = home.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: candidate.path) ||
                (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil else { return nil }
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: home))
        let receipt = try JSONDecoder().decode(Self.self, from: bytes)
        let snapshot = try GenerationBatchStore.load(id: authorization.batchID, home: home)
        try validate(receipt, snapshot: snapshot, home: home)
        guard try GenerationPackageV1.canonicalData(receipt) == bytes else {
            throw GenerationRequestError.storage("A completed batch output no longer matches its recorded request.")
        }
        return receipt
    }

    nonisolated static func validate(_ receipt: Self, snapshot: GenerationBatchStore.Snapshot,
                                     home: URL) throws {
        guard receipt.schema == "generation-batch-output/v1",
              let item = snapshot.batch.payload.items.first(where: { $0.id == receipt.itemID }),
              let execution = snapshot.journal.executions.first(where: { $0.itemID == receipt.itemID }),
              receipt.batchID == snapshot.batch.id,
              receipt.packageID == item.package.id, receipt.transactionID == execution.transactionID,
              execution.placeholders.contains(where: { $0.id == receipt.asset.id }),
              receipt.asset.generationInput?.spendTransactionId == receipt.transactionID,
              receipt.asset.generationInput?.generationPackageID == receipt.packageID,
              receipt.asset.generationInput.map(GenerationPackageV1.normalized) == item.package.payload.generationInput,
              receipt.asset.type.rawValue == item.package.payload.modality,
              receipt.asset.duration.isFinite, receipt.asset.duration > 0,
              case .project(let mediaPath) = receipt.asset.source,
              mediaPath.hasPrefix(Project.mediaDirectoryName + "/") else {
            throw GenerationRequestError.storage("A completed batch output no longer matches its recorded request.")
        }
        _ = try ProjectLocalFile.requireHash(receipt.sha256, at: mediaPath, dataRoot: home)
    }

    @MainActor
    static func record(asset: MediaAsset, authorization: GenerationBatchAuthorization,
                       editor: EditorViewModel) async throws {
        guard let home = editor.workingRoot, let transaction = asset.generationInput?.spendTransactionId,
              let package = asset.generationInput?.generationPackageID else {
            throw GenerationRequestError.storage("The completed batch output has no project or request identity.")
        }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        let entry = asset.toManifestEntry(projectURL: home)
        guard case .project(let mediaPath) = entry.source,
              mediaPath.hasPrefix(Project.mediaDirectoryName + "/"),
              entry.duration.isFinite, entry.duration > 0 else {
            throw GenerationRequestError.storage("The completed batch output is not project-local.")
        }
        let digest = try await Task.detached(priority: .utility) {
            try FileDigest.sha256(of: ProjectLocalFile.resolve(mediaPath, dataRoot: home))
        }.value
        try scope.requireCurrent(editor: editor)
        guard editor.mediaAssets.contains(where: { $0 === asset }), asset.toManifestEntry(projectURL: home) == entry else {
            throw GenerationRequestError.storage("The completed batch output changed while its receipt was recorded.")
        }
        let snapshot = try GenerationBatchStore.load(id: authorization.batchID, home: home)
        guard let item = snapshot.batch.payload.items.first(where: { $0.id == authorization.itemID }),
              let execution = snapshot.journal.executions.first(where: { $0.itemID == authorization.itemID }),
              execution.transactionID == transaction, execution.providerRequestID != nil,
              [.running, .blocked].contains(execution.state),
              execution.placeholders.contains(where: { $0.id == entry.id }),
              item.package.id == package, entry.type.rawValue == item.package.payload.modality,
              entry.generationInput.map(GenerationPackageV1.normalized) == item.package.payload.generationInput else {
            throw GenerationRequestError.gate("The completed output cannot be attached to this batch execution.")
        }
        let receipt = Self(schema: "generation-batch-output/v1", batchID: authorization.batchID, itemID: authorization.itemID,
            packageID: package, transactionID: transaction, asset: entry, sha256: digest)
        let existing = try await Task.detached(priority: .utility) {
            try load(authorization: authorization, assetID: entry.id, home: home)
        }.value
        try scope.requireCurrent(editor: editor)
        guard asset.toManifestEntry(projectURL: home) == entry else {
            throw GenerationRequestError.storage("The batch output changed while checking its existing receipt.")
        }
        if let existing {
            guard existing == receipt else { throw GenerationRequestError.storage("A completed batch output cannot replace its receipt.") }
            try GenerationExecutionAuthorityStore.live().archiveOutput(receipt, home: home)
            return
        }
        try GenerationExecutionAuthorityStore.live().archiveOutput(receipt, home: home)
        try scope.requireCurrent(editor: editor)
        let relative = try receiptPath(authorization: authorization, assetID: entry.id)
        let destination = home.appendingPathComponent(relative)
        let parent = try ProjectLocalFile.resolve("generation-batches/\(authorization.batchID)/manifest.json", dataRoot: home)
            .deletingLastPathComponent()
        guard destination.deletingLastPathComponent() == parent, let key = editor.openWorkingCopyKey else {
            throw GenerationRequestError.storage("The batch output receipt has no recoverable destination.")
        }
        try ProjectWorkingCopy.markDirty(key: key)
        try GenerationPackageV1.canonicalData(receipt).write(to: destination, options: .withoutOverwriting)
    }

    nonisolated static func receiptKey(authorization: GenerationBatchAuthorization, assetID: String) -> String {
        FileDigest.sha256(of: Data((authorization.itemID + "\n" + assetID).utf8))
    }

    nonisolated static func receiptPath(authorization: GenerationBatchAuthorization, assetID: String) throws -> String {
        guard authorization.batchID.count == 64,
              authorization.batchID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              UUID(uuidString: authorization.itemID) != nil, !assetID.isEmpty else {
            throw GenerationRequestError.storage("Invalid batch output identity.")
        }
        let key = receiptKey(authorization: authorization, assetID: assetID)
        return "generation-batches/\(authorization.batchID)/output-\(key).json"
    }
}
