import AppKit
import Foundation
import NexGenEngine

@MainActor
enum PipelineBibleEditor {
    private struct Revision: Sendable {
        let bible: Bible
        let sha256: String
        let variants: BibleIdentityVariantsV1
        let variantsSHA256: String
        let home: URL
        let key: String
    }

    @MainActor private final class Session {
        weak var editor: EditorViewModel?
        let home: URL?
        let key: String?
        let manager: UndoManager
        lazy var history = PipelineNativeRevisionHistory<Revision>(manager: manager,
            equivalent: { $0.home == $1.home && $0.key == $1.key && $0.bible == $1.bible && $0.variants == $1.variants }, restore: { [weak self] desired, expected in
                guard let editor = self?.editor else { throw GateBlocked("Open the original project to restore its Bible.") }
                return try await restore(desired, expected: expected, editor: editor)
            }, failure: { [weak self] error in
                self?.editor?.mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            })
        init(editor: EditorViewModel, manager: UndoManager) {
            self.editor = editor; self.manager = manager; home = editor.workingRoot; key = editor.openWorkingCopyKey
        }
    }
    private static var sessions: [ObjectIdentifier: Session] = [:]

    static func recordNativeAssignment(before: Bible, beforeSHA256: String, after: Bible, afterSHA256: String,
        editor: EditorViewModel, name: String = "Assign Bible View") async throws {
        guard before != after else { return }
        guard let manager = editor.undoManager else { throw GateBlocked("The Bible was saved, but its editor window has no Undo manager.") }
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let key = editor.openWorkingCopyKey else { throw changed() }
        let revisions = try await Task.detached(priority: .userInitiated) {
            guard before.project == after.project, try loadBible(dataRoot: root) == after,
                  try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root)) == afterSHA256,
                  let variants = try BibleIdentityVariantStoreV1.loadIfPresent(dataRoot: root) else { throw changed() }
            let variantSHA = try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleIdentityVariantsFile, dataRoot: root))
            return (Revision(bible: before, sha256: beforeSHA256, variants: variants, variantsSHA256: variantSHA, home: home, key: key),
                Revision(bible: after, sha256: afterSHA256, variants: variants, variantsSHA256: variantSHA, home: home, key: key))
        }.value
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key else { throw changed() }
        sessions = sessions.filter { $0.value.editor != nil }
        let id = ObjectIdentifier(editor)
        let session: Session
        if let existing = sessions[id], existing.home == home, existing.key == key { session = existing }
        else { sessions[id]?.history.clear(); session = Session(editor: editor, manager: manager); sessions[id] = session }
        session.history.record(before: revisions.0, after: revisions.1, name: name)
    }

    static func resetHistory(editor: EditorViewModel) {
        sessions.removeValue(forKey: ObjectIdentifier(editor))?.history.clear()
    }

    private static func restore(_ desired: Revision, expected: Revision, editor: EditorViewModel) async throws -> Revision {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Restore Bible View")
        defer { access.end(editor: editor) }
        guard access.home == expected.home, access.key == expected.key, desired.home == expected.home,
              desired.key == expected.key, desired.variants == expected.variants else { throw changed() }
        let task = Task.detached(priority: .userInitiated) {
            _ = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "bible")
            try requireCurrent(expected, dataRoot: access.root)
            let paths = [PipelineLayout.bibleFile, PipelineLayout.bibleIdentityVariantsFile]
                + PipelineBibleWriter.referencePaths(expected.bible) + PipelineBibleWriter.referencePaths(desired.bible)
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root, additionalCanonicalPaths: paths)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "bible")
                try requireCurrent(expected, dataRoot: staging)
                try PipelineBibleWriter.write(desired.bible, variants: expected.variants, dataRoot: staging)
                try writer.revalidate()
                try PipelinePhaseMutationRecorder.record(phase: "bible", dataRoot: staging, captureLineage: true,
                    declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
                    declaredProductionContract: access.declaration.productionContract)
                guard let actual = try loadBible(dataRoot: staging) else { throw changed() }
                return Revision(bible: actual,
                    sha256: try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: staging)),
                    variants: expected.variants,
                    variantsSHA256: try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleIdentityVariantsFile, dataRoot: staging)),
                    home: access.home, key: access.key)
            }
            do { try fence.requireUnchanged(); return (transaction, fence) }
            catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        let written: Revision
        do {
            try Task.checkCancellation()
            written = try result.0.commit { _ in
                try access.requireCurrent(editor: editor)
                try result.1.requireCanonicalRootsUnchanged()
                try ProjectWorkingCopy.markDirty(key: access.key)
            }
        } catch {
            await Task.detached(priority: .utility) { result.0.discard() }.value
            throw error
        }
        await Task.detached(priority: .utility) { result.0.discard() }.value
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return written
    }

    nonisolated private static func requireCurrent(_ expected: Revision, dataRoot: URL) throws {
        guard try loadBible(dataRoot: dataRoot) == expected.bible,
              try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: dataRoot)) == expected.sha256,
              try BibleIdentityVariantStoreV1.loadIfPresent(dataRoot: dataRoot) == expected.variants,
              try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleIdentityVariantsFile, dataRoot: dataRoot)) == expected.variantsSHA256 else { throw changed() }
    }

    nonisolated private static func changed() -> GateBlocked { GateBlocked("The Bible changed. Reload it before restoring this native view assignment.") }
}
