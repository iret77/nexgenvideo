import AppKit
import AVFoundation
import CoreVideo
import NexGenEngine
import SwiftUI

@MainActor
enum WorkspaceUIAcceptance {
    private enum NativeControlState: Equatable {
        case enabled
        case disabled
    }

    private static var editorSizeProbes: [[String: String]] = []
    private static var axDiagnosticKeys = Set<String>()
    static let agentPinnedAwayNotification = Notification.Name(
        "WorkspaceUIAcceptance.agentPinnedAway"
    )

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_ACCEPTANCE"] == "1"
    }

    private static var inspectorRequested: Bool {
        ProcessInfo.processInfo.environment["NGV_INSPECTOR_UI_ACCEPTANCE"] == "1"
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
        axDiagnosticKeys = []
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
                projectURL = try await makeProjectFixture(scale: scale)
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
            await captureProductionNavigationCases(
                editor: editor,
                window: window,
                host: host,
                evidenceURL: evidenceURL,
                scale: scale
            )
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
            if inspectorRequested {
                await captureInspectorCases(
                    editor: editor,
                    window: window,
                    host: host,
                    evidenceURL: evidenceURL,
                    scale: scale
                )
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
                    && productionLayoutEvidence(in: window, frames: frames) != nil
            }) else {
                fail("narrow production controls did not fit", scale: scale)
            }
            let narrowFrames = visiblePanelFrames(in: host)
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let narrowName = "scale-\(scaleLabel(scale))-production-narrow"
            guard visiblePanelFrames(in: host) == narrowFrames,
                  let productionLayout = productionLayoutEvidence(
                      in: window,
                      frames: narrowFrames
                  ),
                  snapshot(host, at: evidenceURL.appendingPathComponent("\(narrowName).png")) else {
                fail("narrow production layout did not settle", scale: scale)
            }
            emit(
                "narrow-production",
                scale: scale,
                fields: [
                    "screenshot": "\(narrowName).png",
                    "frames": narrowFrames.mapValues { frameDescription($0) },
                    "productionLayout": productionLayout,
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

    private static func captureInspectorCases(
        editor: EditorViewModel,
        window: NSWindow,
        host: NSView,
        evidenceURL: URL,
        scale: Double
    ) async {
        let originalAssets = editor.mediaAssets
        let originalClipIDs = editor.selectedClipIds
        let originalObject = editor.inspectedObject
        let originalMediaTab = editor.mediaPanelTab(for: .edit)
        let image = MediaAsset(
            id: "inspector-image",
            url: FileManager.default.temporaryDirectory.appendingPathComponent("ngv-inspector-fixture.png"),
            type: .image,
            name: "Inspector reference"
        )
        let audio = MediaAsset(
            id: "inspector-audio",
            url: FileManager.default.temporaryDirectory.appendingPathComponent("ngv-inspector-fixture.wav"),
            type: .audio,
            name: "Inspector audio"
        )
        editor.mediaAssets.append(contentsOf: [image, audio])

        let cases: [(family: String, clipIDs: Set<String>, tab: String?)] = [
            ("text", ["inspector-text"], nil),
            ("video", ["inspector-image-1"], "Video"),
            ("effects", ["inspector-image-1"], "Adjust"),
            ("ai", ["inspector-image-1"], "AI Edit"),
            ("audio", ["inspector-audio-clip"], nil),
            ("mixed", ["inspector-image-1", "inspector-image-2"], nil),
            ("asset", [], nil),
        ]
        for item in cases {
            editor.selectedClipIds = item.clipIDs
            if item.family == "asset" {
                guard await waitUntil(timeout: .seconds(5), {
                    host.layoutSubtreeIfNeeded()
                    return editor.selectedClipIds.isEmpty && editor.inspectedObject == nil
                }) else {
                    fail("could not clear the clip inspection before asset inspection", scale: scale)
                }
                editor.inspectedObject = .mediaAsset(image.id)
            } else if item.clipIDs.count == 1, let clipID = item.clipIDs.first {
                editor.inspectedObject = .clip(clipID)
            } else {
                editor.inspectedObject = nil
            }
            guard await waitUntil(timeout: .seconds(5), {
                host.layoutSubtreeIfNeeded()
                return visiblePanelIDs(in: host) == expectedPanels(for: .edit)
                    && editor.selectedClipIds == item.clipIDs
                    && (item.family != "asset" || editor.inspectedObject == .mediaAsset(image.id))
            }) else {
                fail("inspector \(item.family) did not settle", scale: scale)
            }
            if let tab = item.tab {
                let identifier = "inspector.tab.\(tab)"
                if probeState(identifier: identifier, in: window) != true {
                    guard click(identifier: identifier, in: window) == nil,
                          await waitUntil(timeout: .seconds(5), {
                              host.layoutSubtreeIfNeeded()
                              return probeState(identifier: identifier, in: window) == true
                          }) else {
                        fail("inspector tab \(tab) did not activate", scale: scale)
                    }
                }
            }
            let capturesKeyframes = item.family == "video" || item.family == "audio"
            if capturesKeyframes, probeState(identifier: "inspector.keyframes", in: window) != false {
                guard click(identifier: "inspector.keyframes", in: window) == nil,
                      await waitUntil(timeout: .seconds(5), {
                          host.layoutSubtreeIfNeeded()
                          return probeState(identifier: "inspector.keyframes", in: window) == false
                      }) else {
                    fail("inspector \(item.family) keyframes did not close", scale: scale)
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let name = "scale-\(scaleLabel(scale))-inspector-\(item.family).png"
            guard snapshot(host, at: evidenceURL.appendingPathComponent(name)) else {
                fail("could not capture inspector \(item.family)", scale: scale)
            }
            var fields: [String: Any] = ["family": item.family, "screenshot": name]
            if capturesKeyframes { fields["keyframes"] = "closed" }
            emit("inspector", scale: scale, fields: fields)
            if capturesKeyframes {
                guard click(identifier: "inspector.keyframes", in: window) == nil,
                      await waitUntil(timeout: .seconds(5), {
                          host.layoutSubtreeIfNeeded()
                          return probeState(identifier: "inspector.keyframes", in: window) == true
                      }) else {
                    fail("inspector \(item.family) keyframes did not open", scale: scale)
                }
                let expectedLaneProperties: [AnimatableProperty] = item.family == "audio"
                    ? [.volume]
                    : [.position, .scale, .rotation, .opacity, .crop]
                guard let root = window.contentView else {
                    fail("inspector \(item.family) window content was unavailable", scale: scale)
                }
                let openName = "scale-\(scaleLabel(scale))-inspector-\(item.family)-keyframes-open.png"
                let sideEvidence = await captureKeyframeLayoutEvidence(
                    family: item.family,
                    properties: expectedLaneProperties,
                    window: window,
                    host: host,
                    evidenceURL: evidenceURL,
                    screenshotName: openName,
                    inspectorWidthTarget: nil,
                    scale: scale
                )
                guard let splitState = inspectorSplitState(in: root),
                      let originalInspectorFrame = visiblePanelFrames(in: host)["inspectorPanel"] else {
                    fail("inspector \(item.family) split geometry was unavailable", scale: scale)
                }
                splitState.splitView.setPosition(
                    splitState.splitView.bounds.maxX - AppTheme.Layout.inspectorMin,
                    ofDividerAt: splitState.dividerIndex
                )
                guard await waitUntil(timeout: .seconds(5), {
                    host.layoutSubtreeIfNeeded()
                    guard let frame = visiblePanelFrames(in: host)["inspectorPanel"] else {
                        return false
                    }
                    return abs(frame.width - AppTheme.Layout.inspectorMin)
                        <= AppTheme.BorderWidth.thin
                }) else {
                    fail("inspector \(item.family) did not reach minimum width", scale: scale)
                }
                let stackedName = "scale-\(scaleLabel(scale))-inspector-\(item.family)-keyframes-open-stacked.png"
                let stackedEvidence = await captureKeyframeLayoutEvidence(
                    family: item.family,
                    properties: expectedLaneProperties,
                    window: window,
                    host: host,
                    evidenceURL: evidenceURL,
                    screenshotName: stackedName,
                    inspectorWidthTarget: AppTheme.Layout.inspectorMin,
                    scale: scale
                )
                splitState.splitView.setPosition(
                    splitState.originalPosition,
                    ofDividerAt: splitState.dividerIndex
                )
                guard await waitUntil(timeout: .seconds(5), {
                    host.layoutSubtreeIfNeeded()
                    guard let frame = visiblePanelFrames(in: host)["inspectorPanel"] else {
                        return false
                    }
                    return abs(frame.width - originalInspectorFrame.width)
                        <= AppTheme.BorderWidth.thin
                }) else {
                    fail("inspector \(item.family) width did not restore", scale: scale)
                }
                let layoutEvidence = [sideEvidence, stackedEvidence]
                guard layoutEvidence.compactMap({ $0["mode"] as? String }) == ["side", "stacked"] else {
                    fail("inspector \(item.family) did not exercise both keyframe layouts", scale: scale)
                }
                emit(
                    "inspector",
                    scale: scale,
                    fields: [
                        "family": item.family,
                        "keyframes": "open",
                        "laneLayoutEvidence": layoutEvidence,
                        "screenshot": openName,
                    ]
                )
                guard click(identifier: "inspector.keyframes", in: window) == nil,
                      await waitUntil(timeout: .seconds(5), {
                          host.layoutSubtreeIfNeeded()
                          return probeState(identifier: "inspector.keyframes", in: window) == false
                      }) else {
                    fail("inspector \(item.family) keyframes did not close again", scale: scale)
                }
            }
        }
        let captionIdentifier = "media.tab.Captions"
        if probeState(identifier: captionIdentifier, in: window) != true {
            guard click(identifier: captionIdentifier, in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.mediaPanelTab(for: .edit) == .captions
                          && probeState(identifier: captionIdentifier, in: window) == true
                  }) else {
                fail("caption form did not activate", scale: scale)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let captionName = "scale-\(scaleLabel(scale))-inspector-caption.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(captionName)) else {
            fail("could not capture caption form", scale: scale)
        }
        emit("inspector", scale: scale, fields: ["family": "caption", "screenshot": captionName])
        editor.setMediaPanelTab(originalMediaTab, for: .edit)
        editor.selectedClipIds = originalClipIDs
        editor.inspectedObject = originalObject
        editor.mediaAssets = originalAssets
    }

    private static func captureProductionNavigationCases(
        editor: EditorViewModel,
        window: NSWindow,
        host: NSView,
        evidenceURL: URL,
        scale: Double
    ) async {
        guard await waitUntil(timeout: .seconds(5), {
            host.layoutSubtreeIfNeeded()
            return editor.workspaceFocus == .production
                && editor.projectState?.nextPhaseName == "frames"
                && probeState(identifier: "production.phase.frames", in: window) != nil
        }) else {
            fail("production navigation fixture did not load", scale: scale)
        }

        let destinations = [
            (phase: "brief", artifact: "brief"),
            (phase: "treatment", artifact: "treatment"),
            (phase: "frames", artifact: "frames"),
            (phase: "render", artifact: "render"),
        ]
        for destination in destinations {
            let phaseID = "production.phase.\(destination.phase)"
            guard clickRevealing(identifier: phaseID, in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      let artifactID = probeValue(
                          identifier: "production.artifact.\(destination.artifact)",
                          in: window
                      )
                      return editor.workspaceFocus == .production
                          && editor.viewedPipelinePhaseID == destination.phase
                          && probeState(identifier: phaseID, in: window) == true
                          && validProductionArtifactID(
                              artifactID,
                              phase: destination.phase,
                              project: editor.projectState?.project
                          )
                  }) else {
                fail("production phase did not open \(destination.artifact)", scale: scale)
            }
            guard let artifactID = probeValue(
                identifier: "production.artifact.\(destination.artifact)",
                in: window
            ) else {
                fail("production artifact identity was unavailable for \(destination.artifact)", scale: scale)
            }
            let name = "scale-\(scaleLabel(scale))-production-\(destination.artifact).png"
            guard snapshot(host, at: evidenceURL.appendingPathComponent(name)) else {
                fail("could not capture production \(destination.artifact)", scale: scale)
            }
            emit(
                "production-surface",
                scale: scale,
                fields: [
                    "artifact": destination.artifact,
                    "artifactID": artifactID,
                    "focusedWorkspace": editor.workspaceFocus.rawValue,
                    "phase": destination.phase,
                    "screenshot": name,
                ]
            )
        }

        guard probeValue(identifier: "production.dock.open", in: window) == "frames",
              click(identifier: "production.dock.open", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return editor.viewedPipelinePhaseID == "frames"
                      && probeState(
                          identifier: "production.surface.frames",
                          in: window
                      ) == true
                      && probeState(identifier: "production.dock.approve", in: window) == false
              }), let dockRequirement = probeValue(
                  identifier: "production.dock.approve",
                  in: window
              ), dockRequirement.contains("Frames"),
              !dockRequirement.contains("/"),
              !dockRequirement.contains("write_") else {
            fail("phase dock did not expose its current blocked artifact", scale: scale)
        }
        let dockName = "scale-\(scaleLabel(scale))-production-dock-blocked.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(dockName)) else {
            fail("could not capture blocked production dock", scale: scale)
        }
        emit(
            "production-dock",
            scale: scale,
            fields: [
                "approvalEnabled": false,
                "requirement": dockRequirement,
                "screenshot": dockName,
            ]
        )

        guard click(identifier: "production.settings", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return editor.cockpitTab == .project
                      && probeState(identifier: "production.settings", in: window) == true
                      && probeValue(identifier: "production.budget.status", in: window) != nil
              }), let budget = probeValue(identifier: "production.budget.status", in: window) else {
            fail("project spend status was not reachable from production", scale: scale)
        }
        let budgetName = "scale-\(scaleLabel(scale))-production-budget.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(budgetName)) else {
            fail("could not capture project spend status", scale: scale)
        }
        emit(
            "production-budget",
            scale: scale,
            fields: ["status": budget, "screenshot": budgetName]
        )
        guard click(identifier: "production.settings.back", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return editor.cockpitTab == .pipeline
                      && probeState(identifier: "production.phase.frames", in: window) == true
              }) else {
            fail("production settings did not return to the selected phase", scale: scale)
        }

        guard clickRevealing(identifier: "production.phase.brief", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return editor.viewedPipelinePhaseID == "brief"
                      && probeState(identifier: "production.phase.brief.actions", in: window) == true
              }), click(identifier: "production.phase.brief.actions", in: window) == nil else {
            fail("approved Brief gate menu was unavailable", scale: scale)
        }
        try? await Task.sleep(for: .milliseconds(200))
        pressKey(keyCode: 125, characters: "\u{f701}")
        pressKey(keyCode: 125, characters: "\u{f701}")
        pressKey(keyCode: 36, characters: "\r")
        guard await waitUntil(timeout: .seconds(5), {
            host.layoutSubtreeIfNeeded()
            return probeValue(identifier: "production.rewind.confirmation", in: window) == "brief"
        }) else {
            fail("Brief rewind did not present its consequences", scale: scale)
        }
        let rewindName = "scale-\(scaleLabel(scale))-production-rewind.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(rewindName)) else {
            fail("could not capture rewind consequences", scale: scale)
        }
        guard let home = editor.workingRoot,
              let root = DataRootResolver.dataRoot(of: home),
              let rewindLease = editor.pipelinePhaseRunCoordinator.beginMutation(
                  projectRoot: root,
                  label: "Acceptance readiness transition"
              ) else {
            fail("rewind readiness transition could not start", scale: scale)
        }
        guard await waitUntil(timeout: .seconds(5), {
            probeValue(identifier: "production.rewind.confirmation", in: window) == nil
                && editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root)
                    == "Acceptance readiness transition"
        }) else {
            editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: rewindLease)
            fail("rewind confirmation remained open after editing became unavailable", scale: scale)
        }
        editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: rewindLease)
        emit(
            "production-rewind",
            scale: scale,
            fields: [
                "closedOnReadinessChange": true,
                "phase": "brief",
                "screenshot": rewindName,
            ]
        )
        guard await waitUntil(timeout: .seconds(5), {
            editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
        }) else {
            fail("rewind readiness transition did not settle", scale: scale)
        }
        guard clickRevealing(identifier: "production.phase.frames", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return editor.viewedPipelinePhaseID == "frames"
                      && probeState(identifier: "production.surface.frames", in: window) == true
                      && nativeControlState(
                          identifier: "production.frames.redo.acceptance-shot.acceptance-01-start.png",
                          in: window
                      ) == .enabled
              }), clickControlRevealing(
                  identifier: "production.frames.redo.acceptance-shot.acceptance-01-start.png",
                  in: window
              ) == nil,
              await waitUntil(timeout: .seconds(5), {
                  probeState(identifier: "production.frames.redo-open", in: window) == true
              }) else {
            fail("the real Frames mutation popover was unavailable before the phase run", scale: scale)
        }
        guard let lockedProjectURL = editor.projectURL,
              let beforeLockedProject = try? projectSnapshot(at: lockedProjectURL),
              let beforeLockedWorkingCopy = try? treeSnapshot(at: home) else {
            fail("read-only production snapshots were unavailable", scale: scale)
        }
        let beforeLockedMessages = editor.agentService.messages
        let beforeLockedCanUndo = window.undoManager?.canUndo ?? false
        let beforeLockedUndoName = window.undoManager?.undoActionName ?? ""
        let runnerGate = DispatchSemaphore(value: 0)
        let running = Task { @MainActor in
            await editor.pipelinePhaseRunCoordinator.run(
                projectRoot: root,
                phase: "frames",
                sourceFilename: nil,
                runner: { _ in runnerGate.wait() },
                progressRunner: nil,
                state: editor.pipelinePhaseExecution
            )
        }
        guard await waitUntil(timeout: .seconds(5), {
            editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == "frames"
                && probeState(identifier: "production.frames.redo-open", in: window) == false
        }), clickRevealing(identifier: "production.phase.frames", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return editor.viewedPipelinePhaseID == "frames"
                      && nativeControlState(
                          identifier: "production.frames.use.acceptance-shot.acceptance-01-start.png",
                          in: window
                      ) == .disabled
                      && nativeControlState(
                          identifier: "production.phase.frames.actions.control",
                          in: window
                      ) == .disabled
              }) else {
            runnerGate.signal()
            _ = await running.value
            fail("real Frames mutation controls were not disabled during a phase run", scale: scale)
        }
        guard clickControlRevealing(
            identifier: "production.frames.use.acceptance-shot.acceptance-01-start.png",
            in: window
        ) == nil,
        clickControl(
            identifier: "production.phase.frames.actions.control",
            in: window
        ) == nil,
        clickControlRevealing(
            identifier: "production.frames.inspect.acceptance-shot",
            in: window
        ) == nil,
        await waitUntil(timeout: .seconds(5), {
            editor.inspectedObject == .shot("acceptance-shot")
        }), scrollControlToVisible(
            identifier: "production.frames.candidate.acceptance-shot.acceptance-03-option.png",
            in: window
        ) else {
            runnerGate.signal()
            _ = await running.value
            fail("read-only Frames inspection was not usable during the phase run", scale: scale)
        }
        guard clickRevealing(identifier: "production.phase.render", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return editor.viewedPipelinePhaseID == "render"
                      && validProductionArtifactID(
                          probeValue(identifier: "production.artifact.render", in: window),
                          phase: "render",
                          project: editor.projectState?.project
                      )
                      && nativeControlState(
                          identifier: "production.render.review-takes",
                          in: window
                      ) == .enabled
              }), clickControlRevealing(
                  identifier: "production.render.review-takes",
                  in: window
              ) == nil,
              await waitUntil(timeout: .seconds(5), {
                  window.attachedSheet.flatMap {
                      findAccessibilityElement(identifier: "production.render.take-picker", in: $0)
                  } != nil
              }), let reviewWindow = window.attachedSheet,
              nativeControlState(
                  identifier: "production.render.take-picker",
                  in: reviewWindow
              ) == .enabled,
              clickControl(identifier: "production.render.take-picker", in: reviewWindow) == nil else {
            runnerGate.signal()
            _ = await running.value
            fail("the recorded Render take was not inspectable during the phase run", scale: scale)
        }
        try? await Task.sleep(for: .milliseconds(200))
        pressKey(keyCode: 125, characters: "\u{f701}")
        pressKey(keyCode: 36, characters: "\r")
        guard await waitUntil(timeout: .seconds(5), {
            findAccessibilityElement(identifier: "production.render.player", in: reviewWindow) != nil
                && Double(probeValue(identifier: "production.render.playback-seconds", in: reviewWindow) ?? "") != nil
        }), scrollControlToVisible(
            identifier: "production.render.use-take",
            in: reviewWindow
        ), nativeControlState(
            identifier: "production.render.use-take",
            in: reviewWindow
        ) == .disabled, clickControl(
            identifier: "production.render.use-take",
            in: reviewWindow
        ) == nil, scrollControlToVisible(
            identifier: "production.render.record-pass",
            in: reviewWindow
        ), nativeControlState(
            identifier: "production.render.record-pass",
            in: reviewWindow
        ) == .disabled, clickControl(
            identifier: "production.render.record-pass",
            in: reviewWindow
        ) == nil, clickControlRevealing(
            identifier: "production.render.references",
            in: reviewWindow
        ) == nil,
        await waitUntil(timeout: .seconds(5), {
            guard let content = reviewWindow.contentView else { return false }
            return findProbe(
                in: content,
                identifier: "production.render.references.content"
            ) != nil
        }) else {
            runnerGate.signal()
            _ = await running.value
            fail("the recorded Render take did not expose its player and references", scale: scale)
        }
        guard let initialPlayback = Double(probeValue(
            identifier: "production.render.playback-seconds",
            in: reviewWindow
        ) ?? ""), scrollControlToVisible(
            identifier: "production.render.play-take",
            in: reviewWindow
        ), nativeControlState(
            identifier: "production.render.play-take",
            in: reviewWindow
        ) == .enabled, clickControl(
            identifier: "production.render.play-take",
            in: reviewWindow
        ) == nil else {
            runnerGate.signal()
            _ = await running.value
            fail("the recorded Render Play control was unavailable", scale: scale)
        }
        guard await waitUntil(timeout: .seconds(5), {
            guard let current = Double(probeValue(
                identifier: "production.render.playback-seconds",
                in: reviewWindow
            ) ?? "") else { return false }
            return current > initialPlayback + 0.15
        }) else {
            runnerGate.signal()
            _ = await running.value
            fail("the recorded Render player did not advance after Play", scale: scale)
        }
        let firstRefresh = Task { @MainActor in await editor.refreshEngineState() }
        let secondRefresh = Task { @MainActor in await editor.refreshEngineState() }
        var playerRetainedDuringReload = true
        for _ in 0..<250 {
            if findAccessibilityElement(identifier: "production.render.player", in: reviewWindow) == nil {
                playerRetainedDuringReload = false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await firstRefresh.value
        await secondRefresh.value
        guard playerRetainedDuringReload,
              findAccessibilityElement(identifier: "production.render.player", in: reviewWindow) != nil,
              findAccessibilityElement(identifier: "production.render.take-picker", in: reviewWindow) != nil else {
            runnerGate.signal()
            _ = await running.value
            fail("the selected Render take disappeared during concurrent real-store refreshes", scale: scale)
        }
        emit("production-take-reload", scale: scale, fields: [
            "playerRetained": true,
            "realStoreRefreshes": 2,
        ])
        let readOnlyName = "scale-\(scaleLabel(scale))-production-read-only.png"
        guard let reviewContent = reviewWindow.contentView,
              snapshot(reviewContent, at: evidenceURL.appendingPathComponent(readOnlyName)) else {
            runnerGate.signal()
            _ = await running.value
            fail("could not capture running-phase read-only browsing", scale: scale)
        }
        emit(
            "production-read-only",
            scale: scale,
            fields: [
                "inspectedPhase": "frames,render",
                "mutationsDisabled": true,
                "nativeInspectionWorked": true,
                "playerAdvancedAfterNativeInput": true,
                "popoverClosedOnReadinessChange": true,
                "runningPhase": "frames",
                "screenshot": readOnlyName,
            ]
        )
        guard clickControlRevealing(
            identifier: "production.render.review-close",
            in: reviewWindow
        ) == nil,
        await waitUntil(timeout: .seconds(5), { window.attachedSheet == nil }),
        (try? projectSnapshot(at: lockedProjectURL)) == beforeLockedProject,
        (try? treeSnapshot(at: home)) == beforeLockedWorkingCopy,
        editor.agentService.messages == beforeLockedMessages,
        (window.undoManager?.canUndo ?? false) == beforeLockedCanUndo,
        (window.undoManager?.undoActionName ?? "") == beforeLockedUndoName else {
            runnerGate.signal()
            _ = await running.value
            fail("blocked production controls changed project, transcript, or undo state", scale: scale)
        }
        runnerGate.signal()
        let outcome = await running.value
        guard outcome == .completed else {
            fail("acceptance phase coordinator did not settle", scale: scale)
        }

        do {
            let store = YAMLArtifactStore(dataRoot: root)
            var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
            GatesOperations.approve(&gates, phase: "frames")
            try store.save(gates, to: PipelineLayout.gatesFile)
        } catch {
            fail("could not advance the acceptance fixture to Render: \(error.localizedDescription)", scale: scale)
        }
        await editor.refreshEngineState()
        guard await waitUntil(timeout: .seconds(5), {
            editor.projectState?.nextPhaseName == "render"
        }), clickRevealing(identifier: "production.phase.render", in: window) == nil,
        await waitUntil(timeout: .seconds(5), {
            validProductionArtifactID(
                probeValue(identifier: "production.artifact.render", in: window),
                phase: "render", project: editor.projectState?.project
            ) && nativeControlState(
                identifier: "production.render.review-takes", in: window
            ) == .enabled
        }), clickControlRevealing(
            identifier: "production.render.review-takes", in: window
        ) == nil,
        await waitUntil(timeout: .seconds(5), {
            window.attachedSheet.flatMap {
                findAccessibilityElement(identifier: "production.render.take-picker", in: $0)
            } != nil
        }), let writableWindow = window.attachedSheet,
        clickControl(identifier: "production.render.take-picker", in: writableWindow) == nil else {
            fail("the current Render take was not available for the running-lock check", scale: scale)
        }
        try? await Task.sleep(for: .milliseconds(200))
        pressKey(keyCode: 125, characters: "\u{f701}")
        pressKey(keyCode: 36, characters: "\r")
        guard await waitUntil(timeout: .seconds(5), {
            scrollControlToVisible(identifier: "production.render.observation", in: writableWindow)
                && nativeControlState(identifier: "production.render.observation", in: writableWindow) == .enabled
                && nativeControlState(identifier: "production.render.finding", in: writableWindow) == .enabled
                && probeValue(identifier: "production.render.findings-count", in: writableWindow) == "0"
        }), clickControl(identifier: "production.render.observation", in: writableWindow) == nil else {
            fail("the current Render observation was not natively editable before the run", scale: scale)
        }
        pressKey(keyCode: 7, characters: "x")
        guard await waitUntil(timeout: .seconds(5), {
            nativeControlValue(identifier: "production.render.observation", in: writableWindow) == "x"
        }), let renderProjectBefore = try? projectSnapshot(at: lockedProjectURL),
        let renderWorkingCopyBefore = try? treeSnapshot(at: home) else {
            fail("the current Render observation did not accept native input", scale: scale)
        }
        let renderMessagesBefore = editor.agentService.messages
        let renderCanUndoBefore = window.undoManager?.canUndo ?? false
        let renderUndoNameBefore = window.undoManager?.undoActionName ?? ""
        let renderGate = DispatchSemaphore(value: 0)
        let renderRun = Task { @MainActor in
            await editor.pipelinePhaseRunCoordinator.run(
                projectRoot: root,
                phase: "render",
                sourceFilename: nil,
                runner: { _ in renderGate.wait() },
                progressRunner: nil,
                state: editor.pipelinePhaseExecution
            )
        }
        guard await waitUntil(timeout: .seconds(5), {
            editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == "render"
                && scrollControlToVisible(identifier: "production.render.observation", in: writableWindow)
                && nativeControlState(identifier: "production.render.observation", in: writableWindow) == .disabled
                && nativeControlState(identifier: "production.render.finding", in: writableWindow) == .disabled
                && nativeControlValue(identifier: "production.render.observation", in: writableWindow) == "x"
        }), clickControl(identifier: "production.render.observation", in: writableWindow) == nil else {
            renderGate.signal()
            _ = await renderRun.value
            fail("the Render observation did not lock during its phase run", scale: scale)
        }
        pressKey(keyCode: 16, characters: "y")
        try? await Task.sleep(for: .milliseconds(200))
        guard nativeControlValue(identifier: "production.render.observation", in: writableWindow) == "x",
              probeValue(identifier: "production.render.findings-count", in: writableWindow) == "0",
              (try? projectSnapshot(at: lockedProjectURL)) == renderProjectBefore,
              (try? treeSnapshot(at: home)) == renderWorkingCopyBefore,
              editor.agentService.messages == renderMessagesBefore,
              (window.undoManager?.canUndo ?? false) == renderCanUndoBefore,
              (window.undoManager?.undoActionName ?? "") == renderUndoNameBefore else {
            renderGate.signal()
            _ = await renderRun.value
            fail("the locked Render observation changed review or project state", scale: scale)
        }
        emit("production-render-running-lock", scale: scale, fields: [
            "editableBeforeRun": true,
            "observationDisabledDuringRun": true,
            "nativeEditIgnored": true,
            "findingsUnchanged": true,
            "projectAndUndoUnchanged": true,
        ])
        guard clickControlRevealing(
            identifier: "production.render.review-close", in: writableWindow
        ) == nil,
        await waitUntil(timeout: .seconds(5), { window.attachedSheet == nil }) else {
            renderGate.signal()
            _ = await renderRun.value
            fail("the locked Render review sheet did not close", scale: scale)
        }
        renderGate.signal()
        let renderOutcome = await renderRun.value
        guard renderOutcome == .completed else {
            fail("acceptance Render coordinator did not settle", scale: scale)
        }
    }

    private static func makeProjectFixture(scale: Double) async throws -> URL {
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
        var timeline = Timeline()
        if inspectorRequested {
            var textClip = Clip(mediaRef: "inspector-title", startFrame: 0, durationFrames: 90)
            textClip.id = "inspector-text"
            textClip.mediaType = .text
            textClip.sourceClipType = .text
            textClip.textContent = "Inspector title"

            var firstImage = Clip(mediaRef: "inspector-image", startFrame: 100, durationFrames: 90)
            firstImage.id = "inspector-image-1"
            firstImage.mediaType = .image
            firstImage.sourceClipType = .image

            var secondImage = Clip(mediaRef: "inspector-image", startFrame: 200, durationFrames: 90)
            secondImage.id = "inspector-image-2"
            secondImage.mediaType = .image
            secondImage.sourceClipType = .image
            secondImage.speed = 1.5
            secondImage.transform.centerX = 0.6
            secondImage.transform.rotation = 30
            secondImage.opacity = 0.5

            var audioClip = Clip(mediaRef: "inspector-audio", startFrame: 0, durationFrames: 290)
            audioClip.id = "inspector-audio-clip"
            audioClip.mediaType = .audio
            audioClip.sourceClipType = .audio

            timeline.tracks = [
                Track(type: .text, clips: [textClip]),
                Track(type: .image, clips: [firstImage, secondImage]),
                Track(type: .audio, clips: [audioClip]),
            ]
        }
        try JSONEncoder().encode(timeline).write(
            to: projectURL.appendingPathComponent(Project.timelineFilename),
            options: .atomic
        )
        try JSONEncoder().encode(MediaManifest()).write(
            to: projectURL.appendingPathComponent(Project.manifestFilename),
            options: .atomic
        )
        var generationLog = GenerationLog()
        generationLog.entries = [
            GenerationLogEntry(
                id: "workspace-ui-legacy-generation",
                model: "fixture-model",
                costCredits: nil,
                createdAt: Date(timeIntervalSince1970: 1_750_000_000)
            ),
        ]
        try JSONEncoder().encode(generationLog).write(
            to: projectURL.appendingPathComponent(Project.generationLogFilename),
            options: .atomic
        )
        _ = try ProjectIdentity.uuid(for: projectURL)
        let dataRoot = try ProjectScaffold.initProject(
            home: projectURL,
            name: title,
            mode: .beat,
            budgetEur: 125
        )
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        try store.save(
            Brief(
                project: title,
                generated: "2026-09-24",
                mission: .demo,
                targetPlatform: "screening",
                aspectRatio: .landscape16x9,
                projectMode: "beat",
                budgetEur: 125,
                budgetStopEur: 150,
                conceptType: .abstract,
                visualMedium: .liveActionRealistic,
                figures: .none,
                lyricsIntegration: .ignored
            ),
            to: PipelineLayout.briefFile
        )
        try TreatmentStore.save(
            Treatment(
                meta: try TreatmentMeta(
                    project: title,
                    version: 1,
                    generated: "2026-09-24T00:00:00Z",
                    origin: .agentProposal,
                    generator: "workspace-ui-acceptance",
                    summaryOneline: "Acceptance treatment"
                ),
                bodyMarkdown: "Acceptance treatment artifact."
            ),
            to: dataRoot
        )
        try prepareFramesFixture(project: title, dataRoot: dataRoot)
        try await prepareRenderTakeFixture(
            project: title,
            projectURL: projectURL,
            dataRoot: dataRoot
        )
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&gates, phase: "project_init")
        GatesOperations.approve(&gates, phase: "brief")
        GatesOperations.approve(&gates, phase: "production_design")
        GatesOperations.approve(&gates, phase: "treatment")
        GatesOperations.approve(&gates, phase: "storyboard")
        GatesOperations.approve(&gates, phase: "bible")
        GatesOperations.approve(&gates, phase: "shotlist")
        GatesOperations.approve(&gates, phase: "sanity")
        try store.save(gates, to: PipelineLayout.gatesFile)
        return projectURL
    }

    private static func prepareFramesFixture(project: String, dataRoot: URL) throws {
        let shotID = "acceptance-shot"
        let names = [
            "acceptance-01-start.png",
            "acceptance-02-option.png",
            "acceptance-03-option.png",
        ]
        let colors: [(UInt8, UInt8, UInt8)] = [
            (36, 92, 168),
            (168, 72, 52),
            (74, 148, 88),
        ]
        let directory = dataRoot
            .appendingPathComponent(PipelineLayout.framesDir, isDirectory: true)
            .appendingPathComponent(shotID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for (name, color) in zip(names, colors) {
            try fixturePNG(red: color.0, green: color.1, blue: color.2)
                .write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        let framePath = "\(PipelineLayout.framesDir)/\(shotID)/\(names[0])"
        var render = RenderManifest(project: project, phase: "frames")
        record(
            &render,
            shotId: shotID,
            output: framePath,
            costEur: 0,
            phase: "frames",
            updatedAt: "2026-09-24T00:00:00Z"
        )
        let frames = FramesManifest(
            project: project,
            generated: "2026-09-24T00:00:00Z",
            shots: [
                ShotFrames(
                    shotId: shotID,
                    keyframeStrategy: "start",
                    frames: [
                        FrameEntry(
                            role: "start",
                            path: framePath,
                            prompt: "Acceptance frame",
                            runwayModel: "fixture-model",
                            providerPrompt: "Deterministic local acceptance frame."
                        ),
                    ]
                ),
            ]
        )
        _ = try PipelineRenderRecordWriter.publish(
            manifest: render,
            proof: nil,
            routingProof: nil,
            framesManifest: frames,
            replacingShotID: shotID,
            preparedLastFrame: nil,
            expectedPublicationTransactionID: nil,
            dataRoot: dataRoot
        )
    }

    private static func prepareRenderTakeFixture(
        project: String,
        projectURL: URL,
        dataRoot: URL
    ) async throws {
        let shotID = "acceptance-render-shot"
        let outputPath = "media/acceptance-render-take.mp4"
        let outputURL = projectURL.appendingPathComponent(outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await writeFixtureVideo(to: outputURL)
        let output = RenderPublishedArtifactV1(
            path: outputPath,
            sha256: try FileDigest.sha256(of: outputURL)
        )
        var manifest = RenderManifest(project: project, phase: "final")
        record(
            &manifest,
            shotId: shotID,
            output: outputPath,
            costEur: 0,
            phase: "final",
            updatedAt: "2026-09-24T00:00:00Z"
        )
        try saveRenderManifest(manifest, dataRoot: dataRoot)
        guard let entry = manifest.entries[shotID] else {
            throw CocoaError(.fileWriteUnknown)
        }
        var input = GenerationInput(
            prompt: "A deterministic local acceptance take.",
            model: "fixture-model",
            duration: 1,
            aspectRatio: "16:9"
        )
        input.promptShotId = shotID
        input.promptShotFingerprint = String(repeating: "a", count: 64)
        input.createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        let proof = RenderShotProvenanceProofV1(
            project: project,
            phase: "final",
            shotID: shotID,
            renderEntry: entry,
            renderProofEntry: RenderProofEntry(
                shotId: shotID,
                output: outputPath,
                outputSha256: output.sha256,
                providerPrompt: input.prompt,
                generationModel: input.model
            ),
            routingProofEntry: nil,
            frames: nil,
            lastFrame: nil,
            outputs: [output]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let proofBytes = try encoder.encode(proof)
        let proofPath = "renders/provenance/acceptance-render-shot.v1.json"
        let proofURL = dataRoot.appendingPathComponent(proofPath)
        try FileManager.default.createDirectory(
            at: proofURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try proofBytes.write(to: proofURL, options: .atomic)
        let prepared = try PipelineRenderTakeStore.prepare(
            completed: .init(
                eventID: "workspace-ui-acceptance-render",
                generationInput: input
            ),
            provenance: RenderPublishedArtifactV1(
                path: proofPath,
                sha256: FileDigest.sha256(of: proofBytes)
            ),
            shotProof: proof,
            manifest: manifest,
            shotID: shotID,
            dataRoot: dataRoot
        )
        for file in prepared.files {
            let url = dataRoot.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.data.write(to: url, options: .atomic)
        }
    }

    private static func fixturePNG(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let bytes = bitmap.bitmapData else {
            throw CocoaError(.fileWriteUnknown)
        }
        for pixel in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh / 4) {
            let offset = pixel * 4
            bytes[offset] = red
            bytes[offset + 1] = green
            bytes[offset + 2] = blue
            bytes[offset + 3] = UInt8.max
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func writeFixtureVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 180,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let buffer = adaptor.pixelBufferPool.flatMap({ pool -> CVPixelBuffer? in
                var value: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &value)
                return value
            }) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, frame < 6 ? 48 : 112, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12)
            ) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
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
        defaults.set(false, forKey: "keyframesPanelVisible")
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

    private static func productionLayoutEvidence(
        in window: NSWindow,
        frames: [String: NSRect]
    ) -> [String: Any]? {
        guard let project = frames["projectPanel"],
              probeValue(identifier: "production.layout.navigation", in: window) == "compact",
              probeValue(identifier: "production.layout.dock", in: window) == "compact",
              let navigation = visibleProbeFrame(
                  identifier: "production.layout.navigation",
                  in: window
              ),
              let artifact = visibleProbeFrame(
                  identifier: "production.layout.artifact",
                  in: window
              ),
              let dock = visibleProbeFrame(
                  identifier: "production.layout.dock",
                  in: window
              ),
              let open = visibleProbeFrame(
                  identifier: "production.dock.open",
                  in: window
              ),
              let approve = visibleProbeFrame(
                  identifier: "production.dock.approve",
                  in: window
              ) else { return nil }
        let bounds = project.insetBy(
            dx: -AppTheme.BorderWidth.thin,
            dy: -AppTheme.BorderWidth.thin
        )
        let dockBounds = dock.insetBy(
            dx: -AppTheme.BorderWidth.thin,
            dy: -AppTheme.BorderWidth.thin
        )
        guard bounds.contains(navigation),
              bounds.contains(artifact),
              bounds.contains(dock),
              artifact.width >= AppTheme.ComponentSize.productionArtifactMinWidth,
              dockBounds.contains(open),
              dockBounds.contains(approve) else { return nil }
        return [
            "approveFrame": frameDescription(approve),
            "artifactFrame": frameDescription(artifact),
            "artifactMinimumWidth": Double(AppTheme.ComponentSize.productionArtifactMinWidth),
            "dockFrame": frameDescription(dock),
            "mode": "compact",
            "navigationFrame": frameDescription(navigation),
            "openFrame": frameDescription(open),
            "projectFrame": frameDescription(project),
        ]
    }

    private static func visibleProbeFrame(
        identifier: String,
        in window: NSWindow
    ) -> NSRect? {
        guard let root = window.contentView else { return nil }
        return probes(in: root, identifier: identifier).compactMap { probe in
            let frame = probe.convert(probe.bounds, to: root)
            guard probe.window === window,
                  !probe.isHiddenOrHasHiddenAncestor,
                  frame.width > 0,
                  frame.height > 0 else { return nil }
            return frame
        }.first
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

    private struct InspectorSplitState {
        let splitView: NSSplitView
        let dividerIndex: Int
        let originalPosition: CGFloat
    }

    private static func inspectorSplitState(in root: NSView) -> InspectorSplitState? {
        guard var child = findView(in: root, accessibilityIdentifier: "inspectorPanel") else {
            return nil
        }
        while let parent = child.superview {
            if let splitView = parent as? NSSplitView,
               splitView.isVertical,
               let index = splitView.subviews.firstIndex(where: { $0 === child }),
               index > 0 {
                return InspectorSplitState(
                    splitView: splitView,
                    dividerIndex: index - 1,
                    originalPosition: splitView.subviews[index - 1].frame.maxX
                )
            }
            child = parent
        }
        return nil
    }

    private static func findView(
        in view: NSView,
        accessibilityIdentifier: String
    ) -> NSView? {
        if view.accessibilityIdentifier() == accessibilityIdentifier,
           view.window != nil,
           !view.isHiddenOrHasHiddenAncestor {
            return view
        }
        for child in view.subviews {
            if let match = findView(in: child, accessibilityIdentifier: accessibilityIdentifier) {
                return match
            }
        }
        return nil
    }

    private static func visibleGeometryProbe(
        identifier: String,
        in window: NSWindow,
        containedBy bounds: NSRect
    ) -> NSView? {
        guard let root = window.contentView else { return nil }
        return probes(in: root, identifier: identifier).first { probe in
            let frame = probe.convert(probe.bounds, to: root)
            return probe.window === window
                && !probe.isHiddenOrHasHiddenAncestor
                && frame.width > 0
                && frame.height > 0
                && frame.minX >= bounds.minX - AppTheme.BorderWidth.thin
                && frame.maxX <= bounds.maxX + AppTheme.BorderWidth.thin
        }
    }

    private static func captureKeyframeLayoutEvidence(
        family: String,
        properties: [AnimatableProperty],
        window: NSWindow,
        host: NSView,
        evidenceURL: URL,
        screenshotName: String,
        inspectorWidthTarget: CGFloat?,
        scale: Double
    ) async -> [String: Any] {
        host.layoutSubtreeIfNeeded()
        guard let root = window.contentView,
              let inspectorFrame = visiblePanelFrames(in: host)["inspectorPanel"],
              let panelProbe = visibleGeometryProbe(
                  identifier: "inspector.keyframes.panel",
                  in: window,
                  containedBy: inspectorFrame
              ),
              let firstProperty = properties.first,
              let firstLabel = visibleGeometryProbe(
                  identifier: "inspector.keyframes.lane.\(firstProperty.rawValue).label",
                  in: window,
                  containedBy: inspectorFrame
              ),
              let scrollView = enclosingScrollView(for: firstLabel),
              let documentView = scrollView.documentView else {
            fail("inspector \(family) keyframe layout geometry was unavailable", scale: scale)
        }
        let originalScrollOrigin = scrollView.contentView.bounds.origin
        let rulerProbe = visibleGeometryProbe(
            identifier: "inspector.keyframes.ruler",
            in: window,
            containedBy: inspectorFrame
        )
        let rulerOverlay = visibleGeometryProbe(
            identifier: "inspector.keyframes.ruler.overlay",
            in: window,
            containedBy: inspectorFrame
        )
        guard let rulerProbe, let rulerOverlay else {
            fail("inspector \(family) ruler geometry was unavailable", scale: scale)
        }
        documentView.scrollToVisible(rulerProbe.convert(rulerProbe.bounds, to: documentView))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        host.layoutSubtreeIfNeeded()
        let rulerFrame = rulerProbe.convert(rulerProbe.bounds, to: root)
        let rulerOverlayFrame = rulerOverlay.convert(rulerOverlay.bounds, to: root)
        let rulerClipFrame = scrollView.contentView.convert(scrollView.contentView.bounds, to: root)
        guard visibleFrame(rulerFrame, inside: rulerClipFrame, and: inspectorFrame),
              matchingFrame(rulerOverlayFrame, rulerFrame) else {
            fail("inspector \(family) ruler overlay was outside its drawing area", scale: scale)
        }

        var laneEvidence: [[String: Any]] = []
        var detectedModes = Set<String>()
        for property in properties {
            let prefix = "inspector.keyframes.lane.\(property.rawValue)"
            guard let label = visibleGeometryProbe(
                identifier: "\(prefix).label",
                in: window,
                containedBy: inspectorFrame
            ), let track = visibleGeometryProbe(
                identifier: "\(prefix).track",
                in: window,
                containedBy: inspectorFrame
            ), let overlay = visibleGeometryProbe(
                identifier: "\(prefix).overlay",
                in: window,
                containedBy: inspectorFrame
            ), enclosingScrollView(for: label) === scrollView,
               enclosingScrollView(for: track) === scrollView,
               enclosingScrollView(for: overlay) === scrollView else {
                fail("inspector \(family) \(property.rawValue) geometry was unavailable", scale: scale)
            }
            let target = label.convert(label.bounds, to: documentView)
                .union(track.convert(track.bounds, to: documentView))
                .union(overlay.convert(overlay.bounds, to: documentView))
            documentView.scrollToVisible(target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            try? await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()

            let clipFrame = scrollView.contentView.convert(scrollView.contentView.bounds, to: root)
            let labelFrame = label.convert(label.bounds, to: root)
            let trackFrame = track.convert(track.bounds, to: root)
            let overlayFrame = overlay.convert(overlay.bounds, to: root)
            let side = labelFrame.maxX + AppTheme.Spacing.sm
                <= trackFrame.minX + AppTheme.BorderWidth.thin
            let stacked = labelFrame.maxY + AppTheme.Spacing.xs
                <= trackFrame.minY + AppTheme.BorderWidth.thin
            guard side != stacked,
                  visibleFrame(labelFrame, inside: clipFrame, and: inspectorFrame),
                  visibleFrame(trackFrame, inside: clipFrame, and: inspectorFrame),
                  visibleFrame(overlayFrame, inside: clipFrame, and: inspectorFrame),
                  matchingFrame(overlayFrame, trackFrame),
                  abs(trackFrame.minX - rulerFrame.minX) <= AppTheme.BorderWidth.thin,
                  abs(trackFrame.maxX - rulerFrame.maxX) <= AppTheme.BorderWidth.thin else {
                fail("inspector \(family) \(property.rawValue) layout geometry was invalid", scale: scale)
            }
            detectedModes.insert(side ? "side" : "stacked")
            laneEvidence.append([
                "clipFrame": frameDescription(clipFrame),
                "labelFrame": frameDescription(labelFrame),
                "overlayFrame": frameDescription(overlayFrame),
                "property": property.rawValue,
                "trackFrame": frameDescription(trackFrame),
                "visible": true,
            ])
        }
        guard detectedModes.count == 1, let mode = detectedModes.first else {
            fail("inspector \(family) keyframe lanes disagreed on layout", scale: scale)
        }
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        guard snapshot(host, at: evidenceURL.appendingPathComponent(screenshotName)) else {
            fail("could not capture inspector \(family) \(mode) keyframes", scale: scale)
        }
        let panelFrame = panelProbe.convert(panelProbe.bounds, to: root)
        scrollView.contentView.scroll(to: originalScrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        host.layoutSubtreeIfNeeded()
        var evidence: [String: Any] = [
            "inspectorFrame": frameDescription(inspectorFrame),
            "laneEvidence": laneEvidence,
            "mode": mode,
            "panelFrame": frameDescription(panelFrame),
            "reachableLaneLabels": properties.map(\.rawValue),
            "rulerFrame": frameDescription(rulerFrame),
            "rulerOverlayFrame": frameDescription(rulerOverlayFrame),
            "screenshot": screenshotName,
        ]
        if let inspectorWidthTarget {
            evidence["inspectorWidthTarget"] = Double(inspectorWidthTarget)
        }
        return evidence
    }

    private static func visibleFrame(
        _ frame: NSRect,
        inside clipFrame: NSRect,
        and inspectorFrame: NSRect
    ) -> Bool {
        frame.width > 0
            && frame.height > 0
            && clipFrame.insetBy(
                dx: -AppTheme.BorderWidth.thin,
                dy: -AppTheme.BorderWidth.thin
            ).contains(frame)
            && inspectorFrame.insetBy(
                dx: -AppTheme.BorderWidth.thin,
                dy: -AppTheme.BorderWidth.thin
            ).contains(frame)
    }

    private static func matchingFrame(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= AppTheme.BorderWidth.thin
            && abs(lhs.minY - rhs.minY) <= AppTheme.BorderWidth.thin
            && abs(lhs.maxX - rhs.maxX) <= AppTheme.BorderWidth.thin
            && abs(lhs.maxY - rhs.maxY) <= AppTheme.BorderWidth.thin
    }

    private static func enclosingScrollView(for view: NSView) -> NSScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView { return scrollView }
            ancestor = current.superview
        }
        return nil
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
        return postClick(on: probe, in: window)
    }

    private static func clickControl(identifier: String, in window: NSWindow) -> String? {
        postClick(onAccessibilityElement: identifier, in: window, revealing: false)
    }

    private static func clickControlRevealing(
        identifier: String,
        in window: NSWindow
    ) -> String? {
        postClick(onAccessibilityElement: identifier, in: window, revealing: true)
    }

    private static func postClick(on view: NSView, in window: NSWindow) -> String? {
        guard window.isVisible, window.isKeyWindow, !window.ignoresMouseEvents,
              view.window === window,
              !view.isHiddenOrHasHiddenAncestor,
              let root = window.contentView else {
            return "control geometry unavailable"
        }
        let frame = view.bounds
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            return "control has no finite frame"
        }
        let location = view.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        guard root.bounds.contains(root.convert(location, from: nil)) else {
            return "control is outside the window"
        }
        return postClick(at: location, in: window)
    }

    private static func postClick(at location: NSPoint, in window: NSWindow) -> String? {
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

    private static func nativeControlState(
        identifier: String,
        in window: NSWindow
    ) -> NativeControlState? {
        guard let element = findAccessibilityElement(identifier: identifier, in: window),
              visibleAccessibilityFrame(of: element, in: window) != nil else { return nil }
        return element.isAccessibilityEnabled() ? .enabled : .disabled
    }

    private static func nativeControlValue(
        identifier: String,
        in window: NSWindow
    ) -> String? {
        guard let element = findAccessibilityElement(identifier: identifier, in: window),
              visibleAccessibilityFrame(of: element, in: window) != nil else { return nil }
        return element.accessibilityValue() as? String
    }

    private static func scrollControlToVisible(
        identifier: String,
        in window: NSWindow
    ) -> Bool {
        guard let element = findAccessibilityElement(identifier: identifier, in: window) else {
            return false
        }
        revealAccessibilityElement(element, in: window)
        window.contentView?.layoutSubtreeIfNeeded()
        return visibleAccessibilityFrame(of: element, in: window) != nil
    }

    private static func axDescriptor(_ element: any NSAccessibilityProtocol) -> String {
        let role = String(describing: element.accessibilityRole())
        let rawIdentifier = element.accessibilityIdentifier() ?? ""
        let identifier = rawIdentifier.hasPrefix("production.")
            ? String(rawIdentifier.prefix(80))
            : (rawIdentifier.isEmpty ? "-" : "<other>")
        return "\(role):\(identifier)"
    }

    private static func axParentChain(_ element: any NSAccessibilityProtocol) -> [String] {
        var result: [String] = []
        var parent = element.accessibilityParent()
        var visited = Set<ObjectIdentifier>()
        while let accessible = parent as? any NSAccessibilityProtocol, result.count < 8 {
            guard visited.insert(ObjectIdentifier(accessible)).inserted else { break }
            result.append(axDescriptor(accessible))
            parent = accessible.accessibilityParent()
        }
        return result
    }

    private static func emitAXDiagnostic(
        identifier: String,
        in window: NSWindow,
        reason: String,
        matchCount: Int,
        paths: [String]
    ) {
        let key = "\(window.windowNumber):\(identifier):\(reason)"
        guard axDiagnosticKeys.count < 16,
              axDiagnosticKeys.insert(key).inserted,
              let scale = Double(ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_SCALE"] ?? "") else { return }
        emit("ax-diagnostic", scale: scale, fields: [
            "identifier": identifier,
            "reason": reason,
            "matchCount": matchCount,
            "roleIdentifierPaths": Array(paths.prefix(48)),
        ])
    }

    private static func findAccessibilityElement(
        identifier: String,
        in window: NSWindow
    ) -> (any NSAccessibilityProtocol)? {
        guard let root = window.contentView else { return nil }
        var visited = Set<ObjectIdentifier>()
        var matches: [any NSAccessibilityProtocol] = []
        var samples: [String] = []
        func visit(_ element: any NSAccessibilityProtocol, path: [String]) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            let descriptor = axDescriptor(element)
            let currentPath = Array((path + [descriptor]).suffix(8))
            if samples.count < 48,
               (element.accessibilityIdentifier() != nil || samples.count < 8) {
                samples.append(currentPath.joined(separator: " > "))
            }
            if element.isAccessibilityElement(), element.accessibilityIdentifier() == identifier {
                matches.append(element)
            }
            for child in element.accessibilityChildren() ?? [] {
                if let accessible = child as? any NSAccessibilityProtocol {
                    visit(accessible, path: currentPath)
                }
            }
        }
        visit(root, path: [])
        if matches.count != 1 {
            let chains = matches.prefix(2).map { axParentChain($0).joined(separator: " > ") }
            emitAXDiagnostic(
                identifier: identifier, in: window,
                reason: matches.isEmpty ? "missing" : "ambiguous",
                matchCount: matches.count, paths: samples + chains
            )
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func visibleAccessibilityFrame(
        of element: any NSAccessibilityProtocol,
        in window: NSWindow
    ) -> NSRect? {
        let identifier = element.accessibilityIdentifier() ?? "-"
        let path = [axDescriptor(element)] + axParentChain(element)
        guard window.isVisible, window.isKeyWindow, !window.ignoresMouseEvents,
              (element.accessibilityWindow() as? NSWindow) === window,
              let root = window.contentView else {
            emitAXDiagnostic(identifier: identifier, in: window, reason: "window", matchCount: 1, paths: path)
            return nil
        }
        if let view = element as? NSView,
           (view.window !== window || view.isHiddenOrHasHiddenAncestor) { return nil }
        let frame = element.accessibilityFrame()
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else {
            emitAXDiagnostic(identifier: identifier, in: window, reason: "frame", matchCount: 1, paths: path)
            return nil
        }
        var visible = frame.intersection(window.convertToScreen(root.convert(root.bounds, to: nil)))
        var ancestor = element.accessibilityParent()
        var visited = Set<ObjectIdentifier>()
        var nearestView = element as? NSView
        var sawScroll = false
        while let accessible = ancestor as? any NSAccessibilityProtocol {
            guard visited.insert(ObjectIdentifier(accessible)).inserted else { return nil }
            if let view = accessible as? NSView {
                if view.window !== window || view.isHiddenOrHasHiddenAncestor { return nil }
                if nearestView == nil { nearestView = view }
            }
            if let scrollView = accessible as? NSScrollView {
                let clip = scrollView.contentView
                visible = visible.intersection(window.convertToScreen(clip.convert(clip.bounds, to: nil)))
                sawScroll = true
            }
            ancestor = accessible.accessibilityParent()
        }
        if !sawScroll, let nearestView,
           let scrollView = enclosingScrollView(for: nearestView),
           scrollView.window === window {
            let clip = scrollView.contentView
            visible = visible.intersection(window.convertToScreen(clip.convert(clip.bounds, to: nil)))
        }
        guard visible.origin.x.isFinite, visible.origin.y.isFinite,
              visible.width.isFinite, visible.height.isFinite,
              visible.width > 0, visible.height > 0 else {
            emitAXDiagnostic(identifier: identifier, in: window, reason: "clipped", matchCount: 1, paths: path)
            return nil
        }
        return visible
    }

    private static func postClick(
        onAccessibilityElement identifier: String,
        in window: NSWindow,
        revealing: Bool
    ) -> String? {
        guard let element = findAccessibilityElement(identifier: identifier, in: window) else {
            return "native accessibility element unavailable"
        }
        if revealing {
            revealAccessibilityElement(element, in: window)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        guard let frame = visibleAccessibilityFrame(of: element, in: window) else {
            return "native accessibility element is outside the visible window"
        }
        let point = window.convertFromScreen(NSRect(x: frame.midX, y: frame.midY, width: 0, height: 0)).origin
        return postClick(at: point, in: window)
    }

    private static func revealAccessibilityElement(
        _ element: any NSAccessibilityProtocol,
        in window: NSWindow
    ) {
        let screenFrame = element.accessibilityFrame()
        func reveal(in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView,
                  scrollView.window === window else { return }
            let target = documentView.convert(window.convertFromScreen(screenFrame), from: nil)
            documentView.scrollToVisible(target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        var ancestor = element.accessibilityParent()
        var visited = Set<ObjectIdentifier>()
        var nearestView = element as? NSView
        var sawScroll = false
        while let accessible = ancestor as? any NSAccessibilityProtocol {
            guard visited.insert(ObjectIdentifier(accessible)).inserted else { return }
            if nearestView == nil, let view = accessible as? NSView { nearestView = view }
            if let scrollView = accessible as? NSScrollView {
                reveal(in: scrollView)
                sawScroll = true
            }
            ancestor = accessible.accessibilityParent()
        }
        if !sawScroll, let nearestView,
           let scrollView = enclosingScrollView(for: nearestView) {
            reveal(in: scrollView)
        }
    }

    private static func clickRevealing(
        identifier: String,
        in window: NSWindow
    ) -> String? {
        guard let root = window.contentView,
              let probe = findProbe(in: root, identifier: identifier) else {
            return "control geometry unavailable"
        }
        if let scrollView = enclosingScrollView(for: probe),
           let documentView = scrollView.documentView {
            documentView.scrollToVisible(probe.convert(probe.bounds, to: documentView))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            root.layoutSubtreeIfNeeded()
        }
        return click(identifier: identifier, in: window)
    }

    private static func pressKey(keyCode: UInt16, characters: String) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ), let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
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

    private static func probeValue(identifier: String, in window: NSWindow) -> String? {
        guard let root = window.contentView,
              let probe = findProbe(in: root, identifier: identifier)
                as? AppRelaunchClickProbeView else { return nil }
        return probe.acceptanceValue
    }

    private static func validProductionArtifactID(
        _ value: String?,
        phase: String,
        project: String?
    ) -> Bool {
        guard let value else { return false }
        switch phase {
        case "brief":
            return project.map { value == "brief:\($0)" } == true
        case "treatment":
            return value == "treatment:v1:Acceptance treatment artifact."
        case "frames":
            return value == "frames:acceptance-shot:acceptance-01-start.png"
        case "render":
            let components = value.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 3,
                  components[0] == "render",
                  components[1] == "acceptance-render-shot" else { return false }
            return components[2].count == 64 && components[2].allSatisfy(\.isHexDigit)
        default:
            return false
        }
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
