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

            let host = NSHostingView(
                rootView: GenerationBatchCard(editor: editor, runtimeEvidenceEnabled: true)
                    .environment(editor)
                    .environment(\.interfaceScale, AppTheme.Typography.largestScale)
            )
            let window = NSWindow(
                contentRect: NSRect(
                    x: AppTheme.Spacing.none,
                    y: AppTheme.Spacing.none,
                    width: AppTheme.Layout.agentPanelMin,
                    height: AppTheme.ComponentSize.agentDecisionMaxHeight * AppTheme.Typography.largestScale
                ),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)

            Task { @MainActor in
                do {
                    try await verify(
                        window: window,
                        editor: editor,
                        original: manifest,
                        pricedPackage: priced
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

    private static func verify(
        window: NSWindow,
        editor: EditorViewModel,
        original: GenerationBatch,
        pricedPackage: GenerationPackageV1
    ) async throws {
        let firstID = original.payload.items[0].id
        try await reveal(
            identifier: "generation-batch.remove.\(firstID)",
            in: window,
            context: "13-item narrow large-text review"
        )
        try await requireVisible([
            "generation-batch.remove.\(firstID)",
            "generation-batch.details.\(firstID)",
            "generation-batch.decline",
            "generation-batch.approve",
            "generation-batch.approve-reason",
            "generation-batch.retry-pricing",
        ], in: window, context: "13-item narrow large-text review")
        if let failure = postMouseClick(
            identifier: "generation-batch.details.\(firstID)",
            in: window
        ) {
            throw Failure(message: failure)
        }
        guard await waitUntil(timeout: .seconds(5), {
            hasProbe(identifier: "generation-batch.expanded.\(firstID)", in: window)
        }) else {
            throw Failure(message: "the visible Details action did not expand its concrete item")
        }
        try await requireVisible([
            "generation-batch.decline",
            "generation-batch.approve",
        ], in: window, context: "expanded review")
        if let failure = postMouseClick(
            identifier: "generation-batch.details.\(firstID)",
            in: window
        ) {
            throw Failure(message: failure)
        }
        guard await waitUntil(timeout: .seconds(5), {
            !hasProbe(identifier: "generation-batch.expanded.\(firstID)", in: window)
        }) else {
            throw Failure(message: "the visible Hide details action did not collapse its concrete item")
        }
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
        window.setContentSize(NSSize(
            width: AppTheme.Layout.agentPanelMax,
            height: AppTheme.ComponentSize.agentDecisionMaxHeight * AppTheme.Typography.largestScale
        ))
        try await reveal(
            identifier: "generation-batch.remove.\(keyboardID)",
            in: window,
            context: "13-item wide review"
        )
        try await requireVisible([
            "generation-batch.remove.\(keyboardID)",
            "generation-batch.decline",
            "generation-batch.approve",
        ], in: window, context: "13-item wide review")
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
        window.setContentSize(NSSize(
            width: AppTheme.Layout.agentPanelMin,
            height: AppTheme.ComponentSize.agentDecisionMaxHeight * AppTheme.Typography.largestScale
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
            window.setContentSize(NSSize(
                width: width,
                height: AppTheme.ComponentSize.agentDecisionMaxHeight * AppTheme.Typography.largestScale
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

    private static func reveal(
        identifier: String,
        in window: NSWindow,
        context: String
    ) async throws {
        guard await waitUntil(timeout: .seconds(10), {
            guard let root = window.contentView,
                  let probe = findClickProbes(in: root, identifier: identifier).first else {
                return false
            }
            root.layoutSubtreeIfNeeded()
            probe.scrollToVisible(probe.bounds)
            return isClickProbeReady(probe, root: root, window: window)
        }) else {
            throw Failure(message: "\(context) could not scroll \(identifier) into the batch body viewport")
        }
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
        guard let root = window.contentView,
              let probe = findClickProbes(in: root, identifier: identifier).first(where: {
                  isClickProbeReady($0, root: root, window: window)
              }) else {
            return "the visible \(identifier) control could not receive pointer input"
        }
        let frame = probe.bounds
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width > AppTheme.Spacing.none,
              frame.height > AppTheme.Spacing.none else {
            return "the visible \(identifier) control had no finite pointer target"
        }
        let location = probe.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
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
            return "AppKit could not create pointer events for \(identifier)"
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return nil
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
        guard window.isVisible, window.isKeyWindow, !window.ignoresMouseEvents,
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

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
