import AppKit
import SwiftUI

@MainActor
enum GenerationBatchReviewSelfTest {
    private static let environmentKey = "NGV_SELFTEST_GENERATION_BATCH_REVIEW"

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    static func runIfRequested() {
        guard isRequested else { return }
        do {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let editor = EditorViewModel(
                agentService: AgentService(
                    backend: .claudeCode,
                    refreshBackendStatusOnInit: false
                )
            )
            let priced = try package(editor: editor, priced: true)
            let unpriced = try package(editor: editor, priced: false)
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

            Task { @MainActor in
                do {
                    try await verify(
                        window: window,
                        editor: editor,
                        original: manifest,
                        pricedPackage: priced,
                        runtimeEvidence: runtimeEvidence
                    )
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
        } catch {
            FileHandle.standardError.write(
                Data("SELFTEST_GENERATION_BATCH_REVIEW_FAIL \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
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
        runtimeEvidence: GenerationBatchReviewRuntimeEvidence
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
            "generation-batch.more",
            "generation-batch.approve",
        ], in: window, context: "13-item narrow large-text review")
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
            "generation-batch.more",
            "generation-batch.approve",
        ], in: window, context: "12-item narrow large-text review in the default window")

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
        postRemoveKeyboardActivation(in: window)
        guard await waitUntil(timeout: .seconds(5), {
            editor.generationBatchCoordinator.pending?.payload.items.count == 11
        }), let afterKeyboard = editor.generationBatchCoordinator.pending else {
            throw Failure(message: "the keyboard event did not activate the visible Remove action")
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
            "generation-batch.more",
            "generation-batch.approve",
        ], in: window, context: "single-item narrow large-text review")

        editor.generationBatchCoordinator.decline(editor: editor)
        let fifty = try batch(
            package: pricedPackage,
            purposes: (1...50).map { index in
                let group = index.isMultiple(of: 3) ? "Location" : index.isMultiple(of: 2) ? "Prop" : "Character"
                return "\(group) item \(index) — continuity view with a deliberately long readable purpose"
            }
        )
        try present(fifty, editor: editor)
        for width in [CGFloat(400), AppTheme.Layout.agentPanelMax] {
            place(window, contentSize: NSSize(
                width: width,
                height: minimumPanelHeight
            ))
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

    private static func package(editor: EditorViewModel, priced: Bool) throws -> GenerationPackageV1 {
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
            sourceSHA256: String(repeating: "a", count: 64),
            submittedSHA256: String(repeating: "a", count: 64)
        )
        if !editor.mediaAssets.contains(where: { $0.id == receipt.assetID }) {
            let thumbnail = NSImage(
                systemSymbolName: "person.crop.rectangle",
                accessibilityDescription: "Mara reference"
            )
            editor.mediaAssets.append(MediaAsset(
                id: receipt.assetID,
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ngv-generation-batch-reference.png"),
                type: .image,
                name: "Mara front",
                thumbnail: thumbnail,
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
        let binding = PromptBinding(
            projectKey: "generation-batch-review-selftest",
            shotId: "none",
            shotFingerprint: "none"
        )
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
        return try GenerationPackageV1(payload: .init(
            target: target,
            modality: "image",
            operation: "generate_image",
            intent: prompt,
            prompt: prompt,
            promptRevisionID: "selftest",
            generationInput: input,
            binding: binding,
            compilerInputsSHA256: "none",
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

    private static func reveal(
        identifier: String,
        in window: NSWindow,
        context: String
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var lastBoundary = "native probe absent"
        while clock.now < deadline {
            guard let root = window.contentView else {
                throw Failure(message: "\(context) has no window content view while revealing \(identifier)")
            }
            guard let probe = findClickProbes(in: root, identifier: identifier).first else {
                lastBoundary = "native probe absent"
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            root.layoutSubtreeIfNeeded()
            // No in-process accessibility hit test: SwiftUI builds its accessibility tree only for an assistive client.
            if isClickProbeReady(probe, root: root, window: window) {
                return
            } else {
                guard let scrollView = probe.enclosingScrollView else {
                    throw Failure(message: "\(context) cannot reveal \(identifier): native probe has no enclosing NSScrollView")
                }
                let target = probe.convert(probe.bounds, to: scrollView.contentView)
                guard target.height <= scrollView.contentView.bounds.height else {
                    throw Failure(
                        message: "\(context) cannot show \(identifier) completely: the control is taller than "
                            + "its list viewport; " + scrollGeometry(probe: probe, scrollView: scrollView)
                    )
                }
                let before = scrollView.contentView.bounds.origin
                if let failure = AppRelaunchSelfTest.scrollProbeToVisible(probe, in: window) {
                    lastBoundary = failure
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                root.layoutSubtreeIfNeeded()
                let after = scrollView.contentView.bounds.origin
                let progress = "moved=\(before != after) before=\(pointDescription(before)) "
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
                + "last boundary: \(lastBoundary)"
        )
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
        let appKitHitChain = viewChain(from: root.hitTest(contentPoint))
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

    private static func postRemoveKeyboardActivation(in window: NSWindow) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ), let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ) {
            window.sendEvent(down)
            window.sendEvent(up)
        }
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
