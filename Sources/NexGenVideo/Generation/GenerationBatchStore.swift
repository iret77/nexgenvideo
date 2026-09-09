import Foundation
import NexGenEngine

@MainActor
enum GenerationBatchStore {
    struct Snapshot: Codable, Sendable, Equatable {
        let batch: GenerationBatch
        var journal: GenerationBatchJournal

        nonisolated func validate() throws { try journal.validate(batch: batch) }
    }

    nonisolated static func load(id: String, home: URL) throws -> Snapshot {
        let path = try relativePath(id: id)
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

    nonisolated static func all(home: URL) throws -> [Snapshot] {
        let directory = try directory(home: home, create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { try load(id: $0.lastPathComponent, home: home) }
            .sorted { $0.journal.approvedAt < $1.journal.approvedAt }
    }

    static func approve(_ batch: GenerationBatch, editor: EditorViewModel) async throws -> Snapshot {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("Save this project before approving a generation batch.") }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        let snapshot = Snapshot(batch: batch, journal: try GenerationBatchJournal(approving: batch))
        for item in batch.payload.items {
            try await item.package.requireCurrentContext(editor: editor)
            _ = try await GenerationPackageInputs.restore(package: item.package, editor: editor)
        }
        try scope.requireCurrent(editor: editor)
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(try relativePath(id: batch.id)).path) {
            let existing = try load(id: batch.id, home: home)
            guard existing.batch == batch else { throw GenerationRequestError.gate("This batch identity already belongs to another manifest.") }
            return existing
        }
        for item in batch.payload.items { try item.package.persist(editor: editor) }
        try markDirty(editor: editor)
        let folder = try directory(home: home, create: true)
        let staging = folder.appendingPathComponent(".\(batch.id)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try GenerationPackageV1.canonicalData(batch).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try GenerationPackageV1.canonicalData(snapshot.journal).write(to: staging.appendingPathComponent("journal.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: folder.appendingPathComponent(batch.id, isDirectory: true))
        editor.generationBatchCoordinator.record(snapshot)
        return snapshot
    }

    static func update(_ expected: Snapshot, editor: EditorViewModel,
                       mutate: (inout GenerationBatchJournal) throws -> Void) throws -> Snapshot {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("The generation batch project is no longer open.") }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        guard try load(id: expected.batch.id, home: home) == expected else {
            throw GenerationRequestError.gate("The generation batch advanced in another operation. Read its current state before continuing.")
        }
        var updated = expected
        try mutate(&updated.journal)
        try updated.validate()
        guard updated.journal.approvedAt == expected.journal.approvedAt,
              updated.journal.revision >= expected.journal.revision,
              updated.journal.revision > expected.journal.revision || updated == expected else {
            throw GenerationRequestError.gate("The generation batch cannot replace its approval or rewind execution.")
        }
        guard updated != expected else { return expected }
        try scope.requireCurrent(editor: editor)
        try markDirty(editor: editor)
        let file = try ProjectLocalFile.resolve(relativePath(id: expected.batch.id) + "/journal.json", dataRoot: home)
        try GenerationPackageV1.canonicalData(updated.journal).write(to: file, options: .atomic)
        editor.generationBatchCoordinator.record(updated)
        return updated
    }

    static func updateExecution(_ expected: Snapshot, itemID: String, editor: EditorViewModel,
                                mutate: (inout GenerationBatchJournal) throws -> Void) throws -> Snapshot {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("The generation batch project is no longer open.") }
        let current = try load(id: expected.batch.id, home: home)
        guard current.batch == expected.batch, current.journal.approvedAt == expected.journal.approvedAt,
              let execution = expected.journal.executions.first(where: { $0.itemID == itemID }),
              current.journal.executions.first(where: { $0.itemID == itemID }) == execution else {
            throw GenerationRequestError.gate("This batch item advanced while its output was verified. Read its current execution before continuing.")
        }
        return try update(current, editor: editor) { journal in
            try mutate(&journal)
            guard journal.executions.filter({ $0.itemID != itemID }) == current.journal.executions.filter({ $0.itemID != itemID }) else {
                throw GenerationRequestError.gate("An item update cannot change another batch execution.")
            }
        }
    }

    private static func markDirty(editor: EditorViewModel) throws {
        guard let key = editor.openWorkingCopyKey else { throw GenerationRequestError.storage("The generation batch has no recoverable working copy.") }
        try ProjectWorkingCopy.markDirty(key: key)
    }

    nonisolated private static func relativePath(id: String) throws -> String {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GenerationRequestError.storage("Invalid generation batch identity.")
        }
        return "generation-batches/\(id)"
    }

    nonisolated private static func directory(home: URL, create: Bool) throws -> URL {
        let directory = home.appendingPathComponent("generation-batches", isDirectory: true)
        guard directory.resolvingSymlinksInPath() == home.resolvingSymlinksInPath().appendingPathComponent("generation-batches") else {
            throw GenerationRequestError.storage("Generation batches cannot traverse symbolic links.")
        }
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory
    }
}
