import Foundation
import NexGenEngine

@MainActor
enum GenerationBatchStore {
    struct Snapshot: Codable, Sendable, Equatable {
        let batch: GenerationBatch
        var journal: GenerationBatchJournal

        func validate() throws { try journal.validate(batch: batch) }
    }

    static func load(id: String, home: URL) throws -> Snapshot {
        let path = try relativePath(id: id)
        let file = try ProjectLocalFile.resolve(path, dataRoot: home)
        let bytes = try Data(contentsOf: file)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: bytes)
        try snapshot.validate()
        guard snapshot.batch.id == id, try GenerationPackageV1.encode(snapshot) == bytes else {
            throw GenerationRequestError.storage("The generation batch has changed or incomplete recorded bytes.")
        }
        return snapshot
    }

    static func all(home: URL) throws -> [Snapshot] {
        let directory = try directory(home: home, create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try load(id: $0.deletingPathExtension().lastPathComponent, home: home) }
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
        try GenerationPackageV1.encode(snapshot).write(to: folder.appendingPathComponent(batch.id + ".json"), options: .withoutOverwriting)
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
        let file = try ProjectLocalFile.resolve(relativePath(id: expected.batch.id), dataRoot: home)
        try GenerationPackageV1.encode(updated).write(to: file, options: .atomic)
        editor.generationBatchCoordinator.record(updated)
        return updated
    }

    private static func markDirty(editor: EditorViewModel) throws {
        guard let key = editor.openWorkingCopyKey else { throw GenerationRequestError.storage("The generation batch has no recoverable working copy.") }
        try ProjectWorkingCopy.markDirty(key: key)
    }

    private static func relativePath(id: String) throws -> String {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GenerationRequestError.storage("Invalid generation batch identity.")
        }
        return "generation-batches/\(id).json"
    }

    private static func directory(home: URL, create: Bool) throws -> URL {
        let directory = home.appendingPathComponent("generation-batches", isDirectory: true)
        guard directory.resolvingSymlinksInPath() == home.resolvingSymlinksInPath().appendingPathComponent("generation-batches") else {
            throw GenerationRequestError.storage("Generation batches cannot traverse symbolic links.")
        }
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory
    }
}
