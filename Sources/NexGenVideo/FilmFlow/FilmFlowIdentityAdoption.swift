import AppKit
import Foundation
import NexGenEngine

@MainActor
enum FilmFlowIdentityAdoption {
    private final class Session {
        weak var editor: EditorViewModel?
        let home: URL?
        let key: String?
        let generation: UUID?
        let manager: UndoManager
        lazy var history = PipelineNativeRevisionHistory<ConfirmedIdentityAssetManifestV1>(manager: manager,
            equivalent: { $0 == $1 }, restore: { [weak self] desired, expected in
                guard let self, let editor = self.editor, editor.workingRoot == self.home, editor.openWorkingCopyKey == self.key, editor.openWorkingCopyGeneration == self.generation else {
                    throw GateBlocked("Open the original project before restoring its prepared identity.")
                }
                return try await transact(editor: editor) { root in
                    guard try ConfirmedIdentityAssetStoreV1.load(dataRoot: root) == expected else {
                        throw GateBlocked("Prepared identities changed. Reload before Undo.")
                    }
                    try ConfirmedIdentityAssetStoreV1.save(desired, dataRoot: root)
                    return desired
                }
            }, failure: { [weak self] error in self?.editor?.mediaPanelToast = .init(message: error.localizedDescription) })
        init(editor: EditorViewModel, manager: UndoManager) {
            self.editor = editor; self.home = editor.workingRoot; self.key = editor.openWorkingCopyKey; self.generation = editor.openWorkingCopyGeneration; self.manager = manager
        }
    }
    private static var sessions: [ObjectIdentifier: Session] = [:]

    static func confirm(_ retained: FilmFlowSnapshotStore.Retained, sourceID: String, name: String,
                        explicitlyConfirmed: Bool, editor: EditorViewModel) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard explicitlyConfirmed, !name.isEmpty, let manager = editor.undoManager else {
            throw GateBlocked("Name this identity and explicitly confirm the displayed image before adopting it.")
        }
        let slug = AgentService.identitySlug(name)
        guard !slug.isEmpty else { throw GateBlocked("Enter a usable identity name.") }
        sessions = sessions.filter { $0.value.editor != nil }
        let key = ObjectIdentifier(editor)
        let session: Session
        if let current = sessions[key], current.home == editor.workingRoot, current.key == editor.openWorkingCopyKey, current.generation == editor.openWorkingCopyGeneration { session = current }
        else { sessions[key]?.history.clear(); session = Session(editor: editor, manager: manager); sessions[key] = session }
        try session.history.beginPublication()
        defer { session.history.endPublication() }
        _ = try await transact(editor: editor, validate: { guard session.home == editor.workingRoot, session.key == editor.openWorkingCopyKey,
                  session.generation == editor.openWorkingCopyGeneration else { throw FilmFlowFailure.message("The project changed during preparation.") }; try session.history.requireNoPendingRestore() },
            didCommit: { result in session.history.record(before: result.0, after: result.1, name: "Confirm FilmFlow Identity") }) { root in
            let directory = root.appendingPathComponent(FilmFlowSnapshotStore.path(retained.id))
            let snapshot = try FilmFlowSnapshot.verify(directory: directory, expectedSHA256: retained.sha256)
            let material = try FilmFlowMaterial.load(directory: directory, snapshot: snapshot)
            guard let item = material.items.first(where: { $0.id == sourceID }), let entity = item.entity,
                  let image = item.image, ["CHARACTER", "LOCATION"].contains(entity.type) else {
                throw GateBlocked("Choose a downloaded Character or Location image for native identity confirmation.")
            }
            let role: ConfirmedIdentityAssetRoleV1 = entity.type == "CHARACTER" ? .character : .location
            let category = role == .character ? "characters" : "locations"
            let before = try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
            let path = "import/\(category)/\(slug)/\(retained.id.uuidString.lowercased())-\((image.path as NSString).lastPathComponent)"
            let source = try ProjectLocalFile.requireHash(image.sha256, at: image.path, dataRoot: directory)
            _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: root)
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
                try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(path))
            }
            _ = try ProjectLocalFile.requireHash(image.sha256, at: path, dataRoot: root)
            try ConfirmedIdentityAssetStoreV1.recordIntake(role: role, identityName: name, identitySlug: slug, paths: [path], dataRoot: root)
            let after = try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
            let archive = "import/filmflow-adoptions/\(retained.id.uuidString.lowercased())/identity-\(UUID().uuidString.lowercased()).v1.json"
            _ = try ProjectLocalFile.ensureDirectory((archive as NSString).deletingLastPathComponent, dataRoot: root)
            try FileManager.default.copyItem(at: ProjectLocalFile.resolve(PipelineLayout.confirmedIdentityAssetsFile, dataRoot: root),
                to: root.appendingPathComponent(archive))
            let mapping = FilmFlowAdoption(snapshotID: retained.id, snapshotSHA256: retained.sha256,
                sourceObjectID: sourceID, targetID: role.rawValue + ":" + slug, fields: ["image", "native-identity-confirmation"])
            try mapping.record(phase: "brief", outputs: [
                PlanningWriterIO.reference(archive, id: "confirmed-identities", role: "host.confirmed-identities", dataRoot: root),
                PlanningWriterIO.reference(path, id: sourceID, role: "host.confirmed-identity-source", dataRoot: root)], dataRoot: root)
            return (before, after)
        }
    }

    private static func transact<T: Sendable>(editor: EditorViewModel,
        validate: @escaping @MainActor () throws -> Void = {},
        didCommit: @escaping @MainActor (T) -> Void = { _ in }, body: @escaping @Sendable (URL) throws -> T) async throws -> T {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Confirm prepared identity")
        defer { access.end(editor: editor) }
        let task = Task.detached(priority: .userInitiated) {
            _ = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "brief")
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { root in
                let writer = try PipelinePlanningWriteAccess(dataRoot: root, declaration: access.declaration, phase: "brief")
                let output = try body(root)
                try writer.revalidate()
                try PipelinePhaseMutationRecorder.record(phase: "brief", dataRoot: root, captureLineage: false,
                    declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
                    declaredProductionContract: access.declaration.productionContract)
                return output
            }
            do { try fence.requireUnchanged(); return (transaction, fence) }
            catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        let output = try result.0.commit { _ in
            try validate(); try access.requireCurrent(editor: editor)
            try result.1.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        didCommit(output)
        editor.onPipelineChanged?(); await editor.refreshEngineState()
        return output
    }
}
