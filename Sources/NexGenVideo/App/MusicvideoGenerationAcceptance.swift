import AppKit
import Foundation
import NexGenEngine
import os

@MainActor
enum MusicvideoGenerationAcceptance {
    struct Receipt: Codable {
        let providerEvidence: String
        let batchID: String
        let packageID: String
        let takeID: String
        let generationAssetID: String
        let compiledPromptSHA256: String
        let referenceSHA256: String
        let outputSHA256: String
        let generatedShotIDs: [String]
        let importedShotIDs: [String]
        let submitCount: Int
        let pollCount: Int
        let resultCount: Int
        let downloadCount: Int
        let uploadCount: Int
        let unexpectedRequestCount: Int
        let selectedSourceSHA256: String
        let requestMethods: [String]
        let spendEvents: [String]
        let generatedSourceStartFrame: Int
        let generatedSourceEndFrame: Int
        let totalFrames: Int
        let nativeInteractions: [NativeInteraction]
        let nativeApproval: NativeApproval
        let nativeTakeReview: NativeTakeReview
        let nativeScreenshots: [String]
    }

    struct NativeInteraction: Codable {
        let index: Int
        let controlID: String
        let windowNumber: Int
        let documentWindowNumber: Int
        let frame: [Double]
        let viewport: [Double]
        let before: String
        let after: String
    }

    struct NativeApproval: Codable {
        let authorityBefore: Bool
        let journalCountBefore: Int
        let requestCountBefore: Int
        let spendCountBefore: Int
        let authorityAfterID: String
        let approvedPackageSHA256: String
        let pricingOverrideItemIDs: [String]
        let continuationPhases: [String]
        let continuationHidden: Bool
    }

    struct NativeTakeReview: Codable {
        let takeIDBefore: String
        let takeIDAfter: String
        let findingsBefore: Int
        let findings: [TakeReview.Finding]
        let selectedTakeIDBefore: String?
        let selectedTakeIDAfter: String
        let reviewSHA256: String
    }

    private final class Run {
        var batchID: String?
        var packageID: String?
        var takeID: String?
        var assetID: String?
        var promptSHA256: String?
        var referenceSHA256: String?
        var outputSHA256: String?
        var interactions: [NativeInteraction] = []
        var approval: NativeApproval?
        var takeReview: NativeTakeReview?
    }

    static func makeDocument(evidenceURL: URL) async throws -> (document: VideoProject, fixture: FullflowAcceptanceFixture.Receipt, generation: Receipt) {
        guard WorkspaceUIAcceptance.isRequested else {
            throw FullflowAcceptanceFixture.Failure("The simulated provider is available only in explicit UI acceptance.")
        }
        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries)
        let activation = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
        let modelID = "bytedance/seedance-2.5/reference-to-video"
        let candidates = catalog.productionRouteCandidates(activation: activation).filter { $0.modelID == modelID }
        guard let candidate = candidates.first,
              let mode = candidate.candidate.inputSlots.first(where: { $0.id == CoreReferenceInputSlotIDV1.referenceImage })?.modeIDs.first,
              let model = catalog.video.first(where: { $0.id == modelID }) else {
            throw FullflowAcceptanceFixture.Failure("The simulator's reference-video route is unavailable.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MusicvideoGenerationHTTP.self]
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); MusicvideoGenerationHTTP.clear() }
        let run = Run()
        let makeExecutor: @MainActor (EditorViewModel) -> ToolExecutor = { editor in
            ToolExecutor(editor: editor, providerActivation: { activation }, modelCatalog: catalog,
                productionRouteCandidates: { _ in candidates }, catalogReadiness: { true }, isModelEnabled: { _ in true })
        }
        let scenario = FullflowAcceptanceFixture.GeneratedShotScenario(modeID: mode, makeExecutor: makeExecutor) { editor, outputURL in
            guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else {
                throw FullflowAcceptanceFixture.Failure("The generation project is not open.")
            }
            let outputBytes = try Data(contentsOf: outputURL)
            let referenceBytes = try Data(contentsOf: root.appendingPathComponent("bible/stage.png"))
            try MusicvideoGenerationHTTP.install(endpoint: modelID, output: outputBytes)
            editor.generationService.reconciliation = ProviderRunReconciliation(session: session,
                providerKey: { $0 == .fal ? "simulator-only-key" : nil }, falCharge: { _, _, _ in nil })
            let coordinator = editor.generationBatchCoordinator
            coordinator.catalogReadiness = {}
            coordinator.providerActivation = { activation }
            coordinator.modelCatalog = catalog
            let executor = makeExecutor(editor)
            let selection = try PipelineProductionRouting.resolveAndWrite(shotID: "s001", dataRoot: root,
                activation: activation, candidateProvider: { _ in candidates },
                declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
            let inputs = try await executor.productionVideoInputs(selection: selection, editor: editor, dataRoot: root)
            let projection = try PromptCompiler.currentShotProjection(editor: editor, shotId: "s001")
            let compiled = try await PromptCompiler.compile(intent: "A centered marker moves across a warm field.",
                modelId: modelID, modality: .video, aspectRatio: "16:9", durationSeconds: 4,
                editor: editor, shotId: "s001", shot: projection, modelCatalog: catalog)
            let request = GenerationRequest(modality: .video, modelId: modelID, intent: compiled.text,
                aspectRatio: "16:9", durationSeconds: 4, outputResolution: "720p",
                placement: .mediaLibrary(folderId: nil), origin: .agentTool, target: selection.target,
                precompiled: (compiled.text, compiled.token, compiled.binding), submission: .video(make: { text in
                    var input = GenerationInput(prompt: text, model: modelID, duration: 4, aspectRatio: "16:9", resolution: "720p")
                    input.videoDuration = .seconds(4)
                    input.promptShotId = compiled.binding.shotId
                    input.promptProjectKey = compiled.binding.projectKey
                    input.promptShotFingerprint = compiled.binding.shotFingerprint
                    input.productionRouting = inputs.routingProof
                    return VideoGenerationSubmission.make(genInput: input, model: model,
                        offeringCapabilities: inputs.offeringCapabilities, inputAssets: inputs.assets,
                        placeholderDuration: 4, name: "HTTP simulator · s001", generateAudio: false)
                }))
            let prepared = try await GenerationController.prepare(request, editor: editor).get()
            let noPrice: GenerationBudgetGuard.QuoteLoader = { _, _ in
                throw GenerationBackendError.transport("The HTTP simulator has no monetary quote.")
            }
            let package = try await GenerationController.prepareReviewPackage(prepared, editor: editor, quoteLoader: noPrice)
            guard let references = prepared.references, MusicvideoGenerationHTTP.requests.isEmpty,
                  editor.generationLog.spendEvents.isEmpty else {
                throw FullflowAcceptanceFixture.Failure("Preparation dispatched or reserved an unapproved generation.")
            }
            try await GenerationPackageInputs.persist(package: package, snapshot: references, editor: editor)
            let item = GenerationBatch.Item(id: UUID().uuidString, purpose: "Generate the first Musicvideo shot", package: package)
            let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: package.payload.binding.projectKey,
                phase: "render", items: [item]))
            coordinator.quoteLoader = noPrice
            let window = try MusicvideoNativeAcceptance.window(for: editor)
            guard let sessionID = editor.agentService.currentSessionId else {
                throw FullflowAcceptanceFixture.Failure("The real document has no recording-runtime chat session.")
            }
            let option = SpendOption(modelId: modelID, modelName: model.displayName, target: selection.target,
                credits: nil, requiresCatalogAvailability: true, generationPackage: package)
            _ = try editor.agentService.presentGenerationBatch(batch,
                recoveries: [item.id: GenerationBatchRecovery(options: [option]) { currentEditor, _ in
                    try await GenerationController.prepareReviewPackage(prepared, editor: currentEditor, quoteLoader: noPrice)
                }], origin: .inAppChat(sessionID: sessionID), editor: editor)
            try await MusicvideoNativeAcceptance.waitUntil {
                WorkspaceUIAcceptance.probeState(identifier: "generation-batch.approve", in: window) == true
            }
            let before = try GenerationBatchStore.all(home: home)
            let requestsBefore = MusicvideoGenerationHTTP.requests.count
            let spendBefore = editor.generationLog.spendEvents.count
            let runtimePhasesBefore = try MusicvideoNativeAcceptance.recordedPhases(for: editor)
            guard before.isEmpty, requestsBefore == 0, spendBefore == 0,
                  coordinator.pending?.id == batch.id, coordinator.startsApprovedBatches else {
                throw FullflowAcceptanceFixture.Failure("The visible batch created authority, spend or HTTP work before its native approval.")
            }
            try capture(window, name: "generation-batch-approval", evidenceURL: evidenceURL)
            try await interact("generation-batch.approve", in: window, documentWindow: window,
                before: "unapproved", run: run) {
                try await MusicvideoNativeAcceptance.click("generation-batch.approve", in: window)
                try await MusicvideoNativeAcceptance.waitUntil {
                    (try? GenerationBatchStore.load(id: batch.id, home: home).authorityAvailable) == true
                }
                guard let authority = try GenerationBatchStore.load(id: batch.id, home: home).journal.authorityID else {
                    throw FullflowAcceptanceFixture.Failure("The native approval did not persist execution authority.")
                }
                return authority
            }
            guard await WorkspaceUIAcceptance.waitUntil(timeout: .seconds(30), {
                guard let stored = try? GenerationBatchStore.load(id: batch.id, home: home),
                      let state = stored.journal.executions.first?.state else { return false }
                return [.complete, .blocked, .failed, .canceled].contains(state) && coordinator.activeBatchID == nil
                    && !editor.agentService.isStreaming
            }) else { throw FullflowAcceptanceFixture.Failure("The native-approved batch did not settle through its coordinator.") }
            try await MusicvideoNativeAcceptance.waitUntil {
                (try? MusicvideoNativeAcceptance.recordedPhases(for: editor).count) == runtimePhasesBefore.count + 1
                    && !editor.agentService.isStreaming
            }
            let continuationPhases = Array(try MusicvideoNativeAcceptance.recordedPhases(for: editor).dropFirst(runtimePhasesBefore.count))
            let continuationHidden = editor.agentService.messages.last(where: { $0.role == .user })
                .map { $0.hidden && $0.userPresentation == nil } == true
            guard continuationPhases == ["render"], continuationHidden else {
                throw FullflowAcceptanceFixture.Failure("The batch did not continue Render through exactly one hidden recording-runtime turn.")
            }
            let completedBatch = try GenerationBatchStore.load(id: batch.id, home: home)
            guard completedBatch.journal.executions.first?.state == .complete,
                  let assetID = completedBatch.journal.executions.first?.outputAssetIDs.first,
                  let asset = editor.mediaAssets.first(where: { $0.id == assetID }),
                  asset.pendingDownloadURL == nil, asset.generationInput?.generationPackageID == package.id,
                  let transaction = asset.generationInput?.spendTransactionId,
                  try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: outputBytes) else {
                throw FullflowAcceptanceFixture.Failure("The native-approved provider output was not finalized: \(completedBatch.journal.executions.first?.detail ?? "missing exact package output").")
            }
            guard let authorityID = completedBatch.journal.authorityID,
                  completedBatch.batch.payload.items.first?.package == package,
                  completedBatch.journal.pricingOverrideItemIDs == [item.id] else {
                throw FullflowAcceptanceFixture.Failure("The native approval changed its package or unknown-price permission.")
            }
            run.approval = NativeApproval(authorityBefore: before.contains(where: \.authorityAvailable),
                journalCountBefore: before.count, requestCountBefore: requestsBefore, spendCountBefore: spendBefore,
                authorityAfterID: authorityID, approvedPackageSHA256: package.id,
                pricingOverrideItemIDs: completedBatch.journal.pricingOverrideItemIDs ?? [],
                continuationPhases: continuationPhases, continuationHidden: continuationHidden)
            let events = editor.generationLog.spendEvents.filter { $0.transactionId == transaction }
            guard events.map(\.kind) == [.reserved, .submitted, .settled],
                  events.first(where: { $0.kind == .submitted })?.providerRequestId == MusicvideoGenerationHTTP.requestID,
                  events.allSatisfy({ $0.money == nil }),
                  MusicvideoGenerationHTTP.uploadedReference == referenceBytes,
                  MusicvideoGenerationHTTP.submittedPrompt == compiled.text,
                  MusicvideoGenerationHTTP.submittedEnvelopeMatches,
                  completedBatch.journal.executions.first?.state == .complete,
                  completedBatch.journal.executions.first?.outputAssetIDs == [asset.id],
                  MusicvideoGenerationHTTP.unexpectedRequests.isEmpty else {
                throw FullflowAcceptanceFixture.Failure("The real provider path lost its prompt, reference bytes or spend receipt.")
            }
            let recorded = await executor.execute(name: "record_render", args: ["phase": "final", "shot_id": "s001", "output": asset.id])
            try requireOK(recorded, operation: "record_render")
            let takeID = PipelineRenderTakeStore.identity(eventID: asset.id, outputSHA256: FileDigest.sha256(of: outputBytes))
            let snapshot = try await TakeReview.capture(takeID: takeID, home: home)
            guard abs(snapshot.durationSeconds - 4) < 1.0 / 30 else {
                throw FullflowAcceptanceFixture.Failure("The generated take does not include both one-second handles.")
            }
            run.takeReview = try await reviewTake(snapshot, editor: editor, window: window, run: run, evidenceURL: evidenceURL)
            run.batchID = batch.id; run.packageID = package.id; run.takeID = takeID; run.assetID = asset.id
            run.promptSHA256 = FileDigest.sha256(of: Data(compiled.text.utf8))
            run.referenceSHA256 = FileDigest.sha256(of: referenceBytes); run.outputSHA256 = FileDigest.sha256(of: outputBytes)
        }
        let (document, fixture) = try await FullflowAcceptanceFixture.makeDocument(evidenceURL: evidenceURL, generatedShot: scenario)
        let editor = document.editorViewModel
        guard let assembly = try PipelineAssemblyStore.load(dataRoot: fixture.dataRoot),
              let generated = assembly.plan.selectedMedia.first(where: { $0.shotID == "s001" }),
              let imported = assembly.plan.selectedMedia.first(where: { $0.shotID == "s002" }),
              generated.sourceKind == .generatedTake, imported.sourceKind == .importedSource,
              generated.sourceStartFrame == 30, generated.sourceEndFrame == 90,
              imported.sourceStartFrame == 0, imported.sourceEndFrame == 69,
              fixture.totalFrames == 129,
              let batchID = run.batchID, let packageID = run.packageID, let takeID = run.takeID,
              let assetID = run.assetID, let promptSHA256 = run.promptSHA256,
              let referenceSHA256 = run.referenceSHA256, let outputSHA256 = run.outputSHA256,
              let nativeApproval = run.approval, let nativeTakeReview = run.takeReview,
              generated.takeID == takeID, generated.sourceSHA256 == outputSHA256,
              editor.timeline.tracks.flatMap(\.clips).contains(where: { $0.mediaRef == assetID && $0.trimStartFrame == 30 && $0.durationFrames == 60 }) else {
            throw FullflowAcceptanceFixture.Failure("Mixed assembly must select the reviewed generated take and trim its handles while preserving imported footage and all 129 song frames.")
        }
        return (document, fixture, Receipt(providerEvidence: "Real FalClient HTTP against a deny-by-default simulator; no live provider or model-quality evidence. Creative and review decisions are supplied fixture inputs.",
            batchID: batchID, packageID: packageID, takeID: takeID, generationAssetID: assetID,
            compiledPromptSHA256: promptSHA256, referenceSHA256: referenceSHA256, outputSHA256: outputSHA256,
            generatedShotIDs: assembly.plan.selectedMedia.filter { $0.sourceKind == .generatedTake }.map(\.shotID),
            importedShotIDs: assembly.plan.selectedMedia.filter { $0.sourceKind == .importedSource }.map(\.shotID),
            submitCount: MusicvideoGenerationHTTP.requests.filter { $0.method == "POST" && $0.url.hasPrefix("https://queue.fal.run/") }.count,
            pollCount: MusicvideoGenerationHTTP.requests.filter { $0.url.hasSuffix("/status") }.count,
            resultCount: MusicvideoGenerationHTTP.requests.filter { $0.url.hasSuffix("/requests/" + MusicvideoGenerationHTTP.requestID) }.count,
            downloadCount: MusicvideoGenerationHTTP.requests.filter { $0.url == "https://media.invalid/fullflow.mov" }.count,
            uploadCount: MusicvideoGenerationHTTP.requests.filter { $0.method == "PUT" }.count,
            unexpectedRequestCount: MusicvideoGenerationHTTP.unexpectedRequests.count,
            selectedSourceSHA256: generated.sourceSHA256,
            requestMethods: MusicvideoGenerationHTTP.requests.map { $0.method }, spendEvents: editor.generationLog.spendEvents.map { $0.kind.rawValue },
            generatedSourceStartFrame: generated.sourceStartFrame, generatedSourceEndFrame: generated.sourceEndFrame, totalFrames: fixture.totalFrames,
            nativeInteractions: run.interactions, nativeApproval: nativeApproval, nativeTakeReview: nativeTakeReview,
            nativeScreenshots: ["generation-batch-approval", "generation-take-review", "generation-take-selected"].map(screenshotName)))
    }

    private static func reviewTake(_ snapshot: TakeReview.Snapshot, editor: EditorViewModel, window: NSWindow,
                                   run: Run, evidenceURL: URL) async throws -> NativeTakeReview {
        guard let root = DataRootResolver.dataRoot(of: snapshot.home) else {
            throw FullflowAcceptanceFixture.Failure("The take's project closed before native review.")
        }
        func selectedTake() throws -> String? {
            try PipelineRenderTakeStore.load(dataRoot: root, project: snapshot.take.project,
                phase: snapshot.take.phase).selected[snapshot.take.shotID]
        }
        let selectedBefore = try selectedTake()
        let findingsBefore = try TakeReview.load(take: snapshot.take, dataRoot: root)?.findings.count ?? 0
        guard selectedBefore == nil, findingsBefore == 0 else {
            throw FullflowAcceptanceFixture.Failure("The generated take was selected or reviewed before native input.")
        }
        try await interact("take.open", in: window, documentWindow: window, before: "closed", run: run) {
            try await MusicvideoNativeAcceptance.click("take.open", in: window)
            try await MusicvideoNativeAcceptance.waitUntil {
                guard let sheet = window.attachedSheet else { return false }
                return WorkspaceUIAcceptance.probeText(identifier: "take.picker", in: sheet) != nil
            }
            return "open"
        }
        guard let sheet = window.attachedSheet,
              let pickerBefore = WorkspaceUIAcceptance.probeText(identifier: "take.picker", in: sheet), pickerBefore.isEmpty else {
            throw FullflowAcceptanceFixture.Failure("The real take review sheet did not start with an explicit choice.")
        }
        try await choose("take.picker", index: 1, expected: snapshot.take.id, in: sheet, documentWindow: window, run: run)
        try await MusicvideoNativeAcceptance.waitUntil {
            WorkspaceUIAcceptance.probeText(identifier: "take.pass", in: sheet) == TakeReview.Pass.identity.rawValue
        }
        guard WorkspaceUIAcceptance.probeState(identifier: "take.use", in: sheet) == false,
              WorkspaceUIAcceptance.probeState(identifier: "take.record-pass", in: sheet) == false else {
            throw FullflowAcceptanceFixture.Failure("An unreviewed take or empty finding can be accepted in the native sheet.")
        }
        var expectedFindings: [TakeReview.Finding] = []
        for (index, pass) in TakeReview.Pass.allCases.enumerated() {
            guard WorkspaceUIAcceptance.probeText(identifier: "take.pass", in: sheet) == pass.rawValue else {
                throw FullflowAcceptanceFixture.Failure("The native take review skipped or reordered its passes.")
            }
            let verdict: TakeReview.Verdict = pass == .identity ? .conforms : .acceptedDeviation
            if pass == .identity {
                try await choose("take.verdict", index: 1, expected: TakeReview.Verdict.rejected.rawValue,
                    in: sheet, documentWindow: window, run: run)
            }
            try await choose("take.verdict", index: pass == .identity ? 0 : 2, expected: verdict.rawValue,
                in: sheet, documentWindow: window, run: run)
            let observation = "Supplied acceptance decision: \(pass.rawValue) uses the deterministic moving marker; the synthetic scene and muted provider audio are intentional."
            try await fill("take.observation", value: observation, expected: observation, in: sheet, documentWindow: window, run: run)
            try await fill("take.start", value: "1", expected: "1.0", in: sheet, documentWindow: window, run: run)
            try await fill("take.end", value: "3", expected: "3.0", in: sheet, documentWindow: window, run: run)
            expectedFindings.append(.init(pass: pass, verdict: verdict, observation: observation, startSeconds: 1, endSeconds: 3))
            try await interact("take.record-pass", in: sheet, documentWindow: window, before: String(index), run: run) {
                try await MusicvideoNativeAcceptance.click("take.record-pass", in: sheet)
                try await MusicvideoNativeAcceptance.waitUntil {
                    if index + 1 < TakeReview.Pass.allCases.count {
                        return WorkspaceUIAcceptance.probeText(identifier: "take.record-pass", in: sheet) == String(index + 1)
                    }
                    return WorkspaceUIAcceptance.probeText(identifier: "take.save", in: sheet) == String(index + 1)
                }
                return String(index + 1)
            }
        }
        guard await WorkspaceUIAcceptance.revealProbe("take.save", in: sheet) else {
            throw FullflowAcceptanceFixture.Failure("The completed native review cannot reach Save.")
        }
        try capture(sheet, name: "generation-take-review", evidenceURL: evidenceURL)
        try await interact("take.save", in: sheet, documentWindow: window, before: String(findingsBefore), run: run) {
            try await MusicvideoNativeAcceptance.click("take.save", in: sheet)
            try await MusicvideoNativeAcceptance.waitUntil {
                (try? TakeReview.load(take: snapshot.take, dataRoot: root)?.findings) == expectedFindings
                    && WorkspaceUIAcceptance.probeState(identifier: "take.use", in: sheet) == true
            }
            return String(expectedFindings.count)
        }
        try await interact("take.use", in: sheet, documentWindow: window, before: selectedBefore ?? "none", run: run) {
            try await MusicvideoNativeAcceptance.click("take.use", in: sheet)
            try await MusicvideoNativeAcceptance.waitUntil { (try? selectedTake()) == snapshot.take.id }
            return try selectedTake() ?? "none"
        }
        try capture(sheet, name: "generation-take-selected", evidenceURL: evidenceURL)
        guard let review = try TakeReview.load(take: snapshot.take, dataRoot: root), review.accepted,
              review.findings == expectedFindings, let selectedAfter = try selectedTake(),
              selectedAfter == snapshot.take.id else {
            throw FullflowAcceptanceFixture.Failure("Native take review or selection did not persist its exact findings and take.")
        }
        let reviewHash = try FileDigest.sha256(of: root.appendingPathComponent(TakeReview.path(takeID: snapshot.take.id)))
        try await interact("take.close", in: sheet, documentWindow: window, before: "open", run: run) {
            try await MusicvideoNativeAcceptance.click("take.close", in: sheet)
            try await MusicvideoNativeAcceptance.waitUntil { window.attachedSheet == nil }
            return "closed"
        }
        return NativeTakeReview(takeIDBefore: pickerBefore, takeIDAfter: review.takeID,
            findingsBefore: findingsBefore, findings: review.findings, selectedTakeIDBefore: selectedBefore,
            selectedTakeIDAfter: selectedAfter, reviewSHA256: reviewHash)
    }

    private static func interact(_ identifier: String, in window: NSWindow, documentWindow: NSWindow,
                                 before: String, run: Run, action: () async throws -> String) async throws {
        try await MusicvideoNativeAcceptance.waitUntil {
            WorkspaceUIAcceptance.probeState(identifier: identifier, in: window) == true
        }
        guard window === documentWindow || window.sheetParent === documentWindow,
              window.isVisible, await WorkspaceUIAcceptance.revealProbe(identifier, in: window),
              let frame = WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: window),
              let viewport = window.contentView?.bounds, viewport.insetBy(dx: -1, dy: -1).contains(frame),
              frame.width > 0, frame.height > 0,
              WorkspaceUIAcceptance.probeState(identifier: identifier, in: window) == true else {
            throw FullflowAcceptanceFixture.Failure("The actual document control is disabled, clipped or missing: \(identifier).")
        }
        let windowNumber = window.windowNumber
        let documentWindowNumber = documentWindow.windowNumber
        let after = try await action()
        run.interactions.append(NativeInteraction(index: run.interactions.count, controlID: identifier,
            windowNumber: windowNumber, documentWindowNumber: documentWindowNumber,
            frame: [frame.minX, frame.minY, frame.width, frame.height].map(Double.init),
            viewport: [viewport.minX, viewport.minY, viewport.width, viewport.height].map(Double.init),
            before: before, after: after))
    }

    private static func fill(_ identifier: String, value: String, expected: String, in window: NSWindow,
                            documentWindow: NSWindow, run: Run) async throws {
        guard let before = WorkspaceUIAcceptance.probeText(identifier: identifier, in: window), before != expected else {
            throw FullflowAcceptanceFixture.Failure("The native take input must change: \(identifier).")
        }
        try await interact(identifier, in: window, documentWindow: documentWindow, before: before, run: run) {
            try await MusicvideoNativeAcceptance.click(identifier, in: window)
            try await MusicvideoNativeAcceptance.waitUntil { window.firstResponder is NSTextView }
            guard let field = window.firstResponder as? NSTextView else {
                throw FullflowAcceptanceFixture.Failure("The native take input did not receive keyboard focus.")
            }
            field.setSelectedRange(NSRange(location: 0, length: (field.string as NSString).length))
            field.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil)
            try await MusicvideoNativeAcceptance.waitUntil {
                WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) == expected
            }
            return WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) ?? "missing"
        }
    }

    private static func choose(_ identifier: String, index: Int, expected: String, in window: NSWindow,
                              documentWindow: NSWindow, run: Run) async throws {
        guard let before = WorkspaceUIAcceptance.probeText(identifier: identifier, in: window), before != expected else {
            throw FullflowAcceptanceFixture.Failure("The native take picker must change: \(identifier).")
        }
        try await interact(identifier, in: window, documentWindow: documentWindow, before: before, run: run) {
            try await MusicvideoNativeAcceptance.click(identifier, in: window)
            postKey(115, characters: "\u{f729}", in: window)
            for _ in 0..<index { postKey(125, characters: "\u{f701}", in: window) }
            postKey(36, characters: "\r", in: window)
            try await MusicvideoNativeAcceptance.waitUntil {
                WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) == expected
            }
            return WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) ?? "missing"
        }
    }

    private static func postKey(_ code: UInt16, characters: String, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func capture(_ window: NSWindow, name: String, evidenceURL: URL) throws {
        guard let view = window.contentView, WorkspaceUIAcceptance.snapshot(view,
            at: evidenceURL.appendingPathComponent(screenshotName(name))) else {
            throw FullflowAcceptanceFixture.Failure("Could not capture the native generation review: \(name).")
        }
    }

    private static func screenshotName(_ name: String) -> String {
        let scale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
        return "scale-\(Int((scale * 100).rounded()))-\(name).png"
    }

    private static func requireOK(_ result: ToolResult, operation: String) throws {
        guard !result.isError else {
            throw FullflowAcceptanceFixture.Failure(operation + ": " + result.content.compactMap {
                if case .text(let value) = $0 { return value }; return nil
            }.joined(separator: "\n"))
        }
    }
}

private final class MusicvideoGenerationHTTP: URLProtocol, @unchecked Sendable {
    struct Request: Sendable { let method: String; let url: String; let body: Data }
    struct Response: Sendable { let method: String; let type: String; let bytes: Data }
    struct State: Sendable {
        var responses: [String: Response] = [:]
        var requests: [Request] = []
        var unexpected: [String] = []
    }
    static let requestID = "simulated-fullflow-request"
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var requests: [Request] { state.withLock { $0.requests } }
    static var unexpectedRequests: [String] { state.withLock { $0.unexpected } }
    static var uploadedReference: Data? { requests.first(where: { $0.method == "PUT" })?.body }
    static var submittedPrompt: String? {
        guard let body = requests.first(where: { $0.url.hasPrefix("https://queue.fal.run/") && $0.method == "POST" })?.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["prompt"] as? String
    }
    static var submittedEnvelopeMatches: Bool {
        guard let body = requests.first(where: { $0.url.hasPrefix("https://queue.fal.run/") && $0.method == "POST" })?.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return json["duration"] as? String == "4"
            && json["image_urls"] as? [String] == ["https://media.invalid/stage.png"]
            && json["generate_audio"] as? Bool == false
            && json["resolution"] as? String == "720p"
    }
    static func clear() { state.withLock { $0 = State() } }
    static func install(endpoint: String, output: Data) throws {
        let status = "https://queue.fal.run/bytedance/seedance-2.5/requests/\(requestID)/status"
        let response = "https://queue.fal.run/bytedance/seedance-2.5/requests/\(requestID)"
        func json(_ value: [String: Any], method: String = "GET") throws -> Response {
            Response(method: method, type: "application/json", bytes: try JSONSerialization.data(withJSONObject: value))
        }
        let responses: [String: Response] = [
            "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3": try json([
                "upload_url": "https://upload.invalid/stage.png", "file_url": "https://media.invalid/stage.png"], method: "POST"),
            "https://upload.invalid/stage.png": Response(method: "PUT", type: "application/octet-stream", bytes: Data()),
            "https://queue.fal.run/\(endpoint)": try json(["request_id": requestID, "status_url": status, "response_url": response], method: "POST"),
            status: try json(["status": "COMPLETED"]),
            response: try json(["video": ["url": "https://media.invalid/fullflow.mov"]]),
            "https://media.invalid/fullflow.mov": Response(method: "GET", type: "video/quicktime", bytes: output),
        ]
        state.withLock { $0 = State(responses: responses) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url?.absoluteString ?? "missing URL"
        let method = request.httpMethod ?? "GET"
        let body = Self.body(request)
        let fixture = Self.state.withLock { state -> Response? in
            state.requests.append(Request(method: method, url: url, body: body))
            guard let response = state.responses.removeValue(forKey: url), response.method == method else {
                state.unexpected.append(method + " " + url)
                return nil
            }
            return response
        }
        guard let fixture, let target = request.url,
              let response = HTTPURLResponse(url: target, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": fixture.type, "Content-Length": String(fixture.bytes.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { return data }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}
