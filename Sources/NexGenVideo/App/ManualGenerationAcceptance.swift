import AppKit
import SwiftUI
import NexGenEngine

@MainActor
enum ManualGenerationAcceptance {
    static func run(editor: EditorViewModel, directory: URL) async throws {
        guard WorkspaceUIAcceptance.isRequested, editor.workingRoot != nil else {
            throw GateBlocked("Manual generation acceptance requires an explicit native acceptance project.")
        }
        let catalog = ModelCatalog(); catalog.load(entries: ModelCatalog.launchEntries)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MusicvideoGenerationHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); MusicvideoGenerationHTTP.clear() }
        let discovery = try await ManualGenerationDiscovery.images(session: session, catalog: catalog)
        let defaultsName = "ManualGenerationAcceptance." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: defaultsName), let imageModel = catalog.image.first(where: { $0.id == "fal-ai/flux/dev" }) else {
            throw GateBlocked("The actual native generation catalog fixture is unavailable.")
        }
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let services = GenerationPanelServices(catalog: catalog, preferences: ModelPreferences(defaults: defaults),
            activation: { .init(active: [.init(provider: .fal, transport: .api)]) },
            quoteLoader: { _, _ in throw GenerationBackendError.transport("The isolated HTTP simulator has no live price.") })
        let sourceOnly = try require(catalog.video.first { services.target($0.id, sourceVideo: true).binding != nil
            && services.target($0.id, sourceVideo: false).binding == nil }, "No actual source-only offering exists for this native scenario.")
        let previousServices = editor.generationPanelServicesOverride
        editor.generationPanelServicesOverride = services
        let originalFocus = editor.workspaceFocus, originalPanel = editor.showGenerationPanel
        let previousReconciliation = editor.generationService.reconciliation
        editor.setWorkspaceFocus(.media); editor.showGenerationPanel = true
        defer {
            editor.generationService.reconciliation = previousReconciliation
            editor.generationPanelServicesOverride = previousServices
            editor.showGenerationPanel = originalPanel; editor.setWorkspaceFocus(originalFocus)
        }
        editor.generationService.reconciliation = ProviderRunReconciliation(session: session,
            providerKey: { $0 == .fal ? "simulator-only-key" : nil }, falCharge: { _, _, _ in nil })
        guard let document = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject })
            .first(where: { $0.editorViewModel === editor }),
              let window = document.windowControllers.compactMap(\.window).first(where: \.isVisible) else {
            throw GateBlocked("Native generation requires the real document window.")
        }
        window.makeKeyAndOrderFront(nil)
        let driver = ProductionVisualSourcesDriver(window: window, output: directory, name: "manual-generation")
        do {
            let initialSpend = editor.generationLog.spendEvents.count
            try await driver.wait("actual native generation panel") { driver.state("generation.media.type.Image", in: window) != nil }
            try await driver.click("generation.media.type.Image", in: window, enabled: false)
            try await driver.picker("generation.media.model", title: imageModel.displayName, expected: imageModel.id, in: window)
            let intent = "A single red circle on a pale wall, static wide composition."
            try await driver.fill("generation.media.intent", value: intent, in: window)
            try await driver.click("generation.media.review", in: window)
            try await driver.wait("compiled image package for native review") { driver.state("generation.media.approve", in: window) == true }
            try await driver.click("generation.media.package.details", in: window)
            let promptCopyBefore = NSPasteboard.general.changeCount
            try await driver.click("generation.media.package.copy-prompt", in: window)
            guard NSPasteboard.general.changeCount != promptCopyBefore else { throw GateBlocked("Copy provider prompt did not update the pasteboard.") }
            let prompt = try require(NSPasteboard.general.string(forType: .string), "The real Copy provider prompt action copied nothing.")
            let packageCopyBefore = NSPasteboard.general.changeCount
            try await driver.click("generation.media.package.copy-package", in: window)
            guard NSPasteboard.general.changeCount != packageCopyBefore else { throw GateBlocked("Copy package did not update the pasteboard.") }
            let packageText = try require(NSPasteboard.general.string(forType: .string), "The real Copy package action copied nothing.")
            let package = try JSONDecoder().decode(GenerationPackageV1.self, from: Data(packageText.utf8))
            guard package.payload.intent == intent, package.payload.prompt == prompt, package.payload.target.modelId == imageModel.id,
                  package.payload.modality == "image", package.payload.destination.kind == "media_library",
                  editor.generationLog.spendEvents.count == initialSpend,
                  MusicvideoGenerationHTTP.requests.count == 2,
                  MusicvideoGenerationHTTP.requests.allSatisfy({ $0.method == "GET" }) else {
                throw GateBlocked("Native preparation changed spend, dispatched before approval or copied another request.")
            }
            try await driver.fill("generation.media.intent", value: intent + " Soft side lighting.", in: window)
            try await driver.wait("changed direction invalidates the prior package") { driver.state("generation.media.approve", in: window) == nil }
            try await driver.click("generation.media.review", in: window)
            try await driver.wait("replacement request prepared") { driver.state("generation.media.approve", in: window) == true }
            try await driver.click("generation.media.discard", in: window)
            guard editor.generationLog.spendEvents.count == initialSpend,
                  MusicvideoGenerationHTTP.requests.count == 2,
                  MusicvideoGenerationHTTP.requests.allSatisfy({ $0.method == "GET" }) else {
                throw GateBlocked("Discarding a native generation package dispatched or spent money.")
            }
            try await driver.click("generation.media.review", in: window)
            try await driver.wait("exact native request before HTTP approval") { driver.state("generation.media.approve", in: window) == true }
            try await driver.click("generation.media.package.details", in: window)
            let approvedCopyBefore = NSPasteboard.general.changeCount
            try await driver.click("generation.media.package.copy-package", in: window)
            guard NSPasteboard.general.changeCount != approvedCopyBefore else { throw GateBlocked("Copy approved package did not update the pasteboard.") }
            let approvedText = try require(NSPasteboard.general.string(forType: .string), "The approved package is not copyable.")
            let approved = try JSONDecoder().decode(GenerationPackageV1.self, from: Data(approvedText.utf8))
            let output = try imageBytes()
            try MusicvideoGenerationHTTP.installCover(endpoint: approved.payload.target.endpoint, output: output)
            try driver.capture("request-before-approval", target: window)
            try await driver.click("generation.media.approve", in: window)
            try await driver.wait("actual HTTP output reaches the native library", seconds: 60) {
                editor.mediaAssets.contains { $0.generationInput?.generationPackageID == approved.id && $0.generationStatus == .none }
            }
            let asset = try require(editor.mediaAssets.first { $0.generationInput?.generationPackageID == approved.id
                && $0.generationStatus == .none }, "The approved image did not reach the library.")
            let submitted = MusicvideoGenerationHTTP.requests.filter { $0.method == "POST" && $0.url.hasPrefix("https://queue.fal.run/") }
            let body = try require(submitted.first, "The actual HTTP submit was not observed.")
            let json = try JSONSerialization.jsonObject(with: body.body) as? [String: Any]
            guard submitted.count == 1, json?["prompt"] as? String == approved.payload.prompt,
                  try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: output),
                  MusicvideoGenerationHTTP.unexpectedRequests.isEmpty else { throw GateBlocked("The HTTP output or prompt differs from the natively approved package.") }
            try driver.record("manual image generation uses the native reviewed request", fields: ["packageID": approved.id,
                "modelID": approved.payload.target.modelId, "modelLabel": imageModel.displayName,
                "selectedModelID": driver.text("generation.media.model", in: window) ?? "",
                "discovery": discovery,
                "outputSHA256": FileDigest.sha256(of: output), "copiedPromptMatched": true, "discardDidNotSubmit": true,
                "changedInputsInvalidateReview": true, "nativeApproval": true,
                "scope": "Actual native controls and Fal HTTP client against an isolated simulator; no live provider or model-quality proof."])
            try await driver.click("generation.media.type.Video", in: window, enabled: false)
            try await driver.picker("generation.media.model", title: sourceOnly.displayName, expected: sourceOnly.id, in: window)
            let sourceIntent = "Preserve the source composition and motion."
            try await driver.fill("generation.media.intent", value: sourceIntent, in: window, requireFocusExit: true)
            let sourceSlotBefore = try require(driver.text("generation.media.slot.Source Video", in: window), "The native source slot is missing.")
            let reviewEnabledBefore = try require(driver.state("generation.media.review", in: window), "The native Review control is missing.")
            guard sourceSlotBefore.isEmpty, !reviewEnabledBefore else {
                throw GateBlocked("Review must remain disabled for a source-only model until its source is assigned.")
            }
            try driver.capture("source-only-model-before-assignment", target: window)
            let videoURL = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
            defer { try? FileManager.default.removeItem(at: videoURL) }
            let destination = try editor.prepareWorkingMediaDirectory().appendingPathComponent("native-generation-source-" + UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: videoURL, to: destination)
            let source = MediaAsset(url: destination, type: .video, name: "Native original source", duration: 8)
            await source.loadMetadata()
            editor.importMediaAsset(source)
            try await driver.click("generation.media.pick.Source Video", in: window)
            let library = try await popup(containing: "library.pick." + source.id, driver: driver)
            try await driver.click("library.pick." + source.id, in: library)
            try await driver.wait("source-only model receives native library assignment") {
                window.isKeyWindow && driver.text("generation.media.slot.Source Video", in: window) == source.id
                    && driver.state("generation.media.review", in: window) == true
            }
            let sourceSlotAfter = try require(driver.text("generation.media.slot.Source Video", in: window), "The assigned source slot is missing.")
            let reviewEnabledAfter = try require(driver.state("generation.media.review", in: window), "The assigned source Review control is missing.")
            try await driver.click("generation.media.review", in: window)
            try await driver.wait("assigned source opens the actual native review") { driver.state("generation.media.approve", in: window) == true }
            let reviewOpened = driver.state("generation.media.approve", in: window) == true
            try await driver.click("generation.media.package.details", in: window)
            let sourceCopyBefore = NSPasteboard.general.changeCount
            try await driver.click("generation.media.package.copy-package", in: window)
            guard NSPasteboard.general.changeCount != sourceCopyBefore else { throw GateBlocked("Copy source review package did not update the pasteboard.") }
            let sourceText = try require(NSPasteboard.general.string(forType: .string), "The source review package is not copyable.")
            let sourcePackage = try JSONDecoder().decode(GenerationPackageV1.self, from: Data(sourceText.utf8))
            try sourcePackage.validate()
            guard sourcePackage.payload.modality == "video", sourcePackage.payload.intent == sourceIntent,
                  sourcePackage.payload.target.modelId == sourceOnly.id,
                  sourcePackage.payload.generationInput.sourceVideoAssetId == source.id else {
                throw GateBlocked("The native source review opened a different request.")
            }
            try await driver.click("generation.media.discard", in: window)
            guard MusicvideoGenerationHTTP.requests.filter({ $0.method == "POST" && $0.url.hasPrefix("https://queue.fal.run/") }).count == 1 else {
                throw GateBlocked("Assigning a native source dispatched a second generation.")
            }
            try driver.record("source-only offering and native library picker", fields: ["modelID": sourceOnly.id,
                "modelLabel": sourceOnly.displayName, "selectedModelID": driver.text("generation.media.model", in: window) ?? "",
                "sourceSlotBefore": sourceSlotBefore, "sourceSlotAfter": sourceSlotAfter,
                "reviewEnabledBefore": reviewEnabledBefore, "reviewEnabledAfter": reviewEnabledAfter, "reviewOpened": reviewOpened,
                "reviewPackageID": sourcePackage.id, "reviewModelID": sourcePackage.payload.target.modelId,
                "reviewSourceID": sourcePackage.payload.generationInput.sourceVideoAssetId ?? "", "intent": sourcePackage.payload.intent,
                "sourceID": source.id, "sourceSHA256": try FileDigest.sha256(of: source.url), "nativeAssignment": true])
            try await driver.click("media.asset." + asset.id, in: window)
            try await driver.wait("actual generated media selection") { editor.selectedMediaAssetIds == [asset.id] }
            try await driver.click("inspector.tab.AI Edit", in: window, enabled: false)
            try await driver.wait("real generated asset inspector") { driver.state("inspector.tab.AI Edit", in: window) == true }
            let editWindow = window
            try await driver.wait("native generated asset rerun action") { driver.state("ai-edit.rerun", in: editWindow) == true }
            try await driver.click("ai-edit.rerun", in: editWindow)
            window.makeKeyAndOrderFront(nil)
            try await driver.wait("native rerun preserves original intent") {
                driver.text("generation.media.intent", in: window) == approved.payload.intent
                    && driver.text("generation.media.model", in: window) == approved.payload.target.modelId
            }
            let originalInput = asset.generationInput
            defer { asset.generationInput = originalInput }
            asset.generationInput?.referenceImageAssetIds = ["deliberately-missing-native-reference"]
            editWindow.makeKeyAndOrderFront(nil)
            try await driver.click("ai-edit.rerun", in: editWindow)
            window.makeKeyAndOrderFront(nil)
            try await driver.wait("missing original reference is a visible native failure") {
                driver.text("generation.media.seed-error", in: window)?.contains("missing") == true
                    && driver.state("generation.media.review", in: window) == false
            }
            try driver.capture("missing-rerun-reference-visible", target: window)
            try await driver.click("generation.media.new-request", in: window)
            try await driver.wait("explicit new request clears the stale reference failure") {
                driver.text("generation.media.seed-error", in: window) == nil
                    && driver.text("generation.media.slot.Source Video", in: window) == nil
                    && driver.text("generation.media.intent", in: window) == ""
            }
            try driver.record("native rerun loss is explicit", fields: ["originalIntentRestored": true,
                "faultInjection": "missing reference asset ID in stored generation input", "injectedDirectlyIntoModel": true,
                "scope": "Test-only direct stored generation-input mutation followed by the real native Rerun action; no owner workflow or live-provider proof.",
                "missingReferenceBlocked": true, "newRequestIsExplicit": true])
            asset.generationInput = originalInput
            try await ManualUpscaleAcceptance.run(editor: editor, source: asset, services: services, driver: driver)
            try await ManualAudioGenerationAcceptance.run(editor: editor, sourceVideo: source, baseServices: services, driver: driver)
        } catch { driver.failure(error); throw error }
    }

    private static func popup(containing identifier: String, driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        try await driver.wait("native popover " + identifier) {
            NSApp.windows.contains { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: $0) != nil }
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: $0) != nil }),
              window.isKeyWindow else { throw GateBlocked("The actual native library popover did not take keyboard focus.") }
        return window
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw GateBlocked(message) }; return value
    }

    private static func imageBytes() throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap else { throw CocoaError(.fileWriteUnknown) }
        for y in 0..<64 { for x in 0..<64 { bitmap.setColor(NSColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1), atX: x, y: y) } }
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return bytes
    }
}
