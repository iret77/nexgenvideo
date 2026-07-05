import AppKit
import SwiftUI

struct EditorView: NSViewControllerRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSViewController(context: Context) -> EditorSplitViewController {
        EditorSplitViewController(editor: editor)
    }

    func updateNSViewController(_ controller: EditorSplitViewController, context: Context) {
        controller.applyLayoutIfNeeded(editor.layoutPreset)
        controller.applyFocusIfNeeded(editor.workspaceFocus)
        controller.applyMediaVisibility(editor.mediaPanelVisible)
        // Produce hides the Inspector unless an object is being inspected; Edit follows the user's pref.
        let inspectorVisible = editor.workspaceFocus == .edit
            ? editor.inspectorPanelVisible
            : (editor.inspectedObject != nil)
        controller.applyInspectorVisibility(inspectorVisible)
        controller.applyMaximize(editor.maximizedPanel)
        controller.updateTourFrame(stepIndex: editor.tour.stepIndex, anchorRevision: editor.tour.anchorRevision)
    }
}

// MARK: - Split view controller

/// Thicker divider hit area for panel resizing
class PaddedDividerSplitViewController: NSSplitViewController {
    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        let pad = Layout.panelGap / 2
        return splitView.isVertical
            ? drawnRect.insetBy(dx: -pad, dy: 0)
            : drawnRect.insetBy(dx: 0, dy: -pad)
    }
}

/// Autosave keys for the editor splits, defined once so call sites can't drift.
private enum SplitAutosave {
    static let root          = "editor.root"
    static let defaultH      = "editor.default.h"
    static let mediaTop      = "editor.media.top"
    static let mediaRight    = "editor.media.right"
    static let verticalTop   = "editor.vertical.top"
    static let verticalLeft  = "editor.vertical.left"
    static let produceRoot   = "editor.produce.root"
    static let produceCenter = "editor.produce.center"
    static let produceRight  = "editor.produce.right"
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
    private var currentFocus: EditorViewModel.WorkspaceFocus?
    private var currentMaximized: EditorViewModel.FocusedPanel?
    private var pendingPositioning: (() -> Void)?
    private var isPositioning = false
    private weak var mediaSplitItem: NSSplitViewItem?
    private weak var previewSplitItem: NSSplitViewItem?
    private weak var inspectorSplitItem: NSSplitViewItem?
    private weak var timelineSplitItem: NSSplitViewItem?
    private weak var cockpitSplitItem: NSSplitViewItem?

    private lazy var mediaHC: NSViewController     = makeHosting(LeftSidebarView(), panel: .media)
    private lazy var previewHC: NSViewController   = makeHosting(PreviewContainerView(), panel: .preview)
    private lazy var inspectorHC: NSViewController = makeHosting(InspectorView(), panel: .inspector)
    private lazy var cockpitHC: NSViewController   = makeHosting(ProjectCockpitView(), panel: .project)
    private lazy var timelineHC: NSViewController  = makeHosting(TimelinePanel(), panel: .timeline)

    init(editor: EditorViewModel) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        splitView.autosaveName = SplitAutosave.root
        buildLayout(editor.layoutPreset)
    }

    // MARK: - Layout switching

    func applyLayoutIfNeeded(_ preset: LayoutPreset) {
        guard preset != currentPreset else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, preset != self.currentPreset else { return }
            if self.currentMaximized != nil {
                self.currentMaximized = nil
                self.editor.maximizedPanel = nil
            }
            self.buildLayout(preset)
        }
    }

    func applyFocusIfNeeded(_ focus: EditorViewModel.WorkspaceFocus) {
        guard focus != currentFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, focus != self.currentFocus else { return }
            if self.currentMaximized != nil {
                self.currentMaximized = nil
                self.editor.maximizedPanel = nil
            }
            self.buildLayout(self.currentPreset ?? self.editor.layoutPreset)
        }
    }

    func applyMaximize(_ panel: EditorViewModel.FocusedPanel?) {
        guard panel != currentMaximized else { return }
        currentMaximized = panel
        if let panel, let leaf = leafItem(for: panel) {
            for sibling in ancestorChainSiblings(of: leaf) {
                applyCollapsed(item: sibling, collapsed: true)
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
        case .project:   return cockpitSplitItem // Only mounted in Produce focus.
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
        DispatchQueue.main.async {
            item.animator().isCollapsed = collapsed
        }
    }

    private func buildLayout(_ preset: LayoutPreset) {
        pendingPositioning = nil

        while !splitViewItems.isEmpty {
            removeSplitViewItem(splitViewItems.last!)
        }
        mediaSplitItem = nil
        previewSplitItem = nil
        inspectorSplitItem = nil
        timelineSplitItem = nil
        cockpitSplitItem = nil

        currentPreset = preset
        currentFocus = editor.workspaceFocus
        splitView.isVertical = true

        // Produce is one opinionated arrangement; the layout presets are Edit arrangements.
        let isProduce = editor.workspaceFocus == .produce
        let presetRoot = makeChildSplit(
            isVertical: false,
            autosave: isProduce ? SplitAutosave.produceRoot : SplitAutosave.preset(preset)
        )
        if isProduce {
            buildProduceLayout(into: presetRoot)
        } else {
            switch preset {
            case .default:  buildDefaultLayout(into: presetRoot)
            case .media:    buildMediaLayout(into: presetRoot)
            case .vertical: buildVerticalLayout(into: presetRoot)
            }
        }

        let presetItem = NSSplitViewItem(viewController: presetRoot)
        presetItem.minimumThickness = 400
        addSplitViewItem(presetItem)
    }

    // MARK: - Produce layout
    // [Sidebar (Media/Agent)] | [Cockpit / Timeline strip] | [Preview / Inspector]
    // The cockpit is the center work surface; the timeline is a fixed display strip of accumulating
    // shot blocks; the preview stays reachable, docked above the Inspector. Same canonical components,
    // rearranged (docs/UI_UX_CONCEPT.md §3).

    private func buildProduceLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true

        let centerSplit = makeChildSplit(isVertical: false, autosave: SplitAutosave.produceCenter)
        let cockpitItem = NSSplitViewItem(viewController: cockpitHC)
        cockpitItem.minimumThickness = Layout.previewMinHeight
        centerSplit.addSplitViewItem(cockpitItem)
        cockpitSplitItem = cockpitItem
        let stripItem = makeTimelineItem()
        // Resizable: a usable min (toolbar + ruler + a track lane), no fixed max — drag it taller.
        stripItem.minimumThickness = Layout.produceTimelineStripHeight
        centerSplit.addSplitViewItem(stripItem)

        let rightSplit = makeChildSplit(isVertical: false, autosave: SplitAutosave.produceRight)
        let previewItem = makePreviewItem()
        previewItem.minimumThickness = Layout.producePreviewMinHeight
        rightSplit.addSplitViewItem(previewItem)
        rightSplit.addSplitViewItem(makeInspectorItem())

        target.addSplitViewItem(makeMediaItem())
        let centerItem = NSSplitViewItem(viewController: centerSplit)
        centerItem.minimumThickness = Layout.previewMinWidth
        target.addSplitViewItem(centerItem)
        let rightItem = NSSplitViewItem(viewController: rightSplit)
        rightItem.minimumThickness = Layout.inspectorMin
        target.addSplitViewItem(rightItem)

        applyAfterLayout { [weak self, weak target, weak rightSplit, weak centerSplit] in
            guard let self, let target, let rightSplit, let centerSplit else { return }
            let targetW = target.view.bounds.width
            let rightH = rightSplit.view.bounds.height
            self.positionIfUnsaved(target) {
                $0.setPosition(Layout.mediaPanelDefault, ofDividerAt: 0)
                $0.setPosition(targetW - Layout.producePreviewDefaultWidth, ofDividerAt: 1)
            }
            self.positionIfUnsaved(rightSplit) { $0.setPosition(round(rightH * 0.35), ofDividerAt: 0) }
            let centerH = centerSplit.view.bounds.height
            self.positionIfUnsaved(centerSplit) {
                $0.setPosition(max(0, centerH - Layout.produceTimelineStripDefault), ofDividerAt: 0)
            }
        }
    }

    // MARK: - Default layout

    private func buildDefaultLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = false

        let hSplit = makeChildSplit(isVertical: true, autosave: SplitAutosave.defaultH)
        hSplit.addSplitViewItem(makeMediaItem())
        hSplit.addSplitViewItem(makePreviewItem())
        hSplit.addSplitViewItem(makeInspectorItem())

        let upper = NSSplitViewItem(viewController: hSplit)
        upper.minimumThickness = Layout.previewMinHeight
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
                $0.setPosition(Layout.mediaPanelDefault, ofDividerAt: 0)
                $0.setPosition(hW - Layout.inspectorDefault, ofDividerAt: 1)
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
        topItem.minimumThickness = Layout.previewMinHeight
        rightSplit.addSplitViewItem(topItem)
        rightSplit.addSplitViewItem(makeTimelineItem())

        target.addSplitViewItem(makeMediaItem())
        target.addSplitViewItem(NSSplitViewItem(viewController: rightSplit))

        applyAfterLayout { [weak self, weak target, weak rightSplit, weak topSplit] in
            guard let self, let target, let rightSplit, let topSplit else { return }
            let targetW = target.view.bounds.width
            let rightH = rightSplit.view.bounds.height
            let topW = topSplit.view.bounds.width
            self.positionIfUnsaved(target) { $0.setPosition(round(targetW * 0.3), ofDividerAt: 0) }
            self.positionIfUnsaved(rightSplit) { $0.setPosition(round(rightH * 0.55), ofDividerAt: 0) }
            self.positionIfUnsaved(topSplit) { $0.setPosition(topW - Layout.inspectorDefault, ofDividerAt: 0) }
        }
    }

    // MARK: - Vertical layout
    // [Media | Inspector] / [Toolbar + Timeline] | [Preview]

    private func buildVerticalLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true

        let topSplit = makeChildSplit(isVertical: true, autosave: SplitAutosave.verticalTop)
        topSplit.addSplitViewItem(makeMediaItem())
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
            self.positionIfUnsaved(topSplit) { $0.setPosition(Layout.mediaPanelDefault, ofDividerAt: 0) }
        }
    }

    // MARK: - Shared item builders

    private func makeChildSplit(isVertical: Bool, autosave: String? = nil) -> NSSplitViewController {
        let vc = PaddedDividerSplitViewController()
        vc.splitView.isVertical = isVertical
        vc.splitView.dividerStyle = .thin
        vc.splitView.autosaveName = autosave
        return vc
    }

    /// Default positions apply per split: each is skipped independently once it has autosaved frames.
    private func positionIfUnsaved(_ controller: NSSplitViewController, _ apply: (NSSplitView) -> Void) {
        guard !SplitAutosave.hasSavedFrames(controller.splitView.autosaveName) else { return }
        apply(controller.splitView)
    }

    private func makeMediaItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: mediaHC)
        item.minimumThickness = Layout.mediaPanelMin
        item.canCollapse = false
        item.isCollapsed = !editor.mediaPanelVisible
        mediaSplitItem = item
        return item
    }

    private func makePreviewItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: previewHC)
        item.minimumThickness = Layout.previewMinWidth
        previewSplitItem = item
        return item
    }

    private func makeInspectorItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: inspectorHC)
        item.minimumThickness = Layout.inspectorMin
        item.canCollapse = false
        item.isCollapsed = !editor.inspectorPanelVisible
        inspectorSplitItem = item
        return item
    }

    private func makeTimelineItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: timelineHC)
        item.minimumThickness = Layout.timelineMinHeight
        timelineSplitItem = item
        return item
    }

    private func makeHosting<V: View>(_ content: V, panel: EditorViewModel.FocusedPanel) -> NSHostingController<some View> {
        let inset = Layout.panelGap / 2
        let panelShell = RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        let hc = NSHostingController(
            rootView: content
                .environment(editor)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(AppTheme.Background.surfaceColor)
                .clipShape(panelShell)
                .padding(inset)
                .background(AppTheme.Background.baseColor)
                .overlay {
                    PanelFocusRing(editor: editor, panel: panel)
                        .padding(inset)
                        .allowsHitTesting(false)
                }
        )
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
            self.mediaSplitItem?.isCollapsed = !self.editor.mediaPanelVisible
            self.inspectorSplitItem?.isCollapsed = !self.editor.inspectorPanelVisible
        }
        if view.bounds.width > 0 {
            view.layoutSubtreeIfNeeded()
            runPendingPositioning()
        } else {
            view.needsLayout = true
        }
    }

    private func runPendingPositioning() {
        guard !isPositioning, view.bounds.width > 0, let work = pendingPositioning else { return }
        pendingPositioning = nil
        isPositioning = true
        work()
        isPositioning = false
    }
}

// MARK: - Timeline panel (focus-aware)

/// The one canonical timeline, dressed per focus: in Edit it carries the toolbar and full interaction;
/// A real timeline in both focuses: the toolbar (zoom) and interaction (pinch/scroll/select) are
/// available in Produce too — the strip is smaller and resizable, not crippled.
private struct TimelinePanel: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView().frame(height: Layout.toolbarHeight)
            TimelineContainerView()
        }
    }
}

// MARK: - Panel focus ring overlay

private struct PanelFocusRing: View {
    var editor: EditorViewModel
    let panel: EditorViewModel.FocusedPanel

    private var isFocused: Bool { editor.focusedPanel == panel }

    var body: some View {
        // Deliberately faint: a whisper of "this panel gets the keyboard", never a frame around the
        // workspace — with the full-height sidebar a prominent ring reads as broken chrome.
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
            .strokeBorder(AppTheme.Accent.primary, lineWidth: AppTheme.BorderWidth.thin)
            .opacity(isFocused ? AppTheme.Opacity.muted : 0)
            .animation(.easeOut(duration: AppTheme.Anim.transition), value: isFocused)
    }
}
