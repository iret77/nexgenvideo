import Foundation
import NexGenEngine

@MainActor
enum PipelineScriptEditor {
    static func replaceScene(_ scene: ScriptV1.Scene, in expected: ScriptV1, editor: EditorViewModel) throws {
        guard expected.scenes.contains(where: { $0.id == scene.id }) else { throw GateBlocked("This Script scene changed. Reload it before editing.") }
        let scenes = expected.scenes.map { $0.id == scene.id ? scene : $0 }
        try apply(summary: expected.summary, scenes: scenes, expected: expected, undo: false, editor: editor)
    }

    private static func apply(summary: String, scenes: [ScriptV1.Scene], expected: ScriptV1,
                              undo: Bool, editor: EditorViewModel) throws {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let key = editor.openWorkingCopyKey else { throw GateBlocked("Open the project before editing Script.") }
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Script") else {
            throw GateBlocked("Wait for the current production job before editing Script.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "script")
        let current = try PlanningWriterIO.script(dataRoot: root)
        let matching = undo
            ? current.header.projectID == expected.header.projectID && current.header.inputs == expected.header.inputs
                && current.summary == expected.summary && current.scenes == expected.scenes
            : current == expected
        guard matching else { throw GateBlocked("The Script changed since this edit. Reload it before making further changes.") }
        guard summary != current.summary || scenes != current.scenes else { return }
        try ProjectWorkingCopy.markDirty(key: key)
        let written = try PipelineScriptWriter.write(summary: summary, scenes: scenes, origin: .userRevision, access: access)
        editor.undoManager?.registerUndo(withTarget: editor) { target in
            guard target.workingRoot == home, target.openWorkingCopyKey == key else { return }
            do { try apply(summary: current.summary, scenes: current.scenes, expected: written, undo: true, editor: target) }
            catch { target.mediaPanelToast = MediaPanelToast(message: error.localizedDescription) }
        }
        editor.undoManager?.setActionName("Edit Script")
        editor.onPipelineChanged?()
        Task { await editor.refreshEngineState() }
    }
}
