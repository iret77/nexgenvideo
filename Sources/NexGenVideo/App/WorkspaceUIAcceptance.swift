import AVFoundation
import AppKit
import SwiftUI

@MainActor
enum WorkspaceUIAcceptance {
    private static var editorSizeProbes: [[String: String]] = []
    private static var pickerRowProbes: [String: Set<String>] = [:]
    static let agentPinnedAwayNotification = Notification.Name(
        "WorkspaceUIAcceptance.agentPinnedAway"
    )

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_ACCEPTANCE"] == "1"
    }

    static func resetPickerRowProbes(for purpose: MediaLibraryPurpose) {
        guard isRequested else { return }
        pickerRowProbes[purpose.accessibilitySuffix] = []
    }

    static func recordPickerRow(assetID: String, purpose: MediaLibraryPurpose) {
        guard isRequested else { return }
        pickerRowProbes[purpose.accessibilitySuffix, default: []].insert(assetID)
    }

    static func pickerRowProbeCount(for purpose: MediaLibraryPurpose) -> Int {
        pickerRowProbes[purpose.accessibilitySuffix]?.count ?? 0
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
        pickerRowProbes = [:]
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
                    && mediaWorkspaceSurfaceIsValid(in: host)
                    && editor.mediaAssets.count >= 523
                    && editor.mediaAssets
                        .filter { $0.id.hasPrefix("acceptance-bulk-") }
                        .allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }
                    && editor.mediaManifest.intakeRoleByAssetID.keys
                        .allSatisfy { !$0.hasPrefix("acceptance-bulk-") }
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
            var browserFolderReturnOpened = false
            var hiddenSearchFolderDeleteExcluded = false
            var rootSessionWasIntentional = false
            guard click(identifier: "editor.panel.sidebar", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return !editor.isSidebarPresented
                          && visiblePanelIDs(in: host) == ["previewPanel", "inspectorPanel"]
                          && probeFrame("media.workspace.folderTree", in: host) == nil
                          && probeFrame("media.workspace.browser", in: host) != nil
                          && probeFrame("media.workspace.sourcePreview", in: host) != nil
                  }) else {
                fail("media folder sidebar did not hide independently", scale: scale)
            }
            guard click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-source"
                          && editor.mediaCommandFocus == .browser
                          && editor.focusedPanel == .preview
                  }),
                  pressKey(keyCode: 124, characters: "\u{F703}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedMediaAssetIds == ["selection-secondary"]
                  }) else {
                fail("hidden-sidebar media browser did not keep its commands", scale: scale)
            }
            guard click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-source"
                          && editor.mediaCommandFocus == .browser
                  }) else {
                fail("could not restore the browser source selection", scale: scale)
            }
            guard click(identifier: "editor.workspace.production", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .production
                  }),
                  click(identifier: "editor.workspace.media", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .media
                          && editor.mediaCommandFocus == .browser
                          && editor.focusedPanel == .preview
                  }),
                  pressKey(keyCode: 124, characters: "\u{F703}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedMediaAssetIds == ["selection-secondary"]
                  }),
                  click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-source"
                          && editor.mediaCommandFocus == .browser
                  }) else {
                fail("media browser command ownership did not survive a workspace return", scale: scale)
            }
            let sourceFrameBeforePreviewArrow = editor.sourcePlayheadFrame
            guard click(identifier: "media.workspace.sourcePreview", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.focusedPanel == .preview
                          && editor.mediaCommandFocus == .sourcePreview
                  }),
                  pressKey(keyCode: 124, characters: "\u{F703}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.sourcePlayheadFrame == sourceFrameBeforePreviewArrow + 1
                          && editor.mediaCommandFocus == .sourcePreview
                  }) else {
                fail("source preview did not keep its own arrow command", scale: scale)
            }
            guard click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.focusedPanel == .preview
                          && editor.mediaCommandFocus == .browser
                  }),
                  pressKey(keyCode: 50, characters: "`", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.maximizedPanel == .preview
                          && visiblePanelIDs(in: host) == ["previewPanel"]
                          && probeFrame("media.workspace.folderTree", in: host) == nil
                          && probeFrame("media.workspace.browser", in: host) != nil
                          && probeFrame("media.workspace.sourcePreview", in: host) != nil
                  }),
                  pressKey(keyCode: 50, characters: "`", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.maximizedPanel == nil
                          && !editor.isSidebarPresented
                          && visiblePanelIDs(in: host) == ["previewPanel", "inspectorPanel"]
                          && probeFrame("media.workspace.folderTree", in: host) == nil
                          && probeFrame("media.workspace.browser", in: host) != nil
                          && probeFrame("media.workspace.sourcePreview", in: host) != nil
                  }) else {
                fail("media browser maximize or restore targeted the wrong panel", scale: scale)
            }
            guard click(identifier: "editor.panel.sidebar", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.isSidebarPresented
                          && visiblePanelIDs(in: host) == expectedPanels(for: .media)
                          && mediaWorkspaceSurfaceIsValid(in: host)
                  }),
                  click(identifier: "selection.asset.selection-source", in: window) == nil,
                  click(identifier: "media.folder.row.acceptance-folder-0", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaPanelCurrentFolderId == "acceptance-folder-0"
                          && editor.mediaLibrarySession(for: .workspace).folderID
                              == "acceptance-folder-0"
                          && editor.mediaCommandFocus == .folderTree
                          && editor.selectedFolderIds == ["acceptance-folder-0"]
                          && editor.selectedMediaAssetIds.isEmpty
                  }),
                  pressKey(keyCode: 36, characters: "\r", in: window) == nil,
                  pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaPanelDeleteFolderRequest == ["acceptance-folder-0"]
                          && editor.folder(id: "acceptance-folder-0") != nil
                          && editor.mediaAssets.contains { $0.id == "selection-source" }
                          && editor.mediaCommandFocus == .folderTree
                  }),
                  pressKey(keyCode: 53, characters: "\u{1b}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaPanelDeleteFolderRequest.isEmpty
                  }),
                  click(identifier: "media.folder.library", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaPanelCurrentFolderId == nil
                          && editor.mediaLibrarySession(for: .workspace).folderID == nil
                  }),
                  click(identifier: "media.browser.folder.acceptance-folder-0", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaCommandFocus == .browser
                          && editor.selectedFolderIds == ["acceptance-folder-0"]
                  }) else {
                fail("native folder tree did not route the shared media library", scale: scale)
            }
            guard click(identifier: "media.search", in: window) == nil,
                  typeKeys([(6, "z"), (6, "z"), (6, "z"), (6, "z")], in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaLibrarySession(for: .workspace).query == "zzzz"
                          && editor.mediaPanelOrderedItemIds.isEmpty
                  }),
                  click(identifier: "media.workspace.browser", in: window) == nil,
                  pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil else {
                fail("search did not hide the selected browser folder", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(100))
            hiddenSearchFolderDeleteExcluded = editor.folder(id: "acceptance-folder-0") != nil
                && editor.selectedFolderIds == ["acceptance-folder-0"]
            guard hiddenSearchFolderDeleteExcluded,
                  click(identifier: "media.search", in: window) == nil,
                  pressKey(keyCode: 0, characters: "a", modifiers: [.command], in: window) == nil,
                  pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaLibrarySession(for: .workspace).query.isEmpty
                          && editor.mediaPanelOrderedItemIds.contains(
                              MediaPanelItemKey.folder("acceptance-folder-0")
                          )
                  }),
                  click(identifier: "media.workspace.browser", in: window) == nil,
                  pressKey(keyCode: 36, characters: "\r", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      let opened = editor.mediaPanelCurrentFolderId == "acceptance-folder-0"
                          && editor.selectedFolderIds.isEmpty
                      if opened { browserFolderReturnOpened = true }
                      return opened
                  }),
                  click(identifier: "media.search", in: window) == nil,
                  typeKeys(
                      [
                          (1, "s"), (14, "e"), (8, "c"), (31, "o"), (45, "n"),
                          (2, "d"), (0, "a"), (15, "r"), (16, "y"),
                      ],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      findProbe(
                          in: host,
                          identifier: "media.search.asset.selection-secondary"
                      ) != nil
                  }),
                  click(identifier: "media.search.asset.selection-secondary", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-secondary"
                          && editor.mediaPanelCurrentFolderId == "acceptance-folder-0"
                  }),
                  click(identifier: "media.search", in: window) == nil,
                  pressKey(keyCode: 0, characters: "a", modifiers: [.command], in: window) == nil,
                  pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaLibrarySession(for: .workspace).query.isEmpty
                  }),
                  click(identifier: "media.folder.row.acceptance-folder-0", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaCommandFocus == .folderTree
                          && editor.selectedFolderIds == ["acceptance-folder-0"]
                  }),
                  click(identifier: "selection.asset.acceptance-bulk-0", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaCommandFocus == .browser
                          && editor.selectedFolderIds.isEmpty
                          && editor.selectedMediaAssetIds == ["acceptance-bulk-0"]
                  }),
                  pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.folder(id: "acceptance-folder-0") != nil
                          && !editor.mediaAssets.contains { $0.id == "acceptance-bulk-0" }
                  }),
                  pressKey(keyCode: 6, characters: "z", modifiers: [.command], in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.folder(id: "acceptance-folder-0") != nil
                          && editor.mediaAssets.contains { $0.id == "acceptance-bulk-0" }
                  }),
                  click(identifier: "media.folder.library", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaPanelCurrentFolderId == nil
                          && editor.mediaLibrarySession(for: .workspace).folderID == nil
                  }) else {
                fail("native folder and browser selection paths diverged", scale: scale)
            }
            editor.publishMediaPanelFolder("acceptance-folder-0", for: .production)
            guard click(identifier: "editor.workspace.production", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .production
                          && editor.mediaPanelCurrentFolderId == "acceptance-folder-0"
                  }),
                  click(identifier: "editor.workspace.media", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      let restored = editor.workspaceFocus == .media
                          && editor.mediaPanelCurrentFolderId == nil
                          && editor.mediaLibrarySession(for: .workspace).folderID == nil
                          && probeState(identifier: "media.listMode", in: window) == true
                      if restored { rootSessionWasIntentional = true }
                      return restored
                  }),
                  click(identifier: "media.search", in: window) == nil,
                  typeKeys(
                      [
                          (31, "o"), (15, "r"), (34, "i"), (5, "g"), (34, "i"),
                          (45, "n"), (0, "a"), (37, "l"), (49, " "), (29, "0"),
                      ],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaLibrarySession(for: .workspace).query == "original 0"
                          && findProbe(
                              in: host,
                              identifier: "media.search.asset.acceptance-bulk-0"
                          ) != nil
                  }) else {
                fail("native folder tree did not route the shared media library", scale: scale)
            }
            emit(
                "media-keyboard",
                scale: scale,
                fields: [
                    "browserArrowSelected": "selection-secondary",
                    "hiddenSidebarBrowserCommands": true,
                    "browserLayoutPanel": "preview",
                    "browserMaximizePreservedSurface": true,
                    "browserRestorePreservedSurface": true,
                    "browserRoleRestoredAfterWorkspaceReturn": true,
                    "browserFolderReturnOpened": browserFolderReturnOpened,
                    "hiddenSearchFolderDeleteExcluded": hiddenSearchFolderDeleteExcluded,
                    "rootSessionWasIntentional": rootSessionWasIntentional,
                    "globalSearchReachedAnotherFolder": true,
                    "browserDeleteExcludedTreeFolder": editor.folder(id: "acceptance-folder-0") != nil,
                    "browserAssetSelectionSurvivedOwnershipTransfer": true,
                    "sourcePreviewCommandsIsolated": true,
                    "treeDeletePreservedAsset": editor.mediaAssets.contains { $0.id == "selection-source" },
                    "treeDeleteRequestedConfirmation": editor.folder(id: "acceptance-folder-0") != nil,
                    "folderCommandsIsolated": true,
                ]
            )
            resetSplitAutosaveDefaults()
            guard click(identifier: "editor.workspace.production", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
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
            let pickerTimeline = editor.timeline
            let productionPicker = editor.mediaLibrarySession(for: .productionSource)
            productionPicker.folderID = "acceptance-folder-0"
            productionPicker.filterTypes = []
            productionPicker.scrollAnchorID = nil
            WorkspaceUIAcceptance.resetPickerRowProbes(for: .productionSource)
            let productionEligibleCount = MediaLibraryProjection.assets(
                from: editor.mediaAssets.filter { !$0.isGenerating },
                session: productionPicker
            ).count
            var initialPickerScrollOrigin: NSPoint?
            var productionScrollDistance: CGFloat?
            var productionRenderedRows = 0
            guard productionEligibleCount > 1,
                  click(identifier: "mediaPicker.toggle.production", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      let count = pickerRowProbeCount(for: .productionSource)
                      let ready = probeState(identifier: "mediaPicker.toggle.production", in: window) == true
                          && count > 0
                          && count < productionEligibleCount
                      if ready {
                          initialPickerScrollOrigin = scrollOrigin(
                              identifier: "mediaPicker.production.scroll",
                              in: window
                          )
                          productionRenderedRows = count
                      }
                      return ready && initialPickerScrollOrigin != nil
                  }),
                  scroll(identifier: "mediaPicker.production.scroll", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      guard let initialPickerScrollOrigin,
                            let current = scrollOrigin(
                                identifier: "mediaPicker.production.scroll",
                                in: window
                            ) else { return false }
                      let distance = hypot(
                          current.x - initialPickerScrollOrigin.x,
                          current.y - initialPickerScrollOrigin.y
                      )
                      guard distance > AppTheme.BorderWidth.thin else { return false }
                      productionScrollDistance = distance
                      return true
                  }),
                  click(identifier: "mediaPicker.production.filter.video", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "mediaPicker.production.filter.video", in: window) == true
                          && productionPicker.filterTypes == [.video]
                          && findProbe(
                              in: host,
                              identifier: "mediaPicker.production.asset.acceptance-bulk-0"
                          ) != nil
                  }) else {
                fail("production picker did not scroll or apply the native filter", scale: scale)
            }
            productionPicker.scrollAnchorID = "acceptance-bulk-0"
            guard await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return clickTargetIsVisible(
                          identifier: "mediaPicker.production.asset.acceptance-bulk-0",
                          in: window
                      )
                  }),
                  click(
                      identifier: "mediaPicker.production.asset.acceptance-bulk-0",
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "acceptance-bulk-0"
                          && productionPicker.selectedAssetIDs == ["acceptance-bulk-0"]
                  }),
                  click(identifier: "preview.scrub", horizontalFraction: 0.25, in: window) == nil,
                  click(identifier: "source.markIn", in: window) == nil,
                  click(identifier: "preview.scrub", horizontalFraction: 0.75, in: window) == nil,
                  click(identifier: "source.markOut", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourcePreviewState?.inFrame != nil
                          && editor.activeSourcePreviewState?.outFrame != nil
                  }) else {
                fail("production picker did not lazily select and range a real source", scale: scale)
            }
            let productionRange = editor.activeSourcePreviewState
            let postPicker = editor.mediaLibrarySession(for: .postproductionSource)
            postPicker.folderID = "acceptance-folder-0"
            postPicker.filterTypes = []
            WorkspaceUIAcceptance.resetPickerRowProbes(for: .postproductionSource)
            guard click(identifier: "editor.workspace.postproduction", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.workspaceFocus == .postproduction
                          && visiblePanelIDs(in: host) == expectedPanels(for: .postproduction)
                  }),
                  click(identifier: "mediaPicker.toggle.postproduction", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "mediaPicker.toggle.postproduction", in: window) == true
                          && pickerRowProbeCount(for: .postproductionSource) > 0
                  }),
                  click(identifier: "mediaPicker.postproduction.filter.video", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "mediaPicker.postproduction.filter.video", in: window) == true
                          && postPicker.filterTypes == [.video]
                  }) else {
                fail("postproduction picker did not apply the native filter", scale: scale)
            }
            postPicker.scrollAnchorID = "acceptance-bulk-0"
            guard await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return clickTargetIsVisible(
                          identifier: "mediaPicker.postproduction.asset.acceptance-bulk-0",
                          in: window
                      )
                  }),
                  click(
                      identifier: "mediaPicker.postproduction.asset.acceptance-bulk-0",
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "acceptance-bulk-0"
                          && postPicker.selectedAssetIDs == ["acceptance-bulk-0"]
                  }),
                  click(identifier: "preview.scrub", horizontalFraction: 0.1, in: window) == nil,
                  click(identifier: "source.markIn", in: window) == nil,
                  click(identifier: "preview.scrub", horizontalFraction: 0.4, in: window) == nil,
                  click(identifier: "source.markOut", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      guard let state = editor.activeSourcePreviewState else { return false }
                      return state.inFrame != productionRange?.inFrame
                          && state.outFrame != productionRange?.outFrame
                  }),
                  click(identifier: "mediaPicker.toggle.postproduction", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "mediaPicker.toggle.postproduction", in: window) == false
                  }),
                  click(identifier: "editor.workspace.production", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .production
                          && editor.activeSourceAsset?.id == "acceptance-bulk-0"
                          && editor.activeSourcePreviewState == productionRange
                          && productionPicker.folderID == "acceptance-folder-0"
                          && productionPicker.selectedAssetIDs == ["acceptance-bulk-0"]
                          && editor.timeline == pickerTimeline
                  }) else {
                fail("picker purpose switch changed source range, folder, selection, or timeline", scale: scale)
            }
            emit(
                "media-picker",
                scale: scale,
                fields: [
                    "eligibleRows": productionEligibleCount,
                    "renderedRows": productionRenderedRows,
                    "activeAsset": editor.activeSourceAsset?.id ?? "",
                    "folder": productionPicker.folderID ?? "",
                    "sourceIn": editor.activeSourcePreviewState?.inFrame ?? -1,
                    "sourceOut": editor.activeSourcePreviewState?.outFrame ?? -1,
                    "timelineStable": editor.timeline == pickerTimeline,
                    "nativeFilterSelected": productionPicker.filterTypes == [.video],
                    "nativeScrollDistance": productionScrollDistance ?? 0,
                    "postPurposeSelectedSameAsset": postPicker.selectedAssetIDs == ["acceptance-bulk-0"],
                    "productionPurposeRestored": editor.activeSourcePreviewState == productionRange,
                    "fixtureAssetCount": editor.mediaAssets.filter {
                        $0.id.hasPrefix("acceptance-bulk-")
                    }.count,
                    "fixtureTypeCounts": Dictionary(
                        grouping: editor.mediaAssets.filter {
                            $0.id.hasPrefix("acceptance-bulk-")
                        },
                        by: { $0.type.rawValue }
                    ).mapValues(\.count),
                ]
            )
            guard click(identifier: "mediaPicker.production.showInMedia", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .media
                          && editor.activeSourceAsset?.id == "acceptance-bulk-0"
                          && editor.mediaLibrarySession(for: .workspace).query == "original 0"
                          && editor.mediaLibrarySession(for: .workspace).folderID
                              == "acceptance-folder-0"
                  }) else {
                fail("Show in Media did not preserve compatible workspace filters", scale: scale)
            }
            emit(
                "media-reveal",
                scale: scale,
                fields: [
                    "activeAsset": editor.activeSourceAsset?.id ?? "",
                    "compatibleQueryPreserved": true,
                    "revealedFolder": editor.mediaLibrarySession(for: .workspace).folderID ?? "",
                    "rootSessionWasIntentional": rootSessionWasIntentional,
                ]
            )
            guard click(identifier: "media.search", in: window) == nil,
                  pressKey(keyCode: 0, characters: "a", modifiers: [.command], in: window) == nil,
                  pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaLibrarySession(for: .workspace).query.isEmpty
                  }),
                  click(identifier: "editor.workspace.production", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .production
                          && editor.activeSourceAsset?.id == "acceptance-bulk-0"
                          && editor.activeSourcePreviewState == productionRange
                  }) else {
                fail("production source state did not survive native reveal", scale: scale)
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
                        && (workspace != .media || mediaWorkspaceSurfaceIsValid(in: host))
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
                      workspace != .media || mediaWorkspaceSurfaceIsValid(in: host),
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
                var fields: [String: Any] = [
                    "workspace": workspace.rawValue,
                    "screenshot": "\(name).png",
                    "panels": visiblePanels.sorted(),
                    "frames": renderedFrames.mapValues { frameDescription($0) },
                ]
                if workspace == .media {
                    fields["mediaAssetCount"] = editor.mediaAssets.count
                    fields["mediaSurface"] = mediaWorkspaceSurfaceDiagnostics(in: host)
                    fields["bulkFilesUnavailable"] = editor.mediaAssets
                        .filter { $0.id.hasPrefix("acceptance-bulk-") }
                        .filter { !FileManager.default.fileExists(atPath: $0.url.path) }
                        .count
                    fields["bulkIntakeAssignments"] = editor.mediaManifest.intakeRoleByAssetID.keys
                        .filter { $0.hasPrefix("acceptance-bulk-") }
                        .count
                }
                emit(
                    "workspace",
                    scale: scale,
                    fields: fields
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

            guard click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaCommandFocus == .browser
                          && editor.focusedPanel == .media
                  }),
                  click(identifier: "editor.workspace.production", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .production
                  }),
                  click(identifier: "editor.workspace.edit", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .edit
                          && editor.mediaCommandFocus == .browser
                          && editor.focusedPanel == .media
                  }),
                  pressKey(keyCode: 124, characters: "\u{F703}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedMediaAssetIds == ["selection-secondary"]
                  }),
                  click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedMediaAssetIds == ["selection-source"]
                          && editor.mediaCommandFocus == .browser
                  }) else {
                fail("edit browser command ownership did not survive a workspace return", scale: scale)
            }
            let hiddenBrowserSelection = editor.selectedMediaAssetIds
            let hiddenBrowserFolder = editor.mediaPanelCurrentFolderId
            var captionsHiddenBrowserCommandsBlocked = false
            var musicHiddenBrowserCommandsBlocked = false
            guard click(identifier: "media.tab.Captions", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaPanelTab == .captions
                          && editor.mediaCommandFocus == nil
                  }),
                  click(identifier: "editor.workspace.production", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .production
                  }),
                  click(identifier: "editor.workspace.edit", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .edit
                          && editor.mediaPanelTab == .captions
                          && editor.mediaCommandFocus == nil
                  }),
                  pressKey(keyCode: 124, characters: "\u{F703}", in: window) == nil,
                  pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil,
                  pressKey(keyCode: 36, characters: "\r", in: window) == nil else {
                fail("Captions restored hidden media-browser commands", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(100))
            captionsHiddenBrowserCommandsBlocked = editor.selectedMediaAssetIds == hiddenBrowserSelection
                && editor.mediaPanelCurrentFolderId == hiddenBrowserFolder
                && editor.mediaPanelOpenFolderId == nil
            guard captionsHiddenBrowserCommandsBlocked,
                  click(identifier: "media.tab.Music", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaPanelTab == .music
                          && editor.mediaCommandFocus == nil
                  }),
                  click(identifier: "editor.workspace.production", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .production
                  }),
                  click(identifier: "editor.workspace.edit", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.workspaceFocus == .edit
                          && editor.mediaPanelTab == .music
                          && editor.mediaCommandFocus == nil
                  }),
                  pressKey(keyCode: 123, characters: "\u{F702}", in: window) == nil,
                  pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil,
                  pressKey(keyCode: 36, characters: "\r", in: window) == nil else {
                fail("Music restored hidden media-browser commands", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(100))
            musicHiddenBrowserCommandsBlocked = editor.selectedMediaAssetIds == hiddenBrowserSelection
                && editor.mediaPanelCurrentFolderId == hiddenBrowserFolder
                && editor.mediaPanelOpenFolderId == nil
            guard musicHiddenBrowserCommandsBlocked,
                  click(identifier: "media.tab.Assets", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.mediaPanelTab == .assets
                  }),
                  click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedMediaAssetIds == ["selection-source"]
                          && editor.mediaCommandFocus == .browser
                  }) else {
                fail("edit media browser did not recover after hidden-tab command checks", scale: scale)
            }
            emit(
                "media-command-restore",
                scale: scale,
                fields: [
                    "captionsHiddenBrowserCommandsBlocked": captionsHiddenBrowserCommandsBlocked,
                    "editBrowserArrowSelected": "selection-secondary",
                    "editBrowserRoleRestored": true,
                    "mediaBrowserRoleRestored": true,
                    "musicHiddenBrowserCommandsBlocked": musicHiddenBrowserCommandsBlocked,
                ]
            )

            let selectionTimeline = editor.timeline
            let selectionCurrentFrame = editor.currentFrame
            let selectionSourceFrame = editor.sourcePlayheadFrame
            let selectionClipIDs = editor.selectedClipIds
            let selectionAssetIDs = editor.selectedMediaAssetIds
            let selectionFolderIDs = editor.selectedFolderIds
            let selectionInspectedObject = editor.inspectedObject
            let selectionPreviewTabs = editor.previewTabs
            let selectionPreviewTabID = editor.activePreviewTabId
            let selectionPreviewHistory = editor.previewTabHistory
            let selectionPreviewHistoryIndex = editor.previewTabHistoryIndex
            let selectionSourceStates = editor.sourcePreviewStates
            let selectionExplicitTimelineClipID = editor.explicitTimelineInspectionClipID

            guard click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                          && probeState(identifier: "preview.selectionContext", in: window) == false
                          && probeState(identifier: "inspector.selectionContext", in: window) == false
            }) else {
                fail("source selection did not activate the media context", scale: scale)
            }
            guard click(
                identifier: "selection.asset.selection-secondary",
                modifiers: [.shift],
                in: window
            ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedMediaAssetIds == ["selection-source", "selection-secondary"]
                          && editor.activeSourceAsset?.id == "selection-secondary"
                  }),
                  click(
                      identifier: "selection.asset.selection-secondary",
                      modifiers: [.shift],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedMediaAssetIds == ["selection-source"]
                          && editor.activeSourceAsset?.id == "selection-secondary"
                  }),
                  click(
                      identifier: "selection.asset.selection-source",
                      modifiers: [.shift],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedMediaAssetIds.isEmpty
                          && editor.activeSourceAsset?.id == "selection-source"
                  }),
                  click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedMediaAssetIds == ["selection-source"]
                          && editor.activeSourceAsset?.id == "selection-source"
                  }) else {
                fail("source multiselection did not preserve deterministic active context", scale: scale)
            }
            guard click(identifier: "selection.asset.selection-offline", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-offline"
                          && editor.inspectedObject == .mediaAsset("selection-offline")
                          && editor.isMediaOffline("selection-offline")
                          && !editor.canPlaceActiveSource
                  }),
                  click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                  }) else {
                fail("offline source selection exposed an invalid placement command", scale: scale)
            }
            editor.currentFrame = 75
            guard click(
                identifier: "preview.scrub",
                horizontalFraction: 18.5 / 120,
                in: window
            ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.sourcePlayheadFrame == 18 && editor.currentFrame == 75
                  }),
                  click(identifier: "source.markIn", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourcePreviewState?.inFrame == 18
                  }) else {
                fail("source scrub or Mark In did not write the source range", scale: scale)
            }
            guard pressKey(
                keyCode: 124,
                characters: "\u{F703}",
                modifiers: [.shift],
                in: window
            ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.sourcePlayheadFrame == 23 && editor.currentFrame == 75
                  }),
                  click(
                      identifier: "preview.scrub",
                      horizontalFraction: 71.5 / 120,
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), { editor.sourcePlayheadFrame == 71 }),
                  click(identifier: "preview.stepForward", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.sourcePlayheadFrame == 72 && editor.currentFrame == 75
                  }),
                  pressKey(keyCode: 123, characters: "\u{F702}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), { editor.sourcePlayheadFrame == 71 }),
                  click(identifier: "preview.stepForward", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), { editor.sourcePlayheadFrame == 72 }),
                  pressKey(keyCode: 31, characters: "o", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourcePreviewState?.outFrame == 72
                  }) else {
                fail("source skip, arrow, step, or Mark Out command failed", scale: scale)
            }
            guard click(
                identifier: "preview.scrub",
                horizontalFraction: 42.5 / 120,
                in: window
            ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.sourcePlayheadFrame == 42 && editor.currentFrame == 75
            }) else {
                fail("source scrub did not restore the marked source playhead", scale: scale)
            }

            guard click(identifier: "selection.clip.selection-clip", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedClipIds == ["selection-clip"]
                          && editor.inspectedObject == .clip("selection-clip")
                  }),
                  click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                          && editor.selectedClipIds == ["selection-clip"]
                  }) else {
                fail("could not prepare a remembered timeline identity for source placement", scale: scale)
            }

            let timelineBeforePlacement = editor.timeline
            let timelinePlayheadBeforeInsertUndoRedo = editor.currentFrame
            guard let acceptanceUndoManager = document.undoManager else {
                fail("selection acceptance has no undo manager", scale: scale)
            }
            guard click(identifier: "source.insert", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline != timelineBeforePlacement
                          && acceptanceUndoManager.undoActionName == "Insert Source"
                  }),
                  editor.activeSourcePreviewState?.inFrame == 18,
                  editor.activeSourcePreviewState?.outFrame == 72 else {
                fail("source insert did not preserve the active source range", scale: scale)
            }
            guard pressKey(
                keyCode: 6,
                characters: "z",
                modifiers: [.command],
                in: window
            ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline == timelineBeforePlacement
                          && editor.activeSourceAsset?.id == "selection-source"
            }) else {
                fail("undo did not restore the pre-insert timeline and source context", scale: scale)
            }
            guard pressKey(
                      keyCode: 6,
                      characters: "Z",
                      modifiers: [.command, .shift],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline != timelineBeforePlacement
                          && editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                  }),
                  click(identifier: "selection.ruler", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.isTimelinePreviewActive
                          && editor.currentFrame == 96
                          && editor.sourcePlayheadFrame == 42
                          && editor.inspectedObject == .clip("selection-clip")
                          && probeState(
                              identifier: "preview.selectionContext.selection-clip",
                              in: window
                          ) == true
                          && probeState(
                              identifier: "inspector.selectionContext.selection-clip",
                              in: window
                          ) == true
                  }),
                  pressKey(
                      keyCode: 6,
                      characters: "z",
                      modifiers: [.command],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline == timelineBeforePlacement
                          && editor.isTimelinePreviewActive
                          && editor.currentFrame == 96
                          && editor.sourcePlayheadFrame == 42
                          && editor.inspectedObject == .clip("selection-clip")
                          && editor.timelineInspectorClipIDs == ["selection-clip"]
                          && probeState(
                              identifier: "preview.selectionContext.selection-clip",
                              in: window
                          ) == true
                          && probeState(
                              identifier: "inspector.selectionContext.selection-clip",
                              in: window
                          ) == true
                  }),
                  pressKey(
                      keyCode: 6,
                      characters: "Z",
                      modifiers: [.command, .shift],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline != timelineBeforePlacement
                          && editor.isTimelinePreviewActive
                          && editor.currentFrame == 96
                          && editor.sourcePlayheadFrame == 42
                          && editor.inspectedObject == .clip("selection-clip")
                          && editor.timelineInspectorClipIDs == ["selection-clip"]
                  }),
                  pressKey(
                      keyCode: 6,
                      characters: "z",
                      modifiers: [.command],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline == timelineBeforePlacement
                          && editor.isTimelinePreviewActive
                          && editor.currentFrame == 96
                          && editor.sourcePlayheadFrame == 42
                          && editor.inspectedObject == .clip("selection-clip")
                  }),
                  click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                          && editor.currentFrame == 96
                          && editor.sourcePlayheadFrame == 42
                  }) else {
                fail("source Insert Undo/Redo replaced the active timeline context", scale: scale)
            }
            editor.currentFrame = timelinePlayheadBeforeInsertUndoRedo
            guard await waitUntil(timeout: .seconds(5), {
                editor.currentFrame == timelinePlayheadBeforeInsertUndoRedo
                    && editor.sourcePlayheadFrame == 42
            }) else {
                fail(
                    "source Insert Undo/Redo did not restore the prior timeline playhead",
                    scale: scale
                )
            }
            guard click(identifier: "source.overwrite", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline != timelineBeforePlacement
                          && acceptanceUndoManager.undoActionName == "Overwrite Source"
                  }) else {
                fail("source overwrite did not create one undoable edit", scale: scale)
            }
            guard pressKey(
                keyCode: 6,
                characters: "z",
                modifiers: [.command],
                in: window
            ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline == timelineBeforePlacement
                          && editor.sourcePlayheadFrame == 42
                          && editor.currentFrame == 75
                  }) else {
                fail("undo did not keep source and timeline playheads independent", scale: scale)
            }

            guard click(identifier: "preview.playPause", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), { editor.isPlaying }) else {
                fail("source transport did not start playback", scale: scale)
            }
            scheduleKeySequence([(53, "\u{1b}")], in: window)
            guard contextClick(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                          && editor.isPlaying
                  }) else {
                fail("same-source context activation interrupted playback", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard click(identifier: "media.search", in: window) == nil,
                  typeKeys(
                      [
                          (1, "s"), (14, "e"), (37, "l"), (14, "e"),
                          (8, "c"), (17, "t"), (34, "i"), (31, "o"), (45, "n"),
                      ],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "media.search", in: window) == true
                          && probeState(identifier: "media.listMode", in: window) == true
                          && editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                          && editor.isPlaying
                  }),
                  pressKey(
                      keyCode: 0,
                      characters: "a",
                      modifiers: [.command],
                      in: window
                  ) == nil,
                  pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "media.search", in: window) == false
                          && probeState(identifier: "media.listMode", in: window) == true
                          && editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                          && editor.isPlaying
                  }) else {
                fail("search changed or interrupted the active source context", scale: scale)
            }
            scheduleKeySequence(
                [(115, "\u{F729}"), (36, "\r")],
                in: window
            )
            guard click(identifier: "media.sort", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "media.sort", in: window) == true
                          && probeState(identifier: "media.listMode", in: window) == true
                          && editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                          && editor.isPlaying
                  }) else {
                fail("sorting changed or interrupted the active source context", scale: scale)
            }
            scheduleKeySequence([(115, "\u{F729}"), (36, "\r")], in: window)
            guard click(identifier: "media.filter", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "media.filter", in: window) == true
                          && probeState(identifier: "media.listMode", in: window) == true
                          && editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                          && editor.isPlaying
            }) else {
                fail("filtering changed or interrupted the active source context", scale: scale)
            }
            scheduleKeySequence(
                [(115, "\u{F729}"), (125, "\u{F701}"), (36, "\r")],
                in: window
            )
            guard click(identifier: "media.layout", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      probeState(identifier: "media.layout", in: window) == true
                          && editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                          && editor.isPlaying
                  }) else {
                fail("grid/list layout changed or interrupted the active source context", scale: scale)
            }
            guard click(identifier: "preview.playPause", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), { !editor.isPlaying }) else {
                fail("source transport did not stop playback", scale: scale)
            }

            guard click(identifier: "selection.ruler", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.isTimelinePreviewActive
                          && editor.currentFrame == 96
                          && editor.sourcePreviewState(for: "selection-source")
                              == SourcePreviewState(playheadFrame: 42, inFrame: 18, outFrame: 72)
                  }) else {
                fail("timeline ruler did not activate an independent timeline playhead", scale: scale)
            }
            guard click(identifier: "selection.clip.selection-title", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.isTimelinePreviewActive
                          && editor.selectedClipIds == ["selection-title"]
                          && editor.inspectedObject == .clip("selection-title")
                  }),
                  click(identifier: "selection.empty", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.isTimelinePreviewActive
                          && editor.selectedClipIds.isEmpty
                          && editor.inspectedObject == nil
            }) else {
                fail("title or empty-area selection did not produce a deterministic context", scale: scale)
            }
            guard click(identifier: "selection.clip.selection-linked-video", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedClipIds == ["selection-linked-video", "selection-linked-audio"]
                          && editor.isTimelineBatchSelection
                          && editor.inspectedObject == nil
                          && probeState(identifier: "preview.selectionContext", in: window) == false
                          && probeState(identifier: "inspector.selectionContext", in: window) == false
                  }),
                  contextClick(identifier: "selection.clip.selection-linked-video", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeTimelineInspectionClipID == "selection-linked-video"
                          && editor.timelineCommandClipIDs
                              == ["selection-linked-video", "selection-linked-audio"]
                  }) else {
                fail("linked A/V context did not expose its exact command target", scale: scale)
            }
            scheduleKeySequence([(115, "\u{F729}"), (36, "\r")], in: window)
            guard await waitUntil(timeout: .seconds(5), {
                      Set(editor.clipClipboard.map(\.clip.id))
                          == ["selection-linked-video", "selection-linked-audio"]
                          && editor.explicitTimelineInspectionClipID == nil
                          && editor.isTimelineBatchSelection
                  }) else {
                fail("linked A/V context Copy did not capture only the clicked link group", scale: scale)
            }
            let timelinePlayheadBeforePositivePaste = editor.currentFrame
            editor.currentFrame = 210
            guard await waitUntil(timeout: .seconds(5), {
                      editor.focusedPanel == .timeline
                          && validatedMainMenuItemEnabled(title: "Paste") == true
                  }),
                  click(identifier: "selection.trackLock.selection-linked-audio-track", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline.tracks.first(where: {
                          $0.id == "selection-linked-audio-track"
                      })?.editLocked == true
                          && editor.focusedPanel == .timeline
                          && validatedMainMenuItemEnabled(title: "Paste") == false
                  }) else {
                fail("linked A/V selection or native disabled Paste validation failed", scale: scale)
            }
            let pasteBlockedTimeline = editor.timeline
            guard pressKey(
                keyCode: 9,
                characters: "v",
                modifiers: [.command],
                in: window
            ) == nil else {
                fail("could not send the disabled Paste command", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(100))
            guard editor.timeline == pasteBlockedTimeline,
                  click(identifier: "selection.trackLock.selection-linked-audio-track", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline.tracks.first(where: {
                          $0.id == "selection-linked-audio-track"
                      })?.editLocked == false
                          && editor.focusedPanel == .timeline
                          && validatedMainMenuItemEnabled(title: "Paste") == true
                  }) else {
                fail("Paste did not re-enable with the same clipboard and timeline focus", scale: scale)
            }
            let timelineBeforePositivePaste = editor.timeline
            guard pressKey(
                      keyCode: 9,
                      characters: "v",
                      modifiers: [.command],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline != timelineBeforePositivePaste
                          && editor.selectedClipIds.count == 2
                          && editor.explicitTimelineInspectionClipID == nil
                  }),
                  pressKey(
                      keyCode: 6,
                      characters: "z",
                      modifiers: [.command],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline == timelineBeforePositivePaste
                          && editor.focusedPanel == .timeline
                          && validatedMainMenuItemEnabled(title: "Paste") == true
                  }) else {
                fail("Paste positive control or Undo failed", scale: scale)
            }
            editor.currentFrame = timelinePlayheadBeforePositivePaste
            guard await waitUntil(timeout: .seconds(5), {
                editor.currentFrame == timelinePlayheadBeforePositivePaste
            }) else {
                fail("Paste positive control did not restore the prior timeline playhead", scale: scale)
            }
            guard click(identifier: "selection.clip.selection-title", in: window) == nil,
                  click(
                      identifier: "selection.clip.selection-clip",
                      modifiers: [.shift],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedClipIds == ["selection-title", "selection-clip"]
                          && editor.isTimelineBatchSelection
                          && editor.inspectedObject == nil
                  }) else {
                fail("batch selection after Paste Undo failed", scale: scale)
            }
            guard contextClick(identifier: "selection.clip.selection-clip", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedClipIds == ["selection-title", "selection-clip"]
                          && editor.activeTimelineInspectionClipID == "selection-clip"
                          && editor.timelineInspectorClipIDs == ["selection-clip"]
                          && editor.inspectedObject == .clip("selection-clip")
                          && editor.selectionContextHint?.contains("Selection Source") == true
                          && probeState(identifier: "preview.selectionContext", in: window) == true
                          && probeState(identifier: "inspector.selectionContext", in: window) == true
                          && probeState(
                              identifier: "preview.selectionContext.selection-clip",
                              in: window
                          ) == true
                          && probeState(
                              identifier: "inspector.selectionContext.selection-clip",
                              in: window
                          ) == true
                          && probeState(
                              identifier: "inspector.clipMutation.selection-clip",
                              in: window
                          ) == true
                  }) else {
                fail("context click did not keep one visible and actionable clip target", scale: scale)
            }
            scheduleKeySequence([(115, "\u{F729}"), (36, "\r")], in: window)
            guard await waitUntil(timeout: .seconds(5), {
                      editor.clipClipboard.count == 1
                          && editor.clipClipboard.first?.clip.id == "selection-clip"
                          && editor.explicitTimelineInspectionClipID == nil
                          && editor.isTimelineBatchSelection
                  }) else {
                fail("context Copy did not end in the remembered batch context", scale: scale)
            }
            scheduleKeySequence([(53, "\u{1b}")], in: window)
            guard contextClick(identifier: "selection.clip.selection-clip", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeTimelineInspectionClipID == "selection-clip"
                          && editor.timelineCommandClipIDs == ["selection-clip"]
                  }) else {
                fail("could not prepare the explicit Escape target", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard editor.selectedClipIds == ["selection-title", "selection-clip"],
                  editor.explicitTimelineInspectionClipID == nil,
                  editor.inspectedObject == nil,
                  probeState(identifier: "preview.selectionContext", in: window) == false,
                  probeState(identifier: "inspector.selectionContext", in: window) == false else {
                fail("Escape did not end the explicit timeline context", scale: scale)
            }
            guard contextClick(identifier: "selection.clip.selection-clip", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeTimelineInspectionClipID == "selection-clip"
                          && editor.timelineCommandClipIDs == ["selection-clip"]
                  }) else {
                fail("could not prepare the explicit Delete target", scale: scale)
            }
            scheduleKeySequence(
                [(115, "\u{F729}"), (125, "\u{F701}"), (36, "\r")],
                in: window
            )
            guard await waitUntil(timeout: .seconds(5), {
                      editor.clipFor(id: "selection-clip") == nil
                          && editor.clipFor(id: "selection-title") != nil
                          && editor.selectedClipIds == ["selection-title"]
                          && editor.explicitTimelineInspectionClipID == nil
                          && editor.inspectedObject == .clip("selection-title")
                  }),
                  pressKey(
                      keyCode: 6,
                      characters: "z",
                      modifiers: [.command],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.clipFor(id: "selection-clip") != nil
                          && editor.selectedClipIds == ["selection-title", "selection-clip"]
                          && editor.explicitTimelineInspectionClipID == nil
                          && editor.isTimelineBatchSelection
                          && editor.inspectedObject == nil
                          && probeState(identifier: "preview.selectionContext", in: window) == false
                          && probeState(identifier: "inspector.selectionContext", in: window) == false
                  }) else {
                fail("explicit context Delete mutated the remembered batch", scale: scale)
            }
            guard click(identifier: "selection.empty", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.selectedClipIds.isEmpty
                          && editor.explicitTimelineInspectionClipID == nil
                          && probeState(identifier: "preview.selectionContext", in: window) == false
                  }),
                  click(identifier: "selection.clip.selection-clip", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.isTimelinePreviewActive
                          && editor.selectedClipIds == ["selection-clip"]
                          && editor.timelineInspectorClipIDs == ["selection-clip"]
                          && editor.inspectedObject == .clip("selection-clip")
                  }),
                  pressKey(keyCode: 30, characters: "]", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.clipFor(id: "selection-clip")?.durationFrames == 96
                          && editor.clipFor(id: "selection-clip")?.trimEndFrame == 24
                          && editor.sourcePreviewState(for: "selection-source")
                              == SourcePreviewState(playheadFrame: 42, inFrame: 18, outFrame: 72)
                  }),
                  click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-source"
                          && editor.sourcePlayheadFrame == 42
                          && editor.currentFrame == 96
                          && editor.activeSourcePreviewState?.inFrame == 18
                          && editor.activeSourcePreviewState?.outFrame == 72
                  }),
                  pressKey(
                      keyCode: 6,
                      characters: "z",
                      modifiers: [.command],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.clipFor(id: "selection-clip")?.durationFrames == 120
                          && editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                  }),
                  pressKey(
                      keyCode: 6,
                      characters: "Z",
                      modifiers: [.command, .shift],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.clipFor(id: "selection-clip")?.durationFrames == 96
                          && editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
                  }),
                  click(identifier: "selection.clip.selection-clip", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.isTimelinePreviewActive
                          && editor.inspectedObject == .clip("selection-clip")
                  }) else {
                fail("timeline clip trim did not preserve the independent source context", scale: scale)
            }
            guard click(identifier: "selection.trackLock.selection-track", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline.tracks.first?.editLocked == true
                  }) else {
                fail("native track lock did not lock the selected clip", scale: scale)
            }
            let lockedTimeline = editor.timeline
            guard pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil else {
                fail("could not send the locked Delete keyboard command", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(100))
            guard editor.timeline == lockedTimeline,
                  editor.selectedClipIds == ["selection-clip"],
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      return probeState(identifier: "preview.selectionContext", in: window) == true
                          && probeState(identifier: "inspector.selectionContext", in: window) == true
                          && probeState(identifier: "inspector.clipMutation", in: window) == false
                  }) else {
                fail("locked timeline selection exposed an editable clip context", scale: scale)
            }
            let timelineSelectionName = "scale-\(scaleLabel(scale))-selection-timeline"
            guard snapshot(host, at: evidenceURL.appendingPathComponent("\(timelineSelectionName).png")) else {
                fail("could not capture timeline selection evidence", scale: scale)
            }
            emit(
                "selection-timeline",
                scale: scale,
                fields: [
                    "screenshot": "\(timelineSelectionName).png",
                    "activeClip": "selection-clip",
                    "clipMutationEnabled": false,
                    "lockedMutationBlocked": true,
                    "rememberedAsset": editor.selectedMediaAssetIds.contains("selection-source"),
                    "nativeClipSelection": true,
                    "nativeTrackLock": true,
                    "nativeLockedDeleteBlocked": true,
                    "nativeTimelineRuler": true,
                    "nativeTimelineTrim": true,
                    "nativeTitleSelection": true,
                    "nativeEmptySelection": true,
                    "nativeLinkedAVSelection": true,
                    "nativeContextTarget": true,
                    "nativeContextEscape": true,
                    "nativeContextDelete": true,
                    "nativeContextCopyPaste": true,
                    "headerInspectorTargetMatched": true,
                    "nativeTimelineUndoRedoAfterSourceSwitch": true,
                    "nativeSourceInsertUndoRedoAfterTimelineSwitch": true,
                    "nativeDisabledPaste": true,
                    "nativePastePositiveControl": true,
                    "sourceStatePreserved": editor.sourcePreviewState(for: "selection-source")
                        == SourcePreviewState(playheadFrame: 42, inFrame: 18, outFrame: 72),
                ]
            )

            guard click(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      guard let inspectorFrame = visiblePanelFrames(in: host)["inspectorPanel"] else {
                          return false
                      }
                      return editor.activeSourceAsset?.id == "selection-source"
                          && editor.selectedClipIds == ["selection-clip"]
                          && probeState(identifier: "preview.selectionContext", in: window) == false
                          && probeState(identifier: "inspector.selectionContext", in: window) == false
                          && visibleProbe(
                              identifier: "inspector.sourceRange",
                              in: window,
                              containedBy: inspectorFrame,
                              requiredState: true
                          )
                          && visibleProbe(
                              identifier: "inspector.sourcePlacement",
                              in: window,
                              containedBy: inspectorFrame,
                              requiredState: true
                          )
                          && !editor.canInsertActiveSource
                          && editor.canOverwriteActiveSource
                  }) else {
                fail("locked clip state leaked into source controls", scale: scale)
            }
            scheduleKeySequence([(53, "\u{1b}")], in: window)
            guard contextClick(identifier: "selection.clip.selection-clip", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.isTimelinePreviewActive
                          && editor.inspectedObject == .clip("selection-clip")
            }) else {
                fail("timeline context click did not activate the exact remembered clip", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(450))
            scheduleKeySequence([(53, "\u{1b}")], in: window)
            guard contextClick(identifier: "selection.asset.selection-source", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.activeSourceAsset?.id == "selection-source"
                          && editor.inspectedObject == .mediaAsset("selection-source")
            }) else {
                fail("media context click did not activate the exact remembered source", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard pressKey(keyCode: 53, characters: "\u{1b}", in: window) == nil else {
                fail("could not dismiss the media context menu", scale: scale)
            }
            try? await Task.sleep(for: .milliseconds(100))
            guard click(identifier: "selection.trackLock.selection-track", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline.tracks.first(where: { $0.id == "selection-track" })?.editLocked == false
                  }),
                  click(identifier: "selection.asset.selection-source", in: window) == nil,
                  pressKey(keyCode: 51, characters: "\u{8}", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      !editor.mediaAssets.contains { $0.id == "selection-source" }
                          && editor.clipFor(id: "selection-clip") == nil
                  }),
                  pressKey(
                      keyCode: 6,
                      characters: "z",
                      modifiers: [.command],
                      in: window
                  ) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      host.layoutSubtreeIfNeeded()
                      host.displayIfNeeded()
                      return editor.activeSourceAsset?.id == "selection-source"
                          && editor.selectedMediaAssetIds == ["selection-source"]
                          && editor.inspectedObject == .mediaAsset("selection-source")
                          && editor.clipFor(id: "selection-clip") != nil
                          && findProbe(in: host, identifier: "selection.trackLock.selection-track") != nil
                          && editor.sourcePreviewState(for: "selection-source")
                              == SourcePreviewState(playheadFrame: 42, inFrame: 18, outFrame: 72)
                  }),
                  click(identifier: "selection.trackLock.selection-track", in: window) == nil,
                  await waitUntil(timeout: .seconds(5), {
                      editor.timeline.tracks.first(where: { $0.id == "selection-track" })?.editLocked == true
                  }) else {
                fail("active source deletion or Undo did not restore the exact context", scale: scale)
            }
            let mediaSelectionName = "scale-\(scaleLabel(scale))-selection-media"
            guard snapshot(host, at: evidenceURL.appendingPathComponent("\(mediaSelectionName).png")) else {
                fail("could not capture media selection evidence", scale: scale)
            }
            emit(
                "selection-source",
                scale: scale,
                fields: [
                    "screenshot": "\(mediaSelectionName).png",
                    "activeAsset": "selection-source",
                    "sourceFrame": editor.sourcePlayheadFrame,
                    "sourceIn": editor.activeSourcePreviewState?.inFrame ?? -1,
                    "sourceOut": editor.activeSourcePreviewState?.outFrame ?? -1,
                    "timelineFrame": editor.currentFrame,
                    "rememberedClip": editor.selectedClipIds.contains("selection-clip"),
                    "rangeEnabled": editor.canEditActiveSourceRange,
                    "placementEnabled": editor.canPlaceActiveSource,
                    "insertEnabled": editor.canInsertActiveSource,
                    "overwriteEnabled": editor.canOverwriteActiveSource,
                    "insertUndoVerified": true,
                    "overwriteUndoVerified": true,
                    "nativeSourceCommands": true,
                    "nativeSourceScrub": true,
                    "nativeSourceStepAndArrow": true,
                    "nativeMultiselectDeselect": true,
                    "sameSourceReactivationPreservedPlayback": true,
                    "nativeSearchPreservedPlayback": true,
                    "sortAndFilterPreservedPlayback": true,
                    "nativeGridListToggle": true,
                    "listModePreserved": true,
                    "contextClickRoutingVerified": true,
                    "offlineSourceHandled": true,
                    "nativeActiveDeleteUndo": true,
                ]
            )

            editor.timeline = selectionTimeline
            editor.currentFrame = selectionCurrentFrame
            editor.selectedClipIds = selectionClipIDs
            editor.selectedMediaAssetIds = selectionAssetIDs
            editor.selectedFolderIds = selectionFolderIDs
            editor.inspectedObject = selectionInspectedObject
            editor.previewTabs = selectionPreviewTabs
            editor.activePreviewTabId = selectionPreviewTabID
            editor.previewTabHistory = selectionPreviewHistory
            editor.previewTabHistoryIndex = selectionPreviewHistoryIndex
            editor.sourcePreviewStates = selectionSourceStates
            editor.explicitTimelineInspectionClipID = selectionExplicitTimelineClipID
            editor.sourcePlayheadFrame = selectionSourceFrame
            editor.videoEngine?.activateTab(editor.activePreviewTab)
            acceptanceUndoManager.removeAllActions()

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
        let mediaDirectory = projectURL.appendingPathComponent(
            Project.mediaDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let generatedVideo = try await ImageVideoGenerator.blackVideo(
            size: CGSize(width: 640, height: 360)
        )
        let sourceURL = mediaDirectory.appendingPathComponent("selection-source.mov")
        try FileManager.default.copyItem(at: generatedVideo, to: sourceURL)
        let audioURL = mediaDirectory.appendingPathComponent("bulk-audio.wav")
        guard let audioFormat = AVAudioFormat(
            standardFormatWithSampleRate: 8_000,
            channels: 1
        ) else { throw CocoaError(.fileWriteUnknown) }
        let audioFile = try AVAudioFile(forWriting: audioURL, settings: audioFormat.settings)
        guard let audioBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: 8_000
        ), let audioChannel = audioBuffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        audioBuffer.frameLength = 8_000
        audioChannel.initialize(repeating: 0, count: 8_000)
        try audioFile.write(from: audioBuffer)

        let imageURL = mediaDirectory.appendingPathComponent("bulk-image.png")
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: imageURL, options: .atomic)

        let documentURL = mediaDirectory.appendingPathComponent("bulk-document.md")
        try Data("Acceptance document content".utf8).write(to: documentURL, options: .atomic)
        let lottieURL = mediaDirectory.appendingPathComponent("bulk-lottie.json")
        try Data(
            #"{"v":"5.7.4","fr":30,"ip":0,"op":30,"w":64,"h":64,"layers":[]}"#.utf8
        ).write(to: lottieURL, options: .atomic)

        var clip = Clip(
            mediaRef: "selection-source",
            mediaType: .video,
            sourceClipType: .video,
            startFrame: 0,
            durationFrames: 120
        )
        clip.id = "selection-clip"
        var linkedVideo = Clip(
            mediaRef: "selection-source",
            mediaType: .video,
            sourceClipType: .video,
            startFrame: 150,
            durationFrames: 30
        )
        linkedVideo.id = "selection-linked-video"
        linkedVideo.linkGroupId = "selection-linked-pair"
        var linkedAudio = Clip(
            mediaRef: "selection-source",
            mediaType: .audio,
            sourceClipType: .video,
            startFrame: 150,
            durationFrames: 30
        )
        linkedAudio.id = "selection-linked-audio"
        linkedAudio.linkGroupId = "selection-linked-pair"
        var title = Clip(
            mediaRef: "",
            mediaType: .text,
            sourceClipType: .text,
            startFrame: 0,
            durationFrames: 30
        )
        title.id = "selection-title"
        title.textContent = "Picture Lock"
        var timeline = Timeline()
        timeline.fps = 30
        timeline.width = 640
        timeline.height = 360
        timeline.settingsConfigured = true
        var track = Track(type: .video, clips: [clip, linkedVideo])
        track.id = "selection-track"
        var titleTrack = Track(type: .video, clips: [title])
        titleTrack.id = "selection-title-track"
        var linkedAudioTrack = Track(type: .audio, clips: [linkedAudio])
        linkedAudioTrack.id = "selection-linked-audio-track"
        timeline.tracks = [track, titleTrack, linkedAudioTrack]
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

            timeline.tracks.append(contentsOf: [
                Track(type: .text, clips: [textClip]),
                Track(type: .image, clips: [firstImage, secondImage]),
                Track(type: .audio, clips: [audioClip]),
            ])
        }
        try JSONEncoder().encode(timeline).write(
            to: projectURL.appendingPathComponent(Project.timelineFilename),
            options: .atomic
        )
        var manifest = MediaManifest()
        manifest.folders = (0..<12).map { index in
            MediaFolder(
                id: "acceptance-folder-\(index)",
                name: "Folder \(index)",
                parentFolderId: index < 4 ? nil : "acceptance-folder-\((index - 4) % 4)"
            )
        }
        manifest.entries = [
            MediaManifestEntry(
                id: "selection-source",
                name: "Selection Source",
                type: .video,
                source: .project(relativePath: "\(Project.mediaDirectoryName)/selection-source.mov"),
                duration: 4,
                sourceWidth: 640,
                sourceHeight: 360,
                sourceFPS: 30,
                hasAudio: false,
                originalFilename: "Selection Source.mov"
            ),
            MediaManifestEntry(
                id: "selection-secondary",
                name: "Secondary Source",
                type: .video,
                source: .project(relativePath: "\(Project.mediaDirectoryName)/selection-source.mov"),
                duration: 4,
                sourceWidth: 640,
                sourceHeight: 360,
                sourceFPS: 30,
                hasAudio: false,
                originalFilename: "Secondary Source.mov"
            ),
            MediaManifestEntry(
                id: "selection-offline",
                name: "Offline Source",
                type: .video,
                source: .project(relativePath: "\(Project.mediaDirectoryName)/offline-source.mov"),
                duration: 4,
                sourceWidth: 640,
                sourceHeight: 360,
                sourceFPS: 30,
                hasAudio: false,
                originalFilename: "Offline Source.mov"
            ),
        ]
        let bulkFolderCount = manifest.folders.count
        let bulkTypes: [ClipType] = [.video, .audio, .image, .lottie, .document]
        manifest.entries.append(contentsOf: (0..<520).map { index in
            let type = bulkTypes[index % bulkTypes.count]
            let relativePath = switch type {
            case .video: "selection-source.mov"
            case .audio: "bulk-audio.wav"
            case .image: "bulk-image.png"
            case .document: "bulk-document.md"
            case .lottie: "bulk-lottie.json"
            case .text: "bulk-document.md"
            }
            let fileExtension = URL(fileURLWithPath: relativePath).pathExtension
            return MediaManifestEntry(
                id: "acceptance-bulk-\(index)",
                name: "Storage \(index)",
                type: type,
                source: .project(
                    relativePath: "\(Project.mediaDirectoryName)/\(relativePath)"
                ),
                duration: type == .video || type == .audio ? Double((index % 30) + 1) : 0,
                folderId: "acceptance-folder-\(index % bulkFolderCount)",
                originalFilename: "Original \(index).\(fileExtension)"
            )
        })
        try JSONEncoder().encode(manifest).write(
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
        case .media:
            return matches("mediaPanel", AppTheme.Layout.mediaFolderTreeDefault)
                && matches("inspectorPanel", AppTheme.Layout.inspectorDefault)
        case .edit:
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

    private static func mediaWorkspaceSurfaceIsValid(in root: NSView) -> Bool {
        let diagnostics = mediaWorkspaceSurfaceDiagnostics(in: root)
        guard diagnostics["folderTree"] != nil,
              diagnostics["browser"] != nil,
              diagnostics["sourcePreview"] != nil,
              let mediaPanel = visiblePanelFrames(in: root)["mediaPanel"],
              let centerPanel = visiblePanelFrames(in: root)["previewPanel"],
              let folder = probeFrame("media.workspace.folderTree", in: root),
              let browser = probeFrame("media.workspace.browser", in: root),
              let source = probeFrame("media.workspace.sourcePreview", in: root)
        else { return false }
        let tolerance = AppTheme.BorderWidth.thin
        return mediaPanel.insetBy(dx: -tolerance, dy: -tolerance).contains(folder)
            && centerPanel.insetBy(dx: -tolerance, dy: -tolerance).contains(browser)
            && centerPanel.insetBy(dx: -tolerance, dy: -tolerance).contains(source)
            && browser.height >= AppTheme.Layout.mediaBrowserMinHeight - tolerance
            && source.height >= AppTheme.Layout.previewMinHeight - tolerance
            && (browser.maxY <= source.minY + tolerance || source.maxY <= browser.minY + tolerance)
    }

    private static func mediaWorkspaceSurfaceDiagnostics(in root: NSView) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, identifier) in [
            ("folderTree", "media.workspace.folderTree"),
            ("browser", "media.workspace.browser"),
            ("sourcePreview", "media.workspace.sourcePreview"),
        ] {
            if let frame = probeFrame(identifier, in: root) {
                result[key] = frameDescription(frame)
            }
        }
        return result
    }

    private static func probeFrame(_ identifier: String, in root: NSView) -> NSRect? {
        guard let probe = findProbe(in: root, identifier: identifier),
              probe.window != nil,
              !probe.isHiddenOrHasHiddenAncestor else { return nil }
        let frame = probe.convert(probe.bounds, to: root)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame
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

    private static func click(
        identifier: String,
        modifiers: NSEvent.ModifierFlags = [],
        horizontalFraction: CGFloat = 0.5,
        in window: NSWindow
    ) -> String? {
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
        let fraction = max(0, min(1, horizontalFraction))
        let localPoint = NSPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
        guard clickPointIsVisible(localPoint, in: probe) else {
            return "control is outside its clip viewport"
        }
        let location = probe.convert(localPoint, to: nil)
        guard root.bounds.contains(root.convert(location, from: nil)) else {
            return "control is outside the window"
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: modifiers,
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

    private static func clickTargetIsVisible(
        identifier: String,
        horizontalFraction: CGFloat = 0.5,
        in window: NSWindow
    ) -> Bool {
        guard let root = window.contentView,
              let probe = findProbe(in: root, identifier: identifier),
              probe.window === window,
              !probe.isHiddenOrHasHiddenAncestor else { return false }
        let frame = probe.bounds
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            return false
        }
        let fraction = max(0, min(1, horizontalFraction))
        let point = NSPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
        return clickPointIsVisible(point, in: probe)
            && root.bounds.contains(root.convert(probe.convert(point, to: nil), from: nil))
    }

    private static func clickPointIsVisible(_ point: NSPoint, in probe: NSView) -> Bool {
        var ancestor = probe.superview
        while let view = ancestor {
            if let clipView = view as? NSClipView,
               !clipView.visibleRect.contains(probe.convert(point, to: clipView)) {
                return false
            }
            ancestor = view.superview
        }
        return true
    }

    private static func scroll(identifier: String, in window: NSWindow) -> String? {
        guard let scrollView = scrollView(identifier: identifier, in: window),
              let event = CGEvent(
                  scrollWheelEvent2Source: nil,
                  units: .pixel,
                  wheelCount: 1,
                  wheel1: -300,
                  wheel2: 0,
                  wheel3: 0
              ), let wheel = NSEvent(cgEvent: event) else {
            return "native scroll event unavailable"
        }
        scrollView.scrollWheel(with: wheel)
        return nil
    }

    private static func scrollOrigin(identifier: String, in window: NSWindow) -> NSPoint? {
        scrollView(identifier: identifier, in: window)?.contentView.bounds.origin
    }

    private static func scrollView(identifier: String, in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView,
              let probe = findProbe(in: root, identifier: identifier) else { return nil }
        if let enclosing = enclosingScrollView(for: probe) { return enclosing }
        let probeCenter = probe.convert(
            NSPoint(x: probe.bounds.midX, y: probe.bounds.midY),
            to: root
        )
        var candidates: [(view: NSScrollView, area: CGFloat)] = []
        func collect(_ view: NSView) {
            if let scrollView = view as? NSScrollView,
               !scrollView.isHiddenOrHasHiddenAncestor {
                let frame = scrollView.convert(scrollView.bounds, to: root)
                if frame.contains(probeCenter) {
                    candidates.append((scrollView, frame.width * frame.height))
                }
            }
            view.subviews.forEach(collect)
        }
        collect(root)
        return candidates.min(by: { $0.area < $1.area })?.view
    }

    private static func contextClick(identifier: String, in window: NSWindow) -> String? {
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
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .rightMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else {
            return "AppKit could not create context-menu events"
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return nil
    }

    private static func pressKey(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) -> String? {
        guard window.isVisible, window.isKeyWindow else { return "window is not ready for keyboard input" }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ), let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return "AppKit could not create keyboard events"
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return nil
    }

    private static func scheduleKeySequence(
        _ keys: [(UInt16, String)],
        in window: NSWindow
    ) {
        for (index, key) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(index) * 0.1) {
                _ = pressKey(keyCode: key.0, characters: key.1, in: window)
            }
        }
    }

    private static func typeKeys(
        _ keys: [(UInt16, String)],
        in window: NSWindow
    ) -> String? {
        for key in keys {
            if let error = pressKey(keyCode: key.0, characters: key.1, in: window) {
                return error
            }
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

    private static func validatedMainMenuItemEnabled(title: String) -> Bool? {
        guard let menu = NSApp.mainMenu else { return nil }
        func find(in menu: NSMenu) -> NSMenuItem? {
            menu.update()
            for item in menu.items {
                if item.title == title { return item }
                if let submenu = item.submenu, let match = find(in: submenu) { return match }
            }
            return nil
        }
        return find(in: menu)?.isEnabled
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
