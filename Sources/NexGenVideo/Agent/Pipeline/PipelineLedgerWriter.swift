import AppKit
import Foundation
import NexGenEngine
import Observation

@MainActor
enum PipelineLedgerWriter {
    struct Revision: Sendable {
        let ledger: Ledger?
        let sha256: String?
        let home: URL
        let key: String
        let generation: UUID
        let declaration: ProjectPackGate.MutationDeclaration
        let phase: String
    }

    @MainActor @Observable fileprivate final class Session {
        @ObservationIgnored weak var editor: EditorViewModel?
        let home: URL
        let key: String
        let generation: UUID
        let manager: UndoManager
        @ObservationIgnored lazy var history = PipelineNativeRevisionHistory<Revision>(manager: manager,
            equivalent: { $0.home == $1.home && $0.key == $1.key && $0.generation == $1.generation
                && $0.declaration == $1.declaration && $0.phase == $1.phase && $0.ledger == $1.ledger },
            restore: { [weak self] desired, expected in
                guard let editor = self?.editor else { throw changed() }
                return try await restore(desired, expected: expected, editor: editor)
            }, failure: { [weak self] error in
                guard let self, let editor = self.editor, editor.workingRoot == self.home,
                      editor.openWorkingCopyKey == self.key, editor.openWorkingCopyGeneration == self.generation else { return }
                editor.mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            }, restoreStateChanged: { [weak self] pending in self?.restorePending = pending })
        var restorePending = false
        init(editor: EditorViewModel, home: URL, key: String, generation: UUID, manager: UndoManager) {
            self.editor = editor; self.home = home; self.key = key; self.generation = generation; self.manager = manager
        }
    }
    @MainActor @Observable fileprivate final class Registry {
        var sessions: [ObjectIdentifier: Session] = [:]
    }
    private static let registry = Registry()
    private static var sessions: [ObjectIdentifier: Session] {
        get { registry.sessions }
        set { registry.sessions = newValue }
    }

    static func isRestoring(editor: EditorViewModel) -> Bool {
        guard let session = sessions[ObjectIdentifier(editor)], session.home == editor.workingRoot,
              session.key == editor.openWorkingCopyKey, session.generation == editor.openWorkingCopyGeneration else { return false }
        return session.restorePending
    }

    static func restoreMessage(editor: EditorViewModel) -> String? {
        guard isRestoring(editor: editor) else { return nil }
        if editor.agentService.isComposerBlocked {
            return "Intent Ledger restore is waiting. Complete or dismiss the current agent decision; the queued restore will then run. Current values remain unchanged until it completes."
        }
        if editor.agentService.isStreaming {
            return "Intent Ledger restore is waiting. Let the agent finish, or stop it in the Agent panel; the queued restore will then run. Current values remain unchanged until it completes."
        }
        return "Restoring Intent Ledger… Current values remain unchanged until the restore completes. Undo and Redo will then be available."
    }

    @MainActor final class ToolTransaction {
        let home: URL
        let root: URL
        let key: String
        let generation: UUID
        let declaration: ProjectPackGate.MutationDeclaration
        let lease: UUID
        private let session: Session
        private weak var editor: EditorViewModel?
        private var publication: (before: Revision, after: Revision)?

        init(editor: EditorViewModel, dataRoot: URL, declaration: ProjectPackGate.MutationDeclaration, lease: UUID) throws {
            guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home), root == dataRoot,
                  let key = editor.openWorkingCopyKey, let generation = editor.openWorkingCopyGeneration,
                  let manager = editor.undoManager, editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease) else { throw changed() }
            self.home = home; self.root = root; self.key = key; self.generation = generation
            self.declaration = declaration; self.lease = lease; self.editor = editor
            sessions = sessions.filter { $0.value.editor != nil }
            let id = ObjectIdentifier(editor)
            if let current = sessions[id], current.home == home, current.key == key, current.generation == generation {
                session = current
            } else {
                sessions[id]?.history.clear()
                let current = Session(editor: editor, home: home, key: key, generation: generation, manager: manager)
                sessions[id] = current; session = current
            }
            try session.history.beginPublication()
        }

        func requireCurrent(editor: EditorViewModel) throws {
            guard self.editor === editor, editor.workingRoot == home, editor.openWorkingCopyKey == key,
                  editor.openWorkingCopyGeneration == generation,
                  editor.declaredPluginName == declaration.packName, editor.declaredPluginBinding == declaration.binding,
                  editor.declaredProductionContract == declaration.productionContract,
                  editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease) else { throw changed() }
            try session.history.requireNoPendingRestore()
        }
        func finish() {
            defer { session.history.endPublication() }
            guard let publication, publication.before.ledger != publication.after.ledger,
                  let editor, editor.workingRoot == home, editor.openWorkingCopyKey == key,
                  editor.openWorkingCopyGeneration == generation else { return }
            editor.onPipelineChanged?()
            Task { await editor.refreshEngineState() }
        }
        fileprivate func recorded(before: Revision, after: Revision) {
            publication = (before, after)
            guard before.ledger != after.ledger, let editor, editor.workingRoot == home,
                  editor.openWorkingCopyKey == key, editor.openWorkingCopyGeneration == generation else { return }
            session.history.record(before: before, after: after, name: "Revise Intent Ledger")
        }
    }

    static func waitForPendingNativeRestore(editor: EditorViewModel) async throws -> Ledger? {
        guard let session = sessions[ObjectIdentifier(editor)], session.home == editor.workingRoot,
              session.key == editor.openWorkingCopyKey, session.generation == editor.openWorkingCopyGeneration else { throw changed() }
        return try await session.history.waitForRestore().ledger
    }

    static func mutate<T: Sendable>(dataRoot: URL, editor: EditorViewModel, transaction: ToolTransaction,
                                   body: @escaping @Sendable (inout Ledger) throws -> T) async throws -> T {
        try transaction.requireCurrent(editor: editor)
        let home = transaction.home, key = transaction.key, generation = transaction.generation, declaration = transaction.declaration
        let task = Task.detached(priority: .userInitiated) {
            let phase = try requireContext(dataRoot: dataRoot, declaration: declaration)
            let before = try read(dataRoot: dataRoot, home: home, key: key, generation: generation, declaration: declaration, phase: phase)
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: dataRoot, additionalCanonicalPaths: [PipelineLayout.ledgerFile])
            let prepared = try ProjectWorkingCopy.preparePipelineTransaction(at: dataRoot) { staging in
                guard try requireContext(dataRoot: staging, declaration: declaration) == phase else { throw changed() }
                try requireRevision(before, dataRoot: staging)
                var ledger = before.ledger ?? Ledger()
                let value = try body(&ledger)
                try write(ledger, dataRoot: staging)
                try record(phase: phase, dataRoot: staging, declaration: declaration)
                let after = try read(dataRoot: staging, home: home, key: key, generation: generation, declaration: declaration, phase: phase)
                return (value, after)
            }
            do { try fence.requireUnchanged(); return (prepared, fence, before) }
            catch { prepared.discard(); throw error }
        }
        let prepared = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        do {
            try Task.checkCancellation()
            let result = try prepared.0.commit { _ in
                try transaction.requireCurrent(editor: editor)
                try prepared.1.requireCanonicalRootsUnchanged()
                try ProjectWorkingCopy.markDirty(key: key)
            }
            transaction.recorded(before: prepared.2, after: result.1)
            await Task.detached(priority: .utility) { prepared.0.discard() }.value
            return result.0
        } catch {
            await Task.detached(priority: .utility) { prepared.0.discard() }.value
            throw error
        }
    }

    private static func restore(_ desired: Revision, expected: Revision, editor: EditorViewModel) async throws -> Revision {
        try await waitForAgentIdle(expected: expected, editor: editor)
        let access = try PipelineNativeEditAccess(editor: editor, label: "Restore Intent Ledger")
        var holdsLease = true
        defer { if holdsLease { access.end(editor: editor) } }
        guard desired.home == expected.home, desired.key == expected.key, desired.generation == expected.generation,
              desired.declaration == expected.declaration, desired.phase == expected.phase,
              editor.openWorkingCopyGeneration == expected.generation, access.home == expected.home,
              access.key == expected.key, access.declaration == expected.declaration else { throw changed() }
        let task = Task.detached(priority: .userInitiated) {
            guard try requireContext(dataRoot: access.root, declaration: access.declaration) == expected.phase else { throw changed() }
            try requireRevision(expected, dataRoot: access.root)
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root, additionalCanonicalPaths: [PipelineLayout.ledgerFile])
            let prepared = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                guard try requireContext(dataRoot: staging, declaration: access.declaration) == expected.phase else { throw changed() }
                try requireRevision(expected, dataRoot: staging)
                try write(desired.ledger, dataRoot: staging)
                try record(phase: expected.phase, dataRoot: staging, declaration: access.declaration)
                return try read(dataRoot: staging, home: expected.home, key: expected.key, generation: expected.generation,
                    declaration: expected.declaration, phase: expected.phase)
            }
            do { try fence.requireUnchanged(); return (prepared, fence) }
            catch { prepared.discard(); throw error }
        }
        let prepared = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        do {
            try Task.checkCancellation()
            let written = try prepared.0.commit { _ in
                try access.requireCurrent(editor: editor)
                guard editor.openWorkingCopyGeneration == expected.generation else { throw changed() }
                try prepared.1.requireCanonicalRootsUnchanged()
                try ProjectWorkingCopy.markDirty(key: access.key)
            }
            await Task.detached(priority: .utility) { prepared.0.discard() }.value
            access.end(editor: editor); holdsLease = false
            editor.onPipelineChanged?(); await editor.refreshEngineState()
            return written
        } catch {
            await Task.detached(priority: .utility) { prepared.0.discard() }.value
            throw error
        }
    }

    private static func waitForAgentIdle(expected: Revision, editor: EditorViewModel) async throws {
        while true {
            try Task.checkCancellation()
            guard editor.workingRoot == expected.home, editor.openWorkingCopyKey == expected.key,
                  editor.openWorkingCopyGeneration == expected.generation,
                  editor.declaredPluginName == expected.declaration.packName,
                  editor.declaredPluginBinding == expected.declaration.binding,
                  editor.declaredProductionContract == expected.declaration.productionContract else { throw changed() }
            guard editor.agentService.isStreaming || editor.agentService.isComposerBlocked else { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    nonisolated private static func requireContext(dataRoot: URL, declaration: ProjectPackGate.MutationDeclaration) throws -> String {
        _ = try ProjectPackGate.requireMutation(projectURL: FrameInventory.projectHome(of: dataRoot), declaredPack: declaration.packName,
            declaredBinding: declaration.binding, declaredProductionContract: declaration.productionContract)
        let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: declaration.binding,
            expectedProductionContract: declaration.productionContract)
        let order = try workflow.map { try PhaseContractRuntime.order(workflow: $0) } ?? PhaseContractRuntime.order(activePack: declaration.packName)
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot, order: order)
        guard let phase = state.nextPhase,
              (workflow?.isProductionV2 == true ? ProductionWorkflowV2.supporting(phase).contains("set_ledger_attribute")
                : PipelineAgentContract.currentPhaseCapabilities[phase]?.contains(.setLedgerAttribute) == true) else {
            throw GateBlocked("The Intent Ledger can change only in its current allowed production phase. Explicitly rewind before revising approved work.")
        }
        return phase
    }
    nonisolated private static func read(dataRoot: URL, home: URL, key: String, generation: UUID,
                                         declaration: ProjectPackGate.MutationDeclaration, phase: String) throws -> Revision {
        let path = dataRoot.appendingPathComponent(PipelineLayout.ledgerFile)
        if !FileManager.default.fileExists(atPath: path.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil {
            return .init(ledger: nil, sha256: nil, home: home, key: key, generation: generation, declaration: declaration, phase: phase)
        }
        let url = try ProjectLocalFile.resolve(PipelineLayout.ledgerFile, dataRoot: dataRoot)
        let ledger = try YAMLArtifactStore(dataRoot: dataRoot).load(Ledger.self, at: PipelineLayout.ledgerFile)
        try validate(ledger)
        return .init(ledger: ledger, sha256: try FileDigest.sha256(of: url), home: home, key: key, generation: generation, declaration: declaration, phase: phase)
    }
    nonisolated private static func requireRevision(_ revision: Revision, dataRoot: URL) throws {
        let actual = try read(dataRoot: dataRoot, home: revision.home, key: revision.key, generation: revision.generation,
            declaration: revision.declaration, phase: revision.phase)
        guard actual.ledger == revision.ledger, actual.sha256 == revision.sha256 else { throw changed() }
    }
    nonisolated private static func write(_ ledger: Ledger?, dataRoot: URL) throws {
        if let ledger {
            try validate(ledger)
            try YAMLArtifactStore(dataRoot: dataRoot).save(ledger, to: PipelineLayout.ledgerFile)
            guard try YAMLArtifactStore(dataRoot: dataRoot).load(Ledger.self, at: PipelineLayout.ledgerFile) == ledger else { throw changed() }
        } else {
            let file = dataRoot.appendingPathComponent(PipelineLayout.ledgerFile)
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try ProjectLocalFile.resolve(PipelineLayout.ledgerFile, dataRoot: dataRoot)
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    nonisolated private static func validate(_ ledger: Ledger) throws {
        guard ledger.schema_ == ledgerSchemaVersion, ledger.objects.values.allSatisfy({ attributes in
            attributes.allSatisfy { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.value.tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }) else { throw GateBlocked("The Intent Ledger is unreadable or invalid. Restore its current file before revising it.") }
    }
    nonisolated private static func record(phase: String, dataRoot: URL, declaration: ProjectPackGate.MutationDeclaration) throws {
        try PipelinePhaseMutationRecorder.record(phase: phase, dataRoot: dataRoot, captureLineage: false,
            declaredPack: declaration.packName, declaredBinding: declaration.binding, declaredProductionContract: declaration.productionContract)
    }
    nonisolated private static func changed() -> GateBlocked { GateBlocked("The Intent Ledger, project or production phase changed. Reload the selected object before revising or restoring its attributes.") }
}
