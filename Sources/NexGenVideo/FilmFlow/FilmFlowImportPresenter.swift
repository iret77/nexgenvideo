import AppKit
import SwiftUI

@MainActor
struct FilmFlowImportConfiguration {
    let isolated: Bool
    let connect: (@MainActor () async throws -> FilmFlowOAuth.Connection)?
    let makeReader: @Sendable (FilmFlowOAuth.Connection) -> FilmFlowReader
    static let live = Self(isolated: false, connect: nil, makeReader: { FilmFlowReader(connection: $0) })
}

@MainActor
enum FilmFlowImportPresenter {
    private static var windows: [ObjectIdentifier: WindowController] = [:]
    private static var acceptanceConfigurations: [ObjectIdentifier: FilmFlowImportConfiguration] = [:]

    static func setAcceptanceConfiguration(_ configuration: FilmFlowImportConfiguration?, editor: EditorViewModel) throws {
        guard ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_ACCEPTANCE"] == "1" else {
            throw FilmFlowFailure.message("The isolated FilmFlow service is available only in native acceptance.")
        }
        acceptanceConfigurations[ObjectIdentifier(editor)] = configuration
    }

    static func unavailableReason(editor: EditorViewModel) -> String? {
        guard editor.workingRoot != nil, editor.openWorkingCopyKey != nil else { return "Open a project before importing FilmFlow material." }
        let core = editor.declaredProductionContract == .current
        let musicvideo = editor.declaredPluginBinding.map {
            $0.id == "musicvideo" && $0.version == HostWorkflowKey.musicvideoV2Version && $0.projectSchema == HostWorkflowKey.musicvideoV2Schema
        } ?? false
        guard core || musicvideo else { return "FilmFlow import requires the current Core or Music Video production workflow." }
        guard let state = editor.projectState else { return "Wait for the project workflow to load." }
        guard !musicvideo || (!(["project_init", "analysis"].contains(state.nextPhaseName ?? "")) && (state.nextPhaseName != nil || state.isComplete)) else {
            return "Approve Audio Analysis before importing story material."
        }
        if editor.agentService.reviewParentIdleReason != nil || editor.agentService.isComposerBlocked {
            return "Finish the current agent action before importing FilmFlow material."
        }
        if editor.pipelinePhaseRunCoordinator.hasRunningJobs { return "Wait for the current production job to finish." }
        return nil
    }

    static func canPresent(editor: EditorViewModel) -> Bool { unavailableReason(editor: editor) == nil }

    static func present(editor: EditorViewModel, in window: NSWindow) {
        guard window.attachedSheet == nil, canPresent(editor: editor) else {
            editor.mediaPanelToast = .init(message: unavailableReason(editor: editor) ?? "Close the current sheet before importing FilmFlow material.")
            return
        }
        let id = ObjectIdentifier(editor)
        guard windows[id] == nil else { return }
        let controller = WindowController(editor: editor, parent: window, configuration: acceptanceConfigurations[id] ?? .live)
        windows[id] = controller
        controller.onClose = { windows.removeValue(forKey: id) }
        controller.open()
    }

    private final class WindowController: NSObject, NSWindowDelegate {
        weak var editor: EditorViewModel?
        weak var parent: NSWindow?
        let panel: NSPanel
        var onClose: (() -> Void)?
        private var isBusy = false
        init(editor: EditorViewModel, parent: NSWindow, configuration: FilmFlowImportConfiguration) {
            self.editor = editor; self.parent = parent
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: AppTheme.Layout.productionDecisionReviewWidth,
                                               height: AppTheme.Layout.productionDecisionReviewHeight),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            super.init()
            panel.title = "Import from FilmFlow"
            panel.delegate = self
            panel.contentViewController = NSHostingController(rootView: FilmFlowImportView(editor: editor, close: { [weak self] in self?.close() }, configuration: configuration,
                onBusyChanged: { [weak self] in self?.isBusy = $0 }))
        }
        func open() { parent?.beginSheet(panel) { [weak self] _ in self?.onClose?() } }
        func close() { guard !isBusy else { return }; parent?.endSheet(panel); panel.orderOut(nil) }
        func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
            guard let editor else { return nil }
            if editor.projectState?.nextPhaseName == "storyboard" { return PipelineStoryboardEditor.undoManager(editor: editor) }
            return editor.undoManager
        }
    }
}
