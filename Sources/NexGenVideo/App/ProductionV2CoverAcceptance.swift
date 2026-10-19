import AppKit
import NexGenEngine

@MainActor
enum ProductionV2CoverAcceptance {
    struct Format: Sendable {
        let id: String
        let title: String
        let aspect: String
        let width: Int
        let height: Int
    }
    static let formats = [Format(id: "square", title: "Square", aspect: "1:1", width: 640, height: 640),
        Format(id: "landscape", title: "Landscape", aspect: "16:9", width: 640, height: 360),
        Format(id: "portrait", title: "Portrait", aspect: "9:16", width: 360, height: 640)]

    static func run(context: ProductionPlanningAcceptanceFixture.Context, generation: ProductionV2GenerationAcceptance,
                    driver: ProductionVisualSourcesDriver, output: URL) async throws -> [String: Any] {
        let editor = context.editor, root = context.dataRoot, window = driver.window
        guard editor.declaredPluginName == "musicvideo", editor.projectState?.isComplete == true,
              editor.workingRoot != nil, editor.agentService.currentSessionId != nil else {
            throw GateBlocked("Cover acceptance requires the genuinely completed Music Video workflow.")
        }
        let before = try await ProductionCoverOwnerEvidence.pipeline(root: root, output: output, label: "before")
        try driver.record("native cover formats begin", fields: ["pipeline": before, "liveProvider": false])
        let discovery = try await ManualGenerationDiscovery.images(session: generation.session, catalog: generation.catalog)
        try driver.record("native cover catalog", fields: discovery)
        try await ProductionNativeDisclosureAcceptance.toggle("export.cover.open", content: "export.cover.start", expanded: true, driver: driver, in: window)
        try await driver.wait("optional cover entry ready") { driver.state("export.cover.start", in: window) == true }
        let priorMessages = Set(editor.agentService.messages.map(\.id))
        try await driver.click("export.cover.start", in: window)
        try await driver.wait("cover utility actually handed to runtime") {
            editor.workspaceFocus == .production && !editor.agentService.isStreaming
                && editor.agentService.messages.contains { !priorMessages.contains($0.id) && $0.role == .assistant }
        }
        try await decide(title: "Which platforms need cover artwork?", section: "format",
            options: formats.map { ($0.id, $0.title + " — " + $0.aspect) }, selected: formats.map(\.id),
            context: context, driver: driver)
        var kept: [[String: Any]] = []
        for format in formats {
            try await decide(title: "Choose the " + format.title.lowercased() + " cover subject", section: "subject",
                options: [("abstract", "Abstract style image"), ("location", "Location motif")], selected: ["abstract"], context: context, driver: driver)
            let clean = try await generate(format: format, reference: nil, artist: nil, title: nil,
                context: context, generation: generation, driver: driver)
            kept.append(clean.evidence)
            let typography = format.id == "landscape"
            try await decide(title: "Create a second " + format.title.lowercased() + " variant with artist and title?", section: "typography",
                options: [("yes", "Yes"), ("no", "No — keep the clean cover")], selected: [typography ? "yes" : "no"], context: context, driver: driver)
            if typography {
                let artist = try await text(title: "Enter the exact artist name", value: "NATIVE ARTIST", label: "Artist", context: context, driver: driver)
                let title = try await text(title: "Enter the exact cover title", value: "NIGHT SIGNAL", label: "Title", context: context, driver: driver)
                let variant = try await generate(format: format, reference: clean.asset, artist: artist, title: title,
                    context: context, generation: generation, driver: driver)
                kept.append(variant.evidence)
            }
        }
        let after = try await ProductionCoverOwnerEvidence.pipeline(root: root, output: output, label: "after")
        guard before == after, editor.projectState?.isComplete == true,
              let main = kept.first(where: { $0["key"] as? String == "square-clean" }),
              let mainID = main["assetID"] as? String, let mainSHA = main["sha256"] as? String,
              let mainPackage = main["packageSHA256"] as? String else {
            throw GateBlocked("The optional cover utility changed the approved production pipeline.")
        }
        try driver.record("native cover formats completed", fields: ["pipeline": after, "kept": kept,
            "liveProvider": false, "claim": "Real native choices, exact uploaded clean reference and downloaded image bytes; isolated provider pixels do not prove live model typography quality."])
        try driver.record("native optional cover completed", fields: ["assetID": mainID, "packageSHA256": mainPackage,
            "imageSHA256": mainSHA, "format": "square", "cleanCoverKept": true, "typographyExplicitlyDeclined": true])
        return ["nativeCoverEntry": true, "nativeFormatSubjectModel": true, "nativeCoverSpendApproval": true,
            "actualCoverDownloadedAndPreviewed": true, "nativeKeepDecision": true, "typographyExplicitlyDeclined": true,
            "nativeThreeFormats": true, "nativeExplicitTypography": true, "pipelineUnchanged": true,
            "assetID": mainID, "sha256": mainSHA, "kept": kept, "liveProvider": false]
    }

    private static func generate(format: Format, reference: MediaAsset?, artist: String?, title: String?,
        context: ProductionPlanningAcceptanceFixture.Context, generation: ProductionV2GenerationAcceptance,
        driver: ProductionVisualSourcesDriver) async throws -> (asset: MediaAsset, evidence: [String: Any]) {
        let editor = context.editor, window = driver.window, typography = reference != nil
        guard let home = editor.workingRoot, let sessionID = editor.agentService.currentSessionId else { throw GateBlocked("The cover project closed.") }
        let modelID = typography ? "fal-ai/gemini-25-flash-image/edit" : "fal-ai/flux/schnell"
        let offerings = generation.catalog.imageOfferingEvaluation(preferredModelID: modelID, aspectRatio: format.aspect,
            resolution: nil, quality: nil, referenceCount: typography ? 1 : 0, activation: generation.activation).offerings
        guard let offering = offerings.first(where: { $0.model.id == modelID && $0.target.provider == .fal }) else {
            throw GateBlocked("The actual isolated catalog has no executable cover route for this format and reference count.")
        }
        let options: [(String, String)]
        if typography { options = [("selected", offering.model.displayName), ("omit", "Keep the clean cover without typography")] }
        else {
            guard let alternative = offerings.first(where: { $0.model.id == "fal-ai/flux/dev" && $0.target.provider == .fal }) else { throw GateBlocked("The alternate cover model is not offered.") }
            options = [("selected", offering.model.displayName), ("alternate", alternative.model.displayName)]
        }
        try await decide(title: "Choose the " + format.title.lowercased() + (typography ? " typography model" : " cover model"), section: "model",
            options: options, selected: ["selected"], context: context, driver: driver)
        let key = format.id + (typography ? "-typography" : "-clean")
        let name = "Cover — " + format.title + (typography ? " — Artist + Title" : " — Clean")
        let fixture = try ProductionCoverOwnerEvidence.fixture(format: format, artist: artist, title: title)
        if typography { try MusicvideoGenerationHTTP.installFrameImage(endpoint: modelID, output: fixture, referenceCount: 1) }
        else { try MusicvideoGenerationHTTP.installCover(endpoint: modelID, output: fixture) }
        let intent: String
        if let artist, let title, typography {
            intent = "Keep the reference cover composition, motif and colours. Integrate the exact artist wording \"" + artist + "\" and exact title wording \"" + title + "\" as clear readable typography. Do not add any other text."
        } else {
            let constraint = format.id == "portrait" ? "Vertical composition with the lower 15 percent and right edge clear." : format.id == "landscape" ? "Off-centre subject, clear negative space, readable at thumbnail size." : "Square composition with clear negative space."
            intent = "An abstract cover with one coloured shape, hard side light and pale background. " + constraint + " No text or lettering."
        }
        let compiled = try await PromptCompiler.compile(intent: intent, modelId: modelID, modality: .image, aspectRatio: format.aspect,
            editor: editor, shotId: "none", modelCatalog: generation.catalog)
        let references = reference.map { [$0] } ?? []
        let request = GenerationRequest(modality: .image, modelId: modelID, intent: compiled.text, aspectRatio: format.aspect,
            placement: .mediaLibrary(folderId: nil), origin: .agentTool, target: offering.target,
            precompiled: (compiled.text, compiled.token, compiled.binding), submission: .image(make: { text in
                var input = GenerationInput(prompt: text, model: modelID, duration: 0, aspectRatio: format.aspect)
                input.promptShotId = compiled.binding.shotId; input.promptProjectKey = compiled.binding.projectKey
                input.promptShotFingerprint = compiled.binding.shotFingerprint
                return ImageGenerationSubmission.make(genInput: input, model: offering.model, references: references, name: name, numImages: 1)
            }))
        let prepared = try await GenerationController.prepare(request, editor: editor).get()
        let noPrice: GenerationBudgetGuard.QuoteLoader = { _, _ in throw GenerationBackendError.transport("The isolated cover HTTP provider has no monetary quote.") }
        let package = try await GenerationController.prepareReviewPackage(prepared, editor: editor, quoteLoader: noPrice)
        if let references = prepared.references { try await GenerationPackageInputs.persist(package: package, snapshot: references, editor: editor) }
        let item = GenerationBatch.Item(id: UUID().uuidString, purpose: "Create " + name, package: package)
        let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: package.payload.binding.projectKey, phase: nil, items: [item]))
        let option = SpendOption(modelId: modelID, modelName: offering.model.displayName, target: offering.target,
            credits: nil, requiresCatalogAvailability: true, generationPackage: package)
        editor.generationBatchCoordinator.quoteLoader = noPrice
        _ = try editor.agentService.presentGenerationBatch(batch, recoveries: [item.id: GenerationBatchRecovery(options: [option]) { current, _ in
            try await GenerationController.prepareReviewPackage(prepared, editor: current, quoteLoader: noPrice)
        }], origin: .inAppChat(sessionID: sessionID), editor: editor)
        try await driver.wait("cover generation approval visible") { driver.state("generation-batch.approve", in: window) == true }
        guard MusicvideoGenerationHTTP.requests.isEmpty else { throw GateBlocked("The cover provider started before native spend approval.") }
        try driver.capture("cover-" + key + "-unapproved", target: window)
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
              asset.libraryDisplayName == name, asset.pendingDownloadURL == nil,
              asset.generationInput?.generationPackageID == package.id,
              MusicvideoGenerationHTTP.submittedPrompt == compiled.text, MusicvideoGenerationHTTP.unexpectedRequests.isEmpty else {
            throw GateBlocked(stored.journal.executions.first?.detail ?? "The cover output is not bound to its actual approved image request.")
        }
        let evidence = try await ProductionCoverOwnerEvidence.retain(asset: asset, reference: reference, format: format, key: key,
            expected: fixture, artist: artist, title: title, batch: stored, package: package, home: home, output: driver.output)
        try await driver.click("editor.workspace.edit", in: window, enabled: false)
        try await driver.wait("cover library visible") { editor.workspaceFocus == .edit }
        try await driver.click("media.asset." + assetID, in: window)
        try await driver.wait("actual generated cover preview") { editor.activePreviewTab.id == PreviewTab.mediaAssetTabId(for: assetID) }
        try driver.capture("cover-" + key + "-preview", target: window)
        try await driver.click("editor.workspace.production", in: window, enabled: false)
        try await driver.wait("return to cover decision") { editor.workspaceFocus == .production }
        try await decide(title: "Keep " + name + "?", section: "review", options: [("keep", "Keep"), ("revise", "Revise subject or model"), ("skip", "Skip this format")],
            selected: ["keep"], context: context, driver: driver)
        try driver.record("native cover output kept", fields: evidence)
        return (asset, evidence)
    }

    private static func text(title: String, value: String, label: String, context: ProductionPlanningAcceptanceFixture.Context,
        driver: ProductionVisualSourcesDriver) async throws -> String {
        let service = context.editor.agentService
        guard let session = service.currentSessionId else { throw GateBlocked("The cover text has no current conversation.") }
        let result = await context.executor.execute(name: "show_dialog", args: ["title": title, "symbol": "textformat", "sections": [],
            "textField": ["placeholder": label, "multiline": false], "confirmLabel": "Continue"],
            origin: .inAppChat(sessionID: session), toolUseID: "native-cover-" + UUID().uuidString)
        guard !result.isError else { throw GateBlocked("The actual cover text dialog was rejected.") }
        try await driver.wait("cover text visible") { driver.text("agent.dialog.title", in: driver.window) == title }
        guard driver.text("agent.dialog.direction", in: driver.window) == "" else { throw GateBlocked("The artist or title was inferred before native entry.") }
        try await driver.fill("agent.dialog.direction", value: value, in: driver.window, requireFocusExit: true)
        try driver.capture("cover-explicit-" + label.lowercased(), target: driver.window)
        try await driver.click("agent.dialog.confirm", in: driver.window)
        try await driver.wait("cover text received") { service.pendingDialog == nil && !service.isStreaming }
        guard let user = service.messages.last(where: { $0.role == .user }), user.userPresentation?.typedText == value else {
            throw GateBlocked("The exact typed cover wording did not reach the current conversation.")
        }
        let retained = try await ProductionCoverOwnerEvidence.turn(user, output: driver.output)
        try driver.record("native explicit cover wording", fields: ["label": label, "value": value, "messageID": user.id.uuidString, "turn": retained])
        return value
    }

    private static func decide(title: String, section: String, options: [(String, String)], selected: [String],
        context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver) async throws {
        let service = context.editor.agentService
        guard let session = service.currentSessionId, !selected.isEmpty, Set(selected).count == selected.count,
              selected.allSatisfy({ id in options.contains(where: { $0.0 == id }) }) else { throw GateBlocked("The cover decision has no actual session or options.") }
        let result = await context.executor.execute(name: "show_dialog", args: ["title": title, "symbol": "photo",
            "sections": [["id": section, "label": title, "type": "choices", "multiSelect": selected.count > 1,
                "options": options.map { ["id": $0.0, "label": $0.1] }]], "confirmLabel": "Continue"],
            origin: .inAppChat(sessionID: session), toolUseID: "native-cover-" + UUID().uuidString)
        guard !result.isError else { throw GateBlocked("The genuine cover dialog tool rejected its decision.") }
        try await driver.wait("cover decision visible") { driver.text("agent.dialog.title", in: driver.window) == title }
        for choice in selected {
            let id = "agent.dialog.choice." + section + "." + choice
            guard driver.text(id, in: driver.window) == "unselected" else { throw GateBlocked("The cover choice was selected before native input.") }
            try await driver.click(id, in: driver.window)
            try await driver.wait("cover option selected natively") { driver.text(id, in: driver.window) == "selected" }
        }
        try driver.capture("cover-choice-" + section, target: driver.window)
        try await driver.click("agent.dialog.confirm", in: driver.window)
        try await driver.wait("cover decision received") { service.pendingDialog == nil && !service.isStreaming }
        let labels = options.filter { selected.contains($0.0) }.map(\.1)
        guard let user = service.messages.last(where: { $0.role == .user }), let answer = user.userPresentation?.choiceRecord,
              answer.confirmed, answer.selections.contains(where: { $0.values == labels }) else {
            throw GateBlocked("The native cover answer did not reach the actual conversation as its structured choice.")
        }
        let retained = try await ProductionCoverOwnerEvidence.turn(user, output: driver.output)
        try driver.record("native cover decision", fields: ["section": section, "selected": selected, "labels": labels, "messageID": user.id.uuidString, "turn": retained])
    }
}
