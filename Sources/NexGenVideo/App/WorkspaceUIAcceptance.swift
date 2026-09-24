import AppKit
import SwiftUI
import NexGenEngine

@MainActor
enum WorkspaceUIAcceptance {
    private static var editorSizeProbes: [[String: String]] = []
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
                    && statusControlsAreContained(in: window)
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
                    && statusControlsAreContained(in: window)
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
                        && statusControlsAreContained(in: window)
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
                      statusControlsAreContained(in: window),
                      workspace != .production || agentControlsAreContained(in: window) else {
                    fail("workspace layout did not settle for \(workspace.rawValue)", scale: scale)
                }
                guard click(identifier: "editor.status.budget", in: window) == nil,
                      await waitUntil(timeout: .seconds(5), {
                          probeState(identifier: "editor.status.budget", in: window) == true
                              && probeExistsAnywhere(
                                  identifier: "editor.status.budget.close",
                                  preferredWindow: window
                              )
                      }),
                      clickAnywhere(
                          identifier: "editor.status.budget.close",
                          preferredWindow: window
                      ) == nil,
                      await waitUntil(timeout: .seconds(5), {
                          probeState(identifier: "editor.status.budget", in: window) == false
                      }) else {
                    fail("budget details were not clickable in \(workspace.rawValue)", scale: scale)
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
                        "statusContext": probeValue(identifier: "editor.statusBar", in: window) ?? "",
                        "statusFrames": statusControlFrames(in: window),
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
                    && statusControlsAreContained(in: window)
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
                    "statusContext": probeValue(identifier: "editor.statusBar", in: window) ?? "",
                    "statusFrames": statusControlFrames(in: window),
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
            guard let projectRoot = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
                  let mutationID = editor.pipelinePhaseRunCoordinator.beginMutation(
                      projectRoot: projectRoot,
                      label: "A deliberately long production status for compact-layout acceptance"
                  ),
                  await waitUntil(timeout: .seconds(5), {
                      probeValue(identifier: "editor.status.aiJobs", in: window) == "active"
                  }),
                  click(identifier: "editor.status.aiJobs", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "editor.status.aiJobs", in: window) == true
                          && probeExistsAnywhere(
                              identifier: "editor.status.aiJobs.close",
                              preferredWindow: window
                          )
                  }),
                  clickAnywhere(
                      identifier: "editor.status.aiJobs.close",
                      preferredWindow: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "editor.status.aiJobs", in: window) == false
                  }) else {
                fail("AI job status was not reachable while active", scale: scale)
            }
            editor.pipelinePhaseRunCoordinator.endMutation(
                projectRoot: projectRoot,
                id: mutationID
            )
            guard await waitUntil(timeout: .seconds(5), {
                      probeValue(identifier: "editor.status.aiJobs", in: window) == "idle"
                  }), ExportCoordinator.beginExportIfIdle(),
                  await waitUntil(timeout: .seconds(5), {
                      probeValue(identifier: "editor.status.exportJobs", in: window) == "active"
                  }),
                  click(identifier: "editor.status.exportJobs", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "editor.status.exportJobs", in: window) == true
                          && probeExistsAnywhere(
                              identifier: "editor.status.exportJobs.close",
                              preferredWindow: window
                          )
                  }),
                  clickAnywhere(
                      identifier: "editor.status.exportJobs.close",
                      preferredWindow: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "editor.status.exportJobs", in: window) == false
                  }) else {
                fail("export job status was not reachable while active", scale: scale)
            }
            ExportCoordinator.endExport()
            guard await waitUntil(timeout: .seconds(5), {
                probeValue(identifier: "editor.status.exportJobs", in: window) == "idle"
            }) else {
                fail("export job status did not return to idle", scale: scale)
            }
            emit(
                "background-status",
                scale: scale,
                fields: [
                    "aiActiveObserved": true,
                    "controlsClicked": true,
                    "exportActiveObserved": true,
                    "statusFrames": statusControlFrames(in: window),
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
            await captureBudgetCases(
                editor: editor,
                window: window,
                host: host,
                projectURL: projectURL,
                evidenceURL: evidenceURL,
                scale: scale
            )
            emit("completed", scale: scale)
            window.orderOut(nil)
            exit(0)
        }
        app.run()
        exit(1)
    }

    private struct BudgetAcceptanceCase {
        let name: String
        let log: GenerationLog
        let charged: Double
        let reserved: Double
        let active: Int
        let unpriced: Int
        let complete: Bool
        let items: Int
    }

    private static func captureBudgetCases(
        editor: EditorViewModel,
        window: NSWindow,
        host: NSView,
        projectURL: URL,
        evidenceURL: URL,
        scale: Double
    ) async {
        guard let workingRoot = editor.workingRoot else {
            fail("budget acceptance had no working copy", scale: scale)
        }
        await editor.refreshProjectState()
        guard editor.projectState?.budgetEur == 10,
              editor.projectState?.budgetStopEur == 12 else {
            fail("budget acceptance did not load project limits", scale: scale)
        }

        for item in budgetAcceptanceCases() {
            do {
                try installBudgetLog(item.log, in: workingRoot, editor: editor)
            } catch {
                fail("could not install budget case \(item.name): \(error.localizedDescription)", scale: scale)
            }
            let snapshot: ProjectSpendSnapshot
            do {
                snapshot = try GenerationBudgetGuard.spendSnapshot(
                    log: item.log,
                    generatedInputs: editor.mediaAssets.compactMap(\.generationInput)
                )
            } catch {
                fail("budget case \(item.name) was rejected by the guard", scale: scale)
            }
            guard snapshot.chargedEur == item.charged,
                  snapshot.openReservationEur == item.reserved,
                  snapshot.verifiedEur == item.charged + item.reserved,
                  snapshot.activeReservationCount == item.active,
                  snapshot.unpricedTransactionCount == item.unpriced,
                  snapshot.isComplete == item.complete,
                  snapshot.lineItems.count == item.items else {
                fail("budget case \(item.name) did not match guard truth", scale: scale)
            }
            let expectedPresentation = ProjectBudgetPresentation.make(
                log: item.log,
                generatedInputs: editor.mediaAssets.compactMap(\.generationInput),
                projectState: editor.projectState,
                hasProductionPipeline: editor.hasProductionPipeline
            )
            guard await waitUntil(timeout: .seconds(5), {
                host.layoutSubtreeIfNeeded()
                return probeValue(identifier: "editor.status.budget", in: window)
                    == expectedPresentation.acceptanceValue
                    && statusControlsAreContained(in: window)
            }) else {
                fail("budget case \(item.name) did not reach the status bar", scale: scale)
            }

            let beforeLog = editor.generationLog
            let beforeApproval = editor.agentService.pendingSpendApproval?.id
            let logURL = workingRoot.appendingPathComponent(Project.generationLogFilename)
            guard let beforeBytes = try? Data(contentsOf: logURL),
                  click(identifier: "editor.status.budget", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "editor.status.budget", in: window) == true
                          && probeExistsAnywhere(
                              identifier: "editor.status.budget.close",
                              preferredWindow: window
                          )
                  }),
                  let (popoverWindow, _) = probeWindow(
                      identifier: "editor.status.budget.close",
                      preferredWindow: window
                  ), let popoverContent = popoverWindow.contentView else {
                fail("budget case \(item.name) did not open its detail popover", scale: scale)
            }
            popoverContent.layoutSubtreeIfNeeded()
            let popoverName = "scale-\(scaleLabel(scale))-budget-\(item.name).png"
            guard popoverContent.bounds.width > 0,
                  popoverContent.bounds.height > 0,
                  snapshot(popoverContent, at: evidenceURL.appendingPathComponent(popoverName)) else {
                fail("budget case \(item.name) popover geometry was unavailable", scale: scale)
            }

            if item.name == "reserved" {
                let refreshToken = editor.budgetStatusLoadToken
                guard clickAnywhere(
                    identifier: "editor.status.budget.refresh",
                    preferredWindow: window
                ) == nil,
                await waitUntil(timeout: .seconds(5), {
                    editor.budgetStatusLoadToken > refreshToken
                        && probeStateAnywhere(
                            identifier: "editor.status.budget.refresh",
                            preferredWindow: window
                        ) == false
                        && probeValue(identifier: "editor.status.budget", in: window)
                            == expectedPresentation.acceptanceValue
                }) else {
                    fail("budget refresh did not complete", scale: scale)
                }
            }

            guard clickAnywhere(
                identifier: "editor.status.budget.close",
                preferredWindow: window
            ) == nil,
            await waitUntil(timeout: .seconds(5), {
                probeState(identifier: "editor.status.budget", in: window) == false
            }), editor.generationLog == beforeLog,
            editor.agentService.pendingSpendApproval?.id == beforeApproval,
            (try? Data(contentsOf: logURL)) == beforeBytes else {
                fail("budget case \(item.name) changed consent or cost records", scale: scale)
            }
            emit(
                "budget",
                scale: scale,
                fields: [
                    "case": item.name,
                    "charged": snapshot.chargedEur,
                    "complete": snapshot.isComplete,
                    "items": snapshot.lineItems.count,
                    "popoverFrame": frameDescription(popoverContent.bounds),
                    "reserved": snapshot.openReservationEur,
                    "screenshot": popoverName,
                    "statusValue": expectedPresentation.acceptanceValue,
                ]
            )
        }

        await captureBudgetProjectSwitch(
            editor: editor,
            window: window,
            host: host,
            projectURL: projectURL,
            evidenceURL: evidenceURL,
            scale: scale
        )
    }

    private static func budgetAcceptanceCases() -> [BudgetAcceptanceCase] {
        let zero = money(0)
        let low = money(9.25)
        let exceeded = money(12.5)
        let reserved = money(3.25)
        let submitted = money(4)
        let released = money(5)
        return [
            BudgetAcceptanceCase(
                name: "empty",
                log: budgetLog([]),
                charged: 0,
                reserved: 0,
                active: 0,
                unpriced: 0,
                complete: true,
                items: 0
            ),
            BudgetAcceptanceCase(
                name: "zero",
                log: budgetLog(transactionEvents(id: "zero", money: zero, final: .charged)),
                charged: 0,
                reserved: 0,
                active: 0,
                unpriced: 0,
                complete: true,
                items: 1
            ),
            BudgetAcceptanceCase(
                name: "low",
                log: budgetLog(transactionEvents(id: "low", money: low, final: .charged)),
                charged: 9.25,
                reserved: 0,
                active: 0,
                unpriced: 0,
                complete: true,
                items: 1
            ),
            BudgetAcceptanceCase(
                name: "exceeded",
                log: budgetLog(transactionEvents(id: "exceeded", money: exceeded, final: .charged)),
                charged: 12.5,
                reserved: 0,
                active: 0,
                unpriced: 0,
                complete: true,
                items: 1
            ),
            BudgetAcceptanceCase(
                name: "unknown-price",
                log: budgetLog(transactionEvents(
                    id: "unknown-price",
                    money: nil,
                    final: .reserved,
                    note: "Provider price was unavailable.",
                    pricingStatus: .priceUnavailable
                )),
                charged: 0,
                reserved: 0,
                active: 1,
                unpriced: 1,
                complete: false,
                items: 1
            ),
            BudgetAcceptanceCase(
                name: "unknown-currency",
                log: budgetLog(transactionEvents(
                    id: "unknown-currency",
                    money: nil,
                    final: .reserved,
                    note: "Currency conversion was unavailable.",
                    pricingStatus: .currencyUnavailable
                )),
                charged: 0,
                reserved: 0,
                active: 1,
                unpriced: 1,
                complete: false,
                items: 1
            ),
            BudgetAcceptanceCase(
                name: "subscription-credits",
                log: budgetLog(transactionEvents(
                    id: "subscription-credits",
                    money: nil,
                    final: .reserved,
                    transport: .mcp,
                    billing: .subscription,
                    note: "Subscription credits have no verified project monetary cost.",
                    pricingStatus: .subscriptionCredits
                )),
                charged: 0,
                reserved: 0,
                active: 1,
                unpriced: 1,
                complete: false,
                items: 1
            ),
            BudgetAcceptanceCase(
                name: "reserved",
                log: budgetLog(transactionEvents(id: "reserved", money: reserved, final: .reserved)),
                charged: 0,
                reserved: 3.25,
                active: 1,
                unpriced: 0,
                complete: true,
                items: 1
            ),
            BudgetAcceptanceCase(
                name: "submitted-failure",
                log: budgetLog(transactionEvents(
                    id: "submitted-failure",
                    money: submitted,
                    final: .submitted,
                    note: "The provider accepted the request; status reconciliation is pending."
                )),
                charged: 0,
                reserved: 4,
                active: 1,
                unpriced: 0,
                complete: true,
                items: 1
            ),
            BudgetAcceptanceCase(
                name: "released",
                log: budgetLog(transactionEvents(
                    id: "released",
                    money: released,
                    final: .released,
                    note: "Released before provider submission."
                )),
                charged: 0,
                reserved: 0,
                active: 0,
                unpriced: 0,
                complete: true,
                items: 1
            ),
        ]
    }

    private static func transactionEvents(
        id: String,
        money: GenerationMoney?,
        final: GenerationSpendEvent.Kind,
        transport: ProviderTransport = .api,
        billing: BillingMode = .perCall,
        note: String? = nil,
        pricingStatus: GenerationPricingStatus? = nil
    ) -> [GenerationSpendEvent] {
        let endpoint = transport == .mcp ? "generate_video" : "video/generate"
        let pricingStatus = pricingStatus
            ?? (money != nil ? .priced : billing == .subscription ? .subscriptionCredits : .priceUnavailable)
        var events = [GenerationSpendEvent(
            id: "\(id)-reserved",
            transactionId: id,
            kind: .reserved,
            model: "higgsfield/acceptance-video",
            provider: .higgsfield,
            transport: transport,
            endpoint: endpoint,
            money: money,
            note: final == .reserved ? note : nil,
            createdAt: Date(timeIntervalSince1970: 1),
            billing: billing,
            pricingStatus: pricingStatus
        )]
        if final == .submitted || final == .charged {
            events.append(GenerationSpendEvent(
                id: "\(id)-submitted",
                transactionId: id,
                kind: .submitted,
                model: "higgsfield/acceptance-video",
                provider: .higgsfield,
                transport: transport,
                endpoint: endpoint,
                providerRequestId: "acceptance-request",
                providerRequestResumable: true,
                money: money,
                note: final == .submitted ? note : nil,
                createdAt: Date(timeIntervalSince1970: 2),
                billing: billing
            ))
        }
        if final == .charged {
            events.append(GenerationSpendEvent(
                id: "\(id)-charged",
                transactionId: id,
                kind: .charged,
                model: "higgsfield/acceptance-video",
                provider: .higgsfield,
                transport: transport,
                endpoint: endpoint,
                money: money,
                note: note,
                createdAt: Date(timeIntervalSince1970: 3),
                billing: billing
            ))
        } else if final == .released {
            events.append(GenerationSpendEvent(
                id: "\(id)-released",
                transactionId: id,
                kind: .released,
                model: "higgsfield/acceptance-video",
                provider: .higgsfield,
                transport: transport,
                endpoint: endpoint,
                note: note,
                createdAt: Date(timeIntervalSince1970: 2),
                billing: billing
            ))
        }
        return events
    }

    private static func budgetLog(_ events: [GenerationSpendEvent]) -> GenerationLog {
        var log = GenerationLog()
        log.spendEvents = events
        return log
    }

    private static func money(_ eur: Double) -> GenerationMoney {
        GenerationMoney(
            nativeAmount: eur * 1.2,
            nativeCurrency: "USD",
            eurAmount: eur,
            eurPerNativeUnit: 1 / 1.2,
            exchangeRateDate: "2026-09-24",
            pricingSource: "https://provider.example/pricing",
            exchangeRateSource: "https://www.ecb.europa.eu/"
        )
    }

    private static func installBudgetLog(
        _ log: GenerationLog,
        in workingRoot: URL,
        editor: EditorViewModel
    ) throws {
        guard editor.workingRoot?.standardizedFileURL.resolvingSymlinksInPath()
                == workingRoot.standardizedFileURL.resolvingSymlinksInPath() else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try GenerationBudgetGuard.spendSnapshot(
            log: log,
            generatedInputs: editor.mediaAssets.compactMap(\.generationInput)
        )
        editor.generationLog = log
        try editor.persistGenerationLog()
    }

    private static func captureBudgetProjectSwitch(
        editor: EditorViewModel,
        window: NSWindow,
        host: NSView,
        projectURL: URL,
        evidenceURL: URL,
        scale: Double
    ) async {
        let priorLog = editor.generationLog
        let priorPackage = try? projectSnapshot(at: projectURL)
        let secondary: URL
        do {
            secondary = try makeBareProjectFixture(scale: scale)
        } catch {
            fail("could not create the project-switch fixture", scale: scale)
        }
        let secondaryKey = ProjectIdentity.existingKey(for: secondary)
        let secondaryBefore = try? projectSnapshot(at: secondary)
        editor.projectURL = secondary
        guard editor.generationLog == GenerationLog(), editor.projectState == nil else {
            fail("project switch retained stale budget state", scale: scale)
        }
        do {
            try await editor.refreshBudgetStatus()
        } catch {
            fail("could not refresh the switched project budget", scale: scale)
        }
        let emptyPresentation = ProjectBudgetPresentation.make(
            log: GenerationLog(),
            generatedInputs: editor.mediaAssets.compactMap(\.generationInput),
            projectState: nil,
            hasProductionPipeline: false
        )
        guard await waitUntil(timeout: .seconds(5), {
            host.layoutSubtreeIfNeeded()
            return editor.projectURL == secondary
                && editor.hasProductionPipeline == false
                && probeValue(identifier: "editor.status.budget", in: window)
                    == emptyPresentation.acceptanceValue
                && statusControlsAreContained(in: window)
        }) else {
            fail("switched project did not show its own empty budget", scale: scale)
        }
        let secondaryStatusContext = probeValue(
            identifier: "editor.statusBar",
            in: window
        ) ?? ""
        let secondaryLogURL = editor.workingRoot?.appendingPathComponent(
            Project.generationLogFilename
        )
        let secondaryLogBytes = secondaryLogURL.flatMap { try? Data(contentsOf: $0) }
        let approvalBefore = editor.agentService.pendingSpendApproval?.id
        guard click(identifier: "editor.status.budget", in: window) == nil,
              await waitUntil(timeout: .seconds(5), {
                  probeExistsAnywhere(
                      identifier: "editor.status.budget.close",
                      preferredWindow: window
                  )
              }),
              let (popoverWindow, _) = probeWindow(
                  identifier: "editor.status.budget.close",
                  preferredWindow: window
              ), let content = popoverWindow.contentView else {
            fail("switched project budget details did not open", scale: scale)
        }
        content.layoutSubtreeIfNeeded()
        let screenshotName = "scale-\(scaleLabel(scale))-budget-project-switch.png"
        let refreshToken = editor.budgetStatusLoadToken
        guard snapshot(content, at: evidenceURL.appendingPathComponent(screenshotName)),
              clickAnywhere(
                  identifier: "editor.status.budget.refresh",
                  preferredWindow: window
              ) == nil,
              await waitUntil(timeout: .seconds(5), {
                  editor.budgetStatusLoadToken > refreshToken
                      && probeStateAnywhere(
                          identifier: "editor.status.budget.refresh",
                          preferredWindow: window
                      ) == false
              }),
              clickAnywhere(
                  identifier: "editor.status.budget.close",
                  preferredWindow: window
              ) == nil,
              await waitUntil(timeout: .seconds(5), {
                  probeState(identifier: "editor.status.budget", in: window) == false
              }), editor.agentService.pendingSpendApproval?.id == approvalBefore,
              secondaryLogURL.flatMap({ try? Data(contentsOf: $0) }) == secondaryLogBytes,
              (try? projectSnapshot(at: secondary)) == secondaryBefore else {
            fail("switched project controls changed consent or cost records", scale: scale)
        }

        editor.projectURL = projectURL
        editor.recoveredUnsavedWork = false
        do {
            try await editor.refreshBudgetStatus()
        } catch {
            fail("could not restore the original project budget", scale: scale)
        }
        let restoredPresentation = ProjectBudgetPresentation.make(
            log: priorLog,
            generatedInputs: editor.mediaAssets.compactMap(\.generationInput),
            projectState: editor.projectState,
            hasProductionPipeline: editor.hasProductionPipeline
        )
        guard editor.generationLog == priorLog,
              probeValue(identifier: "editor.status.budget", in: window)
                == restoredPresentation.acceptanceValue,
              (try? projectSnapshot(at: projectURL)) == priorPackage else {
            fail("original project budget did not restore after switching", scale: scale)
        }
        emit(
            "budget-project-switch",
            scale: scale,
            fields: [
                "emptyValue": emptyPresentation.acceptanceValue,
                "restoredValue": restoredPresentation.acceptanceValue,
                "screenshot": screenshotName,
                "statusContext": secondaryStatusContext,
                "statusFrames": statusControlFrames(in: window),
            ]
        )
        if let secondaryKey { ProjectWorkingCopy.discard(key: secondaryKey) }
        try? FileManager.default.removeItem(at: secondary)
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
        try JSONEncoder().encode(MediaManifest()).write(
            to: projectURL.appendingPathComponent(Project.manifestFilename),
            options: .atomic
        )
        try JSONEncoder().encode(GenerationLog()).write(
            to: projectURL.appendingPathComponent(Project.generationLogFilename),
            options: .atomic
        )
        let dataRoot = try ProjectScaffold.initProject(
            home: projectURL,
            name: title,
            mode: .beat,
            budgetEur: 10,
            today: { "2026-09-24" }
        )
        let brief = try Brief(
            project: title,
            generated: "2026-09-24",
            mission: .demo,
            targetPlatform: "web",
            aspectRatio: .landscape16x9,
            projectMode: "beat",
            budgetEur: 10,
            budgetStopEur: 12,
            conceptType: .abstract,
            visualMedium: .liveActionRealistic,
            figures: .none,
            lyricsIntegration: .ignored
        )
        try YAMLArtifactStore(dataRoot: dataRoot).save(brief, to: PipelineLayout.briefFile)
        _ = try ProjectIdentity.uuid(for: projectURL)
        return projectURL
    }

    private static func makeBareProjectFixture(scale: Double) throws -> URL {
        let title = "A second project with an exceptionally long status name \(scaleLabel(scale))"
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(title)-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
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

    private static let statusControlIdentifiers = [
        "editor.status.budget",
        "editor.status.aiJobs",
        "editor.status.exportJobs",
    ]

    private static func statusControlsAreContained(in window: NSWindow) -> Bool {
        guard let root = window.contentView,
              let status = findProbe(in: root, identifier: "editor.statusBar") else {
            return false
        }
        let statusFrame = status.convert(status.bounds, to: root)
        guard status.window === window,
              !status.isHiddenOrHasHiddenAncestor,
              statusFrame.width > 0,
              statusFrame.height >= AppTheme.Layout.statusBarHeight,
              root.bounds.insetBy(
                  dx: -AppTheme.BorderWidth.thin,
                  dy: -AppTheme.BorderWidth.thin
              ).contains(statusFrame) else {
            return false
        }
        let bounds = statusFrame.insetBy(
            dx: -AppTheme.BorderWidth.thin,
            dy: -AppTheme.BorderWidth.thin
        )
        return statusControlIdentifiers.allSatisfy {
            visibleProbe(identifier: $0, in: window, containedBy: bounds)
        }
    }

    private static func statusControlFrames(in window: NSWindow) -> [String: [String: Double]] {
        guard let root = window.contentView else { return [:] }
        return Dictionary(uniqueKeysWithValues: (["editor.statusBar"] + statusControlIdentifiers)
            .compactMap { identifier in
                findProbe(in: root, identifier: identifier).map {
                    (identifier, frameDescription($0.convert($0.bounds, to: root)))
                }
            })
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

    private static func clickAnywhere(
        identifier: String,
        preferredWindow: NSWindow
    ) -> String? {
        guard let (window, probe) = probeWindow(
            identifier: identifier,
            preferredWindow: preferredWindow
        ), let root = window.contentView else {
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

    private static func probeExistsAnywhere(
        identifier: String,
        preferredWindow: NSWindow
    ) -> Bool {
        probeWindow(identifier: identifier, preferredWindow: preferredWindow) != nil
    }

    private static func probeStateAnywhere(
        identifier: String,
        preferredWindow: NSWindow
    ) -> Bool? {
        guard let (_, probe) = probeWindow(
            identifier: identifier,
            preferredWindow: preferredWindow
        ) else { return nil }
        return (probe as? AppRelaunchClickProbeView)?.acceptanceState
    }

    private static func probeWindow(
        identifier: String,
        preferredWindow: NSWindow
    ) -> (NSWindow, NSView)? {
        let candidates = [preferredWindow] + NSApp.windows.filter { $0 !== preferredWindow }
        for window in candidates where window.isVisible && !window.ignoresMouseEvents {
            guard let root = window.contentView,
                  let probe = findProbe(in: root, identifier: identifier),
                  probe.window === window,
                  !probe.isHiddenOrHasHiddenAncestor else {
                continue
            }
            return (window, probe)
        }
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

    private static func probeValue(identifier: String, in window: NSWindow) -> String? {
        guard let root = window.contentView,
              let probe = findProbe(in: root, identifier: identifier)
                as? AppRelaunchClickProbeView else { return nil }
        return probe.acceptanceValue
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
