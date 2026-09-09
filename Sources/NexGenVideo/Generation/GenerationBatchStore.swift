import Foundation
import NexGenEngine

@MainActor
enum GenerationBatchStore {
    struct Snapshot: Codable, Sendable, Equatable {
        let batch: GenerationBatch
        var journal: GenerationBatchJournal
        let authorityAvailable: Bool
        let authoritySpendEvents: [GenerationSpendEvent]
        let recoveredOutputs: [GenerationBatchOutput]

        init(batch: GenerationBatch, journal: GenerationBatchJournal, authorityAvailable: Bool = false,
             authoritySpendEvents: [GenerationSpendEvent] = [], recoveredOutputs: [GenerationBatchOutput] = []) {
            self.batch = batch
            self.journal = journal
            self.authorityAvailable = authorityAvailable
            self.authoritySpendEvents = authoritySpendEvents
            self.recoveredOutputs = recoveredOutputs
        }

        init(record: GenerationExecutionAuthorityStore.Record, recoveredOutputs: [GenerationBatchOutput] = []) {
            self.init(batch: record.batch, journal: record.journal, authorityAvailable: true,
                authoritySpendEvents: record.spendEvents, recoveredOutputs: recoveredOutputs)
        }

        nonisolated func validate() throws { try journal.validate(batch: batch) }

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.batch == rhs.batch && lhs.journal == rhs.journal
                && lhs.authorityAvailable == rhs.authorityAvailable
                && lhs.authoritySpendEvents == rhs.authoritySpendEvents
        }
    }

    nonisolated static func load(id: String, home: URL,
                                 authority supplied: GenerationExecutionAuthorityStore? = nil) throws -> Snapshot {
        let authority = try supplied ?? .live()
        let project = try loadProjectIfPresent(id: id, home: home)
        let projectKey = projectIdentity(home: home)
        if let projectKey, let record = try authority.loadIfPresent(projectKey: projectKey, batchID: id) {
            if let project, project.batch != record.batch {
                throw GenerationRequestError.storage("The project batch manifest conflicts with this host's approved execution.")
            }
            let outputs = try authority.hydrate(record, into: home)
            return Snapshot(record: record, recoveredOutputs: outputs)
        }
        guard let project else {
            throw GenerationRequestError.storage("The generation batch is not recorded for this project.")
        }
        return project
    }

    nonisolated static func all(home: URL,
                                authority supplied: GenerationExecutionAuthorityStore? = nil) throws -> [Snapshot] {
        let authority = try supplied ?? .live()
        let directory = try directory(home: home, create: false)
        var ids: Set<String> = []
        if FileManager.default.fileExists(atPath: directory.path) {
            ids.formUnion(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .map(\.lastPathComponent))
        }
        if let projectKey = projectIdentity(home: home) {
            ids.formUnion(try authority.all(projectKey: projectKey).map { $0.batch.id })
        }
        return try ids.map { try load(id: $0, home: home, authority: authority) }
            .sorted { $0.journal.approvedAt < $1.journal.approvedAt }
    }

    static func approve(_ batch: GenerationBatch, editor: EditorViewModel,
                        authority supplied: GenerationExecutionAuthorityStore? = nil) async throws -> Snapshot {
        guard let home = editor.workingRoot else {
            throw GenerationRequestError.storage("Save this project before approving a generation batch.")
        }
        guard batch.payload.projectKey == editor.projectId else {
            throw GenerationRequestError.gate("The generation batch belongs to another project.")
        }
        let authority = try supplied ?? .live()
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        let authorityID = try authority.authorityID(projectKey: batch.payload.projectKey, batchID: batch.id)
        let snapshot = Snapshot(batch: batch,
            journal: try GenerationBatchJournal(approving: batch, authorityID: authorityID), authorityAvailable: true)
        for item in batch.payload.items {
            try await item.package.requireCurrentContext(editor: editor)
            _ = try await GenerationPackageInputs.restore(package: item.package, editor: editor)
        }
        try scope.requireCurrent(editor: editor)
        if try authority.loadIfPresent(projectKey: batch.payload.projectKey, batchID: batch.id) != nil {
            let existing = try load(id: batch.id, home: home, authority: authority)
            guard existing.batch == batch else {
                throw GenerationRequestError.gate("This batch identity already belongs to another manifest.")
            }
            return existing
        }
        for item in batch.payload.items { try item.package.persist(editor: editor) }
        try markDirty(editor: editor)
        let record = try authority.create(batch: batch, journal: snapshot.journal, home: home)
        try scope.requireCurrent(editor: editor)
        try writeProjectProjection(record: record, home: home)
        let stored = Snapshot(record: record)
        editor.generationBatchCoordinator.record(stored)
        return stored
    }

    static func update(_ expected: Snapshot, editor: EditorViewModel,
                       authority supplied: GenerationExecutionAuthorityStore? = nil,
                       addingSpendEvents: [GenerationSpendEvent] = [],
                       mutate: (inout GenerationBatchJournal) throws -> Void) throws -> Snapshot {
        guard let home = editor.workingRoot else {
            throw GenerationRequestError.storage("The generation batch project is no longer open.")
        }
        guard expected.authorityAvailable, let projectKey = editor.projectId,
              projectKey == expected.batch.payload.projectKey else {
            throw GenerationRequestError.gate("This project copy has batch history but no execution authority on this host.")
        }
        let authority = try supplied ?? .live()
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        let current = try load(id: expected.batch.id, home: home, authority: authority)
        guard current == expected else {
            throw GenerationRequestError.gate("The generation batch advanced in another operation. Read its current state before continuing.")
        }
        var updatedJournal = current.journal
        try mutate(&updatedJournal)
        let candidate = Snapshot(batch: current.batch, journal: updatedJournal, authorityAvailable: true,
            authoritySpendEvents: current.authoritySpendEvents + addingSpendEvents,
            recoveredOutputs: current.recoveredOutputs)
        try candidate.validate()
        guard updatedJournal.approvedAt == current.journal.approvedAt,
              updatedJournal.revision >= current.journal.revision,
              updatedJournal.revision > current.journal.revision || !addingSpendEvents.isEmpty || candidate == current else {
            throw GenerationRequestError.gate("The generation batch cannot replace its approval or rewind execution.")
        }
        guard candidate != current else { return current }
        try scope.requireCurrent(editor: editor)
        try markDirty(editor: editor)
        let authorityRecord = try authority.load(projectKey: projectKey, batchID: expected.batch.id)
        guard Snapshot(record: authorityRecord, recoveredOutputs: current.recoveredOutputs) == current else {
            throw GenerationRequestError.gate("The generation execution authority advanced in another operation.")
        }
        let updatedRecord = try authority.update(expected: authorityRecord, journal: updatedJournal,
            adding: addingSpendEvents)
        try scope.requireCurrent(editor: editor)
        try writeProjectProjection(record: updatedRecord, home: home)
        let updated = Snapshot(record: updatedRecord, recoveredOutputs: current.recoveredOutputs)
        editor.generationBatchCoordinator.record(updated)
        return updated
    }

    static func updateExecution(_ expected: Snapshot, itemID: String, editor: EditorViewModel,
                                authority supplied: GenerationExecutionAuthorityStore? = nil,
                                mutate: (inout GenerationBatchJournal) throws -> Void) throws -> Snapshot {
        guard let home = editor.workingRoot else {
            throw GenerationRequestError.storage("The generation batch project is no longer open.")
        }
        let authority = try supplied ?? .live()
        let current = try load(id: expected.batch.id, home: home, authority: authority)
        guard current.batch == expected.batch, current.journal.approvedAt == expected.journal.approvedAt,
              let execution = expected.journal.executions.first(where: { $0.itemID == itemID }),
              current.journal.executions.first(where: { $0.itemID == itemID }) == execution else {
            throw GenerationRequestError.gate("This batch item advanced while its output was verified. Read its current execution before continuing.")
        }
        return try update(current, editor: editor, authority: authority) { journal in
            try mutate(&journal)
            guard journal.executions.filter({ $0.itemID != itemID }) == current.journal.executions.filter({ $0.itemID != itemID }) else {
                throw GenerationRequestError.gate("An item update cannot change another batch execution.")
            }
        }
    }

    static func recordSpendEvent(_ event: GenerationSpendEvent, authorization: GenerationBatchAuthorization,
                                 editor: EditorViewModel,
                                 authority supplied: GenerationExecutionAuthorityStore? = nil) throws {
        guard editor.projectId != nil else {
            throw GenerationRequestError.storage("The generation batch project is closed.")
        }
        let authority = try supplied ?? .live()
        try authority.recordSpendEvent(event, authorization: authorization)
    }

    static func reconcileRuntime(_ snapshots: [Snapshot], editor: EditorViewModel) throws {
        guard let home = editor.workingRoot else {
            throw GenerationRequestError.storage("The generation batch project is closed.")
        }
        var changedLog = false
        for event in snapshots.flatMap(\.authoritySpendEvents) {
            if let existing = editor.generationLog.spendEvents.first(where: { $0.id == event.id }) {
                guard existing == event else {
                    throw GenerationRequestError.storage("A project spend event conflicts with its execution authority.")
                }
            } else {
                editor.generationLog.spendEvents.append(event)
                changedLog = true
            }
        }
        _ = try GenerationBudgetGuard.verifiedSpend(log: editor.generationLog,
            generatedAssets: editor.mediaAssets, requireCompleteMoney: false)
        if changedLog { try editor.persistGenerationLog() }

        var changedMedia = false
        for receipt in snapshots.flatMap(\.recoveredOutputs) {
            guard case .project(let path) = receipt.asset.source else { continue }
            let url = try ProjectLocalFile.resolve(path, dataRoot: home)
            if let asset = editor.mediaAssets.first(where: { $0.id == receipt.asset.id }) {
                let current = asset.toManifestEntry(projectURL: home)
                guard current.generationInput?.spendTransactionId == receipt.transactionID,
                      current.generationInput?.generationPackageID == receipt.packageID else {
                    throw GenerationRequestError.storage("A project asset conflicts with a recovered generation output.")
                }
                asset.url = url
                asset.duration = receipt.asset.duration
                asset.sourceWidth = receipt.asset.sourceWidth
                asset.sourceHeight = receipt.asset.sourceHeight
                asset.sourceFPS = receipt.asset.sourceFPS
                asset.hasAudio = receipt.asset.hasAudio ?? false
                asset.pendingDownloadURL = nil
                asset.generationStatus = .none
            } else {
                let asset = MediaAsset(entry: receipt.asset, resolvedURL: url)
                asset.generationStatus = .none
                editor.mediaAssets.append(asset)
            }
            if let index = editor.mediaManifest.entries.firstIndex(where: { $0.id == receipt.asset.id }) {
                guard editor.mediaManifest.entries[index].generationInput?.spendTransactionId == receipt.transactionID else {
                    throw GenerationRequestError.storage("A project manifest entry conflicts with a recovered generation output.")
                }
                if editor.mediaManifest.entries[index] != receipt.asset {
                    editor.mediaManifest.entries[index] = receipt.asset
                    changedMedia = true
                }
            } else {
                editor.mediaManifest.entries.append(receipt.asset)
                changedMedia = true
            }
        }
        if changedMedia {
            guard let key = editor.openWorkingCopyKey else {
                throw GenerationRequestError.storage("Recovered generation output needs a live working copy.")
            }
            try ProjectWorkingCopy.markDirty(key: key)
            editor.onPipelineChanged?()
        }
    }

    nonisolated private static func loadProjectIfPresent(id: String, home: URL) throws -> Snapshot? {
        let path = try relativePath(id: id)
        let manifestURL = home.appendingPathComponent(path + "/manifest.json")
        let journalURL = home.appendingPathComponent(path + "/journal.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        let manifestBytes = try Data(contentsOf: ProjectLocalFile.resolve(path + "/manifest.json", dataRoot: home))
        let journalBytes = try Data(contentsOf: ProjectLocalFile.resolve(path + "/journal.json", dataRoot: home))
        let batch = try JSONDecoder().decode(GenerationBatch.self, from: manifestBytes)
        let journal = try JSONDecoder().decode(GenerationBatchJournal.self, from: journalBytes)
        let snapshot = Snapshot(batch: batch, journal: journal)
        try snapshot.validate()
        guard batch.id == id, try GenerationPackageV1.canonicalData(batch) == manifestBytes,
              try GenerationPackageV1.canonicalData(journal) == journalBytes else {
            throw GenerationRequestError.storage("The generation batch has changed or incomplete recorded bytes.")
        }
        return snapshot
    }

    private static func writeProjectProjection(record: GenerationExecutionAuthorityStore.Record, home: URL) throws {
        let folder = try directory(home: home, create: true)
        let destination = folder.appendingPathComponent(record.batch.id, isDirectory: true)
        let manifest = try GenerationPackageV1.canonicalData(record.batch)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try Data(contentsOf: ProjectLocalFile.resolve(
                try relativePath(id: record.batch.id) + "/manifest.json", dataRoot: home))
            guard existing == manifest else {
                throw GenerationRequestError.storage("The project batch manifest conflicts with its execution authority.")
            }
        } else {
            let staging = folder.appendingPathComponent(".\(record.batch.id)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            try manifest.write(to: staging.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
            try GenerationPackageV1.canonicalData(record.journal)
                .write(to: staging.appendingPathComponent("journal.json"), options: .withoutOverwriting)
            try FileManager.default.moveItem(at: staging, to: destination)
            return
        }
        try GenerationPackageV1.canonicalData(record.journal)
            .write(to: destination.appendingPathComponent("journal.json"), options: .atomic)
    }

    nonisolated private static func projectIdentity(home: URL) -> String? {
        if let identity = ProjectIdentity.existingUUID(for: home) { return identity }
        let name = home.lastPathComponent
        guard name.hasPrefix("p-") else { return nil }
        let identity = String(name.dropFirst(2))
        return UUID(uuidString: identity) == nil ? nil : identity
    }

    private static func markDirty(editor: EditorViewModel) throws {
        guard let key = editor.openWorkingCopyKey else {
            throw GenerationRequestError.storage("The generation batch has no recoverable working copy.")
        }
        try ProjectWorkingCopy.markDirty(key: key)
    }

    nonisolated private static func relativePath(id: String) throws -> String {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GenerationRequestError.storage("Invalid generation batch identity.")
        }
        return "generation-batches/\(id)"
    }

    nonisolated private static func directory(home: URL, create: Bool) throws -> URL {
        if create {
            do { return try ProjectLocalFile.ensureDirectory("generation-batches", dataRoot: home) }
            catch { throw GenerationRequestError.storage("Generation batch storage is not a safe project-local directory.") }
        }
        return home.appendingPathComponent("generation-batches", isDirectory: true)
    }
}
