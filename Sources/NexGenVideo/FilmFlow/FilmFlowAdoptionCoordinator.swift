import AppKit
import Foundation
import NexGenEngine

@MainActor
enum FilmFlowAdoptionCoordinator {
    struct Targets: Sendable {
        let phase: String
        let script: ScriptV1?
        let board: StoryboardBundleSnapshot?
        let planning: ShotPlanningDraftV1?
        let message: String?
    }

    @MainActor private final class NotesSession {
        weak var editor: EditorViewModel?
        let home: URL?
        let key: String?
        let generation: UUID?
        let manager: UndoManager
        lazy var history = PipelineNativeRevisionHistory<PipelineStorySourceWriter.SelectionState>(manager: manager,
            equivalent: { $0 == $1 }, restore: { [weak self] desired, expected in
                guard let self, let editor = self.editor, editor.workingRoot == self.home, editor.openWorkingCopyKey == self.key, editor.openWorkingCopyGeneration == self.generation else {
                    throw FilmFlowFailure.message("Open the original project before restoring FilmFlow planning notes.")
                }
                return try await notesTransaction(editor: editor) { access in
                    try PipelineStorySourceWriter.restoreSelection(desired, expected: expected, access: access)
                    return try PipelineStorySourceWriter.selectionState(dataRoot: access.dataRoot)
                }
            }, failure: { [weak self] error in self?.editor?.mediaPanelToast = .init(message: error.localizedDescription) })
        init(editor: EditorViewModel, manager: UndoManager) {
            self.editor = editor; self.home = editor.workingRoot; self.key = editor.openWorkingCopyKey; self.generation = editor.openWorkingCopyGeneration; self.manager = manager
        }
    }
    private static var notesSessions: [ObjectIdentifier: NotesSession] = [:]

    static func loadTargets(editor: EditorViewModel) async throws -> Targets {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home), let key = editor.openWorkingCopyKey else {
            throw FilmFlowFailure.message("Open the project before mapping FilmFlow material.")
        }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let value = try await Task.detached(priority: .userInitiated) {
            guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: declaration.binding,
                expectedProductionContract: declaration.productionContract), workflow.isProductionV2 else {
                throw FilmFlowFailure.message("FilmFlow adoption requires the current production workflow.")
            }
            let state = try ProjectStateBuilder.buildSnapshot(dataRoot: root, order: PhaseContractRuntime.order(workflow: workflow))
            let phase = state.nextPhase ?? "complete"
            do {
                switch phase {
                case "script": return Targets(phase: phase, script: try PlanningWriterIO.script(dataRoot: root), board: nil, planning: nil, message: nil)
                case "storyboard": return Targets(phase: phase, script: nil,
                    board: try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false), planning: nil, message: nil)
                case "shot_planning":
                    let board = try PlanningWriterIO.storyboard(dataRoot: root)
                    return Targets(phase: phase, script: nil, board: board,
                        planning: try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: board), message: nil)
                case "brief", "project_init": return Targets(phase: phase, script: nil, board: nil, planning: nil, message: nil)
                default: return Targets(phase: phase, script: nil, board: nil, planning: nil,
                    message: "Retained material is available offline. Continue to its matching phase or explicitly rewind before adopting it.")
                }
            } catch {
                return Targets(phase: phase, script: nil, board: nil, planning: nil,
                    message: "Create a valid draft in the current phase before mapping FilmFlow material. " + error.localizedDescription)
            }
        }.value
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
              editor.declaredPluginBinding == declaration.binding, editor.declaredProductionContract == declaration.productionContract else {
            throw FilmFlowFailure.message("The target project changed. Open the import again.")
        }
        return value
    }

    static func notes(_ retained: FilmFlowSnapshotStore.Retained, selected: Set<String>, editor: EditorViewModel) async throws {
        guard let manager = editor.undoManager else { throw FilmFlowFailure.message("Open the editor window before accepting planning notes.") }
        notesSessions = notesSessions.filter { $0.value.editor != nil }
        let id = ObjectIdentifier(editor)
        let session: NotesSession
        if let current = notesSessions[id], current.home == editor.workingRoot, current.key == editor.openWorkingCopyKey, current.generation == editor.openWorkingCopyGeneration { session = current }
        else { notesSessions[id]?.history.clear(); session = NotesSession(editor: editor, manager: manager); notesSessions[id] = session }
        try session.history.beginPublication()
        defer { session.history.endPublication() }
        _ = try await notesTransaction(editor: editor, validation: { guard session.home == editor.workingRoot, session.key == editor.openWorkingCopyKey,
                  session.generation == editor.openWorkingCopyGeneration else { throw FilmFlowFailure.message("The project changed during preparation.") }; try session.history.requireNoPendingRestore() },
            didCommit: { result in
                session.history.record(before: result.0, after: result.1, name: "Import FilmFlow Planning Notes")
            }) { access in
            let directory = access.dataRoot.appendingPathComponent(FilmFlowSnapshotStore.path(retained.id))
            let snapshot = try FilmFlowSnapshot.verify(directory: directory, expectedSHA256: retained.sha256)
            let material = try FilmFlowMaterial.load(directory: directory, snapshot: snapshot)
            let text = try material.planningNotes(selected: selected)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-filmflow-notes-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let url = temporary.appendingPathComponent("FilmFlow planning notes.md")
            try Data(text.utf8).write(to: url, options: .atomic)
            let before = try PipelineStorySourceWriter.selectionState(dataRoot: access.dataRoot)
            let mapping = FilmFlowAdoption(snapshotID: retained.id, snapshotSHA256: retained.sha256,
                sourceObjectID: "planning-notes", targetID: "brief.story-source", fields: selected.sorted())
            try PipelineStorySourceWriter.writeSelection(from: url, access: access, filmFlow: mapping)
            return (before, try PipelineStorySourceWriter.selectionState(dataRoot: access.dataRoot))
        }
    }

    static func sketch(_ retained: FilmFlowSnapshotStore.Retained, item: FilmFlowMaterial.Item,
                       shotID: String, momentID: String, expected: StoryboardBundleSnapshot, editor: EditorViewModel) async throws {
        let (source, directory) = try await sourceItem(retained, id: item.id, editor: editor)
        guard let image = source.image else { throw FilmFlowFailure.message("Select a downloaded image.") }
        let url = directory.appendingPathComponent(image.path)
        let mapping = FilmFlowAdoption(snapshotID: retained.id, snapshotSHA256: retained.sha256,
            sourceObjectID: item.id, targetID: momentID, fields: ["image"])
        _ = try await PipelineStoryboardEditor.attachImage(from: url, shotID: shotID, momentID: momentID,
            expectedFingerprint: expected.fingerprint, editor: editor, filmFlow: mapping)
        editor.setWorkspaceFocus(.production); editor.productionSelectedPhase = "storyboard"; editor.focusedPanel = .project
    }

    static func script(_ retained: FilmFlowSnapshotStore.Retained, item: FilmFlowMaterial.Item,
                       sceneID: String, eventID: String, expected: ScriptV1, editor: EditorViewModel) async throws {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else { throw changed() }
        let key = editor.openWorkingCopyKey, generation = editor.openWorkingCopyGeneration
        let mapping = FilmFlowAdoption(snapshotID: retained.id, snapshotSHA256: retained.sha256,
            sourceObjectID: item.id, targetID: eventID, fields: ["action"])
        let task = Task.detached(priority: .userInitiated) { try mapping.prepareScript(dataRoot: root) }
        let (prepared, source) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
              editor.openWorkingCopyGeneration == generation else { throw changed() }
        guard let scene = expected.scenes.first(where: { $0.id == sceneID }),
              scene.events.contains(where: { $0.id == eventID }), !source.notes.isEmpty else { throw changed() }
        let events = scene.events.map { event in
            event.id == eventID ? ScriptV1.Event(id: event.id, action: source.notes, dialogue: event.dialogue,
                treatmentBeatIDs: event.treatmentBeatIDs, sourceAnchors: []) : event
        }
        let replacement = ScriptV1.Scene(id: scene.id, title: scene.title, adaptation: scene.adaptation, events: events)
        try PipelineScriptEditor.replaceScene(replacement, in: expected, editor: editor, filmFlow: prepared)
    }

    static func duration(_ retained: FilmFlowSnapshotStore.Retained, item: FilmFlowMaterial.Item,
                         shotID: String, expected: StoryboardBundleSnapshot, editor: EditorViewModel) async throws {
        let (source, _) = try await sourceItem(retained, id: item.id, editor: editor)
        guard let seconds = source.shot?.durationSeconds, seconds.isFinite, seconds > 0 else {
            throw FilmFlowFailure.message("The source shot has no positive duration to adopt.")
        }
        let scaled = seconds * Double(expected.timing.timebase.ticksPerSecond)
        guard scaled.isFinite, scaled > 0, scaled < Double(Int64.max), abs(scaled - scaled.rounded()) < 0.000001 else {
            throw FilmFlowFailure.message("The FilmFlow duration cannot be represented exactly in this project's timebase.")
        }
        let mapping = FilmFlowAdoption(snapshotID: retained.id, snapshotSHA256: retained.sha256,
            sourceObjectID: item.id, targetID: shotID, fields: ["durationSeconds"])
        _ = try await PipelineStoryboardEditor.apply(.setDuration(shotID: shotID, durationTicks: Int64(scaled.rounded())),
            expectedFingerprint: expected.fingerprint, editor: editor, filmFlow: mapping)
        editor.setWorkspaceFocus(.production); editor.productionSelectedPhase = "storyboard"; editor.focusedPanel = .project
    }

    static func camera(_ retained: FilmFlowSnapshotStore.Retained, item: FilmFlowMaterial.Item,
                       shotID: String, movement: CameraMovement, expected: ShotPlanningDraftV1,
                       editor: EditorViewModel) async throws {
        let (source, _) = try await sourceItem(retained, id: item.id, editor: editor)
        guard source.shot != nil, let shot = expected.shots.first(where: { $0.shotID == shotID }) else { throw changed() }
        let original = shot.camera
        let camera = ShotPlanningDraftV1.CameraIntent(framing: original.framing, movement: movement,
            movementDetail: source.notes, blocking: original.blocking, sceneReference: original.sceneReference,
            spatialState: original.spatialState, spatialCameraID: original.spatialCameraID,
            spatialDerivation: original.spatialDerivation, blockingReference: original.blockingReference)
        let replacement = PipelineNativeBlockoutStore.replacing(shot, camera: camera)
        let mapping = FilmFlowAdoption(snapshotID: retained.id, snapshotSHA256: retained.sha256,
            sourceObjectID: item.id, targetID: shotID, fields: ["camera.movementDetail"])
        _ = try await PipelineShotPlanningEditor.replace(replacement, in: expected, editor: editor, filmFlow: mapping)
    }

    private static func sourceItem(_ retained: FilmFlowSnapshotStore.Retained, id: String,
                                   editor: EditorViewModel) async throws -> (FilmFlowMaterial.Item, URL) {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else { throw changed() }
        let key = editor.openWorkingCopyKey, generation = editor.openWorkingCopyGeneration
        let task = Task.detached(priority: .userInitiated) {
            let directory = root.appendingPathComponent(FilmFlowSnapshotStore.path(retained.id))
            let snapshot = try FilmFlowSnapshot.verify(directory: directory, expectedSHA256: retained.sha256)
            let material = try FilmFlowMaterial.load(directory: directory, snapshot: snapshot)
            guard let source = material.items.first(where: { $0.id == id }) else { throw changed() }
            return (source, directory)
        }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
              editor.openWorkingCopyGeneration == generation else { throw changed() }
        return value
    }

    private static func notesTransaction<T: Sendable>(editor: EditorViewModel,
        validation: @escaping @MainActor () throws -> Void = {},
        didCommit: @escaping @MainActor (T) -> Void = { _ in },
        operation: @escaping @Sendable (PipelinePlanningWriteAccess) throws -> T) async throws -> T {
        let access = try PipelineNativeEditAccess(editor: editor, label: "FilmFlow planning notes")
        defer { access.end(editor: editor) }
        let task = Task.detached(priority: .userInitiated) {
            let phase = try PhaseContractRuntime.resolveWorkflow(dataRoot: access.root,
                expectedPack: access.declaration.binding, expectedProductionContract: access.declaration.productionContract)
                .flatMap { workflow in try ProjectStateBuilder.buildSnapshot(dataRoot: access.root,
                    order: PhaseContractRuntime.order(workflow: workflow)).nextPhase }
            guard let phase, ["brief", "project_init"].contains(phase) else { throw changed() }
            _ = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: phase)
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                try operation(PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: phase))
            }
            do { try fence.requireUnchanged(); return (transaction, fence) }
            catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        let output = try result.0.commit { _ in
            try validation()
            try access.requireCurrent(editor: editor)
            try result.1.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        didCommit(output)
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return output
    }

    nonisolated private static func changed() -> FilmFlowFailure {
        .message("The selected target changed. Reload the current phase before adopting FilmFlow material.")
    }
}
