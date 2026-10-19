import AppKit
import NexGenEngine
import SwiftUI

@MainActor
enum GenerationBatchReviewSelfTest {
    private static let environmentKey = "NGV_SELFTEST_GENERATION_BATCH_REVIEW"

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    static func runIfRequested() {
        guard isRequested else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                let followUps = FollowUpEvidence()
                let editor = EditorViewModel(
                    agentService: AgentService(
                        backend: .claudeCode,
                        refreshBackendStatusOnInit: false,
                        embeddedHostFollowUpSender: { text, _ in
                            followUps.messages.append(text)
                            return true
                        },
                        runtimeReadinessOverride: { nil },
                        apiKeyLoader: { nil }
                    )
                )
                let priced = try await package(editor: editor, priced: true)
                let unpriced = try await package(editor: editor, priced: false)
                let purposes = [
                    "Character Mara — front identity sheet",
                    "Character Mara — profile identity sheet",
                    "Character Drummer — front identity sheet",
                    "Character Guitarist — front identity sheet",
                    "Location Rooftop — dusk establishing view",
                    "Location Rooftop — reverse skyline view",
                    "Location Stairwell — sodium-vapor landing",
                    "Prop Chrome microphone — hero angle",
                    "Prop Cassette recorder — continuity sheet",
                    "Character Band — wide ensemble anchor",
                    "Location Backstage corridor — long-lens anchor",
                    "Prop Silver lighter — insert sheet",
                    "Look Lighting anchor — dusk palette",
                ]
                let manifest = try batch(package: unpriced, purposes: purposes)
                try present(manifest, editor: editor)
                let runtimeEvidence = GenerationBatchReviewRuntimeEvidence()

                let host = NSHostingView(
                    rootView: VStack(spacing: AppTheme.Spacing.none) {
                        Spacer(minLength: AppTheme.Spacing.none)
                        GenerationBatchCard(
                            editor: editor,
                            runtimeEvidenceEnabled: true,
                            runtimeEvidence: runtimeEvidence
                        )
                        .layoutPriority(1)
                    }
                    .environment(editor)
                    .environment(\.interfaceScale, AppTheme.Typography.largestScale)
                )
                // A default host grows the window to the card's zero-width minimum, far below the screen.
                host.sizingOptions = []
                let window = NSWindow(
                    contentRect: NSRect(
                        x: AppTheme.Spacing.none,
                        y: AppTheme.Spacing.none,
                        width: AppTheme.Layout.agentPanelMin,
                        height: minimumPanelHeight
                    ),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = host
                place(window, contentSize: NSSize(
                    width: AppTheme.Layout.agentPanelMin,
                    height: minimumPanelHeight
                ))
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)

                do {
                    try await verify(
                        window: window,
                        editor: editor,
                        original: manifest,
                        pricedPackage: priced,
                        runtimeEvidence: runtimeEvidence,
                        followUps: followUps
                    )
                } catch {
                    captureFailureEvidence(in: window)
                    throw error
                }
                FileHandle.standardOutput.write(Data("SELFTEST_GENERATION_BATCH_REVIEW_OK\n".utf8))
                window.orderOut(nil)
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data("SELFTEST_GENERATION_BATCH_REVIEW_FAIL \(error.localizedDescription)\n".utf8)
                )
                exit(1)
            }
        }
        app.run()
        exit(1)
    }

    // Agent panel heights in the smallest project window and in the default window on the fallback screen.
    private static var minimumPanelHeight: CGFloat {
        AppTheme.Window.projectMin.height - AppTheme.Layout.titleBarChromeHeight - AppTheme.Layout.toolbarHeight
    }

    // Top-left in the visible screen area keeps the whole review on screen, as the editor does.
    private static func place(_ window: NSWindow, contentSize: NSSize) {
        window.setContentSize(contentSize)
        guard let visible = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX, y: visible.maxY))
    }

    private static var defaultPanelHeight: CGFloat {
        AppTheme.Window.fallbackVisibleFrame.height * AppTheme.Window.projectHeightFraction
            - AppTheme.Layout.titleBarChromeHeight - AppTheme.Layout.toolbarHeight
    }

    private static func verify(
        window: NSWindow,
        editor: EditorViewModel,
        original: GenerationBatch,
        pricedPackage: GenerationPackageV1,
        runtimeEvidence: GenerationBatchReviewRuntimeEvidence,
        followUps: FollowUpEvidence
    ) async throws {
        guard await waitUntil(timeout: .seconds(10), {
            NSApp.isActive && window.isVisible && window.isKeyWindow
        }) else {
            throw Failure(message: "the review window never became the active key window")
        }
        writeEvidence("keyboard-access fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled)")
        let firstID = original.payload.items[0].id
        try await reveal(
            identifier: "generation-batch.details.\(firstID)",
            in: window,
            context: "13-item narrow large-text review"
        )
        try await requireVisible([
            "generation-batch.remove.\(firstID)",
            "generation-batch.details.\(firstID)",
            "generation-batch.decline",
            "generation-batch.revise",
            "generation-batch.approve",
        ], in: window, context: "13-item narrow large-text review")
        try writeListViewportEvidence(identifier: "generation-batch.details.\(firstID)", in: window,
                                      context: "13-item narrow large-text review")
        try captureWindow(window, name: "generation-batch-narrow-large.png")
        try await verifyLastRequest(original, in: window, context: "13-item narrow large-text review")
        try await reveal(identifier: "generation-batch.details.\(firstID)", in: window,
                         context: "13-item review returned to its first request")
        try await verifyDetailsToggle(
            identifier: "generation-batch.details.\(firstID)",
            itemID: firstID,
            expectExpanded: true,
            in: window,
            runtimeEvidence: runtimeEvidence
        )
        try await requireVisible([
            "generation-batch.decline",
            "generation-batch.approve",
        ], in: window, context: "expanded review")
        try await verifyDetailsToggle(
            identifier: "generation-batch.details.\(firstID)",
            itemID: firstID,
            expectExpanded: false,
            in: window,
            runtimeEvidence: runtimeEvidence
        )
        if let failure = postMouseClick(
            identifier: "generation-batch.remove.\(firstID)",
            in: window
        ) {
            throw Failure(message: failure)
        }
        guard await waitUntil(timeout: .seconds(5), {
            editor.generationBatchCoordinator.pending?.payload.items.count == 12
        }), let afterClick = editor.generationBatchCoordinator.pending else {
            throw Failure(message: "the pointer click did not remove its concrete item")
        }
        guard afterClick.id != original.id,
              afterClick.payload.items.first?.id != firstID,
              afterClick.totalEUR == nil,
              afterClick.payload.items.allSatisfy({ $0.package.payload.estimate == nil }) else {
            throw Failure(message: "pointer removal did not atomically update identity, list and price")
        }

        let keyboardID = afterClick.payload.items[0].id
        place(window, contentSize: NSSize(
            width: AppTheme.Layout.agentPanelMin,
            height: defaultPanelHeight
        ))
        try await reveal(
            identifier: "generation-batch.item.\(keyboardID)",
            in: window,
            context: "12-item narrow large-text review in the default window"
        )
        try await requireVisible([
            "generation-batch.item.\(keyboardID)",
            "generation-batch.decline",
            "generation-batch.revise",
            "generation-batch.approve",
        ], in: window, context: "12-item narrow large-text review in the default window")
        try writeListViewportEvidence(identifier: "generation-batch.item.\(keyboardID)", in: window,
                                      context: "12-item narrow large-text review in the default window")

        place(window, contentSize: NSSize(
            width: AppTheme.Layout.agentPanelMax,
            height: minimumPanelHeight
        ))
        try await reveal(
            identifier: "generation-batch.remove.\(keyboardID)",
            in: window,
            context: "12-item wide review"
        )
        try await requireVisible([
            "generation-batch.remove.\(keyboardID)",
            "generation-batch.decline",
            "generation-batch.revise",
            "generation-batch.retry-pricing",
            "generation-batch.approve",
        ], in: window, context: "12-item wide review")
        guard NSApp.isFullKeyboardAccessEnabled else {
            throw Failure(message: "keyboard navigation is disabled on this runner, so Remove cannot take focus")
        }
        try await verifyVisibleKeyboardFocus(itemID: keyboardID, in: window, runtimeEvidence: runtimeEvidence)
        let tabs = try await focusRemove(itemID: keyboardID, in: window, runtimeEvidence: runtimeEvidence)
        let focusEvidence = "keyboard-focus item=\(keyboardID) tabs=\(tabs.map { String($0) } ?? "exhausted") "
            + keyboardFocusDescription(window: window, runtimeEvidence: runtimeEvidence)
        writeEvidence(focusEvidence)
        guard tabs != nil else {
            throw Failure(message: "Remove never took keyboard focus; \(focusEvidence)")
        }
        try postKey(code: 49, characters: " ", in: window)
        guard await waitUntil(timeout: .seconds(5), {
            editor.generationBatchCoordinator.pending?.payload.items.count == 11
        }), let afterKeyboard = editor.generationBatchCoordinator.pending else {
            throw Failure(
                message: "the keyboard event did not activate the visible Remove action; \(focusEvidence); after Space: "
                    + keyboardFocusDescription(window: window, runtimeEvidence: runtimeEvidence)
            )
        }
        guard afterKeyboard.id != afterClick.id,
              afterKeyboard.payload.items.first?.id != keyboardID,
              window.isKeyWindow,
              !window.ignoresMouseEvents else {
            throw Failure(message: "keyboard removal did not preserve interactive window and manifest state")
        }

        editor.generationBatchCoordinator.decline(editor: editor)
        let single = try batch(
            package: pricedPackage,
            purposes: [
                "Character Mara — full-body front identity sheet with the approved coat silhouette and continuity details",
            ]
        )
        try present(single, editor: editor)
        place(window, contentSize: NSSize(
            width: AppTheme.Layout.agentPanelMin,
            height: minimumPanelHeight
        ))
        try await reveal(
            identifier: "generation-batch.remove.\(single.payload.items[0].id)",
            in: window,
            context: "single-item narrow large-text review"
        )
        try await requireVisible([
            "generation-batch.remove.\(single.payload.items[0].id)",
            "generation-batch.details.\(single.payload.items[0].id)",
            "generation-batch.decline",
            "generation-batch.revise",
            "generation-batch.approve",
        ], in: window, context: "single-item narrow large-text review")
        try captureWindow(window, name: "generation-batch-single-narrow-large.png")

        editor.generationBatchCoordinator.decline(editor: editor)
        let fifty = try batch(
            package: pricedPackage,
            purposes: (1...50).map { index in
                let group = index.isMultiple(of: 3) ? "Location" : index.isMultiple(of: 2) ? "Prop" : "Character"
                return "\(group) item \(index) — continuity view with a deliberately long readable purpose"
            }
        )
        try present(fifty, editor: editor)
        guard let lastItem = GenerationBatchReviewProjection(batch: fifty).sections.last?.items.last else {
            throw Failure(message: "50-item review has no final request")
        }
        for width in [CGFloat(400), AppTheme.Layout.agentPanelMax] {
            writeBatchLayoutEvidence(in: window, context: "before resize to \(Int(width))")
            place(window, contentSize: NSSize(
                width: width,
                height: minimumPanelHeight
            ))
            window.contentView?.layoutSubtreeIfNeeded()
            writeBatchLayoutEvidence(in: window, context: "after resize to \(Int(width))")
            try await reveal(
                identifier: "generation-batch.remove.\(fifty.payload.items[0].id)",
                in: window,
                context: "50-item \(Int(width))-point large-text review"
            )
            try await requireVisible([
                "generation-batch.remove.\(fifty.payload.items[0].id)",
                "generation-batch.decline",
                "generation-batch.approve",
            ], in: window, context: "50-item \(Int(width))-point large-text review")
            try await verifyLastRequest(fifty, in: window, context: "50-item \(Int(width))-point large-text review")
            if width == AppTheme.Layout.agentPanelMax {
                for expanded in [true, false] {
                    let identifier = "generation-batch.details.\(lastItem.id)"
                    try await reveal(identifier: identifier, in: window, context: "last request Details at \(Int(width)) points")
                    try await verifyDetailsToggle(identifier: identifier, itemID: lastItem.id,
                        expectExpanded: expanded, in: window, runtimeEvidence: runtimeEvidence)
                }
            }
            try await requireVisible(["generation-batch.approve"], in: window,
                context: "50-item approval after Details at \(Int(width)) points")
            try captureWindow(window, name: "generation-batch-50-\(Int(width))-last-request.png")
        }
        editor.generationBatchCoordinator.decline(editor: editor)
        try await verifySingleApproval(package: pricedPackage, editor: editor, window: window)
        try await verifyMissingReference(package: pricedPackage, editor: editor, window: window, followUps: followUps)
        try await verifyProductionDock(editor: editor, window: window)
    }

    private static func verifyProductionDock(editor: EditorViewModel, window: NSWindow) async throws {
        @MainActor final class MenuReceipt {
            var menu: NSMenu?
            var titles: [String] = []
            var revisionEnabled: Bool?
            var phaseEnabled: Bool?
            var closed = false
            var keyFailure: String?
        }

        let defaults = UserDefaults.standard
        let previousScale = defaults.object(forKey: AppTheme.Typography.scaleKey)
        let savedAssets = editor.mediaAssets
        defer {
            editor.mediaAssets = savedAssets
            editor.generationBatchCoordinator.decline(editor: editor)
            if let previousScale { defaults.set(previousScale, forKey: AppTheme.Typography.scaleKey) }
            else { defaults.removeObject(forKey: AppTheme.Typography.scaleKey) }
        }
        defaults.set(AppTheme.Typography.largestScale, forKey: AppTheme.Typography.scaleKey)
        let unpriced = try await package(editor: editor, priced: false)
        let pending = try GenerationBatch(payload: .init(nonce: UUID(),
            projectKey: unpriced.payload.binding.projectKey, phase: "bible", items: (1...13).map { index in
                .init(id: UUID().uuidString, purpose: "Character Mara — continuity view \(index)", package: unpriced)
            }))
        try present(pending, editor: editor)
        editor.setWorkspaceFocus(.production)
        editor.mediaPanelVisible = true
        editor.inspectorPanelVisible = true
        editor.maximizedPanel = nil
        editor.showsAgentActivity = false
        let host = NSHostingView(rootView: EditorWindowContentView().environment(editor))
        host.sizingOptions = []
        window.contentView = host
        place(window, contentSize: AppTheme.Window.projectMin)
        guard await waitUntil(timeout: .seconds(10), {
            host.layoutSubtreeIfNeeded()
            return editor.generationBatchCoordinator.canApprovePending
                && findClickProbes(in: host, identifier: "production.artifact").first != nil
                && findClickProbes(in: host, identifier: "production.dock").first != nil
        }) else { throw Failure(message: "minimal production window did not mount its pending decision") }

        for missing in [false, true] {
            if missing {
                editor.mediaAssets.removeAll { $0.id == unpriced.payload.references.first?.assetID }
                guard await waitUntil(timeout: .seconds(10), {
                    editor.generationBatchCoordinator.preflightIssue != nil
                        && !editor.generationBatchCoordinator.canApprovePending
                }) else { throw Failure(message: "production dock did not show its missing-reference failure") }
            }
            try await requireVisible(["generation-batch.review.open", "generation-batch.actions",
                                      "generation-batch.cost", "generation-batch.decline", "generation-batch.approve"],
                in: window, context: "production dock footer at 150 percent")
            guard let artifact = findClickProbes(in: host, identifier: "production.artifact").first,
                  let dock = findClickProbes(in: host, identifier: "production.dock").first,
                  let status = findClickProbes(in: host, identifier: "production.status").first else {
                throw Failure(message: "production layout geometry evidence is incomplete")
            }
            let artifactFrame = artifact.convert(artifact.bounds, to: host)
            let dockFrame = dock.convert(dock.bounds, to: host)
            let statusFrame = status.convert(status.bounds, to: host)
            guard host.bounds.size == AppTheme.Window.projectMin, artifactFrame.height >= 240,
                  dockFrame.height > 0, host.bounds.contains(artifactFrame), host.bounds.contains(dockFrame),
                  host.bounds.contains(statusFrame), !artifactFrame.intersects(dockFrame), !dockFrame.intersects(statusFrame),
                  controlState("generation-batch.approve", in: window) == !missing else {
                throw Failure(message: "production dock obscured its artifact, status or approval state at minimum window size")
            }
            try captureWindow(window, name: "generation-production-dock-\(missing ? "missing-reference" : "unpriced")-150.png")
            let pendingBefore = editor.generationBatchCoordinator.pending?.id
            let activeBefore = editor.generationBatchCoordinator.activeBatchID
            let authorizationBefore = editor.generationBatchCoordinator.autoApprovingPhase
            let menuReceipt = MenuReceipt()
            let began = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    guard let menu = notification.object as? NSMenu else { return }
                    menuReceipt.menu = menu
                    menuReceipt.titles = menu.items.map(\.title)
                    menuReceipt.revisionEnabled = menu.items.first { $0.title == "Ask agent to revise" }?.isEnabled
                    menuReceipt.phaseEnabled = menu.items.first { $0.title == "Allow all paid AI runs in Bible" }?.isEnabled
                    do { try postKey(code: 53, characters: "\u{1b}", in: window) }
                    catch { menuReceipt.keyFailure = error.localizedDescription }
                }
            }
            let ended = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    if let menu = notification.object as? NSMenu, menu === menuReceipt.menu { menuReceipt.closed = true }
                }
            }
            defer {
                NotificationCenter.default.removeObserver(began)
                NotificationCenter.default.removeObserver(ended)
            }
            if let failure = postMouseClick(identifier: "generation-batch.actions", in: window) {
                throw Failure(message: failure)
            }
            guard await waitUntil(timeout: .seconds(5), { menuReceipt.closed || menuReceipt.keyFailure != nil }),
                  menuReceipt.keyFailure == nil, menuReceipt.revisionEnabled == true,
                  menuReceipt.phaseEnabled == !missing,
                  menuReceipt.titles.contains(where: { $0.contains("phase approval") && $0.contains("rewind")
                      && $0.contains("withdrawal") && $0.contains("app quit") }) else {
                throw Failure(message: "production generation actions did not expose their native states and phase scope: \(menuReceipt.titles), keyFailure=\(menuReceipt.keyFailure ?? "none")")
            }
            if let failure = postMouseClick(identifier: "generation-batch.review.open", in: window) {
                throw Failure(message: failure)
            }
            guard await waitUntil(timeout: .seconds(5), {
                window.attachedSheet.map { hasProbe(identifier: "generation-batch.review", in: $0) } == true
            }), let sheet = window.attachedSheet, sheet.sheetParent === window,
                  let screen = sheet.screen ?? window.screen, screen.visibleFrame.contains(sheet.frame) else {
                throw Failure(message: "the input review did not open as a wholly on-screen sheet of the production document")
            }
            try await requireVisible(["generation-batch.review.close", "generation-batch.revise",
                                      "generation-batch.approve-phase", "generation-batch.decline", "generation-batch.approve"],
                in: sheet, context: "expanded production input review at 150 percent")
            guard controlState("generation-batch.approve", in: sheet) == !missing,
                  controlState("generation-batch.approve-phase", in: sheet) == !missing,
                  findClickProbes(in: host, identifier: "generation-batch.list").isEmpty else {
                throw Failure(message: "expanded input review duplicated its list or changed the approval state")
            }
            let detailsID = "generation-batch.details.\(pending.payload.items[0].id)"
            try await reveal(identifier: detailsID, in: sheet, context: "expanded production request")
            if let failure = postMouseClick(identifier: detailsID, in: sheet) { throw Failure(message: failure) }
            guard await waitUntil(timeout: .seconds(5), {
                hasProbe(identifier: "generation-batch.expanded.\(pending.payload.items[0].id)", in: sheet)
            }), let referenceID = unpriced.payload.references.first?.assetID else {
                throw Failure(message: "expanded production review did not reveal its concrete request")
            }
            let previewID = "generation-input.preview.\(referenceID)"
            try await reveal(identifier: previewID, in: sheet, context: "production input image review")
            guard controlState(previewID, in: sheet) == !missing else {
                throw Failure(message: "production input review did not distinguish the real image from the missing reference")
            }
            try captureWindow(sheet, name: "generation-production-inputs-\(missing ? "missing-reference" : "unpriced")-150.png")
            if missing {
                if let failure = postMouseClick(identifier: "generation-batch.review.close", in: sheet) {
                    throw Failure(message: failure)
                }
            } else {
                try postKey(code: 53, characters: "\u{1b}", in: sheet)
            }
            guard await waitUntil(timeout: .seconds(5), { window.attachedSheet == nil && window.isKeyWindow }),
                  editor.generationBatchCoordinator.pending?.id == pendingBefore,
                  editor.generationBatchCoordinator.activeBatchID == activeBefore,
                  editor.generationBatchCoordinator.autoApprovingPhase == authorizationBefore else {
                throw Failure(message: "opening and closing the native input review changed the proposal or execution authority")
            }
            try await requireVisible(["generation-batch.review.open", "generation-batch.cost", "generation-batch.decline",
                                      "generation-batch.approve"], in: window, context: "production controls restored after input review")
            let scale = AppTheme.Typography.validatedScale(defaults.double(forKey: AppTheme.Typography.scaleKey))
            let size = host.bounds.size
            guard scale == 1.5, size == NSSize(width: 960, height: 640) else {
                throw Failure(message: "production dock did not retain the required measured scale and viewport")
            }
            writeEvidence("production-dock textScale=\(scale) window=\(Int(size.width))x\(Int(size.height)) missingReference=\(missing) artifactHeight=\(artifactFrame.height) dockHeight=\(dockFrame.height) footerVisible=true nativeMenuScope=true nativeMenuEscape=true expandedInputs=true proposalUnchanged=true")
        }
    }

    private static func verifyMissingReference(package: GenerationPackageV1, editor: EditorViewModel, window: NSWindow,
                                               followUps: FollowUpEvidence) async throws {
        guard let reference = package.payload.references.first,
              reference.displayName == "Mara-front.png" else {
            throw Failure(message: "missing-reference fixture has no readable original filename")
        }
        let asset = try GenerationPackageInputs.resolveReference(reference, package: package, editor: editor)
        guard NSImage(contentsOf: asset.url) != nil else {
            throw Failure(message: "missing-reference fixture did not begin with a real readable PNG")
        }
        try await GenerationPackageInputs.validate(package: package, editor: editor)
        let batch = try GenerationBatch(payload: .init(nonce: UUID(),
            projectKey: package.payload.binding.projectKey, phase: "bible", items: [
                .init(id: UUID().uuidString, purpose: "Character Mara — front identity sheet", package: package),
            ]))
        editor.agentService.newChat()
        guard let sessionID = editor.agentService.currentSessionId else {
            throw Failure(message: "revision fixture has no originating chat")
        }
        _ = try editor.agentService.presentGenerationBatch(batch, recoveries: [
            batch.payload.items[0].id: GenerationBatchRecovery(options: []) { _, _ in package },
        ], origin: .inAppChat(sessionID: sessionID), editor: editor)
        let host = NSHostingView(rootView: VStack(spacing: AppTheme.Spacing.none) {
            Spacer(minLength: AppTheme.Spacing.none)
            GenerationBatchCard(editor: editor, runtimeEvidenceEnabled: true)
        }.environment(editor).environment(\.interfaceScale, AppTheme.Typography.largestScale))
        host.sizingOptions = []
        window.contentView = host
        place(window, contentSize: NSSize(width: AppTheme.Layout.agentPanelMax, height: minimumPanelHeight))
        guard await waitUntil(timeout: .seconds(10), {
            editor.generationBatchCoordinator.canApprovePending
                && controlState("generation-batch.approve", in: window) == true
                && controlState("generation-batch.approve-phase", in: window) == true
        }) else {
            throw Failure(message: "valid PNG fixture never enabled both rendered approval actions")
        }

        let savedAssets = editor.mediaAssets
        let unavailable = asset.url.appendingPathExtension("unavailable")
        try FileManager.default.moveItem(at: asset.url, to: unavailable)
        defer {
            if FileManager.default.fileExists(atPath: unavailable.path) {
                try? FileManager.default.moveItem(at: unavailable, to: asset.url)
            }
            editor.mediaAssets = savedAssets
        }
        editor.mediaAssets.removeAll { $0.id == reference.assetID }
        guard await waitUntil(timeout: .seconds(10), {
            !editor.generationBatchCoordinator.preflighting
                && editor.generationBatchCoordinator.preflightIssue != nil
                && controlState("generation-batch.approve", in: window) == false
                && controlState("generation-batch.approve-phase", in: window) == false
                && controlState("generation-batch.revise", in: window) == true
        }) else {
            throw Failure(message: "missing input did not disable both rendered approvals while keeping revision enabled")
        }
        try await requireVisible([
            "generation-batch.preflight-issue", "generation-batch.approve",
            "generation-batch.approve-phase", "generation-batch.revise",
        ], in: window, context: "missing-reference large-text review")
        guard let root = window.contentView,
              let issue = findClickProbes(in: root, identifier: "generation-batch.preflight-issue")
                .compactMap({ $0 as? AppRelaunchClickProbeView }).first?.acceptanceText,
              issue.contains("Mara-front.png"),
              !FileManager.default.fileExists(atPath: asset.url.path),
              !editor.generationBatchCoordinator.canApprovePending else {
            throw Failure(message: "rendered missing-reference explanation omitted the original filename")
        }
        try captureWindow(window, name: "generation-batch-missing-reference-large.png")
        if let failure = postMouseClick(identifier: "generation-batch.revise", in: window) {
            throw Failure(message: failure)
        }
        guard await waitUntil(timeout: .seconds(5), {
            editor.generationBatchCoordinator.pending == nil && followUps.messages.count == 1
        }), editor.generationBatchCoordinator.activeBatchID == nil,
            editor.generationBatchCoordinator.snapshots.isEmpty,
            followUps.messages[0].contains(issue), followUps.messages[0].contains(reference.assetID),
            !followUps.messages[0].contains("Pricing diagnostics"),
            !followUps.messages[0].contains("Self-test pricing outage") else {
            throw Failure(message: "native revision did not deliver the reference failure to its originating agent without execution")
        }
        try FileManager.default.moveItem(at: unavailable, to: asset.url)
        editor.mediaAssets = savedAssets
        let repairedPackage = try await Self.package(editor: editor, priced: false)
        let repaired = try GenerationBatch(payload: .init(nonce: UUID(),
            projectKey: repairedPackage.payload.binding.projectKey, phase: "bible", items: [
                .init(id: UUID().uuidString, purpose: "Character Mara — repaired identity reference", package: repairedPackage),
            ]))
        guard repaired.id != batch.id else { throw Failure(message: "revision reused the blocked batch identity") }
        try present(repaired, editor: editor)
        let preview = "generation-input.preview.\(reference.assetID)"
        try await reveal(identifier: preview, in: window, context: "repaired reference proposal")
        guard await waitUntil(timeout: .seconds(10), {
            controlState(preview, in: window) == true
                && controlState("generation-batch.approve", in: window) == true
                && controlState("generation-batch.approve-phase", in: window) == true
                && editor.generationBatchCoordinator.preflightIssue == nil
        }) else { throw Failure(message: "the repaired proposal did not restore its rendered image and approval actions") }
        try await requireVisible([preview, "generation-batch.approve", "generation-batch.approve-phase"],
            in: window, context: "repaired reference proposal")
        try captureWindow(window, name: "generation-batch-revised-reference-large.png")
        let startsBatches = editor.generationBatchCoordinator.startsApprovedBatches
        editor.generationBatchCoordinator.startsApprovedBatches = false
        defer { editor.generationBatchCoordinator.startsApprovedBatches = startsBatches }
        if let failure = postMouseClick(identifier: "generation-batch.approve", in: window) {
            throw Failure(message: failure)
        }
        guard await waitUntil(timeout: .seconds(5), { editor.generationBatchCoordinator.pending == nil }),
              let home = editor.workingRoot else { throw Failure(message: "the repaired proposal could not be approved natively") }
        let approved = try GenerationBatchStore.load(id: repaired.id, home: home)
        guard approved.authorityAvailable, approved.batch == repaired,
              approved.journal.executions.allSatisfy({ $0.state == .queued }),
              editor.generationBatchCoordinator.activeBatchID == nil, editor.generationLog.spendEvents.isEmpty else {
            throw Failure(message: "native repaired approval did not persist exact authority without provider work")
        }
        editor.generationBatchCoordinator.cancelRemaining(batchID: repaired.id, editor: editor)
        guard try GenerationBatchStore.load(id: repaired.id, home: home).journal.executions.allSatisfy({ $0.state == .canceled }) else {
            throw Failure(message: "the focused review fixture left an executable approved request behind")
        }
        writeEvidence("missing-reference filename=Mara-front.png revisionDelivered=true repairedBatchApproved=true renderedPreview=true providerDispatch=false suppliedRepair=true")
    }

    private final class FollowUpEvidence {
        var messages: [String] = []
    }

    private static func controlState(_ identifier: String, in window: NSWindow) -> Bool? {
        guard let root = window.contentView else { return nil }
        return findClickProbes(in: root, identifier: identifier)
            .compactMap { $0 as? AppRelaunchClickProbeView }
            .first { isClickProbeReady($0, root: root, window: window) }?.acceptanceState
    }

    private static func verifySingleApproval(package: GenerationPackageV1, editor: EditorViewModel, window: NSWindow) async throws {
        let target = ResolvedGenerationTarget(modelId: package.payload.target.modelId,
            provider: package.payload.target.provider, endpoint: package.payload.target.endpoint, binding: nil)
        let option = SpendOption(modelId: target.modelId, modelName: "Reference image model", target: target,
            credits: nil, requiresCatalogAvailability: false, generationPackage: package)
        let approval = SpendApproval(id: UUID().uuidString, recommendedOptionId: option.id,
            options: [option], actionLabel: "Generate image", requiresGenerationPackage: true)
        let host = NSHostingView(rootView: VStack(spacing: AppTheme.Spacing.none) {
            Spacer(minLength: AppTheme.Spacing.none)
            SpendApprovalCard(approval: approval, onApprove: { _ in }, onDecline: {})
        }.environment(editor).environment(\.interfaceScale, AppTheme.Typography.largestScale))
        host.sizingOptions = []
        window.contentView = host
        for width in [AppTheme.Layout.agentPanelMin, AppTheme.Layout.agentPanelMax] {
            place(window, contentSize: NSSize(width: width, height: minimumPanelHeight))
            try await requireVisible(["generation-approval.decline", "generation-approval.approve"],
                in: window, context: "single approval large-text review")
            try captureWindow(window, name: "generation-single-\(Int(width))-large.png")
        }
    }

    private static func batch(
        package: GenerationPackageV1,
        purposes: [String]
    ) throws -> GenerationBatch {
        let items = purposes.map { purpose in
            GenerationBatch.Item(
                id: UUID().uuidString,
                purpose: purpose,
                package: package
            )
        }
        return try GenerationBatch(payload: .init(
            nonce: UUID(),
            projectKey: package.payload.binding.projectKey,
            phase: nil,
            items: items
        ))
    }

    private static func present(_ batch: GenerationBatch, editor: EditorViewModel) throws {
        let recoveries = Dictionary(uniqueKeysWithValues: batch.payload.items.map { item in
            (item.id, GenerationBatchRecovery(options: []) { _, _ in item.package })
        })
        try editor.generationBatchCoordinator.present(batch, recoveries: recoveries)
    }

    private static func package(editor: EditorViewModel, priced: Bool) async throws -> GenerationPackageV1 {
        if editor.workingRoot == nil {
            let project = FileManager.default.temporaryDirectory.appendingPathComponent("batch-review-\(UUID().uuidString).ngv")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try JSONEncoder().encode(Timeline()).write(to: project.appendingPathComponent(Project.timelineFilename))
            try JSONEncoder().encode(MediaManifest()).write(to: project.appendingPathComponent(Project.manifestFilename))
            try JSONEncoder().encode(GenerationLog()).write(to: project.appendingPathComponent(Project.generationLogFilename))
            _ = try ProjectIdentity.uuid(for: project)
            editor.projectURL = project
        }
        guard let home = editor.workingRoot else { throw Failure(message: "Reference fixture has no project.") }
        let source = home.appendingPathComponent(Project.mediaDirectoryName).appendingPathComponent("Mara-front.png")
        if !FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let data = pixels.bitmapData else {
                throw Failure(message: "Reference image fixture could not be created.")
            }
            for y in 0..<32 {
                for x in 0..<32 {
                    let offset = y * pixels.bytesPerRow + x * 4
                    data[offset] = UInt8(x * 8)
                    data[offset + 1] = UInt8(y * 8)
                    data[offset + 2] = 180
                    data[offset + 3] = 255
                }
            }
            guard let png = pixels.representation(using: .png, properties: [:]) else {
                throw Failure(message: "Reference image fixture could not be encoded.")
            }
            try png.write(to: source)
        }
        let target = ResolvedGenerationTarget(
            modelId: "selftest-image",
            provider: .runway,
            endpoint: "selftest-image",
            binding: nil
        )
        let receipt = GenerationReferenceReceipt(
            assetID: "selftest-reference",
            displayName: "Mara-front.png",
            type: ClipType.image.rawValue,
            sourceSHA256: try FileDigest.sha256(of: source),
            submittedSHA256: try FileDigest.sha256(of: source)
        )
        if !editor.mediaAssets.contains(where: { $0.id == receipt.assetID }) {
            editor.mediaAssets.append(MediaAsset(
                id: receipt.assetID,
                url: source,
                type: .image,
                name: "Mara front",
                thumbnail: NSImage(contentsOf: source),
                originalFilename: receipt.displayName
            ))
        }
        let prompt = "Full-body identity sheet for Mara."
        var input = GenerationInput(
            prompt: prompt,
            intent: prompt,
            model: target.modelId,
            duration: 0,
            aspectRatio: "1:1",
            numImages: 1
        )
        input.referenceReceipts = [receipt]
        let parameters = try PreparedProviderParameters(referenceCount: 1) { slots in
            .image(.init(
                prompt: prompt,
                aspectRatio: "1:1",
                resolution: nil,
                quality: nil,
                imageURLs: slots,
                numImages: 1
            ))
        }
        let binding = try await PromptCompiler.currentBinding(editor: editor, shotId: "none", modality: .image, modelId: target.modelId)
        let money = GenerationMoney(
            nativeAmount: 0.18,
            nativeCurrency: "EUR",
            eurAmount: 0.18,
            eurPerNativeUnit: 1,
            exchangeRateDate: "2026-09-21",
            pricingSource: "selftest://pricing",
            exchangeRateSource: "selftest://exchange"
        )
        let failure = GenerationPricingFailure(
            reason: .priceQueryUnavailable,
            provider: .runway,
            endpoint: target.endpoint,
            detail: "Self-test pricing outage"
        )
        let package = try GenerationPackageV1(payload: .init(
            target: target,
            modality: "image",
            operation: "generate_image",
            intent: prompt,
            prompt: prompt,
            promptRevisionID: "selftest",
            generationInput: input,
            binding: binding,
            compilerInputsSHA256: try await PromptComposer.inputFingerprint(projectDir: home),
            recipe: nil,
            repairPlanID: nil,
            destination: try GenerationPackageV1.Destination(
                .mediaLibrary(folderId: nil),
                editor: editor
            ),
            outputCount: 1,
            references: [receipt],
            referenceRoles: ["image_reference"],
            requestParametersJSON: try GenerationPackageV1.requestJSON(
                parameters: parameters,
                references: [receipt]
            ),
            routing: nil,
            routeReceipt: GenerationRouteReceipt(
                target: target,
                checks: [],
                capabilitySnapshot: nil
            ),
            estimate: priced ? money : nil,
            pricingFailure: priced ? nil : failure
        ))
        let snapshot = try await GenerationReferenceSnapshot.capture(sources: [
            .init(assetID: receipt.assetID, displayName: receipt.displayName, type: receipt.type, url: source),
        ])
        try await GenerationPackageInputs.persist(package: package, snapshot: snapshot, editor: editor)
        return package
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

    private static func verifyDetailsToggle(
        identifier: String,
        itemID: String,
        expectExpanded: Bool,
        in window: NSWindow,
        runtimeEvidence: GenerationBatchReviewRuntimeEvidence
    ) async throws {
        let receiptOffset = runtimeEvidence.detailsActionReceipts.count
        let dispatch: PointerDispatchEvidence
        switch queuePointerClick(identifier: identifier, in: window) {
        case .success(let evidence):
            dispatch = evidence
        case .failure(let failure):
            throw failure
        }
        let rendered = await waitUntil(timeout: .seconds(5)) {
            hasProbe(identifier: "generation-batch.expanded.\(itemID)", in: window) == expectExpanded
        }
        let newReceipts = runtimeEvidence.detailsActionReceipts.dropFirst(receiptOffset)
        let itemReceipts = newReceipts.filter { $0.itemID == itemID }
        guard let receipt = itemReceipts.first else {
            let receivedIDs = newReceipts.map(\.itemID).joined(separator: ",")
            throw Failure(
                message: "Details action not received for item \(itemID); \(dispatch.description); "
                    + "actionReceiptIDs=[\(receivedIDs)]; "
                    + renderBoundaryDescription(itemID: itemID, in: window)
            )
        }
        guard itemReceipts.count == 1 else {
            throw Failure(
                message: "Details action received \(itemReceipts.count) times for item \(itemID); "
                    + "receiptSequences=[\(itemReceipts.map { String($0.sequence) }.joined(separator: ","))]; "
                    + dispatch.description
            )
        }
        let wasExpanded = receipt.expandedItemIDsBefore.contains(itemID)
        let isExpanded = receipt.expandedItemIDsAfter.contains(itemID)
        let actionEvidence = "action-receipt count=1 sequence=\(receipt.sequence) item=\(itemID) "
            + "before=\(setDescription(receipt.expandedItemIDsBefore)) "
            + "after=\(setDescription(receipt.expandedItemIDsAfter))"
        writeEvidence(actionEvidence)
        guard wasExpanded != expectExpanded, isExpanded == expectExpanded else {
            throw Failure(
                message: "Details action receipt did not make the expected item-specific state transition; "
                    + "expectedExpanded=\(expectExpanded); \(actionEvidence); \(dispatch.description)"
            )
        }
        let renderEvidence = renderBoundaryDescription(itemID: itemID, in: window)
        guard rendered else {
            throw Failure(
                message: "Details state changed but its native render boundary did not become "
                    + "\(expectExpanded ? "present" : "absent"); \(actionEvidence); "
                    + "\(renderEvidence); \(dispatch.description)"
            )
        }
        writeEvidence("render-boundary expectedExpanded=\(expectExpanded) \(renderEvidence)")
    }

    private static func verifyLastRequest(_ batch: GenerationBatch, in window: NSWindow, context: String) async throws {
        let projection = GenerationBatchReviewProjection(batch: batch)
        guard let lastItem = projection.sections.last?.items.last else {
            throw Failure(message: "\(context) has no last request")
        }
        let lastID = lastItem.id
        writeEvidence("last-request-target context=\(context) itemCount=\(projection.itemCount) "
            + "itemID=\(lastID) manifestIndex=\(lastItem.manifestIndex) purpose=\(lastItem.purpose)")
        let identifier = "generation-batch.details.\(lastID)"
        try await reveal(identifier: identifier, in: window, context: context, searchTowardEnd: true)
        try await requireVisible([
            identifier,
            "generation-batch.remove.\(lastID)",
            "generation-batch.decline",
            "generation-batch.approve",
        ], in: window, context: "\(context) last request")
        try writeListViewportEvidence(identifier: identifier, in: window, context: "\(context) last request")
    }

    private static func writeListViewportEvidence(identifier: String, in window: NSWindow, context: String) throws {
        guard let root = window.contentView,
              let probe = findClickProbes(in: root, identifier: identifier).first,
              let scrollView = probe.enclosingScrollView else {
            throw Failure(message: "\(context) has no native list viewport for \(identifier)")
        }
        writeEvidence("list-viewport context=\(context) " + scrollGeometry(probe: probe, scrollView: scrollView))
    }

    private static func reveal(
        identifier: String,
        in window: NSWindow,
        context: String,
        searchTowardEnd: Bool = false
    ) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        // CI exhausted 10 s after 35 steps; reserve a bounded full pass through the 12,296 pt list.
        let maximumSearchSeconds = 30.0
        let hardDeadline = started.advanced(by: .seconds(maximumSearchSeconds))
        var deadline = started.advanced(by: .seconds(10))
        var lastProgress = started
        var lastBoundary = "native probe absent"
        var searchSteps = 0
        var progressingSteps = 0
        var progressingStepSeconds = 0.0
        var maximumEstimatedSteps = 0.0
        var searchedPastIntroduction = false
        while clock.now < deadline && clock.now < lastProgress.advanced(by: .seconds(10)) {
            let stepStarted = clock.now
            guard let root = window.contentView else {
                throw Failure(message: "\(context) has no window content view while revealing \(identifier)")
            }
            guard let probe = findClickProbes(in: root, identifier: identifier).first else {
                lastBoundary = "native probe absent"
                if let list = findClickProbes(in: root, identifier: "generation-batch.list").first,
                   let scrollView = list.enclosingScrollView {
                    let lookupSeconds = durationSeconds(stepStarted.duration(to: clock.now))
                    let layoutStarted = clock.now
                    root.layoutSubtreeIfNeeded()
                    var layoutSeconds = durationSeconds(layoutStarted.duration(to: clock.now))
                    let clip = scrollView.contentView
                    let before = clip.bounds
                    let document = clip.documentRect
                    guard before.minY.isFinite, before.height.isFinite, before.height > 0,
                          document.minY.isFinite, document.maxY.isFinite, document.height.isFinite else {
                        throw Failure(message: "\(context) has invalid native list geometry")
                    }
                    let startY = clip.isFlipped ? document.minY : max(document.minY, document.maxY - before.height)
                    let reachedStart = clip.isFlipped ? before.minY <= startY : before.minY >= startY
                    if !searchTowardEnd, !searchedPastIntroduction, reachedStart {
                        searchedPastIntroduction = true
                        writeEvidence("scroll-search-direction identifier=\(identifier) towardEnd=true "
                            + "reason=document-start-reached startY=\(startY) before=\(rectDescription(before)) "
                            + "document=\(rectDescription(document)) clipFlipped=\(clip.isFlipped)")
                    }
                    let stepTowardEnd = searchTowardEnd || searchedPastIntroduction
                    let increasing = stepTowardEnd == clip.isFlipped
                    let distance = Int32(min(CGFloat(Int32.max), max(1, floor(before.height * 0.75))))
                    let delta = increasing == clip.isFlipped ? -distance : distance
                    let gestureStarted = clock.now
                    try await scrollList(scrollView, delta: delta, in: window)
                    let gestureSeconds = durationSeconds(gestureStarted.duration(to: clock.now))
                    let settleStarted = clock.now
                    try await Task.sleep(for: .milliseconds(20))
                    let settleSeconds = durationSeconds(settleStarted.duration(to: clock.now))
                    let finalLayoutStarted = clock.now
                    root.layoutSubtreeIfNeeded()
                    layoutSeconds += durationSeconds(finalLayoutStarted.duration(to: clock.now))
                    let after = clip.bounds
                    let stepFinished = clock.now
                    let stepSeconds = durationSeconds(stepStarted.duration(to: stepFinished))
                    searchSteps += 1
                    let progressed = increasing ? after.minY > before.minY : after.minY < before.minY
                    if progressed {
                        lastProgress = stepFinished
                        progressingSteps += 1
                        progressingStepSeconds += stepSeconds
                        maximumEstimatedSteps = max(maximumEstimatedSteps, Double(ceil(document.height / CGFloat(distance))))
                        let allowance = min(maximumSearchSeconds,
                            10 + maximumEstimatedSteps * progressingStepSeconds / Double(progressingSteps))
                        deadline = min(hardDeadline, max(deadline, started.advanced(by: .seconds(allowance))))
                    }
                    lastBoundary = "searching native list delta=\(delta) before=\(rectDescription(before)) "
                        + "after=\(rectDescription(after)) document=\(rectDescription(clip.documentRect)) "
                        + "clipFlipped=\(clip.isFlipped) towardEnd=\(stepTowardEnd) "
                        + "reversedAtStart=\(searchedPastIntroduction) steps=\(searchSteps) "
                        + "elapsedSeconds=\(durationSeconds(started.duration(to: stepFinished))) stepSeconds=\(stepSeconds) "
                        + "lookupSeconds=\(lookupSeconds) layoutSeconds=\(layoutSeconds) "
                        + "gestureSeconds=\(gestureSeconds) settleSeconds=\(settleSeconds) "
                        + "deadlineSeconds=\(durationSeconds(started.duration(to: deadline)))"
                    writeEvidence("scroll-search identifier=\(identifier) \(lastBoundary)")
                    continue
                }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            root.layoutSubtreeIfNeeded()
            // No in-process accessibility hit test: SwiftUI builds its accessibility tree only for an assistive client.
            if isClickProbeReady(probe, root: root, window: window) {
                writeEvidence("reveal-complete identifier=\(identifier) searchSteps=\(searchSteps) "
                    + "elapsedSeconds=\(durationSeconds(started.duration(to: clock.now)))")
                return
            } else {
                let scrollView = try scrollContainerClipping(probe, context: context)
                let target = probe.convert(probe.bounds, to: scrollView.contentView)
                let visible = scrollView.contentView.bounds
                let movement = target.minY < visible.minY ? target.minY - visible.minY : target.maxY - visible.maxY
                let distance = Int32(min(CGFloat(Int32.max), max(1, min(ceil(abs(movement)), floor(visible.height * 0.75)))))
                let delta = (movement > 0) == scrollView.contentView.isFlipped ? -distance : distance
                let before = scrollView.contentView.bounds.origin
                try await scrollList(scrollView, delta: delta, in: window)
                root.layoutSubtreeIfNeeded()
                let after = scrollView.contentView.bounds.origin
                if before != after { lastProgress = clock.now }
                let progress = "wheelDelta=\(delta) moved=\(before != after) before=\(pointDescription(before)) "
                    + "after=\(pointDescription(after)) " + scrollGeometry(probe: probe, scrollView: scrollView)
                if progress != lastBoundary {
                    writeEvidence("scroll-progress identifier=\(identifier) \(progress)")
                }
                lastBoundary = progress
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(
            message: "\(context) could not establish concrete control readiness for \(identifier); "
                + "elapsedSeconds=\(durationSeconds(started.duration(to: clock.now))) "
                + "idleSeconds=\(durationSeconds(lastProgress.duration(to: clock.now))); last boundary: \(lastBoundary)"
        )
    }

    private static func scrollContainerClipping(_ probe: NSView, context: String) throws -> NSScrollView {
        var ancestor = probe.superview
        while let current = ancestor {
            defer { ancestor = current.superview }
            guard let clip = current as? NSClipView, let scroll = clip.enclosingScrollView else { continue }
            let target = probe.convert(probe.bounds, to: clip)
            let visible = clip.bounds
            guard !visible.contains(target) else { continue }
            guard [target.minX, target.minY, target.maxX, target.maxY, visible.minX, visible.minY,
                   visible.maxX, visible.maxY].allSatisfy(\.isFinite), visible.height > 0,
                  target.height <= visible.height, target.minX >= visible.minX, target.maxX <= visible.maxX else {
                throw Failure(message: "\(context) cannot reveal the full control with vertical wheel input; "
                    + scrollGeometry(probe: probe, scrollView: scroll))
            }
            return scroll
        }
        throw Failure(message: "\(context) control is not ready and has no vertically clipping scroll container")
    }

    private static func writeBatchLayoutEvidence(in window: NSWindow, context: String) {
        guard let root = window.contentView else { return }
        let list = findClickProbes(in: root, identifier: "generation-batch.list").first
        let geometry = list.flatMap { probe in
            probe.enclosingScrollView.map { scrollGeometry(probe: probe, scrollView: $0) }
        } ?? "list=absent"
        writeEvidence("resize context=\(context) window=\(rectDescription(window.frame)) "
            + "root=\(rectDescription(root.bounds)) \(geometry)")
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func scrollList(_ scroll: NSScrollView, delta: Int32, in window: NSWindow) async throws {
        guard scroll.window === window, let screen = NSScreen.screens.first else {
            throw Failure(message: "native list scrolling has no matching window or screen")
        }
        let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let point = window.convertPoint(toScreen: center)
        let location = CGPoint(x: point.x, y: screen.frame.height - point.y)
        let events = try HangDiagnosticReplay.scrollGestureEvents(delta: delta, location: location)
        for (index, event) in events.enumerated() {
            if index > 0 { try await Task.sleep(for: .milliseconds(20)) }
            scroll.scrollWheel(with: event)
        }
    }

    private static func captureFailureEvidence(in window: NSWindow) {
        guard let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        writeEvidence("failure-window frame=\(rectDescription(window.frame)) root=\(rectDescription(root.bounds)) "
            + "visible=\(window.isVisible) key=\(window.isKeyWindow)")
        if let list = findClickProbes(in: root, identifier: "generation-batch.list").first,
           let scroll = list.enclosingScrollView {
            let frame = scroll.documentView.map { rectDescription($0.frame) } ?? "absent"
            let flipped = scroll.documentView.map { String($0.isFlipped) } ?? "absent"
            writeEvidence("failure-list " + scrollGeometry(probe: list, scrollView: scroll)
                + " documentFrame=\(frame) clipFlipped=\(scroll.contentView.isFlipped) "
                + "documentFlipped=\(flipped)")
        }
        do { try captureWindow(window, name: "generation-batch-failure.png") }
        catch { writeEvidence("failure-screenshot error=\(error.localizedDescription)") }
    }

    private static func requireVisible(
        _ identifiers: [String],
        in window: NSWindow,
        context: String
    ) async throws {
        for identifier in identifiers {
            guard await waitUntil(timeout: .seconds(10), {
                isClickProbeReady(identifier: identifier, in: window)
            }) else {
                throw Failure(message: "\(context) hid or clipped \(identifier)")
            }
        }
    }

    private static func postMouseClick(identifier: String, in window: NSWindow) -> String? {
        switch queuePointerClick(identifier: identifier, in: window) {
        case .success:
            return nil
        case .failure(let failure):
            return failure.message
        }
    }

    private static func queuePointerClick(
        identifier: String,
        in window: NSWindow
    ) -> Result<PointerDispatchEvidence, Failure> {
        guard let root = window.contentView else {
            return .failure(Failure(message: "the \(identifier) pointer dispatch has no window content view"))
        }
        guard let probe = findClickProbes(in: root, identifier: identifier).first(where: {
            isClickProbeReady($0, root: root, window: window)
        }) else {
            return .failure(Failure(message: "the \(identifier) pointer dispatch has no geometry-ready native probe"))
        }
        let frame = probe.bounds
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width > AppTheme.Spacing.none,
              frame.height > AppTheme.Spacing.none else {
            return .failure(Failure(message: "the visible \(identifier) control had no finite pointer target"))
        }
        let location = probe.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        let contentPoint = root.convert(location, from: nil)
        let appKitHitChain = viewChain(from: root.hitTest(root.convert(contentPoint, to: root.superview)))
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
            return .failure(Failure(message: "AppKit could not create pointer events for \(identifier)"))
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        let evidence = PointerDispatchEvidence(
            identifier: identifier,
            windowPoint: location,
            appKitHitChain: appKitHitChain
        )
        writeEvidence(evidence.description)
        return .success(evidence)
    }

    // Programmatic focus first; otherwise Tab moves focus as a keyboard user would.
    private static func focusRemove(
        itemID: String,
        in window: NSWindow,
        runtimeEvidence: GenerationBatchReviewRuntimeEvidence
    ) async throws -> Int? {
        if await waitUntil(timeout: .seconds(2), { runtimeEvidence.focusedRemoveItemID == itemID }) { return 0 }
        for tab in 1...keyboardFocusTabLimit {
            try postKey(code: 48, characters: "\t", in: window)
            if await waitUntil(timeout: .milliseconds(500), { runtimeEvidence.focusedRemoveItemID == itemID }) {
                return tab
            }
        }
        return nil
    }

    private static func verifyVisibleKeyboardFocus(
        itemID: String, in window: NSWindow, runtimeEvidence: GenerationBatchReviewRuntimeEvidence
    ) async throws {
        for control in ["remove", "details"] {
            let identifier = "generation-batch.\(control).\(itemID)"
            window.makeFirstResponder(nil)
            guard await waitUntil(timeout: .seconds(2), {
                runtimeEvidence.focusedRemoveItemID == nil && runtimeEvidence.focusedDetailsItemID == nil
            }) else { throw Failure(message: "keyboard focus did not clear for its visual comparison") }
            try await reveal(identifier: identifier, in: window, context: "visible keyboard focus")
            try await Task.sleep(for: .milliseconds(200))
            let before = try controlBitmap(identifier: identifier, in: window)
            var focused = false
            for _ in 0..<keyboardFocusTabLimit {
                try postKey(code: 48, characters: "\t", in: window)
                if await waitUntil(timeout: .milliseconds(200), {
                    control == "remove" ? runtimeEvidence.focusedRemoveItemID == itemID
                        : runtimeEvidence.focusedDetailsItemID == itemID
                }) { focused = true; break }
            }
            guard focused else { throw Failure(message: "\(control) never took Tab focus") }
            try await Task.sleep(for: .milliseconds(200))
            let after = try controlBitmap(identifier: identifier, in: window)
            guard before.pixelsWide == after.pixelsWide, before.pixelsHigh == after.pixelsHigh,
                  before.samplesPerPixel == after.samplesPerPixel,
                  before.bytesPerRow == after.bytesPerRow,
                  let beforeBytes = before.bitmapData, let afterBytes = after.bitmapData else {
                throw Failure(message: "focus comparison geometry changed")
            }
            var changedPixels = 0
            for y in 0..<before.pixelsHigh {
                for x in 0..<before.pixelsWide {
                    let offset = y * before.bytesPerRow + x * before.samplesPerPixel
                    if (0..<min(3, before.samplesPerPixel)).contains(where: {
                        abs(Int(beforeBytes[offset + $0]) - Int(afterBytes[offset + $0])) > 24
                    }) { changedPixels += 1 }
                }
            }
            guard changedPixels >= 12 else {
                throw Failure(message: "\(control) has keyboard focus but no visible focus indicator")
            }
            try writeImage(before, name: "generation-focus-\(control)-before.png")
            try writeImage(after, name: "generation-focus-\(control).png")
            if let root = window.contentView, let full = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: full)
                try writeImage(full, name: "generation-focus-\(control)-window.png")
            }
            writeEvidence("visible-keyboard-focus control=\(control) changedPixels=\(changedPixels)")
        }
    }

    private static func controlBitmap(identifier: String, in window: NSWindow) throws -> NSBitmapImageRep {
        guard let root = window.contentView,
              let probe = findClickProbes(in: root, identifier: identifier).first(where: {
                  isClickProbeReady($0, root: root, window: window)
              }) else { throw Failure(message: "focus control is not visibly contained") }
        root.layoutSubtreeIfNeeded()
        let frame = probe.convert(probe.bounds, to: root).insetBy(dx: -AppTheme.Spacing.xs, dy: -AppTheme.Spacing.xs)
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: frame) else {
            throw Failure(message: "focus control could not render its pixels")
        }
        root.cacheDisplay(in: frame, to: bitmap)
        return bitmap
    }

    private static func captureWindow(_ window: NSWindow, name: String) throws {
        guard let root = window.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw Failure(message: "review window could not capture its pixels")
        }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try writeImage(bitmap, name: name)
    }

    private static func writeImage(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["NGV_SELFTEST_GENERATION_BATCH_EVIDENCE"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(message: "focus evidence could not encode its screenshot")
        }
        try bytes.write(to: root.appendingPathComponent(name), options: .atomic)
    }

    private static let keyboardFocusTabLimit = 60

    // Queued like the pointer events, so AppKit routes the keys through NSApplication.sendEvent.
    private static func postKey(code: UInt16, characters: String, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            ) else {
                throw Failure(message: "AppKit could not create the key event for key code \(code)")
            }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func keyboardFocusDescription(
        window: NSWindow,
        runtimeEvidence: GenerationBatchReviewRuntimeEvidence
    ) -> String {
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "swiftUIFocus=\(runtimeEvidence.focusedRemoveItemID ?? "nil") firstResponder=\(responder) "
            + "keyWindow=\(window.isKeyWindow)"
    }

    private static func isClickProbeReady(identifier: String, in window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        return findClickProbes(in: root, identifier: identifier).contains {
            isClickProbeReady($0, root: root, window: window)
        }
    }

    private static func isClickProbeReady(_ probe: NSView, root: NSView, window: NSWindow) -> Bool {
        guard NSApp.isActive, window.isVisible, window.isKeyWindow, !window.ignoresMouseEvents,
              probe.window === window,
              !probe.isHiddenOrHasHiddenAncestor else { return false }
        let frame = probe.bounds
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width > AppTheme.Spacing.none,
              frame.height > AppTheme.Spacing.none else { return false }
        guard root.bounds.contains(probe.convert(frame, to: root)) else { return false }
        var ancestor = probe.superview
        while let current = ancestor {
            let frameInAncestor = probe.convert(frame, to: current)
            guard current.visibleRect.contains(frameInAncestor) else { return false }
            if current === root { break }
            ancestor = current.superview
        }
        return true
    }

    private static func viewChain(from hitView: NSView?) -> String {
        var view = hitView
        var chain: [String] = []
        while let current = view {
            let identifier = current.identifier?.rawValue ?? "nil"
            chain.append("\(String(describing: type(of: current)))(id=\(identifier))")
            view = current.superview
        }
        return chain.isEmpty ? "none" : chain.joined(separator: " <- ")
    }

    private static func renderBoundaryDescription(itemID: String, in window: NSWindow) -> String {
        guard let root = window.contentView else { return "render root=absent" }
        let detailsIdentifier = "generation-batch.details.\(itemID)"
        let expandedIdentifier = "generation-batch.expanded.\(itemID)"
        let details = findClickProbes(in: root, identifier: detailsIdentifier)
        let expanded = findClickProbes(in: root, identifier: expandedIdentifier)
        return "render item=\(itemID) detailsProbeCount=\(details.count) "
            + "expandedProbeCount=\(expanded.count)"
    }

    private static func scrollGeometry(probe: NSView, scrollView: NSScrollView) -> String {
        let target = probe.convert(probe.bounds, to: scrollView.contentView)
        let visible = scrollView.contentView.bounds
        return "target=\(rectDescription(target)) visible=\(rectDescription(visible)) "
            + "document=\(rectDescription(scrollView.contentView.documentRect))"
    }

    nonisolated private static func pointDescription(_ point: NSPoint) -> String {
        "(\(String(format: "%.2f", point.x)),\(String(format: "%.2f", point.y)))"
    }

    nonisolated private static func rectDescription(_ rect: NSRect) -> String {
        "(x:\(String(format: "%.2f", rect.origin.x)),y:\(String(format: "%.2f", rect.origin.y)),"
            + "w:\(String(format: "%.2f", rect.width)),h:\(String(format: "%.2f", rect.height)))"
    }

    private static func setDescription(_ values: Set<String>) -> String {
        "[\(values.sorted().joined(separator: ","))]"
    }

    private static func writeEvidence(_ message: String) {
        FileHandle.standardOutput.write(
            Data("SELFTEST_GENERATION_BATCH_REVIEW_EVIDENCE \(message)\n".utf8)
        )
    }

    private static func hasProbe(identifier: String, in window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        return !findClickProbes(in: root, identifier: identifier).isEmpty
    }

    private static func findClickProbes(in view: NSView, identifier: String) -> [NSView] {
        var matches: [NSView] = []
        if view is AppRelaunchClickProbeView,
           view.identifier?.rawValue == identifier {
            matches.append(view)
        }
        for child in view.subviews {
            matches.append(contentsOf: findClickProbes(in: child, identifier: identifier))
        }
        return matches
    }

    private struct PointerDispatchEvidence {
        let identifier: String
        let windowPoint: NSPoint
        let appKitHitChain: String

        var description: String {
            "pointer-dispatch identifier=\(identifier) "
                + "windowPoint=\(GenerationBatchReviewSelfTest.pointDescription(windowPoint)) "
                + "dispatch=queued appKitHit=[\(appKitHitChain)]"
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
