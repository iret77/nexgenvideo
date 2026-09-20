import AppKit
import SwiftUI

struct EditorView: NSViewControllerRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSViewController(context: Context) -> EditorSplitViewController {
        EditorSplitViewController(editor: editor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: EditorSplitViewController,
                      context: Context) -> CGSize? {
        let result = Self.containerSize(for: proposal)
        WorkspaceUIAcceptance.recordEditorSizeProbe(proposal: proposal, result: result)
        return result
    }

    // The window allocates the editor; unbounded probes must not preserve a previous window size.
    static func containerSize(for proposal: ProposedViewSize) -> CGSize {
        func dimension(_ value: CGFloat?) -> CGFloat {
            guard let value, value.isFinite else { return AppTheme.Spacing.none }
            return max(0, value)
        }
        return CGSize(width: dimension(proposal.width), height: dimension(proposal.height))
    }

    func updateNSViewController(_ controller: EditorSplitViewController, context: Context) {
        let layoutIsCurrent = controller.applyLayoutIfNeeded(
            editor.layoutPreset,
            workspace: editor.workspaceFocus
        )
        controller.applyPanelFocus(editor.focusedPanel)
        guard layoutIsCurrent else { return }
        controller.applyMediaVisibility(editor.mediaPanelVisible)
        controller.applyInspectorVisibility(editor.inspectorPanelVisible)
        // Theater collapses everything to the single player, in any stage — reusing the maximize
        // path so the one video engine stays put. Exiting restores the user's real maximize state.
        controller.applyMaximize(editor.theaterActive ? .preview : editor.maximizedPanel)
        controller.updateTourFrame(stepIndex: editor.tour.stepIndex, anchorRevision: editor.tour.anchorRevision)
    }
}

// MARK: - Split view controller

private final class PanelDividerSplitView: NSSplitView {
    override var dividerThickness: CGFloat { AppTheme.BorderWidth.thin }

    override func drawDivider(in rect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            AppTheme.Border.primary.setFill()
            rect.fill()
        }
    }
}

/// Neutral divider with a larger hit area for panel resizing.
class PaddedDividerSplitViewController: NSSplitViewController {
    fileprivate var hadSavedFrames = false

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        splitView = PanelDividerSplitView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        splitView = PanelDividerSplitView()
    }

    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        let pad = AppTheme.Layout.panelGap / 2
        return splitView.isVertical
            ? drawnRect.insetBy(dx: -pad, dy: 0)
            : drawnRect.insetBy(dx: 0, dy: -pad)
    }
}

/// Autosave keys for the editor splits, defined once so call sites can't drift.
private enum SplitAutosave {
    static let defaultH      = "editor.default.h"
    static let mediaTop      = "editor.media.top"
    static let mediaRight    = "editor.media.right"
    static let verticalTop   = "editor.vertical.top"
    static let verticalLeft  = "editor.vertical.left"
    static let productionRoot   = "editor.produce.root"
    static let productionCenter = "editor.produce.center"
    static let productionRight  = "editor.produce.right"
    static let mediaRoot     = "editor.workspace.media.root.v1"
    static let postRoot      = "editor.workspace.postproduction.root.v1"
    static let postCenter    = "editor.workspace.postproduction.center.v1"
    static let exportRoot    = "editor.workspace.export.root.v1"
    static func preset(_ p: LayoutPreset) -> String { "editor.\(p.rawValue).preset" }

    /// AppKit persists divider frames under this key; no public API queries it.
    static func hasSavedFrames(_ name: String?) -> Bool {
        guard let name else { return false }
        return UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(name)") != nil
    }
}

final class EditorSplitViewController: PaddedDividerSplitViewController {
    let editor: EditorViewModel
    private var currentPreset: LayoutPreset?
    private var currentWorkspace: EditorViewModel.WorkspaceFocus?
    private var requestedPreset: LayoutPreset?
    private var requestedWorkspace: EditorViewModel.WorkspaceFocus?
    private var currentMaximized: EditorViewModel.FocusedPanel?
    private var layoutRevision: UInt = 0
    private var pendingPositioning: (() -> Void)?
    private var isPositioning = false
    private weak var mediaSplitItem: NSSplitViewItem?
    private weak var previewSplitItem: NSSplitViewItem?
    private weak var inspectorSplitItem: NSSplitViewItem?
    private weak var timelineSplitItem: NSSplitViewItem?
    private weak var cockpitSplitItem: NSSplitViewItem?
    private var panelHosts: [any PanelFocusUpdating] = []

    private lazy var mediaWorkspaceHC: NSViewController = makeHosting(
        MediaWorkspaceSidebar(workspace: .media),
        panel: .media
    )
    private lazy var editMediaHC: NSViewController = makeHosting(
        MediaWorkspaceSidebar(workspace: .edit),
        panel: .media
    )
    private lazy var agentHC: NSViewController     = makeHosting(AgentPanelView(), panel: .agent)
    private lazy var previewHC: NSViewController   = makeHosting(PreviewContainerView(), panel: .preview)
    private lazy var inspectorHC: NSViewController = makeHosting(InspectorView(), panel: .inspector)
    private lazy var cockpitHC: NSViewController   = makeHosting(ProjectCockpitView(), panel: .project)
    private lazy var timelineHC: NSViewController  = makeHosting(TimelinePanel(), panel: .timeline)
    private lazy var reviewHC: NSViewController     = makeHosting(FinishReviewPane(), panel: .project)
    private lazy var exportHC: NSViewController     = makeHosting(ExportWorkspaceSidebar(), panel: .project)

    init(editor: EditorViewModel) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        layoutRevision &+= 1
        buildLayout(editor.layoutPreset, workspace: editor.workspaceFocus)
    }

    // MARK: - Layout switching

    @discardableResult
    func applyLayoutIfNeeded(
        _ preset: LayoutPreset,
        workspace: EditorViewModel.WorkspaceFocus
    ) -> Bool {
        let effectivePreset = workspace == .edit ? preset : currentPreset ?? preset
        let currentMatches = workspace == currentWorkspace
            && (workspace != .edit || preset == currentPreset)
        if currentMatches {
            if workspace != requestedWorkspace || effectivePreset != requestedPreset {
                layoutRevision &+= 1
                requestedWorkspace = workspace
                requestedPreset = effectivePreset
            }
            return true
        }
        guard workspace != requestedWorkspace || effectivePreset != requestedPreset else { return false }
        requestedWorkspace = workspace
        requestedPreset = effectivePreset
        layoutRevision &+= 1
        let revision = layoutRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, revision == self.layoutRevision else { return }
            self.buildLayout(effectivePreset, workspace: workspace)
        }
        return false
    }

    func applyMaximize(_ panel: EditorViewModel.FocusedPanel?) {
        let mountedPanel = panel.flatMap { leafItem(for: $0) == nil ? nil : $0 }
        guard mountedPanel != currentMaximized else { return }
        currentMaximized = mountedPanel
        if let mountedPanel, let leaf = leafItem(for: mountedPanel) {
            // Assign final collapse state in one pass so panel-to-panel maximize never restores siblings.
            let toCollapse = Set(ancestorChainSiblings(of: leaf).map { ObjectIdentifier($0) })
            walkSplitItems(self) { item in
                applyCollapsed(item: item, collapsed: toCollapse.contains(ObjectIdentifier(item)))
            }
        } else {
            walkSplitItems(self) { item in
                applyCollapsed(item: item, collapsed: self.restoredCollapseState(for: item))
            }
        }
    }

    func leafItem(for panel: EditorViewModel.FocusedPanel) -> NSSplitViewItem? {
        switch panel {
        case .agent:     return mediaSplitItem   // Agent lives in the left sidebar now.
        case .media:     return mediaSplitItem
        case .preview:   return previewSplitItem
        case .inspector: return inspectorSplitItem
        case .timeline:  return timelineSplitItem
        case .project:   return cockpitSplitItem
        }
    }

    /// Walk up from a leaf split item, collecting siblings at every level up to the root.
    /// Those siblings are the items that must collapse for the leaf to fill the entire split.
    private func ancestorChainSiblings(of leaf: NSSplitViewItem) -> [NSSplitViewItem] {
        var result: [NSSplitViewItem] = []
        var current = leaf
        while let parent = current.viewController.parent as? NSSplitViewController {
            result.append(contentsOf: parent.splitViewItems.filter { $0 !== current })
            guard
                let grandparent = parent.parent as? NSSplitViewController,
                let wrapper = grandparent.splitViewItems.first(where: { $0.viewController === parent })
            else { break }
            current = wrapper
        }
        return result
    }

    private func walkSplitItems(_ controller: NSSplitViewController, _ visit: (NSSplitViewItem) -> Void) {
        for item in controller.splitViewItems {
            visit(item)
            if let child = item.viewController as? NSSplitViewController {
                walkSplitItems(child, visit)
            }
        }
    }

    /// On unmaximize, leaves restore their visibility-flag state
    private func restoredCollapseState(for item: NSSplitViewItem) -> Bool {
        if item === mediaSplitItem     { return !editor.mediaPanelVisible }
        if item === inspectorSplitItem { return !editor.inspectorPanelVisible }
        return false
    }

    func applyMediaVisibility(_ visible: Bool) {
        guard currentMaximized == nil else { return }
        applyCollapsed(item: mediaSplitItem, collapsed: !visible)
    }

    func applyInspectorVisibility(_ visible: Bool) {
        guard currentMaximized == nil else { return }
        applyCollapsed(item: inspectorSplitItem, collapsed: !visible)
    }

    private func applyCollapsed(item: NSSplitViewItem?, collapsed: Bool) {
        guard let item, item.isCollapsed != collapsed else { return }
        item.isCollapsed = collapsed
    }

    private func buildLayout(
        _ preset: LayoutPreset,
        workspace: EditorViewModel.WorkspaceFocus
    ) {
        pendingPositioning = nil
        disableAutosave(in: self)
        detachPanelHosts()

        while !splitViewItems.isEmpty {
            removeSplitViewItem(splitViewItems.last!)
        }
        mediaSplitItem = nil
        previewSplitItem = nil
        inspectorSplitItem = nil
        timelineSplitItem = nil
        cockpitSplitItem = nil

        currentPreset = preset
        currentWorkspace = workspace
        requestedPreset = preset
        requestedWorkspace = workspace
        currentMaximized = nil
        splitView.isVertical = true

        let autosave: String
        switch workspace {
        case .media:          autosave = SplitAutosave.mediaRoot
        case .production:     autosave = SplitAutosave.productionRoot
        case .edit:           autosave = SplitAutosave.preset(preset)
        case .postproduction: autosave = SplitAutosave.postRoot
        case .export:         autosave = SplitAutosave.exportRoot
        }
        let presetRoot = makeChildSplit(isVertical: false, autosave: autosave)
        switch workspace {
        case .media:
            buildMediaWorkspace(into: presetRoot)
        case .production:
            buildProductionLayout(into: presetRoot)
        case .edit:
            switch preset {
            case .default:  buildDefaultLayout(into: presetRoot)
            case .media:    buildMediaLayout(into: presetRoot)
            case .vertical: buildVerticalLayout(into: presetRoot)
            }
        case .postproduction:
            buildPostproductionLayout(into: presetRoot)
        case .export:
            buildExportLayout(into: presetRoot)
        }

        let presetItem = NSSplitViewItem(viewController: presetRoot)
        presetItem.minimumThickness = AppTheme.Layout.previewMinWidth
        addSplitViewItem(presetItem)
        applyCurrentPresentationState()
        view.needsLayout = true
        if view.bounds.width > 0 {
            view.layoutSubtreeIfNeeded()
            runPendingPositioning()
        }
    }

    private func disableAutosave(in controller: NSSplitViewController) {
        controller.splitView.autosaveName = nil
        for item in controller.splitViewItems {
            if let child = item.viewController as? NSSplitViewController {
                disableAutosave(in: child)
            }
        }
    }

    private func detachPanelHosts() {
        let hosts = panelHosts
        for panelHost in hosts {
            guard let controller = panelHost as? NSViewController,
                  let parent = controller.parent as? NSSplitViewController,
                  let item = parent.splitViewItems.first(where: {
                      $0.viewController === controller
                  }) else { continue }
            parent.removeSplitViewItem(item)
        }
    }

    // MARK: - Media workspace

    private func buildMediaWorkspace(into target: NSSplitViewController) {
        target.splitView.isVertical = true
        target.addSplitViewItem(makeSidebarItem(host: mediaWorkspaceHC, minimumThickness: AppTheme.Layout.mediaPanelMin))
        target.addSplitViewItem(makePreviewItem())
        target.addSplitViewItem(makeInspectorItem())

        applyAfterLayout { [weak self, weak target] in
            guard let self, let target else { return }
            let width = target.view.bounds.width
            self.positionIfUnsaved(target) {
                $0.setPosition(AppTheme.Layout.mediaPanelDefault, ofDividerAt: 0)
                $0.setPosition(width - AppTheme.Layout.inspectorDefault, ofDividerAt: 1)
            }
        }
    }

    // MARK: - Production layout
    // [Agent] | [Cockpit / Timeline strip] | [Preview / Inspector]
    // The cockpit is the center work surface; the timeline is a fixed display strip of accumulating
    // shot blocks; the preview stays reachable, docked above the Inspector. Same canonical components,
    // rearranged (docs/UI_UX_CONCEPT.md §3).

    private func buildProductionLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true

        let centerSplit = makeChildSplit(isVertical: false, autosave: SplitAutosave.productionCenter)
        let cockpitItem = NSSplitViewItem(viewController: cockpitHC)
        cockpitItem.minimumThickness = AppTheme.Layout.previewMinHeight
        centerSplit.addSplitViewItem(cockpitItem)
        cockpitSplitItem = cockpitItem
        let stripItem = makeTimelineItem()
        // Resizable: a usable min (toolbar + ruler + a track lane), no fixed max — drag it taller.
        stripItem.minimumThickness = AppTheme.Layout.produceTimelineStripHeight
        centerSplit.addSplitViewItem(stripItem)

        let rightSplit = makeChildSplit(isVertical: false, autosave: SplitAutosave.productionRight)
        let previewItem = makePreviewItem()
        previewItem.minimumThickness = AppTheme.Layout.producePreviewMinHeight
        rightSplit.addSplitViewItem(previewItem)
        let inspectorItem = makeInspectorItem()
        inspectorItem.minimumThickness = AppTheme.Layout.inspectorMinHeight
        rightSplit.addSplitViewItem(inspectorItem)

        target.addSplitViewItem(makeSidebarItem(host: agentHC, minimumThickness: AppTheme.Layout.agentPanelMin))
        let centerItem = NSSplitViewItem(viewController: centerSplit)
        centerItem.minimumThickness = AppTheme.Layout.previewMinWidth
        target.addSplitViewItem(centerItem)
        let rightItem = NSSplitViewItem(viewController: rightSplit)
        rightItem.minimumThickness = AppTheme.Layout.produceRightColumnMinWidth
        target.addSplitViewItem(rightItem)

        applyAfterLayout { [weak self, weak target, weak rightSplit, weak centerSplit] in
            guard let self, let target, let rightSplit, let centerSplit else { return }
            let targetW = target.view.bounds.width
            let rightH = rightSplit.view.bounds.height
            self.positionIfUnsaved(target) {
                $0.setPosition(AppTheme.Layout.mediaPanelDefault, ofDividerAt: 0)
                $0.setPosition(targetW - AppTheme.Layout.producePreviewDefaultWidth, ofDividerAt: 1)
            }
            self.positionIfUnsaved(rightSplit) { $0.setPosition(round(rightH * 0.35), ofDividerAt: 0) }
            let centerH = centerSplit.view.bounds.height
            self.positionIfUnsaved(centerSplit) {
                $0.setPosition(max(0, centerH - AppTheme.Layout.produceTimelineStripDefault), ofDividerAt: 0)
            }
        }
    }

    // MARK: - Postproduction workspace

    private func buildPostproductionLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true

        let centerSplit = makeChildSplit(isVertical: false, autosave: SplitAutosave.postCenter)
        let previewItem = makePreviewItem()
        previewItem.minimumThickness = AppTheme.Layout.finishPreviewMinHeight
        centerSplit.addSplitViewItem(previewItem)
        centerSplit.addSplitViewItem(makeTimelineItem())

        target.addSplitViewItem(makeSidebarItem(
            host: reviewHC,
            minimumThickness: AppTheme.Layout.mediaPanelMin,
            projectSurface: true
        ))
        let centerItem = NSSplitViewItem(viewController: centerSplit)
        centerItem.minimumThickness = AppTheme.Layout.previewMinWidth
        target.addSplitViewItem(centerItem)
        target.addSplitViewItem(makeInspectorItem())

        applyAfterLayout { [weak self, weak target, weak centerSplit] in
            guard let self, let target, let centerSplit else { return }
            let width = target.view.bounds.width
            let height = centerSplit.view.bounds.height
            self.positionIfUnsaved(target) {
                $0.setPosition(AppTheme.Layout.mediaPanelDefault, ofDividerAt: 0)
                $0.setPosition(width - AppTheme.Layout.inspectorDefault, ofDividerAt: 1)
            }
            self.positionIfUnsaved(centerSplit) {
                $0.setPosition(round(height * AppTheme.Layout.finishPreviewFraction), ofDividerAt: 0)
            }
        }
    }

    // MARK: - Export workspace

    private func buildExportLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true
        target.addSplitViewItem(makeSidebarItem(
            host: exportHC,
            minimumThickness: AppTheme.Layout.mediaPanelMin,
            projectSurface: true
        ))
        target.addSplitViewItem(makePreviewItem())
        target.addSplitViewItem(makeInspectorItem())

        applyAfterLayout { [weak self, weak target] in
            guard let self, let target else { return }
            let width = target.view.bounds.width
            self.positionIfUnsaved(target) {
                $0.setPosition(AppTheme.Layout.mediaPanelDefault, ofDividerAt: 0)
                $0.setPosition(width - AppTheme.Layout.inspectorDefault, ofDividerAt: 1)
            }
        }
    }

    // MARK: - Default layout

    private func buildDefaultLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = false

        let hSplit = makeChildSplit(isVertical: true, autosave: SplitAutosave.defaultH)
        hSplit.addSplitViewItem(makeSidebarItem(host: editMediaHC, minimumThickness: AppTheme.Layout.mediaPanelMin))
        hSplit.addSplitViewItem(makePreviewItem())
        hSplit.addSplitViewItem(makeInspectorItem())

        let upper = NSSplitViewItem(viewController: hSplit)
        upper.minimumThickness = AppTheme.Layout.previewMinHeight
        target.addSplitViewItem(upper)
        target.addSplitViewItem(makeTimelineItem())

        // Positions are set against each inner split's own bounds — not
        // self.view.bounds, which includes the agent column's width.
        applyAfterLayout { [weak self, weak target, weak hSplit] in
            guard let self, let target, let hSplit else { return }
            let targetH = target.view.bounds.height
            let hW = hSplit.view.bounds.width
            self.positionIfUnsaved(target) { $0.setPosition(round(targetH * 0.7), ofDividerAt: 0) }
            self.positionIfUnsaved(hSplit) {
                $0.setPosition(AppTheme.Layout.mediaPanelDefault, ofDividerAt: 0)
                $0.setPosition(hW - AppTheme.Layout.inspectorDefault, ofDividerAt: 1)
            }
        }
    }

    // MARK: - Media layout
    // [Media] | [Preview | Inspector] / [Toolbar + Timeline]

    private func buildMediaLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true

        let topSplit = makeChildSplit(isVertical: true, autosave: SplitAutosave.mediaTop)
        topSplit.addSplitViewItem(makePreviewItem())
        topSplit.addSplitViewItem(makeInspectorItem())

        let rightSplit = makeChildSplit(isVertical: false, autosave: SplitAutosave.mediaRight)
        let topItem = NSSplitViewItem(viewController: topSplit)
        topItem.minimumThickness = AppTheme.Layout.previewMinHeight
        rightSplit.addSplitViewItem(topItem)
        rightSplit.addSplitViewItem(makeTimelineItem())

        target.addSplitViewItem(makeSidebarItem(host: editMediaHC, minimumThickness: AppTheme.Layout.mediaPanelMin))
        target.addSplitViewItem(NSSplitViewItem(viewController: rightSplit))

        applyAfterLayout { [weak self, weak target, weak rightSplit, weak topSplit] in
            guard let self, let target, let rightSplit, let topSplit else { return }
            let targetW = target.view.bounds.width
            let rightH = rightSplit.view.bounds.height
            let topW = topSplit.view.bounds.width
            self.positionIfUnsaved(target) { $0.setPosition(round(targetW * 0.3), ofDividerAt: 0) }
            self.positionIfUnsaved(rightSplit) { $0.setPosition(round(rightH * 0.55), ofDividerAt: 0) }
            self.positionIfUnsaved(topSplit) { $0.setPosition(topW - AppTheme.Layout.inspectorDefault, ofDividerAt: 0) }
        }
    }

    // MARK: - Vertical layout
    // [Media | Inspector] / [Toolbar + Timeline] | [Preview]

    private func buildVerticalLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true

        let topSplit = makeChildSplit(isVertical: true, autosave: SplitAutosave.verticalTop)
        topSplit.addSplitViewItem(makeSidebarItem(host: editMediaHC, minimumThickness: AppTheme.Layout.mediaPanelMin))
        topSplit.addSplitViewItem(makeInspectorItem())

        let leftSplit = makeChildSplit(isVertical: false, autosave: SplitAutosave.verticalLeft)
        leftSplit.addSplitViewItem(NSSplitViewItem(viewController: topSplit))
        leftSplit.addSplitViewItem(makeTimelineItem())

        target.addSplitViewItem(NSSplitViewItem(viewController: leftSplit))
        target.addSplitViewItem(makePreviewItem())

        applyAfterLayout { [weak self, weak target, weak leftSplit, weak topSplit] in
            guard let self, let target, let leftSplit, let topSplit else { return }
            let targetW = target.view.bounds.width
            let leftH = leftSplit.view.bounds.height
            self.positionIfUnsaved(target) { $0.setPosition(round(targetW * 0.5), ofDividerAt: 0) }
            self.positionIfUnsaved(leftSplit) { $0.setPosition(round(leftH * 0.55), ofDividerAt: 0) }
            self.positionIfUnsaved(topSplit) { $0.setPosition(AppTheme.Layout.mediaPanelDefault, ofDividerAt: 0) }
        }
    }

    // MARK: - Shared item builders

    private func makeChildSplit(isVertical: Bool, autosave: String? = nil) -> NSSplitViewController {
        let vc = PaddedDividerSplitViewController()
        vc.splitView.isVertical = isVertical
        vc.splitView.dividerStyle = .thin
        vc.hadSavedFrames = SplitAutosave.hasSavedFrames(autosave)
        vc.splitView.autosaveName = autosave
        return vc
    }

    /// Default positions apply per split: each is skipped independently once it has autosaved frames.
    private func positionIfUnsaved(_ controller: NSSplitViewController, _ apply: (NSSplitView) -> Void) {
        guard let controller = controller as? PaddedDividerSplitViewController,
              !controller.hadSavedFrames else {
            return
        }
        apply(controller.splitView)
    }

    private func makeSidebarItem(
        host: NSViewController,
        minimumThickness: CGFloat,
        projectSurface: Bool = false
    ) -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: host)
        item.minimumThickness = minimumThickness
        item.canCollapse = false
        item.isCollapsed = !editor.mediaPanelVisible
        mediaSplitItem = item
        if projectSurface { cockpitSplitItem = item }
        return item
    }

    private func makePreviewItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: previewHC)
        item.minimumThickness = AppTheme.Layout.previewMinWidth
        previewSplitItem = item
        return item
    }

    private func makeInspectorItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: inspectorHC)
        item.minimumThickness = AppTheme.Layout.inspectorMin
        item.canCollapse = false
        item.isCollapsed = !editor.inspectorPanelVisible
        inspectorSplitItem = item
        return item
    }

    private func makeTimelineItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: timelineHC)
        item.minimumThickness = AppTheme.Layout.timelineMinHeight
        timelineSplitItem = item
        return item
    }

    func applyPanelFocus(_ focusedPanel: EditorViewModel.FocusedPanel?) {
        for host in panelHosts {
            host.applyPanelFocus(focusedPanel)
        }
    }

    private func makeHosting<V: View>(_ content: V, panel: EditorViewModel.FocusedPanel) -> NSViewController {
        let hc = PanelHostingController(
            rootView: ProjectInterface { content }
                .environment(editor)
                .frame(minWidth: AppTheme.Spacing.none, maxWidth: .infinity, minHeight: AppTheme.Spacing.none, maxHeight: .infinity),
            panel: panel
        )
        panelHosts.append(hc)
        hc.applyPanelFocus(editor.focusedPanel)
        hc.view.setAccessibilityIdentifier(panel.accessibilityID)
        return hc
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        runPendingPositioning()
        updateTourFrame()   // see EditorSplitViewController+Tour.swift
    }

    private func applyAfterLayout(_ apply: @escaping () -> Void) {
        pendingPositioning = { [weak self] in
            guard let self else { return }
            apply()
            self.applyCurrentPresentationState()
        }
        view.needsLayout = true
    }

    private func runPendingPositioning() {
        guard !isPositioning, view.bounds.width > 0, let work = pendingPositioning else { return }
        pendingPositioning = nil
        isPositioning = true
        work()
        isPositioning = false
    }

    private func applyCurrentPresentationState() {
        mediaSplitItem?.isCollapsed = !editor.mediaPanelVisible
        inspectorSplitItem?.isCollapsed = !editor.inspectorPanelVisible
        currentMaximized = nil
        applyMaximize(editor.theaterActive ? .preview : editor.maximizedPanel)
    }
}

private struct MediaWorkspaceSidebar: View {
    @Environment(EditorViewModel.self) private var editor
    let workspace: EditorViewModel.WorkspaceFocus

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            if let progress = editor.mediaImportProgress {
                MediaImportProgressBanner(progress: progress)
            }
            MediaPanelView(workspace: workspace)
        }
    }
}

// MARK: - Timeline panel (focus-aware)

/// The one canonical timeline; edit mutations remain gated by `allowsTimelineEditChrome`.
private struct TimelinePanel: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            ToolbarView().frame(height: AppTheme.Layout.toolbarHeight)
            TimelineContainerView()
        }
    }
}

// MARK: - Panel focus ring

@MainActor
private protocol PanelFocusUpdating: AnyObject {
    func applyPanelFocus(_ focusedPanel: EditorViewModel.FocusedPanel?)
}

private final class PanelHostingController<Content: View>: NSViewController, PanelFocusUpdating {
    private let hostingController: NSHostingController<Content>
    private let panel: EditorViewModel.FocusedPanel
    private let focusRing = CAShapeLayer()
    private var focusedPanel: EditorViewModel.FocusedPanel?

    init(rootView: Content, panel: EditorViewModel.FocusedPanel) {
        hostingController = NSHostingController(rootView: rootView)
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
        // The split view owns panel geometry; content must not feed sizes back into Auto Layout.
        hostingController.sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = AppTheme.Background.base.cgColor
        view = container

        addChild(hostingController)
        let hostedView = hostingController.view
        hostedView.wantsLayer = true
        hostedView.layer?.backgroundColor = AppTheme.Background.surface.cgColor
        hostedView.layer?.cornerRadius = AppTheme.Radius.sm
        hostedView.layer?.masksToBounds = true
        container.addSubview(hostedView)

        focusRing.fillColor = nil
        focusRing.strokeColor = AppTheme.Border.divider.cgColor
        focusRing.lineWidth = AppTheme.BorderWidth.thin
        focusRing.opacity = focusRingOpacity
        focusRing.zPosition = 1
        focusRing.actions = [
            "opacity": NSNull(),
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
        container.layer?.addSublayer(focusRing)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let inset = AppTheme.Layout.panelGap / 2
        let bounds = view.bounds
        let panelFrame = bounds.insetBy(dx: inset, dy: inset)
        if hostingController.view.frame != panelFrame {
            hostingController.view.frame = panelFrame
        }
        focusRing.frame = bounds
        focusRing.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: AppTheme.Radius.sm,
            cornerHeight: AppTheme.Radius.sm,
            transform: nil
        )
        if let scale = view.window?.backingScaleFactor {
            focusRing.contentsScale = scale
        }
    }

    func applyPanelFocus(_ focusedPanel: EditorViewModel.FocusedPanel?) {
        self.focusedPanel = focusedPanel
        guard isViewLoaded else { return }
        focusRing.opacity = focusRingOpacity
    }

    private var focusRingOpacity: Float {
        Float(focusedPanel == panel ? AppTheme.Opacity.opaque : AppTheme.Opacity.transparent)
    }
}
