import AppKit
import Foundation
import NexGenEngine

@MainActor
final class PipelineNativeRevisionHistory<Value: Sendable> {
    @MainActor private final class Ticket {
        let task: Task<Value, Error>
        init(value: Value) { task = Task { value } }
        init(task: Task<Value, Error>) { self.task = task }
    }

    let manager: UndoManager
    private let restore: @MainActor (Value, Value) async throws -> Value
    private let failure: @MainActor (Error) -> Void
    private let equivalent: @MainActor (Value, Value) -> Bool
    private var head: Ticket?
    private var pending = 0
    private var latest: Task<Value, Error>?
    private var publishing = false
    private var publicationWaiters: [CheckedContinuation<Void, Never>] = []
    private let restoreStateChanged: @MainActor (Bool) -> Void
    var isBusy: Bool { pending > 0 || publishing }

    func beginPublication() throws {
        guard !isBusy else { throw GateBlocked("Wait for the current native revision to finish.") }
        publishing = true
    }

    func requireNoPendingRestore() throws {
        guard pending == 0 else { throw GateBlocked("Undo was requested while this edit was being prepared. The edit was not applied.") }
    }

    func endPublication() {
        publishing = false
        let waiters = publicationWaiters
        publicationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    init(manager: UndoManager, equivalent: @escaping @MainActor (Value, Value) -> Bool, restore: @escaping @MainActor (Value, Value) async throws -> Value,
         failure: @escaping @MainActor (Error) -> Void,
         restoreStateChanged: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.manager = manager; self.equivalent = equivalent; self.restore = restore; self.failure = failure
        self.restoreStateChanged = restoreStateChanged
    }

    func record(before: Value, after: Value, name: String) {
        head = Ticket(value: after)
        register(desired: Ticket(value: before), expected: Ticket(value: after), name: name)
    }

    func clear() { manager.removeAllActions(withTarget: self); head = nil }

    func waitForRestore() async throws -> Value {
        guard let latest else { throw GateBlocked("No native restore was started.") }
        return try await latest.value
    }

    func replay(redo: Bool) async throws -> Value {
        guard !isBusy, redo ? manager.canRedo : manager.canUndo else {
            throw GateBlocked("No native revision is available to restore.")
        }
        latest = nil
        if redo { manager.redo() } else { manager.undo() }
        guard let task = latest else { throw GateBlocked("The native revision could not be restored.") }
        return try await task.value
    }

    private func register(desired: Ticket, expected: Ticket, name: String) {
        let grouped = !manager.isUndoing && !manager.isRedoing && manager.groupingLevel == 0
        if grouped { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.activate(desired: desired, expected: expected, name: name) }
        }
        manager.setActionName(name)
        if grouped { manager.endUndoGrouping() }
    }

    private func activate(desired: Ticket, expected: Ticket, name: String) {
        let previous = head ?? expected
        pending += 1
        restoreStateChanged(true)
        let task = Task { @MainActor in
            defer { pending -= 1; restoreStateChanged(pending > 0) }
            do {
                if publishing {
                    await withCheckedContinuation { publicationWaiters.append($0) }
                }
                let original = try await desired.task.value
                let current = try await previous.task.value
                let logical = try await expected.task.value
                guard equivalent(logical, current) else { throw GateBlocked("The native revision history no longer matches the current plan.") }
                return try await restore(original, current)
            } catch {
                clear()
                failure(error)
                throw error
            }
        }
        latest = task
        head = Ticket(task: task)
        // NSUndoManager only accepts the inverse during this synchronous callback.
        register(desired: previous, expected: Ticket(task: task), name: name)
    }
}

struct PipelineNativeEditAccess: Sendable {
    let home: URL
    let root: URL
    let key: String
    let declaration: ProjectPackGate.MutationDeclaration
    let lease: UUID

    @MainActor
    init(editor: EditorViewModel, label: String) throws {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let key = editor.openWorkingCopyKey,
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: label) else {
            throw GateBlocked("Finish the current production action before changing this plan.")
        }
        self.home = home; self.root = root; self.key = key; self.lease = lease
        declaration = .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                            productionContract: editor.declaredProductionContract)
    }

    @MainActor
    func requireCurrent(editor: EditorViewModel) throws {
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease),
              editor.declaredPluginName == declaration.packName, editor.declaredPluginBinding == declaration.binding,
              editor.declaredProductionContract == declaration.productionContract else {
            throw GateBlocked("The project changed while this native edit was being prepared.")
        }
    }

    @MainActor
    func end(editor: EditorViewModel) { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
}
