import AppKit

/// Window controller that handles keyboard shortcuts via the responder chain.
/// Forwards actions to the EditorViewModel owned by VideoProject.
final class EditorWindowController: NSWindowController {
    let editorViewModel: EditorViewModel
    private nonisolated(unsafe) var keyMonitor: Any?
    private nonisolated(unsafe) var mouseMonitor: Any?

    init(editorViewModel: EditorViewModel, window: NSWindow) {
        self.editorViewModel = editorViewModel
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The visible titlebar is hidden (custom chrome), but the OS window title still feeds the window
    /// switcher, Mission Control, and screenshots — brand it. AppKit refreshes this whenever the
    /// document name changes. The em dash is fine in the OS title string (not visible-row copy).
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        "NexGenVideo — \(displayName)"
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleKeyDown(event) ? nil : event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let hitView = self.window?.contentView?.hitTest(event.locationInWindow)
            self.resignStaleFocus(hitView: hitView)
            self.handlePanelClick(hitView: hitView)
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Don't intercept keys when a text field has focus
        if isTextInputFocused || hasModalPresentation {
            return false
        }

        let mods = event.modifierFlags
        let shift = mods.contains(.shift)
        let rangeMarkShortcut = mods.intersection([.command, .option, .control, .shift]).isEmpty

        let mediaDirection = mediaArrowDirection(for: event.keyCode)
        if canHandleMediaShortcut(), editorViewModel.mediaCommandFocus == .folderTree,
           mediaDirection != nil {
            return false
        }
        if canHandleMediaBrowserShortcut(), !shift, let direction = mediaDirection {
            editorViewModel.moveMediaSelection(direction: direction)
            return true
        }

        switch event.keyCode {
        case 49 where mods.intersection([.command, .option, .control, .shift]).isEmpty: // Space
            editorViewModel.togglePlayback()
            return true

        case 123 where mods.intersection([.command, .option, .control]).isEmpty: // Left arrow
            if shift { editorViewModel.skipBackward() } else { editorViewModel.stepBackward() }
            return true

        case 124 where mods.intersection([.command, .option, .control]).isEmpty: // Right arrow
            if shift { editorViewModel.skipForward() } else { editorViewModel.stepForward() }
            return true

        case 51 where mods.intersection([.command, .option, .control]).isEmpty: // Delete/Backspace
            return performContextualDelete(ripple: shift)

        case 8: // C key
            if mods.intersection([.command, .option, .control, .shift]).isEmpty,
               canHandleTimelineEditShortcut() {
                editorViewModel.toolMode = .razor
                return true
            }
            return false

        case 9: // V key
            if mods.intersection([.command, .option, .control, .shift]).isEmpty,
               canHandleTimelineEditShortcut() {
                editorViewModel.toolMode = .pointer
                return true
            }
            return false

        case 34: // I key
            if rangeMarkShortcut, canHandleTimelineEditShortcut() {
                editorViewModel.markTimelineRangeStart()
                return true
            }
            return false

        case 31: // O key
            if rangeMarkShortcut, canHandleTimelineEditShortcut() {
                editorViewModel.markTimelineRangeEnd()
                return true
            }
            return false

        case 33 where mods.intersection([.command, .option, .control, .shift]).isEmpty: // [ key
            return canHandleTimelineEditShortcut()
                && editorViewModel.performTimelineCommand(.trimStart)

        case 30 where mods.intersection([.command, .option, .control, .shift]).isEmpty: // ] key
            return canHandleTimelineEditShortcut()
                && editorViewModel.performTimelineCommand(.trimEnd)

        case 50: // ` backtick — maximize focused panel; ⇧` — toggle theater (full-window player)
            if mods.intersection([.command, .option, .control, .shift]).isEmpty {
                toggleMaximizePanelAction()
                return true
            }
            if shift, mods.intersection([.command, .option, .control]).isEmpty {
                editorViewModel.toggleTheater()
                return true
            }
            return false

        case 36 where mods.intersection([.command, .option, .control, .shift]).isEmpty: // Return / Enter
            if canHandleMediaShortcut(),
               editorViewModel.selectedVisibleMediaFolderIDs.count == 1,
               let folderId = editorViewModel.selectedVisibleMediaFolderIDs.first {
                editorViewModel.mediaPanelOpenFolderId = folderId
                return true
            }
            if editorViewModel.cropEditingActive {
                editorViewModel.cropEditingActive = false
                return true
            }
            return false

        case 53: // Escape
            if editorViewModel.theaterActive {
                editorViewModel.theaterActive = false
                return true
            }
            if editorViewModel.pendingSwapClipId != nil {
                editorViewModel.cancelMediaSwap()
                return true
            }
            if editorViewModel.cropEditingActive {
                editorViewModel.cropEditingActive = false
                return true
            }
            if editorViewModel.maximizedPanel != nil {
                editorViewModel.maximizedPanel = nil
                return true
            }
            if canHandleTimelineEditShortcut() {
                editorViewModel.selectedClipIds.removeAll()
                editorViewModel.clearTimelineRange()
                editorViewModel.toolMode = .pointer
                return true
            }
            return false

        default:
            return false
        }
    }

    private func mediaArrowDirection(for keyCode: UInt16) -> EditorViewModel.MediaSelectionDirection? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }

    private var isTextInputFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        if let textField = responder as? NSTextField { return textField.isEditable }
        return false
    }

    private var hasModalPresentation: Bool {
        window?.attachedSheet != nil
            || NSApp.modalWindow != nil
            || editorViewModel.showExportDialog
            || editorViewModel.pendingSettingsMismatch != nil
            || editorViewModel.recoveredUnsavedWork
    }

    private func handlePanelClick(hitView: NSView?) {
        var view = hitView
        while let v = view {
            if let panel = EditorViewModel.FocusedPanel(accessibilityID: v.accessibilityIdentifier()) {
                editorViewModel.focusedPanel = panel
                return
            }
            view = v.superview
        }
    }

    /// Clear stale first-responder focus before the click is dispatched.
    private func resignStaleFocus(hitView: NSView?) {
        // Don't disturb a deliberate click into a text input.
        if hitView is NSTextView || hitView is NSTextField { return }
        guard let responder = window?.firstResponder,
              let view = responder as? NSView, view !== window?.contentView else { return }
        window?.makeFirstResponder(nil)
    }
}

// MARK: - EditorActions (responder chain)

extension EditorWindowController: EditorActions {
    @objc func duplicateSelectedClips(_ sender: Any?) {
        guard canHandleTimelineEditShortcut() else { return }
        editorViewModel.performTimelineCommand(.duplicate)
    }
    @objc func splitAtPlayhead(_ sender: Any?) {
        guard canHandleTimelineEditShortcut() else { return }
        editorViewModel.performTimelineCommand(.split)
    }
    @objc func trimStartToPlayhead(_ sender: Any?) {
        guard canHandleTimelineEditShortcut() else { return }
        editorViewModel.performTimelineCommand(.trimStart)
    }
    @objc func trimEndToPlayhead(_ sender: Any?) {
        guard canHandleTimelineEditShortcut() else { return }
        editorViewModel.performTimelineCommand(.trimEnd)
    }
    @objc func markSourceIn(_ sender: Any?) { if canHandleSourceShortcut() { editorViewModel.performSourceCommand(.markIn) } }
    @objc func markSourceOut(_ sender: Any?) { if canHandleSourceShortcut() { editorViewModel.performSourceCommand(.markOut) } }
    @objc func clearSourceRange(_ sender: Any?) { if canHandleSourceShortcut() { editorViewModel.performSourceCommand(.clearRange) } }
    @objc func insertSourceAtPlayhead(_ sender: Any?) { if canHandleSourceShortcut() { editorViewModel.performSourceCommand(.insert) } }
    @objc func overwriteSourceAtPlayhead(_ sender: Any?) { if canHandleSourceShortcut() { editorViewModel.performSourceCommand(.overwrite) } }
    @objc func deleteSelectedClips(_ sender: Any?) {
        _ = performContextualDelete(ripple: false)
    }
    @objc func playPause(_ sender: Any?) { editorViewModel.togglePlayback() }
    @objc func stepFrameForward(_ sender: Any?) { editorViewModel.stepForward() }
    @objc func stepFrameBackward(_ sender: Any?) { editorViewModel.stepBackward() }
    @objc func skipFramesForward(_ sender: Any?) { editorViewModel.skipForward() }
    @objc func skipFramesBackward(_ sender: Any?) { editorViewModel.skipBackward() }

    @objc func importMedia(_ sender: Any?) {
        MediaImportFlow.present(
            editor: editorViewModel,
            destinationFolderId: editorViewModel.mediaPanelCurrentFolderId
        )
    }

    @objc func showExport(_ sender: Any?) {
        editorViewModel.showExportDialog = true
    }

    @objc func copy(_ sender: Any?) {
        if canHandleMediaBrowserShortcut() {
            editorViewModel.copyVisibleMediaPaths(editorViewModel.selectedVisibleMediaAssetIDs)
            return
        }
        guard canHandleClipboardShortcut() else { return }
        editorViewModel.performTimelineCommand(.copy)
    }

    @objc func cut(_ sender: Any?) {
        guard canHandleClipboardShortcut() else { return }
        editorViewModel.performTimelineCommand(.cut)
    }

    @objc func paste(_ sender: Any?) {
        if canHandleMediaShortcut() {
            editorViewModel.mediaPanelPasteRequestTick &+= 1
            return
        }
        guard canHandleClipboardShortcut() else { return }
        editorViewModel.performTimelineCommand(.paste)
    }

    private func canHandleClipboardShortcut() -> Bool {
        canHandleTimelineEditShortcut()
    }

    private func canHandleTimelineEditShortcut() -> Bool {
        !isTextInputFocused
            && !hasModalPresentation
            && editorViewModel.workspaceFocus == .edit
            && editorViewModel.focusedPanel == .timeline
            && !editorViewModel.theaterActive
            && (editorViewModel.maximizedPanel == nil || editorViewModel.maximizedPanel == .timeline)
    }

    private func canHandleMediaShortcut() -> Bool {
        guard !isTextInputFocused, !hasModalPresentation,
              !editorViewModel.theaterActive else { return false }
        switch (editorViewModel.workspaceFocus, editorViewModel.mediaCommandFocus) {
        case (.media, .some(.folderTree)):
            return editorViewModel.focusedPanel == .media
                && editorViewModel.isSidebarPresented
        case (.media, .some(.browser)):
            return editorViewModel.focusedPanel == .preview
                && (editorViewModel.maximizedPanel == nil
                    || editorViewModel.maximizedPanel == .preview)
        case (.edit, .some(.browser)):
            return editorViewModel.focusedPanel == .media
                && editorViewModel.isSidebarPresented
                && editorViewModel.mediaPanelTab == .assets
        default:
            return false
        }
    }

    private func canHandleMediaBrowserShortcut() -> Bool {
        canHandleMediaShortcut() && editorViewModel.mediaCommandFocus == .browser
    }

    private func canHandleSourceShortcut() -> Bool {
        guard !isTextInputFocused, !hasModalPresentation,
              !editorViewModel.theaterActive,
              editorViewModel.activeSourceAsset != nil else { return false }
        switch editorViewModel.workspaceFocus {
        case .media:
            return editorViewModel.focusedPanel == .preview
                && editorViewModel.mediaCommandFocus != .folderTree
        case .edit:
            return editorViewModel.focusedPanel == .preview
                || (editorViewModel.focusedPanel == .media
                    && editorViewModel.mediaPanelTab == .assets)
        case .production, .postproduction:
            return editorViewModel.focusedPanel == .preview
        case .export:
            return false
        }
    }

    @discardableResult
    private func performContextualDelete(ripple: Bool) -> Bool {
        if canHandleMediaShortcut() {
            if editorViewModel.mediaCommandFocus == .folderTree {
                let folderIDs = editorViewModel.selectedFolderIds
                guard !folderIDs.isEmpty,
                      editorViewModel.canDeleteFolders(ids: folderIDs) else { return false }
                editorViewModel.mediaPanelDeleteFolderRequest = folderIDs
                return true
            }
            let folderIDs = editorViewModel.selectedVisibleMediaFolderIDs
            let assetIDs = editorViewModel.selectedVisibleMediaAssetIDs
            let hasFolders = !folderIDs.isEmpty
            let hasAssets = !assetIDs.isEmpty
            guard hasFolders || hasAssets else { return false }
            return editorViewModel.deleteVisibleMedia(folders: folderIDs, assets: assetIDs)
        }
        guard canHandleTimelineEditShortcut() else { return false }
        return editorViewModel.performTimelineCommand(ripple ? .rippleDelete : .delete)
    }

    @objc func toggleMediaPanel(_ sender: Any?) { editorViewModel.toggleSidebarPresentation() }
    @objc func toggleInspectorPanel(_ sender: Any?) { editorViewModel.toggleInspectorPresentation() }
    @objc func toggleAgentPanel(_ sender: Any?) { editorViewModel.agentPanelVisible.toggle() }
    @objc func newAgentConversation(_ sender: Any?) {
        guard !editorViewModel.agentService.isComposerBlocked,
              !editorViewModel.agentService.isStreaming else { return }
        editorViewModel.agentPanelVisible = true
        editorViewModel.agentService.startNewConversation()
    }
    @objc func showAgentConversationHistory(_ sender: Any?) {
        editorViewModel.agentPanelVisible = true
        editorViewModel.agentConversationHistoryPresented = true
    }
    @objc func selectPreviousAgentConversation(_ sender: Any?) {
        editorViewModel.agentPanelVisible = true
        editorViewModel.agentService.selectAdjacentOpenSession(offset: -1)
    }
    @objc func selectNextAgentConversation(_ sender: Any?) {
        editorViewModel.agentPanelVisible = true
        editorViewModel.agentService.selectAdjacentOpenSession(offset: 1)
    }
    @objc func closeAgentConversation(_ sender: Any?) {
        guard !editorViewModel.agentService.isComposerBlocked,
              !editorViewModel.agentService.isStreaming,
              let id = editorViewModel.agentService.currentSessionId else { return }
        editorViewModel.agentService.closeTab(id)
    }
    @objc func toggleMaximizePanel(_ sender: Any?) { toggleMaximizePanelAction() }
    @objc func setLayoutDefault(_ sender: Any?) { editorViewModel.layoutPreset = .default }
    @objc func setLayoutMedia(_ sender: Any?) { editorViewModel.layoutPreset = .media }
    @objc func setLayoutVertical(_ sender: Any?) { editorViewModel.layoutPreset = .vertical }
    @objc func setWorkspaceMedia(_ sender: Any?) { editorViewModel.setWorkspaceFocus(.media) }
    @objc func setWorkspaceProduction(_ sender: Any?) { editorViewModel.setWorkspaceFocus(.production) }
    @objc func setWorkspaceEdit(_ sender: Any?) { editorViewModel.setWorkspaceFocus(.edit) }
    @objc func setWorkspacePostproduction(_ sender: Any?) { editorViewModel.setWorkspaceFocus(.postproduction) }
    @objc func setWorkspaceExport(_ sender: Any?) { editorViewModel.setWorkspaceFocus(.export) }
    @objc func toggleTheater(_ sender: Any?) { editorViewModel.toggleTheater() }

    private func toggleMaximizePanelAction() {
        if editorViewModel.maximizedPanel != nil {
            editorViewModel.maximizedPanel = nil
        } else if let panel = editorViewModel.focusedPanel {
            editorViewModel.maximizedPanel = panel
        }
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleMediaPanel(_:)):
            menuItem.state = editorViewModel.isSidebarPresented ? .on : .off
            return true
        case #selector(toggleInspectorPanel(_:)):
            menuItem.state = editorViewModel.isInspectorPresented ? .on : .off
            return true
        case #selector(toggleAgentPanel(_:)):
            menuItem.state = editorViewModel.agentPanelVisible ? .on : .off
            return true
        case #selector(newAgentConversation(_:)):
            return editorViewModel.agentService.canStartNewConversation
        case #selector(closeAgentConversation(_:)):
            return !editorViewModel.agentService.isComposerBlocked
                && !editorViewModel.agentService.isStreaming
        case #selector(selectPreviousAgentConversation(_:)),
             #selector(selectNextAgentConversation(_:)):
            return !editorViewModel.agentService.isComposerBlocked
                && !editorViewModel.agentService.isStreaming
                && editorViewModel.agentService.openSessions.count > 1
        case #selector(toggleMaximizePanel(_:)):
            menuItem.state = editorViewModel.maximizedPanel != nil ? .on : .off
            return !isTextInputFocused
                && (editorViewModel.maximizedPanel != nil || editorViewModel.focusedPanel != nil)
        case #selector(setLayoutDefault(_:)):
            menuItem.state = editorViewModel.layoutPreset == .default ? .on : .off
            return editorViewModel.workspaceFocus == .edit
        case #selector(setLayoutMedia(_:)):
            menuItem.state = editorViewModel.layoutPreset == .media ? .on : .off
            return editorViewModel.workspaceFocus == .edit
        case #selector(setLayoutVertical(_:)):
            menuItem.state = editorViewModel.layoutPreset == .vertical ? .on : .off
            return editorViewModel.workspaceFocus == .edit
        case #selector(setWorkspaceMedia(_:)):
            menuItem.state = editorViewModel.workspaceFocus == .media ? .on : .off
            return true
        case #selector(setWorkspaceProduction(_:)):
            menuItem.state = editorViewModel.workspaceFocus == .production ? .on : .off
            return true
        case #selector(setWorkspaceEdit(_:)):
            menuItem.state = editorViewModel.workspaceFocus == .edit ? .on : .off
            return true
        case #selector(setWorkspacePostproduction(_:)):
            menuItem.state = editorViewModel.workspaceFocus == .postproduction ? .on : .off
            return true
        case #selector(setWorkspaceExport(_:)):
            menuItem.state = editorViewModel.workspaceFocus == .export ? .on : .off
            return true
        case #selector(toggleTheater(_:)):
            menuItem.state = editorViewModel.theaterActive ? .on : .off
            return !isTextInputFocused
        case #selector(duplicateSelectedClips(_:)):
            return canHandleTimelineEditShortcut() && editorViewModel.canPerformTimelineCommand(.duplicate)
        case #selector(splitAtPlayhead(_:)),
             #selector(trimStartToPlayhead(_:)),
             #selector(trimEndToPlayhead(_:)):
            guard canHandleTimelineEditShortcut() else { return false }
            switch menuItem.action {
            case #selector(splitAtPlayhead(_:)): return editorViewModel.canPerformTimelineCommand(.split)
            case #selector(trimStartToPlayhead(_:)): return editorViewModel.canPerformTimelineCommand(.trimStart)
            default: return editorViewModel.canPerformTimelineCommand(.trimEnd)
            }
        case #selector(markSourceIn(_:)), #selector(markSourceOut(_:)):
            return canHandleSourceShortcut() && editorViewModel.canPerformSourceCommand(.markIn)
        case #selector(clearSourceRange(_:)):
            return canHandleSourceShortcut() && editorViewModel.canPerformSourceCommand(.clearRange)
        case #selector(insertSourceAtPlayhead(_:)):
            return canHandleSourceShortcut() && editorViewModel.canPerformSourceCommand(.insert)
        case #selector(overwriteSourceAtPlayhead(_:)):
            return canHandleSourceShortcut() && editorViewModel.canPerformSourceCommand(.overwrite)
        case #selector(deleteSelectedClips(_:)):
            if canHandleMediaShortcut() {
                if editorViewModel.mediaCommandFocus == .folderTree {
                    let folderIds = editorViewModel.selectedFolderIds
                    return !folderIds.isEmpty
                        && editorViewModel.canDeleteFolders(ids: folderIds)
                }
                let folderIds = editorViewModel.selectedVisibleMediaFolderIDs
                let assetIds = editorViewModel.selectedVisibleMediaAssetIDs
                return editorViewModel.canDeleteVisibleMedia(folders: folderIds, assets: assetIds)
            }
            return canHandleTimelineEditShortcut() && editorViewModel.canPerformTimelineCommand(.delete)
        case #selector(copy(_:)):
            if canHandleMediaBrowserShortcut() {
                return editorViewModel.canCopyVisibleMediaPaths(editorViewModel.selectedVisibleMediaAssetIDs)
            }
            return canHandleClipboardShortcut() && editorViewModel.canPerformTimelineCommand(.copy)
        case #selector(cut(_:)):
            return canHandleClipboardShortcut() && editorViewModel.canPerformTimelineCommand(.cut)
        case #selector(paste(_:)):
            if canHandleMediaShortcut() {
                return MediaTab.clipboardHasImportableMedia()
            }
            return canHandleClipboardShortcut() && editorViewModel.canPerformTimelineCommand(.paste)
        default:
            return true
        }
    }
}
