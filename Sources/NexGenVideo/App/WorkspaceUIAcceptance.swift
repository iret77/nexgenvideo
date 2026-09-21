import AppKit
import SwiftUI

@MainActor
enum WorkspaceUIAcceptance {
    private static var editorSizeProbes: [[String: String]] = []
    static let agentPinnedAwayNotification = Notification.Name(
        "WorkspaceUIAcceptance.agentPinnedAway"
    )

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_ACCEPTANCE"] == "1"
    }

    static func runIfRequested() {
        guard isRequested else { return }
        guard let evidencePath = ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_EVIDENCE"],
              let requestedScale = ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_SCALE"],
              let scale = Double(requestedScale),
              AppTheme.Typography.validatedScale(scale) == scale else {
            fail("invalid acceptance configuration")
        }

        editorSizeProbes = []
        resetWorkspaceDefaults(scale: scale)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        BundledFonts.register()
        let evidenceURL = URL(fileURLWithPath: evidencePath, isDirectory: true)
        emit("started", scale: scale)
        Task { @MainActor in
            let document: VideoProject
            let window: NSWindow
            let host: NSView
            let projectURL: URL
            let originalProject: [String: Data]
            do {
                projectURL = try makeProjectFixture(scale: scale)
                originalProject = try projectSnapshot(at: projectURL)
                document = try await VideoProject.load(from: projectURL)
                document.makeWindowControllers()
                guard let projectWindow = document.windowControllers
                    .compactMap({ $0 as? EditorWindowController })
                    .first?.window,
                      let contentView = projectWindow.contentView else {
                    fail("the project did not create its production window", scale: scale)
                }
                window = projectWindow
                host = contentView
                document.showWindows()
            } catch {
                fail("could not open the project fixture: \(error.localizedDescription)", scale: scale)
            }
            let editor = document.editorViewModel
            emit(
                "window-initial",
                scale: scale,
                fields: ["window": windowDiagnostics(window, contentView: host)]
            )
            window.setContentSize(NSSize(width: 1470, height: 950))
            if scale == 1.5 {
                window.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
            }
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            editor.setWorkspaceFocus(.media)
            guard await waitUntil(timeout: .seconds(5), {
                host.layoutSubtreeIfNeeded()
                let frames = visiblePanelFrames(in: host)
                return abs(host.bounds.width - 1470) <= AppTheme.BorderWidth.thin
                    && editor.workspaceFocus == .media
                    && visiblePanelIDs(in: host) == expectedPanels(for: .media)
                    && defaultPanelWidthsAreValid(workspace: .media, frames: frames)
                    && previewTimecodeIsSingleLine(in: window, scale: scale)
            }) else {
                fail("could not prepare large media layout", scale: scale)
            }
            let preparedMediaFrames = visiblePanelFrames(in: host)
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            guard visiblePanelFrames(in: host) == preparedMediaFrames else {
                fail("large media layout did not settle", scale: scale)
            }
            resetSplitAutosaveDefaults()
            editor.setWorkspaceFocus(.production)
            guard await waitUntil(timeout: .seconds(5), {
                host.layoutSubtreeIfNeeded()
                let frames = visiblePanelFrames(in: host)
                return editor.workspaceFocus == .production
                    && visiblePanelIDs(in: host) == expectedPanels(for: .production)
                    && defaultPanelWidthsAreValid(workspace: .production, frames: frames)
                    && previewTimecodeIsSingleLine(in: window, scale: scale)
                    && agentControlsAreContained(in: window)
            }) else {
                fail("could not prepare large production layout", scale: scale)
            }
            let preparedProductionFrames = visiblePanelFrames(in: host)
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            guard visiblePanelFrames(in: host) == preparedProductionFrames else {
                fail("large production layout did not settle", scale: scale)
            }
            emit(
                "window-ready",
                scale: scale,
                fields: [
                    "window": windowDiagnostics(window, contentView: host),
                    "viewChain": editorViewChainDiagnostics(in: host),
                    "sizeProbes": editorSizeProbes,
                ]
            )
            guard let workingRoot = editor.workingRoot,
                  let originalWorkingCopy = try? treeSnapshot(at: workingRoot) else {
                fail("the project working copy was unavailable", scale: scale)
            }
            let originalTimeline = editor.timeline
            let originalManifest = editor.mediaManifest
            let originalGenerationLog = editor.generationLog
            let originalPipelineState = editor.projectState
            let originalDocumentEdited = document.isDocumentEdited
            let originalCanUndo = document.undoManager?.canUndo ?? false
            let originalUndoName = document.undoManager?.undoActionName ?? ""
            var initialEditFrames: [String: NSRect]?
            for workspace in EditorViewModel.WorkspaceFocus.allCases {
                let identifier = "editor.workspace.\(workspace.rawValue)"
                guard click(identifier: identifier, in: window) == nil else {
                    fail("could not click \(identifier)", scale: scale)
                }
                guard await waitUntil(timeout: .seconds(5), {
                    host.layoutSubtreeIfNeeded()
                    let frames = visiblePanelFrames(in: host)
                    return editor.workspaceFocus == workspace
                        && probeState(identifier: identifier, in: window) == true
                        && visiblePanelIDs(in: host) == expectedPanels(for: workspace)
                        && defaultPanelWidthsAreValid(workspace: workspace, frames: frames)
                        && previewTimecodeIsSingleLine(in: window, scale: scale)
                        && (workspace != .production || agentControlsAreContained(in: window))
                }) else {
                    let diagnosticName = "scale-\(scaleLabel(scale))-\(workspace.rawValue)-failed"
                    _ = snapshot(
                        host,
                        at: evidenceURL.appendingPathComponent("\(diagnosticName).png")
                    )
                    emit(
                        "layout-diagnostic",
                        scale: scale,
                        fields: [
                            "workspace": workspace.rawValue,
                            "screenshot": "\(diagnosticName).png",
                            "panels": panelDiagnostics(in: host),
                            "splits": splitDiagnostics(in: host),
                            "window": windowDiagnostics(window, contentView: host),
                            "viewChain": editorViewChainDiagnostics(in: host),
                            "geometry": geometryDiagnostics(in: host),
                            "sizeProbes": editorSizeProbes,
                        ]
                    )
                    fail(
                        "workspace did not settle \(workspace.rawValue); focus="
                            + "\(editor.workspaceFocus.rawValue), panels="
                            + "\(visiblePanelIDs(in: host).sorted()), sidebar="
                            + "\(editor.isSidebarPresented), inspector="
                            + "\(editor.isInspectorPresented)",
                        scale: scale
                    )
                }
                let renderedFrames = visiblePanelFrames(in: host)
                try? await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                guard editor.workspaceFocus == workspace,
                      probeState(identifier: identifier, in: window) == true,
                      visiblePanelIDs(in: host) == expectedPanels(for: workspace),
                      visiblePanelFrames(in: host) == renderedFrames,
                      defaultPanelWidthsAreValid(workspace: workspace, frames: renderedFrames),
                      previewTimecodeIsSingleLine(in: window, scale: scale),
                      workspace != .production || agentControlsAreContained(in: window) else {
                    fail("workspace layout did not settle for \(workspace.rawValue)", scale: scale)
                }
                let visiblePanels = visiblePanelIDs(in: host)
                if workspace == .edit { initialEditFrames = renderedFrames }
                let name = "scale-\(scaleLabel(scale))-\(workspace.rawValue)"
                guard snapshot(host, at: evidenceURL.appendingPathComponent("\(name).png")) else {
                    fail("could not capture \(name)", scale: scale)
                }
                emit(
                    "workspace",
                    scale: scale,
                    fields: [
                        "workspace": workspace.rawValue,
                        "screenshot": "\(name).png",
                        "panels": visiblePanels.sorted(),
                        "frames": renderedFrames.mapValues { frameDescription($0) },
                    ]
                )
            }

            guard click(identifier: "editor.workspace.edit", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.workspaceFocus == .edit
                          && probeState(identifier: "editor.workspace.edit", in: window) == true
                          && visiblePanelIDs(in: host) == expectedPanels(for: .edit)
                  }) else {
                fail("could not return to edit", scale: scale)
            }
            let returnedFrames = visiblePanelFrames(in: host)
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            guard probeState(identifier: "editor.workspace.edit", in: window) == true,
                  visiblePanelIDs(in: host) == expectedPanels(for: .edit),
                  visiblePanelFrames(in: host) == returnedFrames,
                  let initialEditFrames,
                  returnedFrames == initialEditFrames else {
                fail("edit workspace did not settle before panel controls", scale: scale)
            }
            guard click(identifier: "editor.panel.sidebar", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return !editor.isSidebarPresented
                          && editor.isInspectorPresented
                          && visiblePanelIDs(in: host)
                              == ["previewPanel", "inspectorPanel", "timelinePanel"]
                  }) else {
                fail(
                    "sidebar click did not hide the panel; sidebar="
                        + "\(editor.isSidebarPresented), inspector=\(editor.isInspectorPresented), "
                        + "probe=\(String(describing: probeState(identifier: "editor.panel.sidebar", in: window))), "
                        + "panels=\(visiblePanelIDs(in: host).sorted())",
                    scale: scale
                )
            }
            guard click(identifier: "editor.panel.inspector", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return !editor.isSidebarPresented
                          && !editor.isInspectorPresented
                          && visiblePanelIDs(in: host) == ["previewPanel", "timelinePanel"]
                  }) else {
                fail("inspector click did not hide the panel", scale: scale)
            }
            let collapsedFrames = visiblePanelFrames(in: host)
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let collapsedName = "scale-\(scaleLabel(scale))-edit-panels-hidden"
            guard probeState(identifier: "editor.panel.sidebar", in: window) == false,
                  probeState(identifier: "editor.panel.inspector", in: window) == false,
                  visiblePanelIDs(in: host) == ["previewPanel", "timelinePanel"],
                  visiblePanelFrames(in: host) == collapsedFrames,
                  snapshot(host, at: evidenceURL.appendingPathComponent("\(collapsedName).png")) else {
                fail("collapsed panel state was not rendered", scale: scale)
            }
            emit(
                "panels-hidden",
                scale: scale,
                fields: ["workspace": "edit", "screenshot": "\(collapsedName).png"]
            )

            guard click(identifier: "editor.panel.sidebar", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.isSidebarPresented
                          && !editor.isInspectorPresented
                          && visiblePanelIDs(in: host)
                              == ["mediaPanel", "previewPanel", "timelinePanel"]
                  }),
                  click(identifier: "editor.panel.inspector", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.isSidebarPresented
                          && editor.isInspectorPresented
                          && visiblePanelIDs(in: host) == expectedPanels(for: .edit)
                  }) else {
                fail("panel controls did not restore their panels", scale: scale)
            }
            let restoredFrames = visiblePanelFrames(in: host)
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            guard probeState(identifier: "editor.panel.sidebar", in: window) == true,
                  probeState(identifier: "editor.panel.inspector", in: window) == true,
                  visiblePanelIDs(in: host) == expectedPanels(for: .edit),
                  visiblePanelFrames(in: host) == restoredFrames else {
                fail("restored panel layout did not settle", scale: scale)
            }
            guard click(identifier: "editor.workspace.production", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.workspaceFocus == .production
                          && visiblePanelIDs(in: host) == expectedPanels(for: .production)
                  }) else {
                fail("could not prepare narrow production workspace", scale: scale)
            }
            window.setContentSize(NSSize(
                width: AppTheme.Window.projectMin.width,
                height: window.contentView?.bounds.height ?? AppTheme.Window.projectMin.height
            ))
            guard await waitUntil(timeout: .seconds(5), {
                host.layoutSubtreeIfNeeded()
                let frames = visiblePanelFrames(in: host)
                return abs(host.bounds.width - AppTheme.Window.projectMin.width)
                        <= AppTheme.BorderWidth.thin
                    && visiblePanelIDs(in: host) == expectedPanels(for: .production)
                    && narrowProductionWidthsAreValid(frames)
                    && previewTimecodeIsSingleLine(in: window, scale: scale)
                    && agentControlsAreContained(in: window)
            }) else {
                fail("narrow production controls did not fit", scale: scale)
            }
            let narrowFrames = visiblePanelFrames(in: host)
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let narrowName = "scale-\(scaleLabel(scale))-production-narrow"
            guard visiblePanelFrames(in: host) == narrowFrames,
                  snapshot(host, at: evidenceURL.appendingPathComponent("\(narrowName).png")) else {
                fail("narrow production layout did not settle", scale: scale)
            }
            emit(
                "narrow-production",
                scale: scale,
                fields: [
                    "screenshot": "\(narrowName).png",
                    "frames": narrowFrames.mapValues { frameDescription($0) },
                    "window": windowDiagnostics(window, contentView: host),
                ]
            )
            NotificationCenter.default.post(
                name: agentPinnedAwayNotification,
                object: true
            )
            guard await waitUntil(timeout: .seconds(5), {
                host.layoutSubtreeIfNeeded()
                return compactAgentControlsAreContained(in: window)
            }) else {
                fail("narrow pinned agent controls did not fit", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let pinnedName = "scale-\(scaleLabel(scale))-production-narrow-pinned"
            guard compactAgentControlsAreContained(in: window),
                  snapshot(host, at: evidenceURL.appendingPathComponent("\(pinnedName).png")) else {
                fail("narrow pinned agent layout did not render", scale: scale)
            }
            emit(
                "narrow-production-pinned",
                scale: scale,
                fields: ["screenshot": "\(pinnedName).png"]
            )
            guard editor.timeline == originalTimeline,
                  editor.mediaManifest == originalManifest,
                  editor.generationLog == originalGenerationLog,
                  editor.projectState == originalPipelineState,
                  (try? treeSnapshot(at: workingRoot)) == originalWorkingCopy,
                  document.isDocumentEdited == originalDocumentEdited,
                  (document.undoManager?.canUndo ?? false) == originalCanUndo,
                  (document.undoManager?.undoActionName ?? "") == originalUndoName,
                  (try? projectSnapshot(at: projectURL)) == originalProject else {
                fail("workspace navigation mutated project or undo state", scale: scale)
            }
            emit(
                "invariants",
                scale: scale,
                fields: [
                    "liveStateUnchanged": true,
                    "projectBytesUnchanged": true,
                    "undoUnchanged": true,
                    "workingCopyUnchanged": true,
                ]
            )
            emit("completed", scale: scale)
            window.orderOut(nil)
            exit(0)
        }
        app.run()
        exit(1)
    }

    private static func makeProjectFixture(scale: Double) throws -> URL {
        let title = scale == 1.25
            ? "An exceptionally long project name for the final picture lock"
            : "Ein außergewöhnlich langes Projekt für den finalen Filmschnitt"
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(title) \(scaleLabel(scale))-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(Timeline()).write(
            to: projectURL.appendingPathComponent(Project.timelineFilename),
            options: .atomic
        )
        try JSONEncoder().encode(MediaManifest()).write(
            to: projectURL.appendingPathComponent(Project.manifestFilename),
            options: .atomic
        )
        try JSONEncoder().encode(GenerationLog()).write(
            to: projectURL.appendingPathComponent(Project.generationLogFilename),
            options: .atomic
        )
        _ = try ProjectIdentity.uuid(for: projectURL)
        return projectURL
    }

    private static func projectSnapshot(at projectURL: URL) throws -> [String: Data] {
        try treeSnapshot(at: projectURL)
    }

    private static func treeSnapshot(at root: URL) throws -> [String: Data] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        let prefix = root.standardizedFileURL.path + "/"
        var snapshot: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: keys).isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
            snapshot[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
        }
        return snapshot
    }

    private static func resetWorkspaceDefaults(scale: Double) {
        let defaults = UserDefaults.standard
        defaults.set(scale, forKey: AppTheme.Typography.scaleKey)
        defaults.set(true, forKey: "mediaPanelVisible")
        defaults.set(true, forKey: "inspectorPanelVisible")
        resetSplitAutosaveDefaults()
    }

    private static func resetSplitAutosaveDefaults() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("NSSplitView Subview Frames editor.") {
            defaults.removeObject(forKey: key)
        }
    }

    private static func expectedPanels(
        for workspace: EditorViewModel.WorkspaceFocus
    ) -> Set<String> {
        switch workspace {
        case .media:
            ["mediaPanel", "previewPanel", "inspectorPanel"]
        case .production:
            ["agentPanel", "projectPanel", "timelinePanel", "previewPanel", "inspectorPanel"]
        case .edit:
            ["mediaPanel", "previewPanel", "inspectorPanel", "timelinePanel"]
        case .postproduction:
            ["projectPanel", "previewPanel", "inspectorPanel", "timelinePanel"]
        case .export:
            ["projectPanel", "previewPanel", "inspectorPanel"]
        }
    }

    private static func visiblePanelIDs(in root: NSView) -> Set<String> {
        Set(visiblePanelFrames(in: root).keys)
    }

    private static func visiblePanelFrames(in root: NSView) -> [String: NSRect] {
        var result: [String: NSRect] = [:]
        func visit(_ view: NSView) {
            let identifier = view.accessibilityIdentifier()
            if identifier.hasSuffix("Panel"),
               view.window != nil,
               !view.isHiddenOrHasHiddenAncestor {
                let frame = view.convert(view.bounds, to: root)
                let visibleBounds = root.bounds.insetBy(dx: -1, dy: -1)
                if frame.width >= AppTheme.Layout.timelineMinHeight,
                   frame.height >= AppTheme.Layout.timelineMinHeight,
                   visibleBounds.contains(frame) {
                    result[identifier] = frame
                }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return result
    }

    private static func defaultPanelWidthsAreValid(
        workspace: EditorViewModel.WorkspaceFocus,
        frames: [String: NSRect]
    ) -> Bool {
        let tolerance = AppTheme.Spacing.md
        func matches(_ panel: String, _ width: CGFloat) -> Bool {
            guard let frame = frames[panel] else { return false }
            return abs(frame.width - width) <= tolerance
        }
        switch workspace {
        case .media, .edit:
            return matches("mediaPanel", AppTheme.Layout.mediaPanelDefault)
                && matches("inspectorPanel", AppTheme.Layout.inspectorDefault)
        case .production:
            return matches("agentPanel", AppTheme.Layout.mediaPanelDefault)
                && matches("previewPanel", AppTheme.Layout.producePreviewDefaultWidth)
                && matches("inspectorPanel", AppTheme.Layout.producePreviewDefaultWidth)
        case .postproduction, .export:
            return matches("projectPanel", AppTheme.Layout.mediaPanelDefault)
                && matches("inspectorPanel", AppTheme.Layout.inspectorDefault)
        }
    }

    private static func narrowProductionWidthsAreValid(_ frames: [String: NSRect]) -> Bool {
        let tolerance = AppTheme.Spacing.md
        guard let agent = frames["agentPanel"],
              let project = frames["projectPanel"],
              let preview = frames["previewPanel"],
              let inspector = frames["inspectorPanel"] else { return false }
        return agent.width >= AppTheme.Layout.agentPanelMin - tolerance
            && project.width >= AppTheme.Layout.previewMinWidth - tolerance
            && preview.width >= AppTheme.Layout.produceRightColumnMinWidth - tolerance
            && inspector.width >= AppTheme.Layout.produceRightColumnMinWidth - tolerance
    }

    private static func previewTimecodeIsSingleLine(in window: NSWindow, scale: Double) -> Bool {
        guard let root = window.contentView,
              let previewFrame = visiblePanelFrames(in: root)["previewPanel"] else { return false }
        let maximumHeight = AppTheme.Typography.ui * CGFloat(scale) + AppTheme.Spacing.md
        let previewBounds = previewFrame.insetBy(
            dx: -AppTheme.BorderWidth.thin,
            dy: -AppTheme.BorderWidth.thin
        )
        guard let transportFrame = probes(in: root, identifier: "preview.transportBar")
            .compactMap({ probe -> NSRect? in
                let frame = probe.convert(probe.bounds, to: root)
                guard probe.window === window,
                      !probe.isHiddenOrHasHiddenAncestor,
                      frame.width > 0,
                      frame.height > 0,
                      previewBounds.contains(frame) else { return nil }
                return frame
            })
            .first else { return false }
        let transportBounds = transportFrame.insetBy(
            dx: -AppTheme.BorderWidth.thin,
            dy: -AppTheme.BorderWidth.thin
        )
        let timecodeFits = probes(in: root, identifier: "preview.timecode").contains { probe in
            let frame = probe.convert(probe.bounds, to: root)
            return probe.window === window
                && !probe.isHiddenOrHasHiddenAncestor
                && frame.width > 0
                && frame.height > 0
                && frame.height <= maximumHeight
                && transportBounds.contains(frame)
        }
        return timecodeFits
            && visibleProbe(identifier: "preview.zoom", in: window, containedBy: transportBounds)
    }

    private static func agentControlsAreContained(
        in window: NSWindow,
        includeLatest: Bool = false,
        requiredState: Bool? = nil
    ) -> Bool {
        guard let root = window.contentView,
              let agentFrame = visiblePanelFrames(in: root)["agentPanel"] else { return false }
        let bounds = agentFrame.insetBy(
            dx: -AppTheme.BorderWidth.thin,
            dy: -AppTheme.BorderWidth.thin
        )
        let standardControlsFit = visibleProbe(
            identifier: "agent.newConversation",
            in: window,
            containedBy: bounds,
            requiredState: requiredState
        ) && visibleProbe(
            identifier: "agent.utilities",
            in: window,
            containedBy: bounds,
            requiredState: requiredState
        )
        return standardControlsFit && (!includeLatest || visibleProbe(
            identifier: "agent.latest",
            in: window,
            containedBy: bounds,
            requiredState: requiredState
        ))
    }

    private static func compactAgentControlsAreContained(in window: NSWindow) -> Bool {
        agentControlsAreContained(
            in: window,
            includeLatest: true,
            requiredState: true
        )
    }

    private static func visibleProbe(
        identifier: String,
        in window: NSWindow,
        containedBy bounds: NSRect,
        requiredState: Bool? = nil
    ) -> Bool {
        guard let root = window.contentView else { return false }
        return probes(in: root, identifier: identifier).contains { probe in
            let frame = probe.convert(probe.bounds, to: root)
            return probe.window === window
                && !probe.isHiddenOrHasHiddenAncestor
                && frame.width > 0
                && frame.height > 0
                && bounds.contains(frame)
                && (requiredState == nil
                    || (probe as? AppRelaunchClickProbeView)?.acceptanceState == requiredState)
        }
    }

    private static func probes(in view: NSView, identifier: String) -> [NSView] {
        var result: [NSView] = []
        if view is AppRelaunchClickProbeView, view.identifier?.rawValue == identifier {
            result.append(view)
        }
        for child in view.subviews {
            result.append(contentsOf: probes(in: child, identifier: identifier))
        }
        return result
    }

    private static func panelDiagnostics(in root: NSView) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func visit(_ view: NSView) {
            let identifier = view.accessibilityIdentifier()
            if identifier.hasSuffix("Panel") {
                let frame = view.convert(view.bounds, to: root)
                result.append([
                    "id": identifier,
                    "frame": frameDescription(frame),
                    "hidden": view.isHidden,
                    "hiddenAncestor": view.isHiddenOrHasHiddenAncestor,
                    "hasWindow": view.window != nil,
                ])
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return result
    }

    private static func splitDiagnostics(in root: NSView) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func visit(_ view: NSView) {
            if let split = view as? NSSplitView {
                var row: [String: Any] = [
                    "autosave": split.autosaveName ?? "",
                    "frame": frameDescription(split.convert(split.bounds, to: root)),
                    "vertical": split.isVertical,
                    "subviews": split.subviews.map {
                        frameDescription($0.convert($0.bounds, to: root))
                    },
                ]
                if let controller = split.delegate as? NSSplitViewController {
                    row["controllerViewIsSplit"] = controller.view === split
                    row["controllerView"] = viewLayoutDiagnostics(controller.view, in: root)
                    row["splitView"] = viewLayoutDiagnostics(split, in: root)
                }
                result.append(row)
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return result
    }

    private static func viewLayoutDiagnostics(
        _ view: NSView,
        in root: NSView
    ) -> [String: Any] {
        [
            "id": String(describing: ObjectIdentifier(view)),
            "class": String(describing: type(of: view)),
            "bounds": frameDescription(view.bounds),
            "frame": frameDescription(view.frame),
            "frameInContent": frameDescription(view.convert(view.bounds, to: root)),
            "superviewID": view.superview.map {
                String(describing: ObjectIdentifier($0))
            } ?? "",
            "autoresizingMask": Int(view.autoresizingMask.rawValue),
            "translatesAutoresizingMask": view.translatesAutoresizingMaskIntoConstraints,
            "horizontalConstraints": view.constraintsAffectingLayout(for: .horizontal).map(\.description),
            "verticalConstraints": view.constraintsAffectingLayout(for: .vertical).map(\.description),
            "parentConstraints": view.superview?.constraints.map(\.description) ?? [],
        ]
    }

    private static func windowDiagnostics(
        _ window: NSWindow,
        contentView: NSView
    ) -> [String: Any] {
        let currentContentView = window.contentView
        let controllerView = window.contentViewController?.view
        return [
            "capturedContentID": String(describing: ObjectIdentifier(contentView)),
            "currentContentID": currentContentView.map {
                String(describing: ObjectIdentifier($0))
            } ?? "",
            "controllerViewID": controllerView.map {
                String(describing: ObjectIdentifier($0))
            } ?? "",
            "capturedIsCurrentContent": currentContentView === contentView,
            "capturedIsControllerView": controllerView === contentView,
            "contentBounds": frameDescription(contentView.bounds),
            "contentFrame": frameDescription(contentView.frame),
            "contentVisibleRect": frameDescription(contentView.visibleRect),
            "contentRectForFrame": frameDescription(window.contentRect(forFrameRect: window.frame)),
            "contentLayoutRect": frameDescription(window.contentLayoutRect),
            "contentMinSize": sizeDescription(window.contentMinSize),
            "contentMaxSize": sizeDescription(window.contentMaxSize),
            "frame": frameDescription(window.frame),
            "backingScaleFactor": Double(window.backingScaleFactor),
            "screenVisibleFrame": frameDescription(window.screen?.visibleFrame ?? .zero),
            "minSize": sizeDescription(window.minSize),
            "maxSize": sizeDescription(window.maxSize),
        ]
    }

    private static func geometryDiagnostics(in root: NSView) -> [String: Any] {
        guard let probe = findProbe(in: root, identifier: "editor.geometry") else {
            return ["available": false]
        }
        return ["available": true, "view": viewLayoutDiagnostics(probe, in: root)]
    }

    private static func editorViewChainDiagnostics(in root: NSView) -> [[String: Any]] {
        func firstSplit(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for child in view.subviews {
                if let split = firstSplit(in: child) { return split }
            }
            return nil
        }
        var result: [[String: Any]] = []
        var current: NSView? = firstSplit(in: root)
        while let view = current {
            result.append([
                "class": String(describing: type(of: view)),
                "bounds": frameDescription(view.bounds),
                "frame": frameDescription(view.frame),
                "frameInContent": frameDescription(view.convert(view.bounds, to: root)),
            "translatesAutoresizingMask": view.translatesAutoresizingMaskIntoConstraints,
            "autoresizesSubviews": view.autoresizesSubviews,
            ])
            current = view.superview
        }
        return result
    }

    private static func frameDescription(_ frame: NSRect) -> [String: Double] {
        [
            "x": Double(frame.minX),
            "y": Double(frame.minY),
            "width": Double(frame.width),
            "height": Double(frame.height),
        ]
    }

    private static func sizeDescription(_ size: NSSize) -> [String: Double] {
        ["width": Double(size.width), "height": Double(size.height)]
    }

    static func recordEditorSizeProbe(proposal: ProposedViewSize, result: CGSize) {
        guard isRequested, editorSizeProbes.count < 32 else { return }
        editorSizeProbes.append([
            "proposalWidth": String(describing: proposal.width),
            "proposalHeight": String(describing: proposal.height),
            "resultWidth": String(describing: result.width),
            "resultHeight": String(describing: result.height),
        ])
    }

    private static func snapshot(_ view: NSView, at url: URL) -> Bool {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func click(identifier: String, in window: NSWindow) -> String? {
        guard window.isVisible, window.isKeyWindow, !window.ignoresMouseEvents,
              let root = window.contentView,
              let probe = findProbe(in: root, identifier: identifier),
              probe.window === window,
              !probe.isHiddenOrHasHiddenAncestor else {
            return "control geometry unavailable"
        }
        let frame = probe.bounds
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            return "control has no finite frame"
        }
        let location = probe.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        guard root.bounds.contains(root.convert(location, from: nil)) else {
            return "control is outside the window"
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else {
            return "AppKit could not create mouse events"
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return nil
    }

    private static func findProbe(in view: NSView, identifier: String) -> NSView? {
        if view is AppRelaunchClickProbeView, view.identifier?.rawValue == identifier {
            return view
        }
        for child in view.subviews {
            if let match = findProbe(in: child, identifier: identifier) { return match }
        }
        return nil
    }

    private static func probeState(identifier: String, in window: NSWindow) -> Bool? {
        guard let root = window.contentView,
              let probe = findProbe(in: root, identifier: identifier)
                as? AppRelaunchClickProbeView else { return nil }
        return probe.acceptanceState
    }

    private static func waitUntil(
        timeout: Duration,
        _ predicate: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return predicate()
    }

    private static func scaleLabel(_ scale: Double) -> String {
        String(Int((scale * 100).rounded()))
    }

    private static func emit(
        _ event: String,
        scale: Double,
        fields: [String: Any] = [:]
    ) {
        var row: [String: Any] = [
            "event": event,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scale": scale,
        ]
        fields.forEach { row[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else {
            fail("could not encode evidence", scale: scale)
        }
        FileHandle.standardOutput.write(data + Data([10]))
    }

    private static func fail(_ reason: String, scale: Double? = nil) -> Never {
        if let scale {
            emit("failed", scale: scale, fields: ["reason": reason])
        } else {
            FileHandle.standardError.write(Data("WORKSPACE_UI_ACCEPTANCE_FAIL \(reason)\n".utf8))
        }
        exit(2)
    }
}
