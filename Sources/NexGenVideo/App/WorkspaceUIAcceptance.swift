import AppKit
import AVFoundation
import AVKit
import NexGenEngine
import SwiftUI
import Vision

@MainActor
enum WorkspaceUIAcceptance {
    private static var editorSizeProbes: [[String: String]] = []

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
        resetWorkspaceDefaults(scale: scale)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.submenu = NSMenu(title: "NexGenVideo")
        menu.addItem(applicationItem)
        menu.addItem(MainMenuBuilder.editMenu())
        app.mainMenu = menu
        BundledFonts.register()
        let evidenceURL = URL(fileURLWithPath: evidencePath, isDirectory: true)
        emit("started", scale: scale, fields: [
            "case": ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_CASE"] ?? "workspace",
            "restorationIgnored": UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState"),
        ])
        Task { @MainActor in
            let scenario = ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_CASE"] ?? "workspace"
            if scenario != "workspace" {
                switch scenario {
                case "cards": await captureProjectCards(evidenceURL: evidenceURL, scale: scale)
                case "analysis": await captureAnalysis(evidenceURL: evidenceURL, scale: scale)
                case "provenance": await captureAssetProvenance(evidenceURL: evidenceURL, scale: scale)
                case "musicvideo": await captureMusicvideoStartup(evidenceURL: evidenceURL, scale: scale)
                case "hoststates":
                    await captureHostStateHistory(evidenceURL: evidenceURL, scale: scale)
                    do {
                        let name = "scale-\(Int((scale * 100).rounded()))-agent-structured"
                        var result = try await AgentStructuredResultsOwnerAcceptance.run(output: evidenceURL.appendingPathComponent(name), scale: scale)
                        result["evidenceDirectory"] = name
                        emit("agent-structured-owner", scale: scale, fields: result)
                        let reviewName = "scale-\(Int((scale * 100).rounded()))-review-children"
                        var review = try await AgentReviewChildOwnerAcceptance.run(output: evidenceURL.appendingPathComponent(reviewName), scale: scale)
                        review["evidenceDirectory"] = reviewName
                        emit("agent-review-child-owner", scale: scale, fields: review)
                    } catch { fail("Agent result acceptance: " + error.localizedDescription, scale: scale) }
                case "storyboard": await captureStoryboardReview(evidenceURL: evidenceURL, scale: scale)
                case "planning": await captureProductionPlanning(evidenceURL: evidenceURL, scale: scale)
                case "aienhanced", "framecontinuation", "nativeextension":
                    do {
                        let name = "scale-\(Int((scale * 100).rounded()))-source-" + scenario
                        let kind: ProductionSourceModesOwnerAcceptance.Kind = scenario == "aienhanced" ? .aiEnhanced
                            : scenario == "framecontinuation" ? .frameContinuation : .nativeExtension
                        var result = try await ProductionSourceVideoOwnerAcceptance.run(kind: kind,
                            output: evidenceURL.appendingPathComponent(name))
                        result["case"] = scenario; result["evidenceDirectory"] = name
                        emit("production-source-owner", scale: scale, fields: result)
                    } catch { fail("Production source owner acceptance: " + error.localizedDescription, scale: scale) }
                case "ledger":
                    do {
                        let name = "scale-\(Int((scale * 100).rounded()))-ledger"
                        var result = try await LedgerAttributeOwnerAcceptance.run(output: evidenceURL.appendingPathComponent(name), scale: scale)
                        result["evidenceDirectory"] = name
                        emit("ledger-owner", scale: scale, fields: result)
                    } catch { fail("Ledger owner acceptance: " + error.localizedDescription, scale: scale) }
                case "captionrevision":
                    do {
                        let name = "scale-\(Int((scale * 100).rounded()))-caption-revision"
                        var result = try await CaptionRevisionAcceptance.run(output: evidenceURL.appendingPathComponent(name), scale: scale)
                        result["evidenceDirectory"] = name
                        emit("caption-revision-owner", scale: scale, fields: result)
                    } catch { fail("Caption revision acceptance: " + error.localizedDescription, scale: scale) }
                case "chronologynegative", "sanitynegative", "animatedstill":
                    do {
                        let name = "scale-\(Int((scale * 100).rounded()))-contract-" + scenario
                        let destination = evidenceURL.appendingPathComponent(name)
                        var result: [String: Any]
                        switch scenario {
                        case "chronologynegative": result = try await ProductionChronologyOwnerAcceptance.run(output: destination)
                        case "sanitynegative": result = try await ProductionSanityOwnerAcceptance.run(output: destination)
                        default: result = try await ProductionAnimatedStillOwnerAcceptance.run(output: destination)
                        }
                        result["case"] = scenario
                        result["evidenceDirectory"] = name
                        emit("production-contract-owner", scale: scale, fields: result)
                    } catch { fail("Production contract owner acceptance: " + error.localizedDescription, scale: scale) }
                case "frames":
                    do {
                        let name = "scale-\(Int((scale * 100).rounded()))-frames-owner"
                        var fields = try await ProductionFramesOwnerAcceptance.run(output: evidenceURL.appendingPathComponent(name))
                        fields["evidenceDirectory"] = name
                        emit("production-frames-owner", scale: scale, fields: fields)
                    } catch { fail("Frames owner acceptance: " + error.localizedDescription, scale: scale) }
                case "filmflow":
                    do {
                        emit("filmflow-owner", scale: scale, fields: try await FilmFlowOwnerAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("FilmFlow import acceptance: " + error.localizedDescription, scale: scale) }
                case "mediabrowser":
                    do {
                        emit("media-browser-owner", scale: scale, fields: try await MediaBrowserOwnerAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Media browser owner acceptance: " + error.localizedDescription, scale: scale) }
                case "exportformats":
                    do {
                        emit("export-formats-owner", scale: scale, fields: try await ExportFormatsOwnerAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Export formats acceptance: " + error.localizedDescription, scale: scale) }
                case "exportrecovery":
                    do {
                        emit("export-recovery-owner", scale: scale, fields: try await ExportRecoveryOwnerAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Export restart acceptance: " + error.localizedDescription, scale: scale) }
                case "layeredtimeline":
                    do {
                        emit("layered-timeline-owner", scale: scale, fields: try await LayeredTimelineOwnerAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Layered timeline acceptance: " + error.localizedDescription, scale: scale) }
                case "timelineediting":
                    do {
                        emit("timeline-editing-owner", scale: scale, fields: try await TimelineEditingOwnerAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Timeline editing acceptance: " + error.localizedDescription, scale: scale) }
                case "sourceoperations":
                    do {
                        emit("source-operations", scale: scale, fields: try await NativeSourceOperationsAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Source operations acceptance: " + error.localizedDescription, scale: scale) }
                case "appnle":
                    do {
                        emit("app-nle-owner", scale: scale, fields: try await AppWorkspaceOwnerAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Application and editing owner acceptance: " + error.localizedDescription, scale: scale) }
                case "genericnle":
                    do {
                        emit("generic-nle", scale: scale, fields: try await GenericNLEAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Plain editing acceptance: " + error.localizedDescription, scale: scale) }
                case "generationrecovery":
                    do {
                        emit("generation-recovery", scale: scale, fields: try await GenerationRecoveryOwnerAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Generation recovery acceptance: " + error.localizedDescription, scale: scale) }
                case "manualvideomodes":
                    do {
                        emit("manual-video-modes", scale: scale, fields: try await ManualVideoModesAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Manual video modes acceptance: " + error.localizedDescription, scale: scale) }
                case "manualgeneration":
                    do {
                        emit("manual-generation", scale: scale, fields: try await ManualGenerationOwnerAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Manual generation acceptance: " + error.localizedDescription, scale: scale) }
                case "animationaudio":
                    do {
                        emit("animation-audio", scale: scale, fields: try await AnimationAudioAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Animation and audio acceptance: " + error.localizedDescription, scale: scale) }
                case "textcaptions":
                    do {
                        emit("text-captions", scale: scale, fields: try await TextCaptionAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Text and captions acceptance: " + error.localizedDescription, scale: scale) }
                case "medialibrary":
                    do {
                        emit("native-media-library", scale: scale, fields: try await MediaLibraryAcceptance.run(output: evidenceURL, scale: scale))
                    } catch { fail("Media library acceptance: " + error.localizedDescription, scale: scale) }
                case "filmreview": await captureProductionOwner(kind: .musicvideo, evidenceURL: evidenceURL, scale: scale)
                case "performance": await captureProductionOwner(kind: .musicvideo, evidenceURL: evidenceURL, scale: scale, performance: true)
                case "performanceroles":
                    do {
                        guard let path = ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_PACK"] else { throw ToolError("Technical role acceptance requires the external Music Video pack.") }
                        let pack = PluginLoader.load(at: URL(fileURLWithPath: path))
                        guard pack.isLoaded, pack.id == "musicvideo" else { throw ToolError("The actual Music Video pack did not load.") }
                        let name = "scale-\(scaleLabel(scale))-performance-roles"
                        var result = try await ProductionPerformanceRoleAcceptance.run(output: evidenceURL.appendingPathComponent(name))
                        result["evidenceDirectory"] = name
                        emit("production-performance-roles", scale: scale, fields: result)
                    } catch { fail("Technical performer/voice binding: " + error.localizedDescription, scale: scale) }
                case "corefilmreview": await captureProductionOwner(kind: .core, evidenceURL: evidenceURL, scale: scale)
                default: fail("unknown native acceptance case", scale: scale)
                }
                emit("completed", scale: scale, fields: ["case": scenario])
                exit(0)
            }
            await VisualModelLoader.shared.prepare()
            guard VisualModelLoader.shared.enabled, VisualModelLoader.shared.state == .notInstalled else {
                fail("workspace fixture requires enabled visual search with no installed model", scale: scale)
            }
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
                    && probeState(identifier: "pipeline.overview.dock.start", in: window) == true
                    && previewTimecodeIsSingleLine(in: window, scale: scale)
                    && productionControlsAreContained(in: window)
            }) else {
                fail("could not prepare large production layout", scale: scale)
            }
            let preparedProductionFrames = visiblePanelFrames(in: host)
            guard productionColumnsAreIndependent(preparedProductionFrames) else {
                fail("production requires independent workflow, artifact and inspector columns", scale: scale)
            }
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
                        && (workspace != .production || productionControlsAreContained(in: window))
                        && (!(workspace == .media || workspace == .edit)
                            || mediaToolbarIsContained(in: window, workspace: workspace))
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
                guard let renderedFrames = await stablePanelFrames(in: host),
                      editor.workspaceFocus == workspace,
                      probeState(identifier: identifier, in: window) == true,
                      visiblePanelIDs(in: host) == expectedPanels(for: workspace),
                      visiblePanelFrames(in: host) == renderedFrames,
                      defaultPanelWidthsAreValid(workspace: workspace, frames: renderedFrames),
                      previewTimecodeIsSingleLine(in: window, scale: scale),
                      workspace != .production || productionControlsAreContained(in: window) else {
                    fail("workspace layout did not settle for \(workspace.rawValue)", scale: scale)
                }
                if workspace == .media || workspace == .edit {
                    guard mediaToolbarIsContained(in: window, workspace: workspace) else {
                        let name = "scale-\(scaleLabel(scale))-\(workspace.rawValue)-toolbar-failed.png"
                        _ = snapshot(host, at: evidenceURL.appendingPathComponent(name))
                        fail("media toolbar overlaps or escapes its rows in \(workspace.rawValue)", scale: scale)
                    }
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

            await captureMediaLibraryCase(
                editor: editor, window: window, host: host, evidenceURL: evidenceURL, scale: scale
            )

            guard click(identifier: "editor.workspace.edit", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.workspaceFocus == .edit
                          && probeState(identifier: "editor.workspace.edit", in: window) == true
                          && visiblePanelIDs(in: host) == expectedPanels(for: .edit)
                  }) else {
                fail("could not return to edit", scale: scale)
            }
            guard let initialEditFrames,
                  await stablePanelFrames(in: host, matching: initialEditFrames) != nil,
                  probeState(identifier: "editor.workspace.edit", in: window) == true,
                  visiblePanelIDs(in: host) == expectedPanels(for: .edit) else {
                let name = "scale-\(scaleLabel(scale))-edit-return-failed.png"
                _ = snapshot(host, at: evidenceURL.appendingPathComponent(name))
                emit("layout-diagnostic", scale: scale, fields: [
                    "expectedFrames": initialEditFrames?.mapValues { frameDescription($0) } ?? [:],
                    "actualFrames": visiblePanelFrames(in: host).mapValues { frameDescription($0) },
                    "splits": splitDiagnostics(in: host), "screenshot": name,
                ])
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
                    && productionControlsAreContained(in: window)
            }) else {
                fail("narrow production controls did not fit", scale: scale)
            }
            let narrowName = "scale-\(scaleLabel(scale))-production-narrow"
            guard let narrowFrames = await stablePanelFrames(in: host),
                  visiblePanelFrames(in: host) == narrowFrames,
                  editor.workspaceFocus == .production,
                  visiblePanelIDs(in: host) == expectedPanels(for: .production),
                  abs(host.bounds.width - AppTheme.Window.projectMin.width) <= AppTheme.BorderWidth.thin,
                  narrowProductionWidthsAreValid(narrowFrames),
                  previewTimecodeIsSingleLine(in: window, scale: scale),
                  productionControlsAreContained(in: window),
                  snapshot(host, at: evidenceURL.appendingPathComponent("\(narrowName).png")) else {
                _ = snapshot(host, at: evidenceURL.appendingPathComponent("\(narrowName)-failed.png"))
                emit("layout-diagnostic", scale: scale, fields: [
                    "reason": "narrow production layout did not settle",
                    "frames": visiblePanelFrames(in: host).mapValues { frameDescription($0) },
                    "window": windowDiagnostics(window, contentView: host),
                ])
                fail("narrow production layout did not settle", scale: scale)
            }
            emit(
                "narrow-production",
                scale: scale,
                fields: [
                    "screenshot": "\(narrowName).png",
                    "workbenchControls": ["production.sidebar", "production.status"],
                    "frames": narrowFrames.mapValues { frameDescription($0) },
                    "window": windowDiagnostics(window, contentView: host),
                ]
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
            window.orderOut(nil)
            emit("completed", scale: scale)
            exit(0)
        }
        app.run()
        exit(1)
    }

    private static func captureMediaLibraryCase(
        editor: EditorViewModel, window: NSWindow, host: NSView, evidenceURL: URL, scale: Double
    ) async {
        func reject(_ reason: String) -> Never {
            let name = "scale-\(scaleLabel(scale))-media-library-failed.png"
            _ = snapshot(host, at: evidenceURL.appendingPathComponent(name))
            emit("media-library-diagnostic", scale: scale, fields: ["reason": reason,
                "folder": editor.mediaPanelCurrentFolderId ?? "root", "selectedFolders": editor.selectedFolderIds.sorted(),
                "firstResponder": String(describing: window.firstResponder), "keyWindow": window.isKeyWindow,
                "nestedProbe": findProbe(in: host, identifier: "media.folder-tile.fixture-nested").map { viewLayoutDiagnostics($0, in: host) } ?? ["available": false],
                "searchProbe": findProbe(in: host, identifier: "media.search").map { viewLayoutDiagnostics($0, in: host) } ?? ["available": false], "screenshot": name])
            fail(reason, scale: scale)
        }
        guard editor.mediaAssets.count == 500,
              editor.missingMediaRefs.isEmpty,
              Set(editor.mediaAssets.map(\.type)) == [.image, .audio, .document],
              editor.mediaAssets.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }),
              click(identifier: "editor.workspace.media", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return editor.workspaceFocus == .media
                      && findProbe(in: host, identifier: "media.folder.fixture-root") != nil
              }),
              click(identifier: "media.folder.fixture-root", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return editor.mediaPanelCurrentFolderId == "fixture-root"
                      && findProbe(in: host, identifier: "media.folder-tile.fixture-nested") != nil
              }), await stablePanelFrames(in: host) != nil else {
            reject("500-asset library or root folder was unavailable")
        }
        if let reason = click(identifier: "media.folder-tile.fixture-nested", in: window, clickCount: 2) {
            reject("nested folder double-click: \(reason)")
        }
        guard await waitUntil(timeout: .seconds(5), {
            host.layoutSubtreeIfNeeded()
            return editor.mediaPanelCurrentFolderId == "fixture-nested"
        }) else { reject("native double-click did not open the nested folder") }
        guard await stablePanelFrames(in: host) != nil else { reject("nested folder layout did not settle") }
        if let reason = click(identifier: "media.search", in: window) { reject("search click: \(reason)") }
        guard await waitUntil(timeout: .seconds(5), { window.firstResponder is NSTextView }),
              let fieldEditor = window.firstResponder as? NSTextView else {
            reject("native search field did not take keyboard focus")
        }
        fieldEditor.insertText("Acceptance Source 498", replacementRange: NSRange(location: NSNotFound, length: 0))
        let state = editor.mediaBrowserState(for: .media)
        guard await waitUntil(timeout: .seconds(5), {
            host.layoutSubtreeIfNeeded()
            return state.searchQuery == "Acceptance Source 498"
                && findProbe(in: host, identifier: "media.search-result.fixture-498") != nil
        }), click(identifier: "media.search-result.fixture-498", in: window) == nil,
        await waitUntil(timeout: .seconds(5), { editor.selectedMediaAssetIds == ["fixture-498"] }) else {
            fail("native search did not find and select the nested source", scale: scale)
        }
        await verifySearchKeyboardIsolation(editor: editor, window: window, scale: scale)
        guard click(identifier: "editor.workspace.edit", in: window) == nil,
              await waitUntil(timeout: .seconds(5), { editor.workspaceFocus == .edit }),
              editor.mediaBrowserState(for: .edit).searchQuery.isEmpty,
              click(identifier: "editor.workspace.media", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return editor.workspaceFocus == .media
                      && state.searchQuery == "Acceptance Source 498"
                      && state.currentFolderId == "fixture-nested"
                      && findProbe(in: host, identifier: "media.search-result.fixture-498") != nil
                      && defaultPanelWidthsAreValid(workspace: .media, frames: visiblePanelFrames(in: host))
                      && mediaToolbarIsContained(in: window, workspace: .media)
                      && editor.activePreviewTab.clipType == .image
                      && visiblePanelFrames(in: host)["previewPanel"].map {
                          visibleProbe(identifier: "preview.zoom", in: window, containedBy: $0)
                      } == true
              }), let frames = await stablePanelFrames(in: host),
              defaultPanelWidthsAreValid(workspace: .media, frames: frames),
              editor.selectedMediaAssetIds == ["fixture-498"] else {
            let name = "scale-\(scaleLabel(scale))-media-return-failed.png"
            _ = snapshot(host, at: evidenceURL.appendingPathComponent(name))
            emit("layout-diagnostic", scale: scale, fields: [
                "query": state.searchQuery, "folder": state.currentFolderId ?? "",
                "selection": editor.selectedMediaAssetIds.sorted(),
                "frames": visiblePanelFrames(in: host).mapValues { frameDescription($0) },
                "splits": splitDiagnostics(in: host), "screenshot": name,
            ])
            fail("media navigation state leaked or was lost across workspaces", scale: scale)
        }
        let name = "scale-\(scaleLabel(scale))-media-library.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(name)) else {
            fail("could not capture the populated media library", scale: scale)
        }
        emit("media-library", scale: scale, fields: [
            "assetCount": editor.mediaAssets.count,
            "types": Set(editor.mediaAssets.map { $0.type.rawValue }).sorted(),
            "nestedFolderOpened": true, "searchSelectedAsset": "fixture-498",
            "workspaceStatePreserved": true, "screenshot": name,
            "frames": frames.mapValues { frameDescription($0) },
        ])
    }

    private static func verifySearchKeyboardIsolation(
        editor: EditorViewModel, window: NSWindow, scale: Double
    ) async {
        let timeline = editor.timeline
        let manifest = editor.mediaManifest
        let selection = editor.selectedMediaAssetIds
        let clipSelection = editor.selectedClipIds
        let playing = editor.isPlaying
        let state = editor.mediaBrowserState(for: .media)
        let query = state.searchQuery
        guard !query.isEmpty, !selection.isEmpty,
              click(identifier: "media.search", in: window) == nil,
              await waitUntil(timeout: .seconds(5), { window.firstResponder is NSTextView }),
              let field = window.firstResponder as? NSTextView else {
            fail("keyboard isolation did not focus the native search field", scale: scale)
        }
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        func postKey(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero,
                    modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                    fail("could not create native keyboard event", scale: scale)
                }
                NSApp.postEvent(event, atStart: false)
            }
        }
        postKey(49, characters: " ")
        guard await waitUntil(timeout: .seconds(5), { state.searchQuery == query + " " }),
              editor.isPlaying == playing else {
            fail("Space escaped the native text field or changed playback", scale: scale)
        }
        postKey(51, characters: "\u{7f}")
        guard await waitUntil(timeout: .seconds(5), { state.searchQuery == query }) else {
            fail("Delete did not edit the native search text", scale: scale)
        }
        postKey(0, characters: "a", modifiers: .command)
        guard await waitUntil(timeout: .seconds(5), {
            field.selectedRange() == NSRange(location: 0, length: (query as NSString).length)
        }) else { fail("Select All escaped the native text field", scale: scale) }
        postKey(51, characters: "\u{7f}")
        guard await waitUntil(timeout: .seconds(5), { state.searchQuery.isEmpty }),
              editor.timeline == timeline, editor.mediaManifest == manifest,
              editor.selectedMediaAssetIds == selection, editor.selectedClipIds == clipSelection,
              editor.isPlaying == playing else {
            fail("text deletion mutated media, timeline, selection, or playback", scale: scale)
        }
        field.insertText(query, replacementRange: NSRange(location: NSNotFound, length: 0))
        guard await waitUntil(timeout: .seconds(5), { state.searchQuery == query }) else {
            fail("native search text could not be restored", scale: scale)
        }
        emit("text-keyboard-isolation", scale: scale, fields: [
            "spaceEditsText": true, "deleteEditsText": true, "selectAllTargetsText": true,
            "timelineUnchanged": true, "mediaUnchanged": true, "selectionUnchanged": true,
            "playbackUnchanged": true,
        ])
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
            guard await waitUntil(timeout: .seconds(5), {
                host.layoutSubtreeIfNeeded()
                return previewHeaderIsContained(in: window)
                    && mediaToolbarIsContained(in: window, workspace: .edit)
            }) else {
                emit("preview-header-diagnostic", scale: scale, fields: [
                    "family": item.family,
                    "panels": visiblePanelFrames(in: host).mapValues { frameDescription($0) },
                    "titleFrames": probes(in: host, identifier: "preview.header.title").map {
                        frameDescription($0.convert($0.bounds, to: host))
                    },
                ])
                fail("preview header or media toolbar escaped after selecting \(item.family)", scale: scale)
            }
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
                guard let splitState = inspectorSplitState(in: root),
                      let originalInspectorFrame = visiblePanelFrames(in: host)["inspectorPanel"] else {
                    fail("inspector \(item.family) split geometry was unavailable", scale: scale)
                }
                let wideInspectorWidth = max(originalInspectorFrame.width, AppTheme.Layout.inspectorDefault * CGFloat(scale))
                splitState.splitView.setPosition(
                    splitState.splitView.bounds.maxX - wideInspectorWidth - splitState.splitView.dividerThickness,
                    ofDividerAt: splitState.dividerIndex
                )
                guard await waitUntil(timeout: .seconds(5), {
                    host.layoutSubtreeIfNeeded()
                    guard let frame = visiblePanelFrames(in: host)["inspectorPanel"] else {
                        return false
                    }
                    return abs(frame.width - wideInspectorWidth) <= AppTheme.BorderWidth.thin
                }) else {
                    fail("inspector \(item.family) did not reach wide layout width", scale: scale)
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
                splitState.splitView.setPosition(
                    splitState.splitView.bounds.maxX - AppTheme.Layout.inspectorMin - splitState.splitView.dividerThickness,
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
        guard await waitUntil(timeout: .seconds(5), {
            host.layoutSubtreeIfNeeded()
            return mediaToolbarIsContained(in: window, workspace: .edit)
        }) else {
            fail("media toolbar did not restore after the inspector tab round trip", scale: scale)
        }
    }

    private static func captureMusicvideoStartup(evidenceURL: URL, scale: Double) async {
        guard let packPath = ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_PACK"] else {
            fail("native Musicvideo acceptance requires an external pack", scale: scale)
        }
        let record = PluginLoader.load(at: URL(fileURLWithPath: packPath))
        guard record.isLoaded, record.id == "musicvideo",
              let binding = PluginLoader.liveBinding(id: "musicvideo") else {
            fail("native Musicvideo pack failed to load: \(record.state)", scale: scale)
        }
        let projectURL: URL
        let document: VideoProject
        do {
            projectURL = try makeProjectFixture(scale: scale)
            try ProjectPluginSettings.setActivePlugin(binding, projectURL: projectURL)
            _ = try ProjectScaffold.initProject(home: projectURL, name: "Native Musicvideo acceptance",
                extraDirs: PackCatalog.projectDirs(activePack: "musicvideo"))
            document = try await VideoProject.load(from: projectURL)
        } catch { fail("could not open pinned Musicvideo fixture: \(error.localizedDescription)", scale: scale) }
        document.makeWindowControllers()
        let editor = document.editorViewModel
        editor.setWorkspaceFocus(.production)
        await editor.refreshEngineState()
        _ = editor.pipelineAgentHarness.reconcile(editor: editor)
        let expectedPhases = ["project_init", "analysis", "brief", "production_design", "treatment", "script",
            "storyboard", "shot_planning", "bible", "shotlist", "sanity", "frames", "render_review", "render"]
        guard editor.declaredPluginBinding == binding,
              editor.projectState?.phases.map(\.phase) == expectedPhases,
              editor.projectState?.nextPhaseName == "project_init",
              editor.agentService.pendingDialog?.title == "Track",
              editor.agentService.pendingDialog?.fileIntake?.attachAs == "song",
              editor.mediaAssets.contains(where: { $0.type == .audio }),
              editor.mediaAssets.contains(where: { $0.type == .document }),
              editor.activePackAccentColor != nil else {
            fail("pinned Musicvideo startup lost its phases, Track intake or pack identity", scale: scale)
        }
        guard let window = document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window,
              let host = window.contentView else { fail("Musicvideo editor window is unavailable", scale: scale) }
        window.setContentSize(AppTheme.Acceptance.workbenchViewport)
        window.appearance = NSAppearance(named: .darkAqua)
        document.showWindows()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        func text(_ id: String) -> String? {
            (findProbe(in: host, identifier: id) as? AppRelaunchClickProbeView)?.acceptanceText
        }
        func reject(_ reason: String) -> Never {
            _ = snapshot(host, at: evidenceURL.appendingPathComponent("scale-\(scaleLabel(scale))-musicvideo-failed.png"))
            emit("musicvideo-diagnostic", scale: scale, fields: ["reason": reason,
                "current": editor.projectState?.nextPhaseName ?? "missing",
                "dialog": text("agent.dialog.title") ?? "missing",
                "selected": editor.productionSelectedPhase ?? "missing"])
            fail(reason, scale: scale)
        }
        guard await waitUntil(timeout: .seconds(10), {
            host.layoutSubtreeIfNeeded()
            return window.isKeyWindow && text("agent.dialog.title") == "Track"
                && productionColumnsAreIndependent(visiblePanelFrames(in: host))
                && productionControlsAreContained(in: window)
                && editor.productionSelectedPhase == "project_init"
                && expectedPhases.allSatisfy { text("pipeline.overview.select.\($0)") != nil }
                && findProbe(in: host, identifier: "pipeline.overview.approve.project_init") == nil
        }) else { reject("Musicvideo workflow, fixed Track decision or artifact did not render") }
        guard let home = editor.workingRoot else { reject("Musicvideo fixture has no working copy") }
        guard await waitUntil(timeout: .seconds(5), {
            guard let owner = editor.agentService.currentSessionId,
                  let expected = editor.agentService.sessions.first(where: { $0.id == owner })?.decision,
                  let restored = try? ChatSessionStore.loadThrowing(from: home).first(where: { $0.id == owner }) else { return false }
            return restored.decision == expected && expected.dialog.title == "Track"
        }) else { reject("initial Track decision did not finish its durable checkpoint") }
        guard let workingBytes = try? treeSnapshot(at: home), let savedBytes = try? treeSnapshot(at: projectURL) else {
            reject("Musicvideo fixture is unreadable")
        }
        let timeline = editor.timeline
        let manifest = editor.mediaManifest
        let log = editor.generationLog
        let canUndo = document.undoManager?.canUndo ?? false
        let edited = document.isDocumentEdited
        let initial = "scale-\(scaleLabel(scale))-musicvideo-track.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(initial)) else { reject("could not capture Track intake") }
        let story = "scale-\(scaleLabel(scale))-musicvideo-story-context.png"
        for phase in expectedPhases.dropFirst(2) {
            let identifier = "pipeline.overview.select.\(phase)"
            guard await revealProbe(identifier, in: window), click(identifier: identifier, in: window) == nil else {
                reject("workflow phase could not open: \(phase)")
            }
            guard await waitUntil(timeout: .seconds(5), {
                host.layoutSubtreeIfNeeded()
                return editor.productionSelectedPhase == phase
                    && editor.projectState?.nextPhaseName == "project_init"
                    && text("agent.dialog.title") == "Track"
                    && productionColumnsAreIndependent(visiblePanelFrames(in: host))
                    && findProbe(in: host, identifier: "pipeline.overview.dock.status") != nil
            }) else { reject("phase selection lost its fixed decision or changed the active step: \(phase)") }
            if phase == "brief", !snapshot(host, at: evidenceURL.appendingPathComponent(story)) {
                reject("could not capture Briefing context")
            }
        }
        guard await revealProbe("pipeline.overview.select.project_init", in: window),
              click(identifier: "pipeline.overview.select.project_init", in: window) == nil,
              await waitUntil(timeout: .seconds(5), { editor.productionSelectedPhase == "project_init" }) else {
            reject("current phase could not be restored")
        }
        let checks: [String: Bool] = [
            "currentPhase": editor.projectState?.nextPhaseName == "project_init",
            "noApprovals": editor.projectState?.phases.allSatisfy({ !$0.approved }) == true,
            "trackDecision": editor.agentService.pendingDialog?.title == "Track",
            "timeline": editor.timeline == timeline, "manifest": editor.mediaManifest == manifest,
            "costs": editor.generationLog == log, "documentEdited": document.isDocumentEdited == edited,
            "undo": (document.undoManager?.canUndo ?? false) == canUndo,
            "workingBytes": (try? treeSnapshot(at: home)) == workingBytes,
            "savedBytes": (try? treeSnapshot(at: projectURL)) == savedBytes,
        ]
        guard checks.values.allSatisfy({ $0 }) else {
            emit("musicvideo-invariant-diagnostic", scale: scale, fields: ["checks": checks])
            reject("viewing another phase changed project truth")
        }
        let final = "scale-\(scaleLabel(scale))-musicvideo-phases.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(final)) else { reject("could not capture workflow state") }
        emit("musicvideo-startup", scale: scale, fields: ["packVersion": binding.version,
            "phases": expectedPhases, "externalPackLoaded": true, "exactBinding": true,
            "libraryDidNotAssignTrack": true, "viewingDidNotAdvance": true, "intakeCheckpointSettled": true,
            "disabledApprovalDidNotMutate": true, "surfaceActionsSingleLine": true,
            "artifactTabsExcludeWorkflowControls": true, "pipelineRestored": true, "tasksReachable": true,
            "nativeWorkbench": true, "fixedDecisionPersists": true,
            "screenshots": [initial, story, final]])
    }

    private static func captureAssetProvenance(evidenceURL: URL, scale: Double) async {
        let projectURL: URL
        let document: VideoProject
        do {
            projectURL = try makeProvenanceFixture(scale: scale)
            document = try await VideoProject.load(from: projectURL)
        } catch { fail("could not load provenance fixture: \(error.localizedDescription)", scale: scale) }
        document.makeWindowControllers()
        let editor = document.editorViewModel
        editor.setWorkspaceFocus(.media)
        guard let home = editor.workingRoot, let originalBytes = try? treeSnapshot(at: home),
              let savedBytes = try? treeSnapshot(at: projectURL) else {
            fail("provenance fixture has no working copy", scale: scale)
        }
        let timeline = editor.timeline
        let manifest = editor.mediaManifest
        let log = editor.generationLog
        let canUndo = document.undoManager?.canUndo ?? false
        let edited = document.isDocumentEdited
        let host = NSHostingView(rootView: InspectorView().interfaceStyle().environment(editor)
            .frame(width: AppTheme.Acceptance.inspectorViewport.width, height: AppTheme.Acceptance.inspectorViewport.height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        func text(_ id: String) -> String? {
            (findProbe(in: host, identifier: id) as? AppRelaunchClickProbeView)?.acceptanceText
        }
        var expectedRows: [String: String] = [:]
        func reject(_ reason: String) -> Never {
            _ = snapshot(host, at: evidenceURL.appendingPathComponent("scale-\(scaleLabel(scale))-provenance-failed.png"))
            emit("provenance-diagnostic", scale: scale, fields: ["reason": reason,
                "expected": expectedRows, "actual": expectedRows.keys.sorted().map { key in
                    ["id": key, "text": text(key) ?? "missing"]
                }, "selection": editor.selectedMediaAssetIds.sorted(), "keyWindow": window.isKeyWindow])
            fail(reason, scale: scale)
        }
        let cases: [(id: String, family: String)] = [
            ("fixture-498", "imported"), ("fixture-492", "generated"),
            ("fixture-495", "enhanced"), ("fixture-489", "offline"),
        ]
        var screenshots: [String] = []
        for item in cases {
            guard let asset = editor.mediaAssets.first(where: { $0.id == item.id }) else { reject("provenance asset missing") }
            editor.selectMediaAsset(asset)
            let prefix = "asset.\(asset.id)."
            let isGenerated = item.family == "generated" || item.family == "enhanced"
            let expected: [String: String] = isGenerated ? [
                "Model ID": "native-image-fixture", "Provider": item.family == "generated" ? "fal.ai" : "Higgsfield",
                "Route": item.family == "generated" ? "API" : "MCP", "Generation receipt": "Unavailable",
                "Billed cost": item.family == "generated" ? "0.25 EUR" : "0.50 EUR",
                "Provider job": "native-job-\(asset.id)",
            ] : ["Source": "Imported media", "Generation route": "Not applicable"]
            expectedRows = Dictionary(uniqueKeysWithValues: expected.map { (prefix + "origin." + $0.key, $0.value) })
            guard await waitUntil(timeout: .seconds(5), {
                host.layoutSubtreeIfNeeded()
                return window.isKeyWindow && abs(host.bounds.width - 440) <= 1 && abs(host.bounds.height - 650) <= 1
                    && text(prefix + "identity") == asset.libraryDisplayName
                    && probeState(identifier: prefix + "identity", in: window) == (item.family == "offline")
                    && expected.allSatisfy { text(prefix + "origin." + $0.key) == $0.value }
            }) else { reject("\(item.family) identity or recorded origin did not render correctly") }
            if item.family == "imported" {
                guard asset.name == String(repeating: "a", count: 64),
                      asset.libraryDisplayName == "Acceptance Source 498.png",
                      editor.activePreviewTab.displayName == "Acceptance Source 498.png",
                      text("inspector.breadcrumb") == "Original Media › Acceptance Source 498.png" else {
                    reject("legacy storage hash escaped into the asset identity or breadcrumb")
                }
            }
            if item.family == "offline" {
                guard probeState(identifier: prefix + "relink", in: window) == true,
                      probeState(identifier: prefix + "reveal", in: window) == false else {
                    reject("offline asset did not enable relink and disable file reveal")
                }
            }
            let anchor = prefix + "origin." + (isGenerated ? "Model ID" : "Source")
            guard await revealProbe(anchor, in: window) else { reject("\(item.family) origin is unreachable") }
            let name = "scale-\(scaleLabel(scale))-provenance-\(item.family).png"
            guard snapshot(host, at: evidenceURL.appendingPathComponent(name)) else { reject("could not capture provenance") }
            screenshots.append(name)
            if isGenerated {
                guard await revealProbe(prefix + "origin.Billed cost", in: window) else { reject("recorded cost is unreachable") }
                let costName = "scale-\(scaleLabel(scale))-provenance-\(item.family)-cost.png"
                guard snapshot(host, at: evidenceURL.appendingPathComponent(costName)) else { reject("could not capture recorded cost") }
                screenshots.append(costName)
            }
            if item.family == "generated" {
                guard text(prefix + "origin.References") == "Not applicable — no reference inputs" else {
                    reject("generated asset invented reference inputs")
                }
            } else if item.family == "enhanced" {
                guard let receipt = asset.generationInput?.referenceReceipts?.first,
                      text(prefix + "origin.Source SHA-256") == receipt.sourceSHA256,
                      await revealProbe(prefix + "original.fixture-498", in: window) else {
                    reject("enhanced asset lost its exact source revision")
                }
                let referenceName = "scale-\(scaleLabel(scale))-provenance-enhanced-reference.png"
                guard snapshot(host, at: evidenceURL.appendingPathComponent(referenceName)) else { reject("could not capture source revision") }
                screenshots.append(referenceName)
                if let reason = click(identifier: prefix + "original.fixture-498", in: window) {
                    reject("show original: \(reason)")
                }
                guard await waitUntil(timeout: .seconds(5), {
                    editor.selectedMediaAssetIds == ["fixture-498"]
                        && text("asset.fixture-498.origin.Source") == "Imported media"
                }) else { reject("Show Original selected the wrong asset") }
            }
        }
        guard editor.timeline == timeline, editor.mediaManifest == manifest, editor.generationLog == log,
              document.isDocumentEdited == edited, (document.undoManager?.canUndo ?? false) == canUndo,
              (try? treeSnapshot(at: home)) == originalBytes,
              (try? treeSnapshot(at: projectURL)) == savedBytes else {
            reject("provenance inspection changed project data, costs or undo")
        }
        emit("asset-provenance", scale: scale, fields: [
            "families": cases.map { $0.family }, "syntheticReceipts": true, "exactOriginRendered": true,
            "originalSelected": true, "offlineActionsCorrect": true, "projectUnchanged": true,
            "legacyNameReadable": true,
            "viewportWidth": host.bounds.width, "viewportHeight": host.bounds.height,
            "screenshots": screenshots,
        ])
    }

    private static func makeProvenanceFixture(scale: Double) throws -> URL {
        let project = try makeProjectFixture(scale: scale)
        let manifestURL = project.appendingPathComponent(Project.manifestFilename)
        var manifest = try JSONDecoder().decode(MediaManifest.self, from: Data(contentsOf: manifestURL))
        var log = GenerationLog()
        let sourceHash = try FileDigest.sha256(of: project.appendingPathComponent("media/fixture-498.png"))
        for index in [492, 495] {
            guard let offset = manifest.entries.firstIndex(where: { $0.id == "fixture-\(index)" }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var input = GenerationInput(prompt: "Synthetic historical provenance fixture", model: "native-image-fixture",
                duration: 0, aspectRatio: "16:9")
            input.generationPackageID = String(repeating: "0", count: 64)
            input.spendTransactionId = "native-transaction-\(index)"
            input.referenceReceipts = index == 492 ? [] : [GenerationReferenceReceipt(
                assetID: "fixture-498", displayName: "Acceptance Source 498.png", type: "image",
                sourceSHA256: sourceHash, submittedSHA256: sourceHash)]
            manifest.entries[offset].generationInput = input
            manifest.entries[offset].name = index == 492
                ? "A generated image with a deliberately long original project filename.png"
                : "An enhanced image with an exact original-source revision and a long name.png"
            log.spendEvents.append(GenerationSpendEvent(transactionId: "native-transaction-\(index)",
                kind: .charged, model: input.model, provider: index == 492 ? .fal : .higgsfield,
                transport: index == 492 ? .api : .mcp, endpoint: "native-fixture",
                providerRequestId: "native-job-fixture-\(index)",
                money: GenerationMoney(nativeAmount: index == 492 ? 0.25 : 0.5, nativeCurrency: "EUR",
                    eurAmount: index == 492 ? 0.25 : 0.5, eurPerNativeUnit: 1,
                    exchangeRateDate: "2026-01-01",
                    pricingSource: "https://api.fal.ai/v1/models/billing-events?request_id=native-job-fixture-\(index)",
                    exchangeRateSource: "identity")))
        }
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try JSONEncoder().encode(log).write(to: project.appendingPathComponent(Project.generationLogFilename))
        try FileManager.default.removeItem(at: project.appendingPathComponent("media/fixture-489.png"))
        return project
    }

    private static func captureProjectCards(evidenceURL: URL, scale: Double) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let available = directory.appendingPathComponent("Claude Mouse.ngv")
        let unavailable = directory.appendingPathComponent("Unavailable Project.ngv")
        do { try FileManager.default.createDirectory(at: available, withIntermediateDirectories: true) }
        catch { fail("could not create project-card fixture", scale: scale) }
        let now = Date()
        let entries = [available, unavailable].map {
            ProjectEntry(id: UUID(), url: $0, createdDate: now, lastOpenedDate: now)
        }
        var opened: [URL] = []
        let host = NSHostingView(rootView: HStack(spacing: AppTheme.Spacing.md) {
            ForEach(entries) { entry in
                ProjectCard(entry: entry, onOpen: { opened.append($0) }, onRemove: { _ in })
                    .frame(width: AppTheme.ComponentSize.projectCardWidth)
            }
        }.padding(AppTheme.Spacing.xl).interfaceStyle())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        let firstID = "home.project.\(entries[0].id)"
        let secondID = "home.project.\(entries[1].id)"
        var previousFrame: NSRect?
        let clock = ContinuousClock()
        var stableSince = clock.now
        guard await waitUntil(timeout: .seconds(5), {
            host.layoutSubtreeIfNeeded()
            guard window.isKeyWindow, let probe = findProbe(in: host, identifier: firstID) else { return false }
            let frame = probe.convert(probe.bounds, to: nil)
            if frame != previousFrame || frame.width <= 0 || frame.height <= 0 {
                previousFrame = frame
                stableSince = clock.now
                return false
            }
            return clock.now - stableSince >= .milliseconds(300)
        }), let first = findProbe(in: host, identifier: firstID),
        let second = findProbe(in: host, identifier: secondID) else {
            let name = "scale-\(scaleLabel(scale))-project-cards-not-ready.png"
            _ = snapshot(host, at: evidenceURL.appendingPathComponent(name))
            emit("project-card-diagnostic", scale: scale, fields: [
                "reason": "native project cards did not appear", "keyWindow": window.isKeyWindow,
                "activeApp": NSApp.isActive, "screenshot": name,
                "firstFound": findProbe(in: host, identifier: firstID) != nil,
                "secondFound": findProbe(in: host, identifier: secondID) != nil,
                "windowContext": failureWindowContext(evidenceURL: evidenceURL, scale: scale, context: "project-cards"),
            ])
            fail("native project cards did not appear", scale: scale)
        }
        func reject(_ reason: String) -> Never {
            let name = "scale-\(scaleLabel(scale))-project-cards-failed.png"
            _ = snapshot(host, at: evidenceURL.appendingPathComponent(name))
            emit("project-card-diagnostic", scale: scale, fields: [
                "reason": reason, "first": frameDescription(first.bounds), "second": frameDescription(second.bounds),
                "opened": opened.map(\.lastPathComponent), "keyWindow": window.isKeyWindow,
                "available": probeState(identifier: firstID, in: window) == true,
                "unavailable": probeState(identifier: secondID, in: window) == false, "screenshot": name,
                "windowContext": failureWindowContext(evidenceURL: evidenceURL, scale: scale, context: "project-cards"),
            ])
            fail(reason, scale: scale)
        }
        // The former 150-point grid cell contained a 142 × 113.6-point card inside 4-point padding.
        guard abs(first.bounds.width - 213) <= 1,
              abs(first.bounds.height - 170.4) <= 1,
              first.bounds.size == second.bounds.size,
              probeState(identifier: firstID, in: window) == true,
              probeState(identifier: secondID, in: window) == false else {
            reject("project-card size or enabled state changed")
        }
        let unavailableParts = ["unavailable-icon", "name", "unavailable-status"].compactMap { part in
            findProbe(in: host, identifier: "\(secondID).\(part)")
        }
        let unavailableFrames = unavailableParts.map { $0.convert($0.bounds, to: second) }
        guard unavailableFrames.count == 3,
              unavailableFrames.allSatisfy({ second.bounds.contains($0) }),
              !unavailableFrames[0].intersects(unavailableFrames[1]),
              !unavailableFrames[0].intersects(unavailableFrames[2]),
              !unavailableFrames[1].intersects(unavailableFrames[2]) else {
            reject("unavailable project-card icon, name, or status overlap")
        }
        if let reason = click(identifier: firstID, in: window) { reject("project-card click: \(reason)") }
        guard await waitUntil(timeout: .seconds(5), { opened == [available] }) else {
            reject("accessible project-card click did not open exactly its project")
        }
        if let reason = click(identifier: secondID, in: window) { reject("unavailable project-card click: \(reason)") }
        try? await Task.sleep(for: .milliseconds(300))
        let name = "scale-\(scaleLabel(scale))-project-cards.png"
        guard opened == [available], snapshot(host, at: evidenceURL.appendingPathComponent(name)) else {
            fail("unavailable project opened or card capture failed", scale: scale)
        }
        emit("project-cards", scale: scale, fields: [
            "width": Double(first.bounds.width), "height": Double(first.bounds.height),
            "openVerified": true, "unavailableDisabled": true, "unavailableContentSeparated": true,
            "screenshot": name,
        ])
    }

    private static func captureAnalysis(evidenceURL: URL, scale: Double) async {
        let projectURL: URL
        let document: VideoProject
        let savedBytes: [String: Data]
        do {
            projectURL = try makeAnalysisFixture()
            savedBytes = try treeSnapshot(at: projectURL)
            document = try await VideoProject.load(from: projectURL)
        } catch { fail("could not load analysis fixture: \(error.localizedDescription)", scale: scale) }
        let surfaceBytes = Data("""
        {"id":"native-analysis","title":"Audio Analysis","phase":"analysis","data_file":"analysis/Acceptance Track.json","layout":[
          {"type":"beatTimeline","title":"Song timeline","duration_field":"duration_s","beats_field":"beats","downbeats_field":"downbeats","sections_field":"sections","sections_visibility":"whenCanonicalSections"},
          {"type":"sectionList","title":"Sections","sections_field":"sections","visibility":"whenCanonicalSections"}
        ]}
        """.utf8)
        guard let surface = try? JSONDecoder().decode(CockpitSurfaceData.self, from: surfaceBytes) else {
            fail("invalid native analysis surface fixture", scale: scale)
        }
        document.makeWindowControllers()
        let editor = document.editorViewModel
        var unavailable = false
        let host = NSHostingView(rootView: DeclarativePackSurfaceView(surface: surface,
            onUnavailable: { unavailable = true }).interfaceStyle(palette: editor.projectPalette).environment(editor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.Background.surfaceColor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 950),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        func value(_ identifier: String) -> Double? {
            (findProbe(in: host, identifier: identifier) as? AppRelaunchClickProbeView)?.acceptanceValue
        }
        func reject(_ reason: String) -> Never {
            let name = "scale-\(scaleLabel(scale))-analysis-failed.png"
            _ = snapshot(host, at: evidenceURL.appendingPathComponent(name))
            let identifiers = ["analysis.source", "analysis.play", "analysis.zoom", "analysis.selection",
                               "analysis.section.1", "analysis.waveform", "analysis.energy"]
            emit("analysis-diagnostic", scale: scale, fields: [
                "reason": reason, "screenshot": name,
                "probes": identifiers.map { id -> [String: Any] in
                    let probe = findProbe(in: host, identifier: id)
                    return ["id": id, "state": probeState(identifier: id, in: window).map { String(describing: $0) } ?? "missing",
                            "value": value(id).map { String(describing: $0) } ?? "missing",
                            "frame": probe.map { frameDescription($0.convert($0.bounds, to: host)) } ?? [:]]
                },
            ])
            fail(reason, scale: scale)
        }
        guard await waitUntil(timeout: .seconds(10), {
            host.layoutSubtreeIfNeeded()
            return window.isKeyWindow && !unavailable
                && probeState(identifier: "analysis.source", in: window) == true
                && findProbe(in: host, identifier: "analysis.waveform") != nil
                && findProbe(in: host, identifier: "analysis.energy") != nil
                && findProbe(in: host, identifier: "analysis.section.1") != nil
        }), let wave = findProbe(in: host, identifier: "analysis.waveform") else {
            reject("native analysis did not load verified audio and measured layers")
        }
        func width(_ identifier: String) -> CGFloat {
            findProbe(in: host, identifier: identifier)?.bounds.width ?? 0
        }
        let initialWidth = wave.bounds.width
        let initialName = "scale-\(scaleLabel(scale))-analysis.png"
        guard initialWidth > 0, snapshot(host, at: evidenceURL.appendingPathComponent(initialName)) else {
            reject("analysis initial waveform could not be captured")
        }
        guard await revealProbe("analysis.section.1", in: window) else {
            reject("analysis section row could not be scrolled into view")
        }
        if let reason = click(identifier: "analysis.section.1", in: window) {
            reject("analysis section click: \(reason)")
        }
        guard await waitUntil(timeout: .seconds(5), {
            probeState(identifier: "analysis.section.1", in: window) == true
                && value("analysis.selection") == 6 && value("analysis.play") == 6
        }) else { reject("analysis section click did not select its exact start time") }
        guard await revealProbe("analysis.play", in: window) else {
            reject("analysis playback control could not be scrolled into view")
        }
        if let reason = click(identifier: "analysis.play", in: window) {
            reject("analysis play click: \(reason)")
        }
        guard await waitUntil(timeout: .seconds(10), {
            probeState(identifier: "analysis.play", in: window) == true
                && (value("analysis.play") ?? 0) > 6.1
        }) else { reject("analysis native playback did not advance from the selected section") }
        if let reason = click(identifier: "analysis.play", in: window) {
            reject("analysis pause click: \(reason)")
        }
        guard await waitUntil(timeout: .seconds(5), {
            probeState(identifier: "analysis.play", in: window) == false
        }) else { reject("analysis native playback did not pause") }
        let playbackPosition = value("analysis.play") ?? 0
        guard let zoom = findProbe(in: host, identifier: "analysis.zoom"), zoom.bounds.width > 16,
              click(identifier: "analysis.zoom", in: window,
                    fraction: NSPoint(x: 1 - 8 / zoom.bounds.width, y: 0.75)) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return value("analysis.zoom") == 2
                      && abs(width("analysis.waveform") - initialWidth * 2) <= 1
                      && abs(width("analysis.energy") - initialWidth * 2) <= 1
              }) else { reject("native analysis zoom did not double the time-aligned lanes") }
        let selectedName = "scale-\(scaleLabel(scale))-analysis-selected.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(selectedName)),
              click(identifier: "analysis.fit", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  host.layoutSubtreeIfNeeded()
                  return value("analysis.zoom") == 1 && abs(width("analysis.waveform") - initialWidth) <= 1
              }), let home = editor.workingRoot else { reject("analysis Fit did not restore lane width") }
        do {
            let song = home.appendingPathComponent("pipeline/audio/Acceptance Track.wav")
            try Data("Changed source bytes".utf8).write(to: song, options: .atomic)
        } catch { reject("could not replace analysis fixture source") }
        await editor.refreshEngineState()
        guard await waitUntil(timeout: .seconds(10), {
            probeState(identifier: "analysis.source", in: window) == false
                && findProbe(in: host, identifier: "analysis.waveform") == nil
        }), click(identifier: "analysis.play", in: window) == nil else {
            reject("changed analysis source remained executable")
        }
        try? await Task.sleep(for: .milliseconds(300))
        let changedName = "scale-\(scaleLabel(scale))-analysis-source-unavailable.png"
        guard probeState(identifier: "analysis.play", in: window) == false,
              snapshot(host, at: evidenceURL.appendingPathComponent(changedName)),
              (try? treeSnapshot(at: projectURL)) == savedBytes else {
            reject("analysis played changed bytes or changed the saved project")
        }
        emit("analysis-interaction", scale: scale, fields: [
            "selectedStart": 6, "playedPosition": playbackPosition, "zoom": 2,
            "fitRestored": true, "changedSourceDisabled": true, "savedProjectUnchanged": true,
            "screenshots": [initialName, selectedName, changedName],
        ])
        window.orderOut(nil); window.contentView = nil; document.close()
        do {
            let name = "scale-\(scaleLabel(scale))-analysis-owner"
            var result = try await AnalysisRemeasurementOwnerAcceptance.run(output: evidenceURL.appendingPathComponent(name), scale: scale)
            result["evidenceDirectory"] = name
            emit("analysis-remeasurement-owner", scale: scale, fields: result)
        } catch { fail("Analysis remeasurement acceptance: " + error.localizedDescription, scale: scale) }
    }

    static func revealProbe(_ identifier: String, in window: NSWindow) async -> Bool {
        guard let root = window.contentView else { return false }
        var previousProbe: ObjectIdentifier?
        var previousFrame: NSRect?
        let revealed = await waitUntil(timeout: .seconds(5), {
            root.layoutSubtreeIfNeeded()
            guard let probe = shownProbe(in: root, identifier: identifier),
                  probe.window === window, !probe.isHiddenOrHasHiddenAncestor,
                  probe.bounds.width.isFinite, probe.bounds.height.isFinite,
                  probe.bounds.width > 0, probe.bounds.height > 0 else {
                previousProbe = nil
                previousFrame = nil
                return false
            }
            var clipped = false
            var ancestor = probe.superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView,
                   !scroll.contentView.bounds.contains(probe.convert(probe.bounds, to: scroll.contentView)) {
                    clipped = true
                    if let document = scroll.documentView {
                        let frame = probe.convert(probe.bounds, to: document)
                        let paddingX = min(AppTheme.Spacing.xs, max(0, (scroll.contentView.bounds.width - frame.width) / 2))
                        let paddingY = min(AppTheme.Spacing.xs, max(0, (scroll.contentView.bounds.height - frame.height) / 2))
                        let target = frame.insetBy(dx: -paddingX, dy: -paddingY).intersection(document.bounds)
                        if !target.isNull, !target.isEmpty {
                            document.scrollToVisible(target)
                            scroll.reflectScrolledClipView(scroll.contentView)
                            root.layoutSubtreeIfNeeded()
                        }
                    }
                }
                ancestor = view.superview
            }
            let frame = probe.convert(probe.bounds, to: root)
            guard !clipped, root.bounds.contains(frame) else {
                previousProbe = nil
                previousFrame = nil
                return false
            }
            let stable = previousProbe == ObjectIdentifier(probe) && previousFrame == frame
            previousProbe = ObjectIdentifier(probe)
            previousFrame = frame
            return stable
        })
        if !revealed, let rawScale = ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_SCALE"],
           let scale = Double(rawScale) {
            emit("probe-reveal-diagnostic", scale: scale,
                fields: ["identifier": identifier, "geometry": probeScrollDiagnostics(identifier, in: window)])
        }
        return revealed
    }

    private static func probeScrollDiagnostics(_ identifier: String, in window: NSWindow) -> [String: Any] {
        guard let root = window.contentView, let probe = shownProbe(in: root, identifier: identifier) else {
            return ["available": false]
        }
        var clips: [[String: Any]] = []
        var ancestor = probe.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView {
                clips.append(["bounds": frameDescription(scroll.contentView.bounds),
                    "control": frameDescription(probe.convert(probe.bounds, to: scroll.contentView)),
                    "document": scroll.documentView.map { frameDescription($0.bounds) } ?? [:]])
            }
            ancestor = view.superview
        }
        return ["available": true, "hidden": probe.isHiddenOrHasHiddenAncestor,
            "control": frameDescription(probe.convert(probe.bounds, to: root)),
            "window": frameDescription(root.bounds), "clips": clips]
    }

    private static func makeAnalysisFixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Analysis-\(UUID().uuidString).ngv")
        let root = home.appendingPathComponent("pipeline")
        for child in ["audio", "analysis"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(child), withIntermediateDirectories: true)
        }
        try JSONEncoder().encode(Timeline()).write(to: home.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: home.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: home.appendingPathComponent(Project.generationLogFilename))
        try Data("project: Native analysis acceptance\nmode: generic\n".utf8).write(to: root.appendingPathComponent("project.yaml"))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000),
              let samples = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = 96_000
        for index in 0..<96_000 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.1 }
        let song = root.appendingPathComponent("audio/Acceptance Track.wav")
        do {
            let audio = try AVAudioFile(forWriting: song, settings: format.settings)
            try audio.write(from: buffer)
        }
        let intervals: [[String: Double]] = [["start": 0, "end": 6], ["start": 6, "end": 12]]
        let sections: [[String: Any]] = [
            ["index": 0, "start": 0, "end": 6, "label": "Intro", "source": "measured_system_hierarchy"],
            ["index": 1, "start": 6, "end": 12, "label": "Verse", "source": "measured_system_hierarchy"],
        ]
        let hierarchy: [String: Any] = [
            "source": "apple_music_understanding", "sections": intervals, "segments": intervals,
            "phrases": [["start": 0, "end": 3], ["start": 3, "end": 6], ["start": 6, "end": 9], ["start": 9, "end": 12]],
        ]
        let resolution: [String: Any] = [
            "status": "resolved", "method": "music_understanding_hierarchy",
            "candidate_boundary_count": 1, "accepted_boundary_count": 1, "discarded_boundary_count": 0,
            "hierarchy": hierarchy, "detail": "Synthetic native interaction fixture",
        ]
        let artifact: [String: Any] = [
            "schema": "analysis/v3", "song_path": "audio/Acceptance Track.wav",
            "song_sha256": try FileDigest.sha256(of: song), "duration_s": 12, "bpm": 120,
            "beats": (0..<24).map { Double($0) / 2 }, "downbeats": [0, 2, 4, 6, 8, 10],
            "sections": sections,
            "energy_curve": (0..<12).map { second -> [String: Double] in
                let sum = (second * 8_000..<(second + 1) * 8_000).reduce(0.0) { sum, i in
                    sum + Double(samples[i] * samples[i])
                }
                return ["t": Double(second), "rms": sqrt(sum / 8_000)]
            },
            "structure_resolution": resolution,
        ]
        let artifactBytes = try JSONSerialization.data(withJSONObject: artifact, options: [.sortedKeys])
        let analysis = try JSONDecoder().decode(AnalysisSurfaceData.self, from: artifactBytes)
        guard analysis.hasNestedHierarchy, analysis.measuredEnergy != nil,
              analysis.verifiedSourceURL(dataRoot: root) != nil else {
            throw NSError(domain: "WorkspaceUIAcceptance", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Analysis fixture lacks hierarchy, energy, or a verified source"])
        }
        try artifactBytes.write(to: root.appendingPathComponent("analysis/Acceptance Track.json"))
        _ = try ProjectIdentity.uuid(for: home)
        return home
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
        try JSONEncoder().encode(makeMediaFixture(at: projectURL)).write(
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

    private static func makeMediaFixture(at projectURL: URL) throws -> MediaManifest {
        let mediaURL = projectURL.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 18, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw CocoaError(.fileWriteUnknown) }
        for y in 0..<18 {
            for x in 0..<32 { bitmap.setColor(.systemBlue, atX: x, y: y) }
        }
        guard let image = bitmap.representation(using: .png, properties: [:]),
              let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800),
              let samples = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = 800
        for index in 0..<800 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.1 }
        let seedURL = mediaURL.appendingPathComponent("seed.caf")
        do {
            let file = try AVAudioFile(forWriting: seedURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let audio = try Data(contentsOf: seedURL)
        try FileManager.default.removeItem(at: seedURL)
        var manifest = MediaManifest()
        manifest.folders = [
            MediaFolder(id: "fixture-root", name: "Acceptance Library"),
            MediaFolder(id: "fixture-nested", name: "Nested Sources", parentFolderId: "fixture-root"),
        ]
        for index in 0..<500 {
            let type: ClipType = index % 3 == 0 ? .image : index % 3 == 1 ? .audio : .document
            let ext = type == .image ? "png" : type == .audio ? "caf" : "txt"
            let name = String(format: "Acceptance Source %03d.%@", index, ext)
            let relativePath = "media/fixture-\(index).\(ext)"
            let bytes = type == .image ? image : type == .audio ? audio
                : Data("Production notes for source \(index).".utf8)
            try bytes.write(to: projectURL.appendingPathComponent(relativePath))
            manifest.entries.append(MediaManifestEntry(
                id: "fixture-\(index)", name: index == 498 ? String(repeating: "a", count: 64) : name, type: type,
                source: .project(relativePath: relativePath), duration: type == .audio ? 0.1 : 0,
                folderId: index < 250 ? "fixture-root" : "fixture-nested",
                originalFilename: name
            ))
        }
        return manifest
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
        defaults.set(true, forKey: SearchIndexConfig.enabledDefaultsKey)
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
            ["mediaFoldersPanel", "mediaPanel", "previewPanel", "inspectorPanel"]
        case .production:
            ["agentPanel", "projectPanel", "inspectorPanel"]
        case .edit:
            ["mediaPanel", "previewPanel", "inspectorPanel", "timelinePanel"]
        case .postproduction:
            ["projectPanel", "previewPanel", "inspectorPanel", "timelinePanel"]
        case .export:
            ["projectPanel", "previewPanel", "exportsPanel", "inspectorPanel"]
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
                if frame.width > 0,
                   frame.height > 0,
                   visibleBounds.contains(frame) {
                    result[identifier] = frame
                }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return result
    }

    private static func productionColumnsAreIndependent(_ frames: [String: NSRect]) -> Bool {
        guard let workflow = frames["agentPanel"], let artifact = frames["projectPanel"],
              let inspector = frames["inspectorPanel"] else { return false }
        return frames["timelinePanel"] == nil && frames["previewPanel"] == nil
            && workflow.maxX <= artifact.minX && artifact.maxX <= inspector.minX
            && abs(workflow.height - artifact.height) <= AppTheme.BorderWidth.thin
            && abs(artifact.height - inspector.height) <= AppTheme.BorderWidth.thin
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
        case .media:
            guard let library = frames["mediaPanel"], let folders = frames["mediaFoldersPanel"],
                  let preview = frames["previewPanel"], let inspector = frames["inspectorPanel"] else { return false }
            return matches("mediaFoldersPanel", AppTheme.Layout.mediaFolderTreeDefault)
                && library.width >= AppTheme.Layout.previewMinWidth
                && folders.maxX <= library.minX + tolerance
                && library.maxX <= preview.minX + tolerance
                && abs(preview.minX - inspector.minX) <= tolerance
                && matches("previewPanel", AppTheme.Layout.producePreviewDefaultWidth)
        case .edit:
            return matches("mediaPanel", AppTheme.Layout.mediaPanelDefault)
                && matches("inspectorPanel", AppTheme.Layout.inspectorDefault)
        case .production:
            return matches("agentPanel", AppTheme.Layout.workflowSidebarDefault)
                && matches("inspectorPanel", AppTheme.Layout.productionInspectorDefault)
                && productionColumnsAreIndependent(frames)
        case .postproduction, .export:
            return matches("projectPanel", AppTheme.Layout.mediaPanelDefault)
                && matches("inspectorPanel", AppTheme.Layout.inspectorDefault)
        }
    }

    private static func narrowProductionWidthsAreValid(_ frames: [String: NSRect]) -> Bool {
        let tolerance = AppTheme.Spacing.md
        guard let workflow = frames["agentPanel"], let project = frames["projectPanel"],
              let inspector = frames["inspectorPanel"] else { return false }
        return workflow.width >= AppTheme.Layout.workflowSidebarMin - tolerance
            && project.width >= AppTheme.Layout.previewMinWidth - tolerance
            && inspector.width >= AppTheme.Layout.productionInspectorMin - tolerance
            && productionColumnsAreIndependent(frames)
    }

    private static func previewTimecodeIsSingleLine(in window: NSWindow, scale: Double) -> Bool {
        guard let root = window.contentView else { return false }
        if visiblePanelFrames(in: root)["previewPanel"] == nil {
            return productionColumnsAreIndependent(visiblePanelFrames(in: root))
        }
        guard let previewFrame = visiblePanelFrames(in: root)["previewPanel"] else { return false }
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

    private static func previewHeaderIsContained(in window: NSWindow) -> Bool {
        guard let root = window.contentView,
              let panel = visiblePanelFrames(in: root)["previewPanel"],
              let title = visibleGeometryProbe(identifier: "preview.header.title", in: window, containedBy: panel) else {
            return false
        }
        return panel.contains(title.convert(title.bounds, to: root))
    }

    private static func mediaToolbarIsContained(
        in window: NSWindow, workspace: EditorViewModel.WorkspaceFocus
    ) -> Bool {
        guard let root = window.contentView,
              let panel = visiblePanelFrames(in: root)["mediaPanel"] else { return false }
        func frame(_ identifier: String) -> NSRect? {
            guard let probe = visibleGeometryProbe(identifier: identifier, in: window, containedBy: panel) else {
                return nil
            }
            let rect = probe.convert(probe.bounds, to: root)
            return panel.contains(rect) ? rect : nil
        }
        guard let tabs = frame("media.tab.Assets"),
              let actions = frame("media.actions"),
              let search = frame("media.searchControls"),
              !actions.intersects(tabs), !actions.intersects(search) else { return false }
        let titles = workspace == .media ? ["Import", "Generate", "New Folder", "Organize"]
            : ["Import", "Generate", "Media"]
        let identifiers = titles.map { "media.action.\($0)" } + ["media.action.smartSearch"]
        let frames = identifiers.compactMap(frame)
        guard frames.count == identifiers.count,
              frames.allSatisfy({ actions.contains($0) }) else { return false }
        for first in frames.indices {
            for second in frames.indices where second > first {
                if frames[first].intersects(frames[second]) { return false }
            }
        }
        return true
    }

    private static func productionControlsAreContained(in window: NSWindow) -> Bool {
        guard let root = window.contentView,
              let workflowFrame = visiblePanelFrames(in: root)["agentPanel"] else { return false }
        let bounds = workflowFrame.insetBy(dx: -AppTheme.BorderWidth.thin, dy: -AppTheme.BorderWidth.thin)
        return visibleProbe(identifier: "production.sidebar", in: window, containedBy: bounds)
            && visibleProbe(identifier: "production.status", in: window, containedBy: root.bounds)
    }

    static func visibleProbe(
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

    private static func failureWindowContext(evidenceURL: URL, scale: Double, context: String) -> [String: Any] {
        func nativeText(in view: NSView) -> [String] {
            var values: [String] = []
            if let field = view as? NSTextField, !field.stringValue.isEmpty { values.append(field.stringValue) }
            if let button = view as? NSButton, !button.title.isEmpty { values.append(button.title) }
            for child in view.subviews where !child.isHiddenOrHasHiddenAncestor {
                values.append(contentsOf: nativeText(in: child))
            }
            return values
        }
        let windows: [[String: Any]] = NSApp.windows.filter(\.isVisible).enumerated().map { index, window in
            var fields: [String: Any] = [
                "class": String(describing: type(of: window)), "title": window.title,
                "number": window.windowNumber, "key": window.isKeyWindow,
                "modal": window.isModalPanel, "sheet": window.isSheet,
                "sheetParentNumber": window.sheetParent?.windowNumber ?? -1,
                "frame": frameDescription(window.frame),
                "document": (window.windowController?.document as? NSDocument)?.fileURL?.lastPathComponent ?? "",
            ]
            if let content = window.contentView {
                let name = "scale-\(scaleLabel(scale))-\(context)-window-\(index).png"
                fields["nativeText"] = nativeText(in: content)
                fields["screenshot"] = snapshot(content, at: evidenceURL.appendingPathComponent(name)) ? name : ""
            }
            return fields
        }
        return [
            "activeApp": NSApp.isActive, "keyWindowNumber": NSApp.keyWindow?.windowNumber ?? -1,
            "modalWindowNumber": NSApp.modalWindow?.windowNumber ?? -1, "windows": windows,
            "documents": NSDocumentController.shared.documents.map { $0.fileURL?.lastPathComponent ?? "untitled" },
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

    static func snapshot(_ view: NSView, at url: URL) -> Bool {
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

    static func click(identifier: String, in window: NSWindow, fraction: NSPoint = NSPoint(x: 0.5, y: 0.5), clickCount: Int = 1) -> String? {
        guard (1...2).contains(clickCount) else { return "unsupported click count" }
        guard window.isVisible, window.isKeyWindow, !window.ignoresMouseEvents,
              let root = window.contentView,
              let probe = shownProbe(in: root, identifier: identifier),
              probe.window === window,
              !probe.isHiddenOrHasHiddenAncestor else {
            return "control geometry unavailable"
        }
        let frame = probe.bounds
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            return "control has no finite frame"
        }
        guard fraction.x.isFinite, fraction.y.isFinite,
              (0...1).contains(fraction.x), (0...1).contains(fraction.y) else { return "invalid click fraction" }
        let point = NSPoint(x: frame.minX + frame.width * fraction.x, y: frame.minY + frame.height * fraction.y)
        let location = probe.convert(point, to: nil)
        guard root.bounds.contains(root.convert(location, from: nil)) else {
            return "control is outside the window"
        }
        let start = ProcessInfo.processInfo.systemUptime
        for count in 1...clickCount {
            let timestamp = start + Double(count - 1) * min(0.08, NSEvent.doubleClickInterval / 4)
            guard let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: count,
                pressure: 1
            ), let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: location,
                modifierFlags: [],
                timestamp: timestamp + 0.001,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: count,
                pressure: 0
            ) else {
                return "AppKit could not create mouse events"
            }
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
        }
        return nil
    }

    /// Layouts such as ViewThatFits can keep an unused variant's probe; act on the one on screen.
    private static func shownProbe(in root: NSView, identifier: String) -> NSView? {
        probes(in: root, identifier: identifier).first {
            !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0
        } ?? findProbe(in: root, identifier: identifier)
    }

    static func findProbe(in view: NSView, identifier: String) -> NSView? {
        if view is AppRelaunchClickProbeView, view.identifier?.rawValue == identifier {
            return view
        }
        for child in view.subviews {
            if let match = findProbe(in: child, identifier: identifier) { return match }
        }
        return nil
    }

    static func probeState(identifier: String, in window: NSWindow) -> Bool? {
        guard let root = window.contentView,
              let probe = findProbe(in: root, identifier: identifier)
                as? AppRelaunchClickProbeView else { return nil }
        return probe.acceptanceState
    }

    static func probeFrame(identifier: String, in window: NSWindow) -> NSRect? {
        guard let root = window.contentView,
              let probe = shownProbe(in: root, identifier: identifier) else { return nil }
        return probe.convert(probe.bounds, to: root)
    }

    static func probeText(identifier: String, in window: NSWindow) -> String? {
        guard let root = window.contentView else { return nil }
        return (shownProbe(in: root, identifier: identifier) as? AppRelaunchClickProbeView)?.acceptanceText
    }

    static func nativeElement<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { nativeElement(type, in: $0) }.first
    }

    private static func stablePanelFrames(
        in host: NSView, matching expected: [String: NSRect]? = nil
    ) async -> [String: NSRect]? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var previous: [String: NSRect] = [:]
        var stableSince = clock.now
        while clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            let frames = visiblePanelFrames(in: host)
            if frames.isEmpty || frames != previous || (expected != nil && frames != expected) {
                previous = frames
                stableSince = clock.now
            } else if clock.now - stableSince >= .milliseconds(300) {
                return frames
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        return nil
    }

    static func waitUntil(
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

extension WorkspaceUIAcceptance {
    /// Owner-visible Tasks history after resume, approval, revision and a rejected first write (#532).
    fileprivate static func captureHostStateHistory(evidenceURL: URL, scale: Double) async {
        func record(_ state: AgentHostStateRecord.State, _ phase: String, action: AgentHostStateRecord.Action = .none,
                    resetPhases: [String]? = nil, note: String? = nil, artifactPath: String? = nil) -> AgentHostStateRecord {
            AgentHostStateRecord(state: state, phase: phase, toolName: "write_\(phase)", action: action,
                artifactPath: artifactPath, byteComparison: nil, previousSHA256: nil, currentSHA256: nil,
                resetPhases: resetPhases, note: note)
        }
        let checkedBible = record(.checked, "bible", action: .reviewForApproval)
        let approvedBible = record(.approved, "bible")
        let approvedTreatment = record(.approved, "treatment")
        let rewound = record(.rewound, "treatment", resetPhases: ["treatment", "storyboard", "bible"],
            note: "Four locations instead of six")
        let rejectedShotlist = record(.writeRejected, "shotlist", action: .agentCorrection,
            artifactPath: PipelineLayout.shotlistVersionFile(1))
        let turns: [[AgentHostStateRecord]] = [[checkedBible], [approvedBible, approvedTreatment], [rewound], [rejectedShotlist]]
        let messages = turns.enumerated().flatMap { index, records in
            [
                AgentMessage(role: .user, blocks: [.text("Continue \(index).")], hidden: true),
                AgentMessage(role: .assistant, blocks: [], hostStateRecords: records),
            ]
        }
        let projected = AgentTranscriptProjection.turns(messages: messages, isStreaming: false)
        let editor = EditorViewModel()
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(projected) { turn in
                AgentTranscriptTurnView(turn: turn, toolResults: [:])
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(editor)
        .interfaceStyle())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 900),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        let all = [checkedBible, approvedBible, approvedTreatment, rewound, rejectedShotlist]
        func probe(_ record: AgentHostStateRecord) -> AppRelaunchClickProbeView? {
            findProbe(in: host, identifier: "agent.hostState.\(record.id.uuidString)") as? AppRelaunchClickProbeView
        }
        let ready = await waitUntil(timeout: .seconds(5)) {
            host.layoutSubtreeIfNeeded()
            return all.allSatisfy { probe($0)?.acceptanceText != nil }
        }
        let name = "scale-\(scaleLabel(scale))-host-state-history.png"
        let captured = snapshot(host, at: evidenceURL.appendingPathComponent(name))
        guard ready, captured else { fail("host state history did not render", scale: scale) }
        func text(_ record: AgentHostStateRecord) -> String { probe(record)?.acceptanceText ?? "" }
        func reviewOffered(_ record: AgentHostStateRecord) -> Bool { probe(record)?.acceptanceState == true }
        let shotList = PhaseDisplay.label("shotlist")
        emit("host-state-history", scale: scale, fields: [
            "supersededRequestHasNoAction": text(checkedBible).contains("Superseded by a later update.")
                && !reviewOffered(checkedBible),
            "resetApprovalsMarked": [approvedBible, approvedTreatment].allSatisfy {
                text($0).contains("Reset by a later revision.") && !reviewOffered($0)
            },
            "revisionNamesResetApprovals": text(rewound).contains("Revising from \(PhaseDisplay.label("treatment"))")
                && text(rewound).contains("Reset approvals: \(["treatment", "storyboard", "bible"].map(PhaseDisplay.label).joined(separator: ", "))"),
            "rejectedFirstWriteNotUnverified": text(rejectedShotlist).hasPrefix("\(shotList) not saved")
                && text(rejectedShotlist).contains("No earlier version exists yet.")
                && !text(rejectedShotlist).contains("unverified") && !reviewOffered(rejectedShotlist),
            "screenshots": [name],
        ])
    }
}

extension WorkspaceUIAcceptance {
    /// A pending Storyboard approval reviewed in the shared cockpit tab, never in a modal surface (#623).
    fileprivate static func captureStoryboardReview(evidenceURL: URL, scale: Double) async {
        let projectURL: URL
        let savedBytes: [String: Data]
        let document: VideoProject
        do {
            projectURL = try makeStoryboardFixture()
            savedBytes = try treeSnapshot(at: projectURL)
            document = try await VideoProject.load(from: projectURL)
        } catch { fail("could not open the Storyboard fixture: \(error.localizedDescription)", scale: scale) }
        document.makeWindowControllers()
        guard let productionWindow = document.windowControllers
            .compactMap({ $0 as? EditorWindowController }).first?.window else {
            fail("Storyboard fixture did not create its document window", scale: scale)
        }
        // Initialize the document once, then let only the cockpit under test own tab selection.
        weak var initialContentController = productionWindow.contentViewController
        productionWindow.contentViewController = nil
        productionWindow.contentView = nil
        guard await waitUntil(timeout: .seconds(5), { initialContentController == nil }) else {
            fail("Storyboard fixture retained a competing production cockpit", scale: scale)
        }
        let editor = document.editorViewModel
        editor.setWorkspaceFocus(.production)
        await editor.refreshEngineState()
        guard let home = editor.workingRoot, let dataRoot = DataRootResolver.dataRoot(of: home),
              let requested = try? StoryboardReviewSnapshot.read(root: dataRoot),
              editor.agentService.pendingDialog == nil,
              PipelineSurfaceRouting.route(for: "storyboard", contract: editor.uiContract,
                  availablePackSurfaces: editor.availableCockpitPackSurfaces)?.destination == .tab(.storyboard) else {
            fail("Storyboard fixture lost its working copy, artifact or canonical route", scale: scale)
        }
        let gatesURL = PipelineLayout.url(PipelineLayout.gatesFile, in: dataRoot)
        let gates = try? Data(contentsOf: gatesURL)
        let approval: GateApproval
        do {
            approval = try editor.agentService.requestGateApproval(GateApproval(
                phase: "storyboard",
                dataRoot: dataRoot,
                declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding,
                artifactFingerprint: GateArtifactFingerprint(
                    path: PipelineLayout.storyboardCurrentFile,
                    sha256: requested.sha256,
                    lineageSHA256: try? FileDigest.sha256(of: PipelineLayout.url(PipelineLayout.lineageFile, in: dataRoot)),
                    phase: "storyboard"
                )
            )).approval
        } catch { fail("could not request the Storyboard approval: \(error.localizedDescription)", scale: scale) }
        editor.cockpitTab = .pipeline
        editor.cockpitPackSurfaceID = nil
        let host = NSHostingView(rootView: HStack(spacing: AppTheme.Spacing.lg) {
            ProjectCockpitView().frame(width: AppTheme.Acceptance.pipelineOverviewWidth)
            AgentPanelView()
        }.interfaceStyle(palette: editor.projectPalette).environment(editor)
            .frame(width: AppTheme.Acceptance.musicvideoViewport.width, height: AppTheme.Acceptance.musicvideoViewport.height)
            .background(AppTheme.Background.surfaceColor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 950),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        let baseline = Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) })
        func shown(_ id: String) -> AppRelaunchClickProbeView? {
            probes(in: host, identifier: id).first { !$0.isHiddenOrHasHiddenAncestor } as? AppRelaunchClickProbeView
        }
        func text(_ id: String) -> String? { shown(id)?.acceptanceText }
        func state(_ id: String) -> Bool? { shown(id)?.acceptanceState }
        func modalSurfaces() -> [String] {
            var found = NSApp.windows.filter {
                $0.isVisible && ($0.isSheet || $0.isModalPanel || $0.sheetParent != nil
                    || ($0.styleMask.contains(.titled) && !baseline.contains(ObjectIdentifier($0))))
            }.map { String(describing: type(of: $0)) }
            if window.attachedSheet != nil { found.append("attachedSheet") }
            if NSApp.modalWindow != nil { found.append("modalWindow") }
            return found
        }
        func reject(_ reason: String) -> Never {
            _ = snapshot(host, at: evidenceURL.appendingPathComponent("scale-\(scaleLabel(scale))-storyboard-failed.png"))
            emit("storyboard-diagnostic", scale: scale, fields: [
                "reason": reason, "tab": editor.cockpitTab.rawValue,
                "pending": editor.agentService.pendingGateApproval?.phase ?? "none",
                "open": text("agent.gate.open") ?? "missing", "approve": text("agent.gate.approve") ?? "missing",
                "review": text("storyboard.review") ?? "missing", "document": text("storyboard.document") ?? "missing",
                "row": text("pipeline.overview.surface.storyboard") ?? "missing", "modal": modalSurfaces(),
                "windowContext": failureWindowContext(evidenceURL: evidenceURL, scale: scale, context: "storyboard"),
            ])
            fail(reason, scale: scale)
        }
        let checking = "Checking the current phase…"
        let storyboardTitle = CockpitTab.storyboard.rawValue
        func reviewIsOffered() -> Bool {
            host.layoutSubtreeIfNeeded()
            guard window.isKeyWindow, state("cockpit.tab.Pipeline") == true else { return false }
            guard text("agent.gate.open") == storyboardTitle, state("agent.gate.open") == true else { return false }
            guard state("agent.gate.decline") == true, state("agent.gate.approve") != nil else { return false }
            guard text("agent.gate.approve") != checking else { return false }
            guard text("pipeline.overview.surface.storyboard") == storyboardTitle else { return false }
            guard state("pipeline.overview.surface.storyboard") == true else { return false }
            return modalSurfaces().isEmpty
        }
        guard await waitUntil(timeout: .seconds(10), reviewIsOffered) else {
            reject("the pending Storyboard approval or its Pipeline action did not render")
        }
        let cardDestination = text("agent.gate.open") ?? ""
        let pipelineDestination = text("pipeline.overview.surface.storyboard") ?? ""
        let approveState = state("agent.gate.approve")
        let approveBlocker = text("agent.gate.approve")
        func showsStoryboard(_ snapshot: StoryboardReviewSnapshot, _ binding: StoryboardReviewBinding) -> Bool {
            host.layoutSubtreeIfNeeded()
            guard state("cockpit.tab.Storyboard") == true, editor.cockpitTab == .storyboard else { return false }
            guard editor.cockpitPackSurfaceID == nil, editor.workspaceFocus == .production else { return false }
            guard text("storyboard.document") == snapshot.sha256 else { return false }
            guard text("storyboard.review") == binding.rawValue else { return false }
            guard findProbe(in: host, identifier: "pipeline.overview.root") == nil else { return false }
            return modalSurfaces().isEmpty
        }
        func showsRequestedStoryboard() -> Bool {
            editor.agentService.pendingGateApproval?.id == approval.id && showsStoryboard(requested, .current)
        }
        func activate(_ identifier: String, _ failure: String) async {
            _ = await revealProbe(identifier, in: window)
            if let reason = click(identifier: identifier, in: window) { reject("\(failure): \(reason)") }
        }
        await activate("agent.gate.open", "Open Storyboard could not be clicked")
        guard await waitUntil(timeout: .seconds(5), showsRequestedStoryboard) else {
            reject("Open Storyboard did not select the Storyboard tab with the requested bytes")
        }
        let opened = "scale-\(scaleLabel(scale))-storyboard-review.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(opened)) else { reject("could not capture the Storyboard tab") }

        func otherTabKeepsCard() -> Bool {
            host.layoutSubtreeIfNeeded()
            guard state("cockpit.tab.References") == true, text("agent.gate.open") == cardDestination else { return false }
            guard findProbe(in: host, identifier: "storyboard.document") == nil else { return false }
            return modalSurfaces().isEmpty
        }
        await activate("cockpit.tab.References", "References tab could not open")
        guard await waitUntil(timeout: .seconds(5), otherTabKeepsCard) else {
            reject("switching tabs lost the approval card or kept the Storyboard")
        }
        await activate("cockpit.tab.Storyboard", "Storyboard tab could not reopen")
        guard await waitUntil(timeout: .seconds(5), showsRequestedStoryboard) else {
            reject("returning to the Storyboard tab did not show the requested bytes")
        }
        func pipelineOffersStoryboard() -> Bool {
            host.layoutSubtreeIfNeeded()
            guard state("cockpit.tab.Pipeline") == true else { return false }
            guard text("pipeline.overview.surface.storyboard") == cardDestination else { return false }
            return state("pipeline.overview.surface.storyboard") == true
        }
        await activate("cockpit.tab.Pipeline", "Pipeline tab could not open")
        guard await waitUntil(timeout: .seconds(5), pipelineOffersStoryboard) else {
            reject("Pipeline did not offer the Storyboard action")
        }
        await activate("pipeline.overview.surface.storyboard", "the Pipeline Storyboard action could not be clicked")
        guard await waitUntil(timeout: .seconds(5), showsRequestedStoryboard) else {
            reject("the Pipeline Storyboard action did not open the same tab and bytes")
        }
        func approvalControlsUsable() -> Bool {
            host.layoutSubtreeIfNeeded()
            guard editor.agentService.pendingGateApproval?.id == approval.id else { return false }
            for id in ["agent.gate.open", "agent.gate.decline", "agent.gate.approve"] {
                guard visibleProbe(identifier: id, in: window, containedBy: host.bounds) else { return false }
            }
            guard state("agent.gate.open") == true, state("agent.gate.decline") == true else { return false }
            guard state("agent.gate.approve") == approveState else { return false }
            guard text("agent.gate.approve") == approveBlocker else { return false }
            return modalSurfaces().isEmpty
        }
        guard await waitUntil(timeout: .seconds(5), approvalControlsUsable) else {
            reject("the approval controls changed or were covered after the tab round trip")
        }

        let revised: StoryboardReviewSnapshot
        do {
            try StoryboardStore.save(storyboardFixture(subject: "The singer stops at the platform edge.", version: 2),
                to: dataRoot)
            revised = try StoryboardReviewSnapshot.read(root: dataRoot)
        } catch { reject("could not revise the Storyboard during review") }
        await editor.refreshEngineState()
        let changedBlocker = "This revision changed. Request a new approval for the updated artifact."
        func changeIsMarked() -> Bool {
            guard editor.agentService.pendingGateApproval?.id == approval.id else { return false }
            guard showsStoryboard(revised, .changed) else { return false }
            guard state("agent.gate.approve") == false else { return false }
            return text("agent.gate.approve") == changedBlocker
        }
        guard revised.sha256 != requested.sha256, await waitUntil(timeout: .seconds(10), changeIsMarked) else {
            reject("a Storyboard change during review was not marked or still offered approval")
        }
        let changed = "scale-\(scaleLabel(scale))-storyboard-changed.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(changed)) else {
            reject("could not capture the changed Storyboard")
        }

        func declinedFromStoryboard() -> Bool {
            guard editor.agentService.pendingGateApproval == nil else { return false }
            guard showsStoryboard(revised, .unrelated) else { return false }
            return findProbe(in: host, identifier: "agent.gate.open") == nil
        }
        await activate("agent.gate.decline", "Not yet could not be clicked")
        guard await waitUntil(timeout: .seconds(5), declinedFromStoryboard) else {
            reject("Not yet did not resolve the approval while the Storyboard stayed open")
        }
        guard gates != nil, (try? Data(contentsOf: gatesURL)) == gates,
              (try? treeSnapshot(at: projectURL)) == savedBytes else {
            reject("reviewing or declining changed the gates or the saved project")
        }
        window.orderOut(nil)
        window.contentView = nil
        let productionContent = NSHostingController(rootView:
            EditorWindowContentView().environment(editor).tint(AppTheme.Accent.primary))
        productionContent.sizingOptions = []
        productionContent.safeAreaRegions = []
        productionWindow.contentViewController = productionContent
        await captureProductionWorkbench(document: document, evidenceURL: evidenceURL, scale: scale)
        do {
            try await captureProductionActivity(document: document, evidenceURL: evidenceURL, scale: scale)
        } catch { fail("native production activity: \(error.localizedDescription)", scale: scale) }
        do {
            let activityImages = try await AgentActivityAcceptance.run(evidenceURL: evidenceURL, scale: scale)
            emit("agent-activity", scale: scale, fields: ["complete": true, "screenshots": activityImages])
        } catch { fail("native agent activity acceptance failed: \(error.localizedDescription)", scale: scale) }
        emit("storyboard-review", scale: scale, fields: [
            "cardDestination": cardDestination, "pipelineDestination": pipelineDestination,
            "openedTabWithoutModal": true, "tabRoundTrip": true, "pipelineActionSameTarget": true,
            "approvalControlsUsable": true, "shownBytesMatchApproval": true, "changeMarked": true,
            "declinedFromStoryboard": true, "gatesUnchanged": true, "savedProjectUnchanged": true,
            "screenshots": [opened, changed],
        ])
    }

    private static func captureProductionPlanning(evidenceURL: URL, scale: Double) async {
        do {
            let fixture = try await ProductionPlanningAcceptanceFixture.makeScript()
            let editor = fixture.editor
            if fixture.document.windowControllers.isEmpty { fixture.document.makeWindowControllers() }
            guard let window = fixture.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window,
                  let host = window.contentView else { throw ToolError("The planning fixture has no native document window.") }
            window.setContentSize(AppTheme.Acceptance.musicvideoViewport)
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            editor.setWorkspaceFocus(.production)
            editor.revealCockpit(.script)
            var screenshots: [String] = []
            func capture(_ name: String) throws {
                let file = "scale-\(scaleLabel(scale))-planning-\(name).png"
                guard snapshot(host, at: evidenceURL.appendingPathComponent(file)) else { throw ToolError("Planning screenshot failed: \(name).") }
                screenshots.append(file)
            }
            func activate(_ id: String, in target: NSWindow? = nil) async throws {
                let target = target ?? window
                guard await revealProbe(id, in: target), click(identifier: id, in: target) == nil else {
                    throw ToolError("The planning control cannot be reached: \(id).")
                }
            }
            func require(_ predicate: @escaping () -> Bool, _ message: String) async throws {
                guard await waitUntil(timeout: .seconds(10), predicate) else { throw ToolError(message) }
            }
            func requestApproval(_ phase: String, path: String) throws {
                let root = fixture.dataRoot
                _ = try editor.agentService.requestGateApproval(.init(phase: phase, dataRoot: root,
                    declaredProductionContract: .current,
                    artifactFingerprint: .init(path: path, sha256: FileDigest.sha256(of: root.appendingPathComponent(path)),
                        lineageSHA256: FileDigest.sha256(of: root.appendingPathComponent(PipelineLayout.lineageFile)), phase: phase)))
            }
            try await require({ probeText(identifier: "script.event.event-red", in: window) == ProductionPlanningAcceptanceFixture.actions[0] },
                "Script did not show the canonical event text.")
            try await activate("script.scene.edit.red")
            try await require({ window.attachedSheet != nil }, "Edit Script did not open a native sheet.")
            guard let sheet = window.attachedSheet else { throw ToolError("The Script sheet disappeared.") }
            try await activate("script.scene.title", in: sheet)
            try await require({ sheet.firstResponder is NSTextView }, "The scene title did not receive keyboard focus.")
            guard let field = sheet.firstResponder as? NSTextView else { throw ToolError("The scene title has no text editor.") }
            field.setSelectedRange(NSRange(location: 0, length: (field.string as NSString).length))
            field.insertText("Red circle in side light", replacementRange: NSRange(location: NSNotFound, length: 0))
            sheet.makeFirstResponder(nil)
            try await require({ probeState(identifier: "script.scene.apply", in: sheet) == true }, "The changed scene could not be applied.")
            try await activate("script.scene.apply", in: sheet)
            try await require({ window.attachedSheet == nil }, "Applying the scene did not close its sheet.")
            let edited = try PlanningWriterIO.script(dataRoot: fixture.dataRoot)
            guard edited.header.revision == 2, edited.scenes.first?.title == "Red circle in side light",
                  edited.events.map(\.action) == ProductionPlanningAcceptanceFixture.actions else {
                throw ToolError("The native Script edit did not preserve the actions and publish its new revision.")
            }
            try capture("script")
            try requestApproval("script", path: ScriptV1.currentPath)
            try await require({ probeState(identifier: "agent.gate.approve", in: window) == true }, "Script approval did not become ready.")
            try await activate("agent.gate.approve")
            try await require({ editor.projectState?.nextPhaseName == "storyboard" && editor.agentService.pendingGateApproval == nil },
                "Approving Script did not advance to Storyboard.")
            let missing = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: fixture)
            editor.revealCockpit(.storyboard)
            try requestApproval("storyboard", path: StoryboardV2.currentPath)
            try await require({ probeText(identifier: "storyboard.moment.moment-1", in: window) == "missing"
                && probeState(identifier: "agent.gate.approve", in: window) == false
                && probeText(identifier: "agent.gate.approve", in: window) != "Checking the current phase…" },
                "A Storyboard without sketches must show the missing image and refuse approval.")
            try capture("missing-sketch")
            try await activate("agent.gate.decline")
            try await require({ editor.agentService.pendingGateApproval == nil }, "Not yet did not leave Storyboard editable.")
            let board = try await ProductionPlanningAcceptanceFixture.attachSketches(in: fixture)
            guard board.fingerprint != missing.fingerprint, let first = board.timing.shots.first,
                  let moment = first.moments.first, let image = moment.asset?.image else {
                throw ToolError("Native sketch attachment did not create an exact image binding.")
            }
            try await require({ probeText(identifier: "storyboard.moment.moment-1", in: window) == image.sha256 },
                "The Storyboard did not show its assigned sketch.")
            try capture("sketches")
            try await activate("storyboard.animatic.\(first.id)")
            try await require({ probeText(identifier: "animatic.image", in: window) == "\(moment.id):\(image.sha256)" },
                "The Animatic did not show the assigned first sketch.")
            try await activate("animatic.play")
            try await require({ editor.storyboardAnimaticPlayback?.isPlaying == true && (editor.storyboardAnimaticPlayback?.tick ?? 0) > 0 },
                "The Animatic did not advance after native Play.")
            try await activate("animatic.play")
            try await require({ editor.storyboardAnimaticPlayback?.isPlaying == false }, "The Animatic did not pause.")
            try capture("animatic")
            guard click(identifier: "storyboard.view", in: window, fraction: NSPoint(x: 0.25, y: 0.5)) == nil else {
                throw ToolError("The Board switch is unreachable.")
            }
            try await require({ probeState(identifier: "storyboard.view", in: window) == false }, "The Board switch did not return to sketches.")
            try requestApproval("storyboard", path: StoryboardV2.currentPath)
            editor.showsAgentActivity = true
            try await require({ probeState(identifier: "agent.gate.approve", in: window) == true
                && findProbe(in: host, identifier: "production.activity") != nil }, "Storyboard approval and AI activity did not appear together.")
            guard let button = probeFrame(identifier: "agent.gate.approve", in: window),
                  let activity = probeFrame(identifier: "production.activity", in: window),
                  host.bounds.contains(button), !activity.intersects(button) else {
                throw ToolError("AI activity covers or clips the Storyboard approval button.")
            }
            try capture("approval-with-activity")
            try await activate("agent.gate.approve")
            try await require({ editor.projectState?.nextPhaseName == "shot_planning" && editor.agentService.pendingGateApproval == nil },
                "The visible Storyboard approval did not advance the actual workflow.")
            let draft = try await ProductionPlanningAcceptanceFixture.writeShotPlanning(in: fixture)
            editor.showsAgentActivity = false
            editor.revealCockpit(.shotPlanning)
            try await require({ findProbe(in: host, identifier: "shot-planning.workspace") != nil
                && findProbe(in: host, identifier: "shot-planning.apply.\(draft.shots[0].shotID)") != nil },
                "Shot Planning did not expose its native editing controls.")
            try capture("shot-planning")
            let gates = try YAMLArtifactStore(dataRoot: fixture.dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
            guard ["project_init", "brief", "production_design", "treatment", "script", "storyboard"].allSatisfy({ gates.gates[$0]?.approved == true }),
                  gates.gates["shot_planning"]?.approved == false else { throw ToolError("Planning approval history differs from the performed native actions.") }
            emit("production-planning", scale: scale, fields: [
                "workflow": "core.production.v2", "actualToolWriters": true, "nativeScriptEdit": true,
                "missingSketchBlocked": true, "nativeSketchAssignment": true, "animaticPlayedAndPaused": true,
                "activityDoesNotCoverApproval": true, "nativeApprovalAdvancedPhase": true,
                "shotIDsPreserved": board.timing.shots.map(\.id) == draft.shots.map(\.shotID),
                "generatedSketchesTested": false, "screenshots": screenshots,
            ])
        } catch { fail("production planning: \(error.localizedDescription)", scale: scale) }
    }

    private static func makeStoryboardFixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Storyboard-\(UUID().uuidString).ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try JSONEncoder().encode(Timeline()).write(to: home.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: home.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: home.appendingPathComponent(Project.generationLogFilename))
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "Native Storyboard acceptance")
        let brief = try Brief(project: "Night platform", generated: "2026-10-17", mission: .artPiece,
            targetPlatform: "Cinema", aspectRatio: .landscape16x9, projectMode: "production",
            conceptType: .narrative, visualMedium: .liveActionRealistic, figures: .artistOnly,
            lyricsIntegration: .metaphorical, notes: "A singer leaves the city behind as night turns to morning.")
        try YAMLArtifactStore(dataRoot: dataRoot).save(brief, to: PipelineLayout.briefFile)
        try StoryboardStore.save(storyboardFixture(subject: "The singer crosses the empty night platform.", version: 1),
            to: dataRoot)
        _ = try ProjectIdentity.uuid(for: home)
        return home
    }

    private static func captureProductionWorkbench(document: VideoProject, evidenceURL: URL, scale: Double) async {
        let editor = document.editorViewModel
        guard let window = document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window,
              let host = window.contentView else { fail("native production editor is unavailable", scale: scale) }
        window.setContentSize(AppTheme.Acceptance.workbenchViewport)
        window.appearance = NSAppearance(named: .darkAqua)
        document.showWindows()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.setWorkspaceFocus(.production)
        defer { window.orderOut(nil) }
        guard await waitUntil(timeout: .seconds(10), {
            host.layoutSubtreeIfNeeded()
            return productionColumnsAreIndependent(visiblePanelFrames(in: host))
                && productionControlsAreContained(in: window)
        }) else { fail("native production columns or status did not render", scale: scale) }
        var captures: [String] = []
        var inspectorSelections: [[String: Any]] = []
        var storyboardCards: [[String: Any]] = []
        for phase in ["project_init", "brief", "storyboard"] {
            let identifier = "pipeline.overview.select.\(phase)"
            guard await revealProbe(identifier, in: window), click(identifier: identifier, in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.productionSelectedPhase == phase
                          && findProbe(in: host, identifier: "pipeline.overview.dock.status") != nil
                          && (phase != "storyboard" || findProbe(in: host, identifier: "storyboard.shot.chorus1.01") != nil)
                  }) else { fail("native production phase could not be selected: \(phase)", scale: scale) }
            if phase == "storyboard" {
                let expectedSelections: [(String, [(String, String)])] = [
                    ("verse1.01", [("Section", "Verse 1"), ("Section timing", "0.0–12.0 s"),
                        ("Camera", "Slow dolly"), ("Framing", "Wide"), ("Angle", "Frontal"), ("Height", "Eye Level")]),
                    ("chorus1.01", [("Section", "Chorus 1"), ("Section timing", "12.0–24.0 s"),
                        ("Camera", "Slow push in"), ("Framing", "Medium"), ("Angle", "Frontal"),
                        ("Lens Hint", "Wide"), ("Location view", "Wide · Noon")]),
                ]
                for (shotID, fields) in expectedSelections {
                    let control = "storyboard.shot.\(shotID)"
                    guard await revealProbe(control, in: window), click(identifier: control, in: window) == nil,
                          await waitUntil(timeout: .seconds(5), {
                              probeText(identifier: "storyboard.inspector", in: window) == shotID
                          }), let inspector = panelView(in: host, identifier: "inspectorPanel") else {
                        fail("storyboard shot did not bind its technical inspector", scale: scale)
                    }
                    let text = renderedAccessibilityText(in: inspector).joined(separator: "\n")
                    guard fields.allSatisfy({ text.contains($0.0) && text.contains($0.1) }),
                          text.contains("AI generation"),
                          !text.contains(shotID == "chorus1.01" ? "Slow dolly" : "Slow push in"),
                          !["basis: inferred", "angle:", "height:", "lens_hint", "eye_level", "wide.noon"]
                            .contains(where: text.contains) else {
                        fail("the selected Storyboard inspector omitted readable fields or retained another shot", scale: scale)
                    }
                    inspectorSelections.append(["shotID": shotID, "controlID": control,
                        "renderedFields": fields.map { ["label": $0.0, "value": $0.1] },
                        "rawFieldsAbsent": true, "previousSelectionAbsent": true])
                }
                guard let artifactHost = panelView(in: host, identifier: "projectPanel") else {
                    fail("storyboard artifact host is unavailable", scale: scale)
                }
                let expectedCards = [
                    ("verse1.01", "The singer stops at the platform edge."),
                    ("verse1.02", "A train passes the empty platform."),
                    ("chorus1.01", "The singer turns toward the morning light."),
                ]
                let forbidden = ["basis: inferred", "angle:", "height:", "lens_hint:",
                    "generated", "transition", "performance", "wide.noon"]
                // SwiftUI's in-process AX tree omits these cards; verify the visible pixels.
                for (shotID, subject) in expectedCards {
                    let control = "storyboard.shot.\(shotID)"
                    guard await revealProbe(control, in: window) else {
                        fail("storyboard card is not fully reachable: \(shotID)", scale: scale)
                    }
                    var rendered = ""
                    var leaked: [String] = []
                    var pixelEvidence: [String: Any] = [:]
                    var crop: Data?
                    var captureError: String?
                    let verified = await waitUntil(timeout: .seconds(5), {
                        host.layoutSubtreeIfNeeded()
                        rendered = ""
                        leaked = []
                        crop = nil
                        pixelEvidence = [:]
                        captureError = nil
                        guard let probe = shownProbe(in: host, identifier: control),
                              probe.window === window, probe.isDescendant(of: artifactHost),
                              !probe.isHiddenOrHasHiddenAncestor,
                              visibleProbe(identifier: control, in: window,
                                containedBy: artifactHost.convert(artifactHost.bounds, to: host)) else { return false }
                        var ancestor = probe.superview
                        while let view = ancestor, view !== artifactHost {
                            if let clip = view as? NSClipView,
                               !clip.bounds.contains(probe.convert(probe.bounds, to: clip)) { return false }
                            ancestor = view.superview
                        }
                        let frame = probe.convert(probe.bounds, to: artifactHost)
                        guard frame.width > 0, frame.height > 0, artifactHost.bounds.contains(frame),
                              let pixels = storyboardCardPixels(in: artifactHost, frame: frame) else {
                            captureError = "The visible card could not be captured."
                            return false
                        }
                        crop = pixels.png
                        pixelEvidence = ["captureMultiplierOverBacking": 2,
                            "pixelsPerPointX": Double(pixels.image.width) / Double(frame.width),
                            "pixelsPerPointY": Double(pixels.image.height) / Double(frame.height),
                            "backingScaleFactor": Double(window.backingScaleFactor), "frame": frameDescription(frame),
                            "pixelWidth": pixels.image.width, "pixelHeight": pixels.image.height]
                        do {
                            let raw = try recognizedStoryboardText(in: pixels.image, correctingLanguage: false)
                            rendered = raw.text
                            pixelEvidence["rawRecognition"] = raw.evidence
                            let corrected = try recognizedStoryboardText(in: pixels.image, correctingLanguage: true)
                            pixelEvidence["languageCorrectedRecognition"] = corrected.evidence
                            leaked = forbidden.filter { rendered.contains($0) || corrected.text.contains($0) }
                            return rendered.contains(subject) && leaked.isEmpty
                        } catch {
                            captureError = error.localizedDescription
                            return false
                        }
                    })
                    let cropName = "scale-\(scaleLabel(scale))-storyboard-card-\(shotID).png"
                    var cropSaved = false
                    if let crop {
                        do {
                            try crop.write(to: evidenceURL.appendingPathComponent(cropName), options: .atomic)
                            cropSaved = true
                        } catch { captureError = error.localizedDescription }
                    }
                    var diagnostic: [String: Any] = ["shotID": shotID, "missingSubject": !rendered.contains(subject),
                        "leakedTokens": leaked, "renderedText": rendered, "pixelEvidence": pixelEvidence,
                        "geometry": probeScrollDiagnostics(control, in: window), "cropSaved": cropSaved,
                        "cropScreenshot": cropName]
                    if let captureError { diagnostic["error"] = captureError }
                    emit("storyboard-card-text", scale: scale, fields: diagnostic)
                    guard verified, cropSaved else {
                        let name = "scale-\(scaleLabel(scale))-production-storyboard-failed.png"
                        _ = snapshot(host, at: evidenceURL.appendingPathComponent(name))
                        diagnostic["screenshot"] = name
                        emit("storyboard-text-diagnostic", scale: scale, fields: diagnostic)
                        fail("visible storyboard card is missing its description or leaks technical planning fields: \(shotID)", scale: scale)
                    }
                    storyboardCards.append(["shotID": shotID, "subject": subject,
                        "fullyVisible": true, "renderedDescription": true, "rawFieldsAbsent": true,
                        "screenshot": cropName, "pixelEvidence": pixelEvidence])
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            let name = "scale-\(scaleLabel(scale))-production-\(phase).png"
            guard snapshot(host, at: evidenceURL.appendingPathComponent(name)) else {
                fail("native production capture failed", scale: scale)
            }
            captures.append(name)
        }
        emit("production-workbench", scale: scale, fields: ["screenshots": captures,
            "threeColumns": true, "noTimelineOrEmptyPreview": true, "shotInspectorBound": true,
            "twoStoryboardSections": true, "statusVisible": true, "shotInspectorSelections": inspectorSelections,
            "storyboardCards": storyboardCards])
    }

    private static func captureProductionActivity(document: VideoProject, evidenceURL: URL, scale: Double) async throws {
        let editor = document.editorViewModel
        let service = editor.agentService
        guard let window = document.windowControllers.first?.window, let host = window.contentView,
              let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else {
            throw ToolError("The activity fixture has no document window or working copy.")
        }
        window.setContentSize(AppTheme.Window.projectMin)
        window.makeKeyAndOrderFront(nil)
        let store = YAMLArtifactStore(dataRoot: root)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&gates, phase: "project_init")
        try store.save(gates, to: PipelineLayout.gatesFile)
        await editor.refreshEngineState()
        guard let selection = editor.storyboardSelection else {
            throw ToolError("The activity fixture has no selected Storyboard shot to restore.")
        }
        let originalInspector = editor.inspectorPanelVisible
        let originalMaximized = editor.maximizedPanel
        defer {
            editor.showsAgentActivity = false
            editor.inspectorPanelVisible = originalInspector
            editor.maximizedPanel = originalMaximized
            window.orderOut(nil)
        }
        var screenshots: [String] = []
        var decisions: [[String: Any]] = []
        func uniqueDecision(_ identifier: String) -> NSView? {
            let matches = probes(in: host, identifier: identifier).filter {
                !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0
            }
            guard matches.count == 1, let decision = matches.first,
                  let activity = shownProbe(in: host, identifier: "production.activity"),
                  !activity.convert(activity.bounds, to: host)
                    .intersects(decision.convert(decision.bounds, to: host)) else { return nil }
            return decision
        }
        func activate(_ id: String) async throws {
            if editor.showsAgentActivity, id.hasPrefix("agent.gate."), uniqueDecision(id) == nil {
                throw ToolError("The phase decision does not have a unique target outside activity: \(id).")
            }
            guard await revealProbe(id, in: window), click(identifier: id, in: window) == nil else {
                throw ToolError("Activity decision control is not reachable: \(id).")
            }
        }
        func activityIsUsable() -> Bool {
            host.layoutSubtreeIfNeeded()
            guard let activity = shownProbe(in: host, identifier: "production.activity"),
                  activity.window === window,
                  visibleProbe(identifier: "production.activity.close", in: window, containedBy: host.bounds),
                  visibleProbe(identifier: "agent.gate.approve", in: window, containedBy: host.bounds),
                  visibleProbe(identifier: "agent.gate.decline", in: window, containedBy: host.bounds),
                  probeState(identifier: "agent.gate.approve", in: window) == true,
                  let primary = uniqueDecision("agent.gate.approve"),
                  let decline = uniqueDecision("agent.gate.decline") else { return false }
            let area = activity.convert(activity.bounds, to: host)
            return !area.intersects(primary.convert(primary.bounds, to: host))
                && !area.intersects(decline.convert(decline.bounds, to: host))
                && abs(host.bounds.width - AppTheme.Window.projectMin.width) < 1
                && abs(host.bounds.height - AppTheme.Window.projectMin.height) < 1
                && window.attachedSheet == nil
        }
        for operation in ["decline", "approve", "rewind"] {
            let phase = operation == "rewind" ? "storyboard" : "brief"
            if operation == "rewind" {
                gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
                GatesOperations.approve(&gates, phase: "storyboard")
                try store.save(gates, to: PipelineLayout.gatesFile)
            }
            let before = try Data(contentsOf: PipelineLayout.url(PipelineLayout.gatesFile, in: root))
            let action: GateApproval.Action = operation == "rewind"
                ? .rewind(gatesSHA256: FileDigest.sha256(of: before), phases: ["storyboard"]) : .approve
            _ = try service.requestGateApproval(GateApproval(phase: phase, dataRoot: root, action: action,
                declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding))
            editor.selectProductionPhase(phase)
            editor.inspectorPanelVisible = false
            editor.maximizedPanel = .project
            editor.showsAgentActivity = false
            let visibleWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            try await activate("production.ai")
            guard await waitUntil(timeout: .seconds(10), activityIsUsable),
                  !editor.inspectorPanelVisible, editor.maximizedPanel == .project,
                  Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)).isSubset(of: visibleWindows),
                  try Data(contentsOf: PipelineLayout.url(PipelineLayout.gatesFile, in: root)) == before else {
                throw ToolError("Activity covered the phase decision, changed preferences or mutated gates before a decision.")
            }
            let screenshot = "scale-\(scaleLabel(scale))-activity-\(operation).png"
            guard snapshot(host, at: evidenceURL.appendingPathComponent(screenshot)) else {
                throw ToolError("Could not capture simultaneous activity and phase decision.")
            }
            screenshots.append(screenshot)
            guard let activity = shownProbe(in: host, identifier: "production.activity"),
                  let primary = uniqueDecision("agent.gate.approve"),
                  let decline = uniqueDecision("agent.gate.decline") else {
                throw ToolError("The simultaneous decision controls disappeared before clicking.")
            }
            let activityFrame = frameDescription(activity.convert(activity.bounds, to: host))
            let primaryFrame = frameDescription(primary.convert(primary.bounds, to: host))
            let declineFrame = frameDescription(decline.convert(decline.bounds, to: host))
            let control = operation == "decline" ? "agent.gate.decline" : "agent.gate.approve"
            try await activate(control)
            guard await waitUntil(timeout: .seconds(10), { service.pendingGateApproval == nil }),
                  editor.showsAgentActivity else {
                throw ToolError("The decision did not finish with activity still open.")
            }
            gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
            let after = try Data(contentsOf: PipelineLayout.url(PipelineLayout.gatesFile, in: root))
            let expectedState = operation == "decline" ? after == before
                : operation == "approve" ? gates.get("brief").approved
                : !gates.get("storyboard").approved && gates.get("brief").approved
            guard expectedState else {
                throw ToolError("The native decision did not persist its expected gate state.")
            }
            decisions.append(["operation": operation, "phase": phase, "controlID": control,
                "activityStayedOpen": true, "disjointControls": true, "nativeClick": true,
                "activityFrame": activityFrame, "primaryFrame": primaryFrame, "declineFrame": declineFrame,
                "gatesBeforeSHA256": FileDigest.sha256(of: before), "gatesAfterSHA256": FileDigest.sha256(of: after)])
            try await activate("production.activity.close")
            guard await waitUntil(timeout: .seconds(5), {
                !editor.showsAgentActivity && !editor.presentedInspectorVisible
                    && editor.presentedMaximizedPanel == .project
            }) else { throw ToolError("Closing activity lost the saved panel visibility or maximize preference.") }
        }
        editor.maximizedPanel = nil
        editor.inspectorPanelVisible = true
        editor.selectProductionPhase("storyboard")
        editor.storyboardSelection = selection
        try await activate("production.ai")
        try await activate("production.activity.close")
        guard await waitUntil(timeout: .seconds(5), {
            probeText(identifier: "storyboard.inspector", in: window) == selection.step.id
        }) else { throw ToolError("Closing activity lost the selected Storyboard inspector.") }
        editor.setWorkspaceFocus(.edit)
        try await activate("production.ai")
        guard await waitUntil(timeout: .seconds(5), { editor.showsAgentActivity }) else {
            throw ToolError("Activity could not open outside Production.")
        }
        editor.setWorkspaceFocus(.production)
        guard await waitUntil(timeout: .seconds(5), {
            editor.showsAgentActivity && shownProbe(in: host, identifier: "production.activity")?.window === window
        }) else { throw ToolError("Entering Production dismissed activity instead of docking it.") }
        editor.setWorkspaceFocus(.edit)
        guard !editor.showsAgentActivity else { throw ToolError("Leaving Production reopened an activity popover.") }
        emit("production-activity", scale: scale, fields: ["decisions": decisions,
            "minimumViewport": frameDescription(host.bounds), "inspectorRestored": true,
            "preferencesPreserved": true, "workspaceTransitions": true, "screenshots": screenshots])
    }

    private static func panelView(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { panelView(in: $0, identifier: identifier) }.first
    }

    private static func storyboardCardPixels(in view: NSView, frame: NSRect) -> (image: CGImage, png: Data)? {
        guard let native = view.bitmapImageRepForCachingDisplay(in: frame),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: native.pixelsWide * 2, pixelsHigh: native.pixelsHigh * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = frame.size
        view.cacheDisplay(in: frame, to: bitmap)
        guard let image = bitmap.cgImage,
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (image, png)
    }

    private static func recognizedStoryboardText(
        in image: CGImage, correctingLanguage: Bool
    ) throws -> (text: String, evidence: [String: Any]) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = correctingLanguage
        request.minimumTextHeight = 0
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        let lines = observations.compactMap { observation -> [String: Any]? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return ["text": candidate.string, "confidence": Double(candidate.confidence),
                "bounds": frameDescription(observation.boundingBox)]
        }
        let text = lines.compactMap { $0["text"] as? String }.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (text, ["text": text, "lines": lines, "usesLanguageCorrection": correctingLanguage,
            "customWords": [String](), "minimumTextHeight": 0])
    }

    private static func renderedAccessibilityText(in view: NSView) -> [String] {
        var visited: Set<ObjectIdentifier> = []
        var text: [String] = []
        func visit(_ object: NSObject) {
            guard visited.count < 10_000, visited.insert(ObjectIdentifier(object)).inserted else { return }
            for property in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
                let selector = NSSelectorFromString(property)
                if object.responds(to: selector),
                   let value = object.perform(selector)?.takeUnretainedValue() as? String, !value.isEmpty {
                    text.append(value)
                }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children),
               let values = object.perform(children)?.takeUnretainedValue() as? [NSObject] {
                values.forEach(visit)
            }
            (object as? NSView)?.subviews.forEach(visit)
        }
        visit(view)
        return text
    }

    private static func storyboardFixture(subject: String, version: Int) throws -> Storyboard {
        try Storyboard(
            meta: StoryboardMeta(project: "Native Storyboard acceptance", version: version, generated: "2026-10-16",
                summaryOneline: "Director pattern: cartoon-adult-swim-tartakovsky (all values basis: inferred)",
                notes: "main_street [wide.noon street axis | horizon.long]"),
            sections: [.init(id: "verse1", label: "Verse 1", timeStart: 0, timeEnd: 12,
                energy: "low", function: "setup",
                steps: [.init(id: "verse1.01", function: .story, subject: subject,
                    camera: "Slow dolly", framing: "Wide", cameraSetup: ["angle": "frontal", "height": "eye_level"]),
                    .init(id: "verse1.02", function: .transition, subject: "A train passes the empty platform.", camera: "Locked wide")]),
                .init(id: "chorus1", label: "Chorus 1", timeStart: 12, timeEnd: 24,
                    steps: [.init(id: "chorus1.01", function: .performance, subject: "The singer turns toward the morning light.",
                        camera: "Slow push in", locationViewRequest: "wide.noon", framing: "Medium",
                        cameraSetup: ["angle": "frontal", "lens_hint": "wide"])])]
        )
    }
}


extension WorkspaceUIAcceptance {
    static func captureBibleBlocker(editor: EditorViewModel, evidenceURL: URL) async throws -> [String: Any] {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let window = NSApp.windows.first(where: {
                  ($0.windowController as? EditorWindowController)?.editorViewModel === editor
              }), let host = window.contentView,
              editor.projectState?.nextPhaseName == "bible", editor.agentService.pendingGateApproval == nil else {
            throw ToolError("The Bible blocker acceptance requires the actual current phase before its artifact is written.")
        }
        let scale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
        window.setContentSize(AppTheme.Window.projectMin)
        window.makeKeyAndOrderFront(nil)
        let bibleURL = root.appendingPathComponent("bible/bible.yaml")
        guard !FileManager.default.fileExists(atPath: bibleURL.path) else {
            throw ToolError("The Bible failure fixture must precede its first canonical write.")
        }
        try FileManager.default.createDirectory(at: bibleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalidBible = Data("fixture: structurally invalid Bible\n".utf8)
        try invalidBible.write(to: bibleURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: bibleURL) }
        await editor.refreshEngineState()
        let gatesURL = root.appendingPathComponent(PipelineLayout.gatesFile)
        let gatesBefore = try Data(contentsOf: gatesURL)
        guard await revealProbe("pipeline.overview.select.bible", in: window),
              click(identifier: "pipeline.overview.select.bible", in: window) == nil else {
            throw ToolError("The native Bible sidebar action is not reachable.")
        }
        let readiness = await NativeGateWriter.controlReadiness(projectDir: home, phase: "bible",
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
            executionCoordinator: editor.pipelinePhaseRunCoordinator)
        guard !readiness.approval.isReady, let diagnostic = readiness.approval.blocker,
              diagnostic.contains("bible/bible.yaml"),
              await waitUntil(timeout: .seconds(10), {
                  let reason = probeText(identifier: "pipeline.overview.dock.reason", in: window) ?? ""
                  return reason.contains("References") && reason.contains("reference images")
                      && probeText(identifier: "pipeline.overview.dock.status", in: window) == "Incomplete"
                      && probeText(identifier: "pipeline.overview.select.shotlist", in: window) == "Upcoming"
                      && probeState(identifier: "pipeline.overview.dock.continue", in: window) == true
              }), let reason = probeText(identifier: "pipeline.overview.dock.reason", in: window) else {
            throw ToolError("The incomplete Bible did not show its actual missing content and distinct current-phase state.")
        }
        guard !["bible.yaml", root.path, "write_bible", "schema", "Not started"].contains(where: reason.contains),
              probeState(identifier: "pipeline.overview.approve.bible", in: window) != true,
              await revealProbe("pipeline.overview.dock.reason", in: window),
              visibleProbe(identifier: "pipeline.overview.dock.reason", in: window, containedBy: host.bounds),
              findProbe(in: host, identifier: "pipeline.overview.dock.diagnostic-text") == nil else {
            throw ToolError("The blocked Bible exposed raw diagnostics or offered approval before it was ready.")
        }
        let blockedImage = "scale-\(scaleLabel(scale))-bible-incomplete.png"
        guard snapshot(host, at: evidenceURL.appendingPathComponent(blockedImage)),
              await revealProbe("pipeline.overview.dock.diagnostics", in: window),
              click(identifier: "pipeline.overview.dock.diagnostics", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  NSApp.windows.contains { $0.isVisible
                      && probeText(identifier: "pipeline.overview.dock.diagnostic-text", in: $0) == diagnostic }
              }), let diagnosticsWindow = NSApp.windows.first(where: { $0.isVisible
                  && probeText(identifier: "pipeline.overview.dock.diagnostic-text", in: $0) == diagnostic }),
              let diagnosticsHost = diagnosticsWindow.contentView,
              renderedAccessibilityText(in: diagnosticsHost).joined(separator: "\n").contains(diagnostic),
              await revealProbe("pipeline.overview.dock.diagnostics-done", in: diagnosticsWindow),
              visibleProbe(identifier: "pipeline.overview.dock.diagnostics-done", in: diagnosticsWindow, containedBy: diagnosticsHost.bounds) else {
            throw ToolError("The native Diagnostics action did not expose the raw Bible failure in a usable bounded surface.")
        }
        let diagnosticImage = "scale-\(scaleLabel(scale))-bible-diagnostics.png"
        guard snapshot(diagnosticsHost, at: evidenceURL.appendingPathComponent(diagnosticImage)),
              click(identifier: "pipeline.overview.dock.diagnostics-done", in: diagnosticsWindow) == nil,
              await waitUntil(timeout: .seconds(5), { !diagnosticsWindow.isVisible }),
              try Data(contentsOf: gatesURL) == gatesBefore,
              try Data(contentsOf: bibleURL) == invalidBible else {
            throw ToolError("Closing Bible Diagnostics changed approval state or left its surface open.")
        }
        return ["phase": "bible", "reason": reason, "status": "Incomplete", "futureStatus": "Upcoming",
            "approvalUnavailable": true, "diagnosticOpenedByControl": "pipeline.overview.dock.diagnostics",
            "diagnosticMatchesReadiness": true, "diagnosticHiddenByDefault": true,
            "invalidArtifactPresent": true,
            "diagnosticSHA256": FileDigest.sha256(of: Data(diagnostic.utf8)), "gatesUnchanged": true,
            "screenshots": [blockedImage, diagnosticImage]]
    }

    private static func captureProductionOwner(kind: ProductionV2OwnerAcceptance.Kind, evidenceURL: URL, scale: Double, performance: Bool = false) async {
        do {
            if kind == .musicvideo {
                guard let path = ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_PACK"] else {
                    throw ToolError("Film acceptance requires the external Music Video pack.")
                }
                let pack = PluginLoader.load(at: URL(fileURLWithPath: path))
                guard pack.isLoaded, pack.id == "musicvideo" else {
                    throw ToolError("The external Music Video pack did not load.")
                }
            }
            let directory = "scale-\(scaleLabel(scale))-owner-v2-" + kind.rawValue + (performance ? "-performance" : "")
            var result = try await ProductionV2OwnerAcceptance.run(kind: kind,
                output: evidenceURL.appendingPathComponent(directory, isDirectory: true), performanceAlignment: performance)
            result["evidenceDirectory"] = directory
            emit(performance ? "production-v2-performance" : "production-v2-owner", scale: scale, fields: result)
        } catch {
            fail("Native V2 \(kind.rawValue) owner flow: \(error.localizedDescription)", scale: scale)
        }
    }

    static func finishMusicvideoDelivery(document: VideoProject, receipt fixture: FullflowAcceptanceFixture.Receipt,
                                        evidenceURL: URL, scale: Double) async throws -> [String: Any] {
            if document.windowControllers.isEmpty { document.makeWindowControllers() }
            let editor = document.editorViewModel
            editor.setWorkspaceFocus(.production)
            await editor.refreshEngineState()
            guard let window = document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window,
                  let host = window.contentView else { throw ToolError("The fullflow editor window is unavailable.") }
            window.setContentSize(AppTheme.Window.projectMin)
            window.appearance = NSAppearance(named: .darkAqua)
            document.showWindows()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.orderOut(nil) }
            var screenshots: [String] = []
            var controlFrames: [[String: Any]] = []
            var pickerTransitions: [[String: String]] = []
            func capture(_ name: String, view: NSView? = nil) throws {
                let name = "scale-\(scaleLabel(scale))-filmreview-\(name).png"
                guard snapshot(view ?? host, at: evidenceURL.appendingPathComponent(name)) else {
                    throw ToolError("Could not capture \(name).")
                }
                screenshots.append(name)
            }
            func reach(_ identifier: String, artifact: Bool = true) async throws {
                guard await revealProbe(identifier, in: window),
                      let frame = probeFrame(identifier: identifier, in: window),
                      let bounds = artifact ? probeFrame(identifier: "production.artifact", in: window) : host.bounds,
                      bounds.insetBy(dx: -1, dy: -1).contains(frame), frame.width > 0, frame.height > 0 else {
                    throw ToolError("Review control is clipped or unreachable: \(identifier).")
                }
                controlFrames.append(["id": identifier, "control": frameDescription(frame), "viewport": frameDescription(bounds)])
            }
            func activate(_ identifier: String, artifact: Bool = true) async throws {
                try await reach(identifier, artifact: artifact)
                guard click(identifier: identifier, in: window) == nil else {
                    throw ToolError("The native review control could not be clicked: \(identifier).")
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            func fill(_ identifier: String, _ value: String) async throws {
                try await activate(identifier)
                guard await waitUntil(timeout: .seconds(3), { window.firstResponder is NSTextView }),
                      let field = window.firstResponder as? NSTextView else {
                    throw ToolError("Review input did not receive keyboard focus: \(identifier).")
                }
                field.setSelectedRange(NSRange(location: 0, length: (field.string as NSString).length))
                field.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
                window.makeFirstResponder(nil)
                guard await waitUntil(timeout: .seconds(3), { probeText(identifier: identifier, in: window) == value }) else {
                    throw ToolError("Review input did not commit its native edit: \(identifier).")
                }
            }
            func choose(_ identifier: String, index: Int, expected: String) async throws {
                try await reach(identifier)
                guard let before = probeText(identifier: identifier, in: window), before != expected else {
                    throw ToolError("The review picker must change its current selection: \(identifier).")
                }
                guard click(identifier: identifier, in: window) == nil else { throw ToolError("The review picker did not open.") }
                postReviewKey(115, characters: "\u{f729}", in: window)
                for _ in 0..<index { postReviewKey(125, characters: "\u{f701}", in: window) }
                postReviewKey(36, characters: "\r", in: window)
                guard await waitUntil(timeout: .seconds(3), { probeText(identifier: identifier, in: window) == expected }) else {
                    throw ToolError("The native review picker did not select \(expected).")
                }
                pickerTransitions.append(["id": identifier, "before": before, "after": expected])
            }
            guard await waitUntil(timeout: .seconds(10), {
                host.layoutSubtreeIfNeeded()
                return window.isKeyWindow && productionControlsAreContained(in: window)
                    && abs(host.bounds.width - AppTheme.Window.projectMin.width) < 1
                    && abs(host.bounds.height - AppTheme.Window.projectMin.height) < 1
            }) else { throw ToolError("The minimum-size production window did not settle.") }
            try await activate("pipeline.overview.select.render", artifact: false)
            guard await waitUntil(timeout: .seconds(5), {
                editor.cockpitTab == .review && probeState(identifier: "sequence.disclosure", in: window) != nil
            }) else { throw ToolError("The native Render phase did not open film review.") }
            let initialTimeline = editor.timeline
            guard let assembly = try PipelineAssemblyStore.load(dataRoot: fixture.dataRoot),
                  assembly.plan.placements.count >= 2 else { throw ToolError("Film review requires an assembled cut.") }
            let pair = Array(fixture.shotIDs.prefix(2))
            let cutFrame = assembly.plan.placements[1].timelineStartFrame
            let firstFrame = max(0, cutFrame - 1)
            let endFrame = min(fixture.totalFrames, cutFrame + 1)
            let fullDuration = Double(fixture.totalFrames) / Double(fixture.fps)
            guard (try? PipelineSequenceReviewStore.requireCurrent(dataRoot: fixture.dataRoot, timeline: initialTimeline, resolver: editor.mediaResolver.snapshot())) == nil else {
                throw ToolError("The fixture unexpectedly bypassed native sequence review.")
            }
            try await activate("sequence.disclosure")
            guard await waitUntil(timeout: .seconds(3), { probeState(identifier: "sequence.build", in: window) == true }) else {
                throw ToolError("The sequence review did not expand.")
            }
            try await activate("sequence.build")
            guard await waitUntil(timeout: .seconds(30), {
                probeState(identifier: "sequence.record", in: window) == false
                    && nativeElement(AVPlayerView.self, in: host)?.player?.currentItem?.status == .readyToPlay
            }), let player = nativeElement(AVPlayerView.self, in: host)?.player else {
                throw ToolError("The real review reel did not become playable with approval still disabled.")
            }
            guard let reelAsset = player.currentItem?.asset,
                  try await !reelAsset.loadTracks(withMediaType: .audio).isEmpty else {
                throw ToolError("The Musicvideo review reel lost its original soundtrack.")
            }
            try await activate("sequence.play")
            guard await waitUntil(timeout: .seconds(5), { player.currentTime().seconds > 0.1 }) else {
                throw ToolError("The native Play reel control did not advance the real movie.")
            }
            try capture("playing")
            guard await waitUntil(timeout: .seconds(fullDuration + 15), { player.currentTime().seconds >= fullDuration - 1 / Double(fixture.fps) }) else {
                throw ToolError("The review reel did not play through the complete song.")
            }
            let playedSeconds = player.currentTime().seconds
            try await fill("sequence.shots", pair.joined(separator: ","))
            try await fill("sequence.start", String(firstFrame))
            try await fill("sequence.end", String(endFrame))
            let observation = "At frame \(cutFrame) the warm source cuts directly to the cool source; the soundtrack remains continuous."
            try await fill("sequence.evidence", observation)
            try await choose("sequence.severity", index: 0, expected: "info")
            try await choose("sequence.action", index: 0, expected: "accept")
            try await reach("sequence.add")
            try capture("finding")
            try await activate("sequence.add")
            guard await waitUntil(timeout: .seconds(3), { probeState(identifier: "sequence.remove.0", in: window) == true }),
                  probeState(identifier: "sequence.record", in: window) == false else {
                throw ToolError("Adding a finding bypassed the required playback acknowledgements.")
            }
            try await activate("sequence.adjacent")
            guard probeState(identifier: "sequence.record", in: window) == false else {
                throw ToolError("Adjacent-cut acknowledgement bypassed whole-playback review.")
            }
            try await activate("sequence.whole")
            guard await waitUntil(timeout: .seconds(3), { probeState(identifier: "sequence.record", in: window) == true }) else {
                throw ToolError("The completed playback acknowledgements did not enable Record review.")
            }
            try await activate("sequence.record")
            guard await waitUntil(timeout: .seconds(30), {
                (try? PipelineSequenceReviewStore.requireCurrent(dataRoot: fixture.dataRoot, timeline: editor.timeline, resolver: editor.mediaResolver.snapshot())) != nil
            }) else { throw ToolError("The native sequence review did not persist its current immutable record.") }
            let sequence = try PipelineSequenceReviewStore.requireCurrent(dataRoot: fixture.dataRoot, timeline: editor.timeline, resolver: editor.mediaResolver.snapshot())
            guard sequence.findings.count == 1, let finding = sequence.findings.first,
                  finding.evidence == observation, finding.shotIDs == pair,
                  finding.startFrame == firstFrame, finding.endFrame == endFrame,
                  finding.severity == .info, finding.recommendedAction == .accept,
                  sequence.adjacentPairCompleted, sequence.wholePlaybackCompleted,
                  sequence.reviewReel.durationFrames == fixture.totalFrames else {
                throw ToolError("The saved sequence review does not match the native inputs and full-song reel.")
            }
            try await reach("sequence.message")
            try capture("sequence-recorded")
            guard let style = try await TimelineStyleReview.capture(timeline: editor.timeline, resolver: editor.mediaResolver.snapshot()),
                  !style.style.criteria.isEmpty else { throw ToolError("The fixture has no required production style review.") }
            var initiallyBlocked = false
            do { try TimelineStyleReview.requireCurrent(style) } catch { initiallyBlocked = true }
            guard initiallyBlocked else { throw ToolError("The fixture bypassed native style review.") }
            try await activate("style.disclosure")
            try await activate("style.begin")
            guard await waitUntil(timeout: .seconds(5), { probeState(identifier: "style.record", in: window) == false }) else {
                throw ToolError("The style review did not require native findings and observations.")
            }
            let styleObservation = "Frames 0–\(fixture.totalFrames): warm and cool source clips with moving markers, direct cuts and the continuous original song. This simplified visual treatment is an explicitly accepted deviation for this fixture."
            for criterion in style.style.criteria {
                guard style.targetsByCriterion[criterion.auditKey]?.isEmpty == false else {
                    throw ToolError("The style fixture has no actual evidence for \(criterion.auditKey).")
                }
                try await choose("style.choice.\(criterion.auditKey)", index: 3, expected: "accepted_deviation")
                try await fill("style.observation.\(criterion.auditKey)",
                    styleObservation)
            }
            try await reach("style.record")
            try capture("style-inputs")
            guard probeState(identifier: "style.record", in: window) == true else {
                throw ToolError("Completed native style observations did not enable recording.")
            }
            try await activate("style.record")
            guard await waitUntil(timeout: .seconds(10), { (try? TimelineStyleReview.requireCurrent(style)) != nil }) else {
                throw ToolError("The native style review did not satisfy the exact-cut export gate.")
            }
            let reviewURL = fixture.dataRoot.appendingPathComponent(TimelineStyleReview.relativePath)
            let review = try JSONDecoder().decode(TimelineStyleReview.self, from: Data(contentsOf: reviewURL))
            guard review.findings.count == style.style.criteria.count,
                  review.findings.allSatisfy({ $0.acceptedDeviation && !$0.evidenceReferences.isEmpty && $0.observation == styleObservation }),
                  editor.timeline == initialTimeline else { throw ToolError("Style observations lost source evidence or changed the assembled cut.") }
            try await reach("style.message")
            try capture("style-recorded")
            try await activate("production.export", artifact: false)
            guard await waitUntil(timeout: .seconds(5), {
                NSApp.windows.contains { $0.isVisible && probeState(identifier: "production.export.open", in: $0) != nil }
            }), let popover = NSApp.windows.first(where: { $0.isVisible && probeState(identifier: "production.export.open", in: $0) != nil }) else {
                throw ToolError("The production Export status did not open its native activity menu.")
            }
            popover.makeKeyAndOrderFront(nil)
            guard click(identifier: "production.export.open", in: popover) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      NSApp.windows.contains { $0.isVisible && probeState(identifier: "export.require-sequence", in: $0) != nil }
                  }), let export = NSApp.windows.first(where: { $0.isVisible && probeState(identifier: "export.require-sequence", in: $0) != nil }),
                  let exportHost = export.contentView else { throw ToolError("The production Export action did not open native settings.") }
            export.makeKeyAndOrderFront(nil)
            guard await revealProbe("export.require-sequence", in: export),
                  click(identifier: "export.require-sequence", in: export) == nil,
                  await waitUntil(timeout: .seconds(3), { probeState(identifier: "export.require-sequence", in: export) == true }) else {
                throw ToolError("The native Export settings did not require the recorded sequence review.")
            }
            try capture("export-settings", view: exportHost)
            var result = try await MusicvideoDeliveryAcceptance.run(editor: editor, outputDirectory: evidenceURL)
            try capture("export-completed", view: exportHost)
            let gateEvidence = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.nativeGateApprovals))
            result.merge([
                "route": "imported-musicvideo", "viewport": frameDescription(host.bounds),
                "controls": controlFrames, "nativeSequenceReview": true, "nativeStyleReview": true,
                "recordDisabledUntilReviewed": true, "reviewInputsPersisted": true, "reviewReelHasAudio": true,
                "sequenceFindingCount": sequence.findings.count, "styleFindingCount": review.findings.count,
                "pickerTransitions": pickerTransitions,
                "recordedSequenceSelection": ["severity": finding.severity.rawValue, "action": finding.recommendedAction.rawValue],
                "playbackSeconds": playedSeconds, "timelineUnchangedByReview": editor.timeline == initialTimeline,
                "screenshots": screenshots, "suppliedInputs": fixture.suppliedInputs,
                "canonicalArtifacts": fixture.canonicalArtifacts,
                "nativeGateApprovals": gateEvidence, "nativeBibleBlocker": fixture.nativeBibleBlocker,
            ]) { _, value in value }
            return result
    }

    private static func postReviewKey(_ code: UInt16, characters: String, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
}
