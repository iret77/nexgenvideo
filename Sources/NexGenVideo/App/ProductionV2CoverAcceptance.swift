import AppKit
import NexGenEngine

@MainActor
enum ProductionV2CoverAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context, generation: ProductionV2GenerationAcceptance,
                    driver: ProductionVisualSourcesDriver, output: URL) async throws -> [String: Any] {
        let editor = context.editor, root = context.dataRoot, window = driver.window
        guard editor.declaredPluginName == "musicvideo", editor.projectState?.isComplete == true,
              let home = editor.workingRoot, let sessionID = editor.agentService.currentSessionId else {
            throw GateBlocked("Cover acceptance requires the genuinely completed Music Video workflow.")
        }
        let gates = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
        let lineage = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.lineageFile))
        try await ProductionNativeDisclosureAcceptance.toggle("export.cover.open", content: "export.cover.start", expanded: true, driver: driver, in: window)
        try await driver.wait("optional cover entry ready") { driver.state("export.cover.start", in: window) == true }
        let priorMessages = Set(editor.agentService.messages.map(\.id))
        try await driver.click("export.cover.start", in: window)
        try await driver.wait("cover utility actually handed to runtime") {
            editor.workspaceFocus == .production && !editor.agentService.isStreaming
                && editor.agentService.messages.contains { !priorMessages.contains($0.id) && $0.role == .assistant }
        }
        try await decide(title: "Which platforms need cover artwork?", section: "format",
            options: [("square", "Streaming square"), ("landscape", "YouTube landscape"),
                ("portrait", "TikTok / Reels portrait")], selected: "landscape", context: context, driver: driver)
        try await decide(title: "Choose the cover subject", section: "subject",
            options: [("abstract", "Abstract style image"), ("location", "Location motif")], selected: "abstract",
            context: context, driver: driver)
        let modelID = "fal-ai/flux/schnell"
        guard let offering = generation.catalog.compatibleImageOfferings(preferredModelID: modelID, aspectRatio: "16:9",
            resolution: nil, quality: nil, referenceCount: 0).first(where: { $0.model.id == modelID && $0.target.provider == .fal }),
              let alternative = generation.catalog.compatibleImageOfferings(preferredModelID: "fal-ai/flux/dev", aspectRatio: "16:9",
                resolution: nil, quality: nil, referenceCount: 0).first(where: { $0.model.id == "fal-ai/flux/dev" && $0.target.provider == .fal }) else {
            throw GateBlocked("The actual simulator image offerings do not include the displayed cover choices.")
        }
        try await decide(title: "Choose the cover model", section: "model",
            options: [("fast", offering.model.displayName), ("alternate", alternative.model.displayName)], selected: "fast",
            context: context, driver: driver)
        let png = output.appendingPathComponent("cover-provider-source.png")
        try FullflowAcceptanceFixture.writeReference(to: png)
        let bytes = try Data(contentsOf: png)
        try MusicvideoGenerationHTTP.installCover(endpoint: modelID, output: bytes)
        let compiled = try await PromptCompiler.compile(intent: "An abstract landscape cover with one coloured shape, hard side light, pale background and clear negative space. No text or lettering.",
            modelId: modelID, modality: .image, aspectRatio: "16:9", editor: editor, shotId: "none", modelCatalog: generation.catalog)
        let request = GenerationRequest(modality: .image, modelId: modelID, intent: compiled.text, aspectRatio: "16:9",
            placement: .mediaLibrary(folderId: nil), origin: .agentTool, target: offering.target,
            precompiled: (compiled.text, compiled.token, compiled.binding), submission: .image(make: { text in
                var input = GenerationInput(prompt: text, model: modelID, duration: 0, aspectRatio: "16:9")
                input.promptShotId = compiled.binding.shotId; input.promptProjectKey = compiled.binding.projectKey
                input.promptShotFingerprint = compiled.binding.shotFingerprint
                return ImageGenerationSubmission.make(genInput: input, model: offering.model, references: [],
                    name: "Cover — Landscape — Clean", numImages: 1)
            }))
        let prepared = try await GenerationController.prepare(request, editor: editor).get()
        let noPrice: GenerationBudgetGuard.QuoteLoader = { _, _ in throw GenerationBackendError.transport("The cover HTTP simulator has no monetary quote.") }
        let package = try await GenerationController.prepareReviewPackage(prepared, editor: editor, quoteLoader: noPrice)
        if let references = prepared.references { try await GenerationPackageInputs.persist(package: package, snapshot: references, editor: editor) }
        let item = GenerationBatch.Item(id: UUID().uuidString, purpose: "Create the selected clean landscape cover", package: package)
        let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: package.payload.binding.projectKey, phase: nil, items: [item]))
        let option = SpendOption(modelId: modelID, modelName: offering.model.displayName, target: offering.target,
            credits: nil, requiresCatalogAvailability: true, generationPackage: package)
        editor.generationBatchCoordinator.quoteLoader = noPrice
        _ = try editor.agentService.presentGenerationBatch(batch, recoveries: [item.id: GenerationBatchRecovery(options: [option]) { current, _ in
            try await GenerationController.prepareReviewPackage(prepared, editor: current, quoteLoader: noPrice)
        }], origin: .inAppChat(sessionID: sessionID), editor: editor)
        try await driver.wait("cover generation approval visible") { driver.state("generation-batch.approve", in: window) == true }
        guard MusicvideoGenerationHTTP.requests.isEmpty else { throw GateBlocked("The cover provider started before native spend approval.") }
        try driver.capture("cover-unapproved", target: window)
        try await driver.click("generation-batch.approve", in: window)
        try await driver.wait("actual cover download completed", seconds: 60) {
            guard let value = try? GenerationBatchStore.load(id: batch.id, home: home), let state = value.journal.executions.first?.state else { return false }
            return [.complete, .blocked, .failed, .canceled].contains(state)
                && editor.generationBatchCoordinator.activeBatchID == nil && !editor.agentService.isStreaming
        }
        let stored = try GenerationBatchStore.load(id: batch.id, home: home)
        guard stored.journal.executions.first?.state == .complete,
              let assetID = stored.journal.executions.first?.outputAssetIDs.first,
              let asset = editor.mediaAssets.first(where: { $0.id == assetID }), asset.type == .image,
              asset.libraryDisplayName == "Cover — Landscape — Clean", asset.pendingDownloadURL == nil,
              asset.generationInput?.generationPackageID == package.id,
              try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: bytes),
              MusicvideoGenerationHTTP.submittedPrompt == compiled.text, MusicvideoGenerationHTTP.unexpectedRequests.isEmpty else {
            throw GateBlocked(stored.journal.executions.first?.detail ?? "The cover output is not bound to its actual approved image request.")
        }
        try await driver.click("editor.workspace.edit", in: window, enabled: false)
        try await driver.wait("cover library visible") { editor.workspaceFocus == .edit }
        try await driver.click("media.asset." + assetID, in: window)
        try await driver.wait("actual generated cover preview") { editor.activePreviewTab.id == PreviewTab.mediaAssetTabId(for: assetID) }
        try driver.capture("cover-actual-image-preview", target: window)
        try await driver.click("editor.workspace.production", in: window, enabled: false)
        try await driver.wait("return to cover decision") { editor.workspaceFocus == .production }
        try await decide(title: "Keep this clean landscape cover?", section: "review",
            options: [("keep", "Keep"), ("revise", "Revise subject or model"), ("skip", "Skip this format")],
            selected: "keep", context: context, driver: driver)
        try await decide(title: "Create a second variant with artist and title?", section: "typography",
            options: [("yes", "Yes"), ("no", "No — keep the clean cover")], selected: "no", context: context, driver: driver)
        guard try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile)) == gates,
              try Data(contentsOf: root.appendingPathComponent(PipelineLayout.lineageFile)) == lineage,
              editor.projectState?.isComplete == true else { throw GateBlocked("The optional cover utility changed the approved production pipeline.") }
        try driver.record("native optional cover completed", fields: ["assetID": assetID, "packageSHA256": package.id,
            "imageSHA256": FileDigest.sha256(of: bytes), "cleanCoverKept": true, "typographyExplicitlyDeclined": true])
        return ["nativeCoverEntry": true, "nativeFormatSubjectModel": true, "nativeCoverSpendApproval": true,
            "actualCoverDownloadedAndPreviewed": true, "nativeKeepDecision": true, "typographyExplicitlyDeclined": true,
            "pipelineUnchanged": true, "assetID": assetID, "sha256": FileDigest.sha256(of: bytes)]
    }

    private static func decide(title: String, section: String, options: [(String, String)], selected: String,
                               context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver) async throws {
        let service = context.editor.agentService
        guard let session = service.currentSessionId, let label = options.first(where: { $0.0 == selected })?.1 else {
            throw GateBlocked("The cover decision has no actual session or selected option.")
        }
        let result = await context.executor.execute(name: "show_dialog", args: ["title": title, "symbol": "photo",
            "sections": [["id": section, "label": title, "type": "choices", "multiSelect": false,
                "options": options.map { ["id": $0.0, "label": $0.1] }]], "confirmLabel": "Continue"],
            origin: .inAppChat(sessionID: session), toolUseID: "native-cover-" + UUID().uuidString)
        guard !result.isError else { throw GateBlocked("The genuine cover dialog tool rejected its decision.") }
        try await driver.wait("cover decision visible") { driver.text("agent.dialog.title", in: driver.window) == title }
        let id = "agent.dialog.choice." + section + "." + selected
        guard driver.text(id, in: driver.window) == "unselected" else { throw GateBlocked("The cover choice was already selected before native input.") }
        try await driver.click(id, in: driver.window)
        try await driver.wait("cover option selected natively") { driver.text(id, in: driver.window) == "selected" }
        try driver.capture("cover-choice-" + section, target: driver.window)
        try await driver.click("agent.dialog.confirm", in: driver.window)
        try await driver.wait("cover decision received") { service.pendingDialog == nil && !service.isStreaming }
        guard let answer = service.messages.last(where: { $0.role == .user })?.userPresentation?.choiceRecord,
              answer.confirmed, answer.selections.contains(where: { $0.values.contains(label) }) else {
            throw GateBlocked("The native cover answer did not reach the actual conversation as its structured choice.")
        }
    }
}
