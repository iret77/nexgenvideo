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
        let plannedCutSeconds: Double
        let requestedDurationSeconds: Int
        let providerDurationFrames: Int
        let importedSourceEndFrame: Int
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
        let evidenceURL: URL
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
        var plannedCutSeconds: Double?
        var requestedDurationSeconds: Int?
        var providerDurationFrames: Int?
        var reviewPass: String?
        var controlID: String?
        var latestFieldEdit: [String: Any] = [:]
        var fieldEdits: [[String: Any]] = []
        var diagnosticScreenshots: [String] = []

        init(evidenceURL: URL) { self.evidenceURL = evidenceURL }
    }

    static func makeDocument(evidenceURL: URL) async throws -> (document: VideoProject, fixture: FullflowAcceptanceFixture.Receipt, generation: Receipt) {
        guard WorkspaceUIAcceptance.isRequested else {
            throw FullflowAcceptanceFixture.Failure("The simulated provider is available only in explicit UI acceptance.")
        }
        guard let binding = PluginLoader.liveBinding(id: "musicvideo"),
              let contract = try PhaseContractRuntime.contract(activePack: binding.id),
              !(try HostWorkflowKey.resolve(binding: binding, contract: contract)).isProductionV2 else {
            throw FullflowAcceptanceFixture.Failure("The legacy fixture requires an exact pinned legacy pack in its own process. Use the V2 owner driver for the current pack.")
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
        let run = Run(evidenceURL: evidenceURL)
        let makeExecutor: @MainActor (EditorViewModel) -> ToolExecutor = { editor in
            ToolExecutor(editor: editor, providerActivation: { activation }, modelCatalog: catalog,
                productionRouteCandidates: { _ in candidates }, catalogReadiness: { true }, isModelEnabled: { _ in true })
        }
        let scenario = FullflowAcceptanceFixture.GeneratedShotScenario(modeID: mode, makeExecutor: makeExecutor) { editor, outputURL in
            guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else {
                throw FullflowAcceptanceFixture.Failure("The generation project is not open.")
            }
            guard let shot = try loadShotlist(dataRoot: root)?.shots.first, shot.id == "s001",
                  shot.timeStart == 0, abs(shot.timeEnd - 2) <= 0.075, editor.timeline.fps == 30 else {
                throw FullflowAcceptanceFixture.Failure("The measured fixture cut must be within 75 ms of its two-second beat at 30 fps.")
            }
            let duration = Int(ceil(shot.timeEnd + 2))
            let cutFrames = Int((shot.timeEnd * 30).rounded())
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
                modelId: modelID, modality: .video, aspectRatio: "16:9", durationSeconds: Double(duration),
                editor: editor, shotId: "s001", shot: projection, modelCatalog: catalog)
            let request = GenerationRequest(modality: .video, modelId: modelID, intent: compiled.text,
                aspectRatio: "16:9", durationSeconds: Double(duration), outputResolution: "720p",
                placement: .mediaLibrary(folderId: nil), origin: .agentTool, target: selection.target,
                precompiled: (compiled.text, compiled.token, compiled.binding), submission: .video(make: { text in
                    var input = GenerationInput(prompt: text, model: modelID, duration: duration, aspectRatio: "16:9", resolution: "720p")
                    input.videoDuration = .seconds(duration)
                    input.promptShotId = compiled.binding.shotId
                    input.promptProjectKey = compiled.binding.projectKey
                    input.promptShotFingerprint = compiled.binding.shotFingerprint
                    input.productionRouting = inputs.routingProof
                    return VideoGenerationSubmission.make(genInput: input, model: model,
                        offeringCapabilities: inputs.offeringCapabilities, inputAssets: inputs.assets,
                        placeholderDuration: Double(duration), name: "HTTP simulator · s001", generateAudio: false)
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
                  MusicvideoGenerationHTTP.submittedEnvelopeMatches(duration: duration),
                  completedBatch.journal.executions.first?.state == .complete,
                  completedBatch.journal.executions.first?.outputAssetIDs == [asset.id],
                  MusicvideoGenerationHTTP.unexpectedRequests.isEmpty else {
                throw FullflowAcceptanceFixture.Failure("The real provider path lost its prompt, reference bytes or spend receipt.")
            }
            let recorded = await executor.execute(name: "record_render", args: ["phase": "final", "shot_id": "s001", "output": asset.id])
            try requireOK(recorded, operation: "record_render")
            let takeID = PipelineRenderTakeStore.identity(eventID: asset.id, outputSHA256: FileDigest.sha256(of: outputBytes))
            let snapshot = try await TakeReview.capture(takeID: takeID, home: home)
            let providerFrames = Int((snapshot.durationSeconds * 30).rounded())
            guard providerFrames == duration * 30, providerFrames >= cutFrames + 60 else {
                throw FullflowAcceptanceFixture.Failure("The generated take does not include both one-second handles.")
            }
            run.takeReview = try await reviewTake(snapshot, endSeconds: Double(cutFrames + 30) / 30,
                editor: editor, window: window, run: run, evidenceURL: evidenceURL)
            run.batchID = batch.id; run.packageID = package.id; run.takeID = takeID; run.assetID = asset.id
            run.promptSHA256 = FileDigest.sha256(of: Data(compiled.text.utf8))
            run.referenceSHA256 = FileDigest.sha256(of: referenceBytes); run.outputSHA256 = FileDigest.sha256(of: outputBytes)
            run.plannedCutSeconds = shot.timeEnd
            run.requestedDurationSeconds = duration
            run.providerDurationFrames = providerFrames
        }
        let (document, fixture) = try await FullflowAcceptanceFixture.makeDocument(evidenceURL: evidenceURL, generatedShot: scenario)
        let editor = document.editorViewModel
        guard let cutSeconds = run.plannedCutSeconds, let requestedDuration = run.requestedDurationSeconds,
              let providerFrames = run.providerDurationFrames else {
            throw FullflowAcceptanceFixture.Failure("The generation lacks measured cut and provider-duration evidence.")
        }
        let cutFrames = Int((cutSeconds * 30).rounded())
        guard let assembly = try PipelineAssemblyStore.load(dataRoot: fixture.dataRoot),
              let generated = assembly.plan.selectedMedia.first(where: { $0.shotID == "s001" }),
              let imported = assembly.plan.selectedMedia.first(where: { $0.shotID == "s002" }),
              generated.sourceKind == .generatedTake, imported.sourceKind == .importedSource,
              generated.sourceStartFrame == 30, generated.sourceEndFrame == 30 + cutFrames,
              imported.sourceStartFrame == 0, imported.sourceEndFrame == 129 - cutFrames,
              fixture.totalFrames == 129,
              let batchID = run.batchID, let packageID = run.packageID, let takeID = run.takeID,
              let assetID = run.assetID, let promptSHA256 = run.promptSHA256,
              let referenceSHA256 = run.referenceSHA256, let outputSHA256 = run.outputSHA256,
              let nativeApproval = run.approval, let nativeTakeReview = run.takeReview,
              generated.takeID == takeID, generated.sourceSHA256 == outputSHA256,
              editor.timeline.tracks.flatMap(\.clips).contains(where: { $0.mediaRef == assetID && $0.trimStartFrame == 30 && $0.durationFrames == cutFrames }) else {
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
            nativeScreenshots: ["generation-batch-approval", "generation-take-review", "generation-take-selected",
                "generation-take-workspace"].map(screenshotName),
            plannedCutSeconds: cutSeconds, requestedDurationSeconds: requestedDuration,
            providerDurationFrames: providerFrames, importedSourceEndFrame: imported.sourceEndFrame))
    }

    private static func reviewTake(_ snapshot: TakeReview.Snapshot, endSeconds: Double, editor: EditorViewModel, window: NSWindow,
                                   run: Run, evidenceURL: URL) async throws -> NativeTakeReview {
        do {
            return try await performTakeReview(snapshot, endSeconds: endSeconds, editor: editor, window: window,
                run: run, evidenceURL: evidenceURL)
        } catch {
            var surfaces = [("generation-take-failure-document", window)]
            if let sheet = window.attachedSheet { surfaces.append(("generation-take-failure-sheet", sheet)) }
            for (name, surface) in surfaces {
                if let view = surface.contentView,
                   WorkspaceUIAcceptance.snapshot(view, at: evidenceURL.appendingPathComponent(screenshotName(name))) {
                    run.diagnosticScreenshots.append(screenshotName(name))
                }
            }
            do { try persistReviewEvidence(run, failure: error.localizedDescription) }
            catch { FileHandle.standardError.write(Data("MUSICVIDEO_TAKE_EVIDENCE_WRITE_FAILED \(error.localizedDescription)\n".utf8)) }
            throw error
        }
    }

    private static func performTakeReview(_ snapshot: TakeReview.Snapshot, endSeconds: Double, editor: EditorViewModel, window: NSWindow,
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
        try capture(sheet, name: "generation-take-before-review", evidenceURL: evidenceURL)
        run.diagnosticScreenshots.append(screenshotName("generation-take-before-review"))
        var expectedFindings: [TakeReview.Finding] = []
        for (index, pass) in TakeReview.Pass.allCases.enumerated() {
            run.reviewPass = pass.rawValue
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
            try await fill("take.end", value: String(endSeconds), expected: String(endSeconds), in: sheet, documentWindow: window, run: run)
            expectedFindings.append(.init(pass: pass, verdict: verdict, observation: observation, startSeconds: 1, endSeconds: endSeconds))
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
        let previewControl = "take.workspace.select.\(snapshot.take.id)"
        guard await WorkspaceUIAcceptance.revealProbe(previewControl, in: window) else {
            throw FullflowAcceptanceFixture.Failure("The selected take is not reachable in the Render workspace.")
        }
        try await interact(previewControl, in: window, documentWindow: window, before: "none", run: run) {
            guard WorkspaceUIAcceptance.probeText(identifier: "take.workspace.player", in: window) == nil else {
                throw FullflowAcceptanceFixture.Failure("The take workspace started without an explicit preview choice.")
            }
            try await MusicvideoNativeAcceptance.click(previewControl, in: window)
            try await MusicvideoNativeAcceptance.waitUntil {
                WorkspaceUIAcceptance.probeText(identifier: "take.workspace.player", in: window) == snapshot.take.id
            }
            guard try selectedTake() == selectedAfter,
                  try FileDigest.sha256(of: root.appendingPathComponent(TakeReview.path(takeID: snapshot.take.id))) == reviewHash,
                  await WorkspaceUIAcceptance.revealProbe("take.workspace.player", in: window) else {
                throw FullflowAcceptanceFixture.Failure("Previewing a take changed its review or selection, or its video is unreachable.")
            }
            try capture(window, name: "generation-take-workspace", evidenceURL: evidenceURL)
            return snapshot.take.id
        }
        return NativeTakeReview(takeIDBefore: pickerBefore, takeIDAfter: review.takeID,
            findingsBefore: findingsBefore, findings: review.findings, selectedTakeIDBefore: selectedBefore,
            selectedTakeIDAfter: selectedAfter, reviewSHA256: reviewHash)
    }

    private static func interact(_ identifier: String, in window: NSWindow, documentWindow: NSWindow,
                                 before: String, run: Run, action: () async throws -> String) async throws {
        run.controlID = identifier
        try persistReviewEvidence(run)
        try await MusicvideoNativeAcceptance.waitUntil("\(identifier): enabled", diagnostic: {
            "pass=\(run.reviewPass ?? "none"), state=\(String(describing: WorkspaceUIAcceptance.probeState(identifier: identifier, in: window))), text=\(WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) ?? "missing")"
        }) {
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
        try persistReviewEvidence(run)
    }

    private static func fill(_ identifier: String, value: String, expected: String, in window: NSWindow,
                            documentWindow: NSWindow, run: Run) async throws {
        let before = WorkspaceUIAcceptance.probeText(identifier: identifier, in: window)
        var stage = "locate"
        var target: NSTextField?
        var editor: NSTextView?
        var commitRequested = false
        var typedText: String?
        func diagnostics() -> String {
            let fields = textFields(in: window.contentView)
            let owners = fields.filter { field in
                guard let editor else { return false }
                return field.currentEditor() === editor
            }
            run.latestFieldEdit = [
                "fieldID": identifier, "pass": run.reviewPass ?? "none", "stage": stage,
                "before": before as Any? ?? NSNull(), "input": value, "expected": expected,
                "actual": WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) as Any? ?? NSNull(),
                "windowNumber": window.windowNumber, "documentWindowNumber": documentWindow.windowNumber, "keyWindow": window.isKeyWindow,
                "firstResponderClass": window.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
                "typedText": typedText as Any? ?? NSNull(),
                "editorText": editor?.string as Any? ?? NSNull(),
                "editorSelection": editor.map { [$0.selectedRange().location, $0.selectedRange().length] } ?? [],
                "editorOwnerCount": owners.count, "editorOwnedByTarget": target.map { target in owners.contains { $0 === target } } ?? false,
                "commitMethod": "Tab", "commitRequested": commitRequested,
                "commitEndedTargetEditing": commitRequested && target.map { $0.currentEditor() == nil } == true,
                "targetCandidates": matchingTextFields(identifier, in: window).count,
                "fields": fields.map { field -> [String: Any] in
                    let frame = field.convert(field.bounds, to: window.contentView)
                    return ["class": String(describing: type(of: field)), "text": field.stringValue,
                        "frame": [frame.minX, frame.minY, frame.width, frame.height].map { $0.isFinite ? $0 as Any : String(describing: $0) },
                        "target": field === target,
                        "currentEditorIsFirstResponder": field.currentEditor().map { $0 === window.firstResponder } ?? false]
                },
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: run.latestFieldEdit, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return "Field diagnostics could not be encoded." }
            return text
        }
        func waitFor(_ label: String, _ ready: () -> Bool) async throws {
            stage = label
            _ = diagnostics()
            try persistReviewEvidence(run)
            try await MusicvideoNativeAcceptance.waitUntil("\(identifier)/\(run.reviewPass ?? "none"): \(label)", diagnostic: diagnostics, ready)
        }
        func ownsEditor() -> Bool {
            guard let target, let editor else { return false }
            return window.isKeyWindow && target.window === window && target.currentEditor() === editor
                && window.firstResponder === editor && editor.isEditable
        }
        do {
            guard let before, before != expected else {
                throw FullflowAcceptanceFixture.Failure("The native take input must change: \(identifier).")
            }
            try await interact(identifier, in: window, documentWindow: documentWindow, before: before, run: run) {
                try await MusicvideoNativeAcceptance.click(identifier, in: window)
                try await waitFor("focused target field") {
                    let candidates = matchingTextFields(identifier, in: window)
                    guard candidates.count == 1, let field = candidates.first,
                          let active = field.currentEditor() as? NSTextView else { return false }
                    target = field; editor = active
                    return ownsEditor()
                }
                guard let editor else { throw FullflowAcceptanceFixture.Failure("The target field has no native editor.") }
                try postKey(0, characters: "a", modifiers: .command, in: window)
                try await waitFor("select all") {
                    ownsEditor() && editor.selectedRange() == NSRange(location: 0, length: (editor.string as NSString).length)
                }
                for character in value { try postKey(0, characters: String(character), in: window) }
                try await waitFor("typed text") { ownsEditor() && editor.string == value }
                typedText = editor.string
                commitRequested = true
                try postKey(48, characters: "\t", in: window)
                try await waitFor("Tab commit") {
                    target.map { $0.currentEditor() == nil } == true
                        && WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) == expected
                }
                stage = "verified"
                _ = diagnostics()
                run.fieldEdits.append(run.latestFieldEdit)
                return WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) ?? "missing"
            }
        } catch {
            let detail = diagnostics()
            FileHandle.standardError.write(Data("MUSICVIDEO_TAKE_FIELD_FAILED \(detail)\n".utf8))
            throw error
        }
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return [] }
        let current = (view as? NSTextField).flatMap { $0.isEditable ? $0 : nil }.map { [$0] } ?? []
        return current + view.subviews.flatMap { textFields(in: $0) }
    }

    private static func matchingTextFields(_ identifier: String, in window: NSWindow) -> [NSTextField] {
        guard let root = window.contentView, let frame = WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: window) else { return [] }
        return textFields(in: root).filter {
            let bounds = $0.convert($0.bounds, to: root)
            return $0.window === window && bounds.width > 0 && bounds.height > 0
                && frame.insetBy(dx: -1, dy: -1).contains(bounds)
                && bounds.contains(NSPoint(x: frame.midX, y: frame.midY))
        }
    }

    private static func persistReviewEvidence(_ run: Run, failure: String? = nil) throws {
        let interactions = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run.interactions))
        let evidence: [String: Any] = ["schema": "native-take-review-progress/v1", "pass": run.reviewPass as Any? ?? NSNull(),
            "controlID": run.controlID as Any? ?? NSNull(), "interactions": interactions,
            "latestFieldEdit": run.latestFieldEdit, "fieldEdits": run.fieldEdits,
            "screenshots": run.diagnosticScreenshots, "failure": failure as Any? ?? NSNull()]
        let path = "generation-take-progress-" + screenshotName("evidence").replacingOccurrences(of: ".png", with: ".json")
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: run.evidenceURL.appendingPathComponent(path), options: .atomic)
    }

    private static func choose(_ identifier: String, index: Int, expected: String, in window: NSWindow,
                              documentWindow: NSWindow, run: Run) async throws {
        guard let before = WorkspaceUIAcceptance.probeText(identifier: identifier, in: window), before != expected else {
            throw FullflowAcceptanceFixture.Failure("The native take picker must change: \(identifier).")
        }
        try await interact(identifier, in: window, documentWindow: documentWindow, before: before, run: run) {
            try await MusicvideoNativeAcceptance.click(identifier, in: window)
            try postKey(115, characters: "\u{f729}", in: window)
            for _ in 0..<index { try postKey(125, characters: "\u{f701}", in: window) }
            try postKey(36, characters: "\r", in: window)
            try await MusicvideoNativeAcceptance.waitUntil {
                WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) == expected
            }
            return WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) ?? "missing"
        }
    }

    private static func postKey(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                throw FullflowAcceptanceFixture.Failure("AppKit could not create the native key event for key code \(code).")
            }
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

final class MusicvideoGenerationHTTP: URLProtocol, @unchecked Sendable {
    struct Request: Sendable { let method: String; let url: String; let body: Data }
    struct Response: Sendable { let method: String; let type: String; let bytes: Data }
    struct State: Sendable {
        var responses: [String: Response] = [:]
        var uploads: [String: Response] = [:]
        var requests: [Request] = []
        var unexpected: [String] = []
        var imageUploads: [Response] = []
    }
    static let requestID = "simulated-fullflow-request"
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var requests: [Request] { state.withLock { $0.requests } }
    static var unexpectedRequests: [String] { state.withLock { $0.unexpected } }
    static var uploadedReference: Data? { requests.first(where: { $0.method == "PUT" && $0.url == "https://upload.invalid/stage.png" })?.body }
    static var uploadedTimingAudio: Data? { requests.first(where: { $0.method == "PUT" && $0.url == "https://upload.invalid/phrase.wav" })?.body }
    static var submittedPrompt: String? {
        guard let body = requests.first(where: { $0.url.hasPrefix("https://queue.fal.run/") && $0.method == "POST" })?.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["prompt"] as? String
    }
    static func submittedEnvelopeMatches(duration: Int, timingAudio: Bool = false) -> Bool {
        guard let body = requests.first(where: { $0.url.hasPrefix("https://queue.fal.run/") && $0.method == "POST" })?.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return json["duration"] as? String == String(duration)
            && json["image_urls"] as? [String] == ["https://media.invalid/stage.png"]
            && (timingAudio ? json["audio_urls"] as? [String] == ["https://media.invalid/phrase.wav"] : json["audio_urls"] == nil)
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
    static func installPerformance(endpoint: String, output: Data) throws {
        try install(endpoint: endpoint, output: output)
        let image = Response(method: "POST", type: "application/json", bytes: try JSONSerialization.data(withJSONObject: [
            "upload_url": "https://upload.invalid/stage.png", "file_url": "https://media.invalid/stage.png"]))
        let audio = Response(method: "POST", type: "application/json", bytes: try JSONSerialization.data(withJSONObject: [
            "upload_url": "https://upload.invalid/phrase.wav", "file_url": "https://media.invalid/phrase.wav"]))
        state.withLock {
            $0.responses.removeValue(forKey: "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")
            $0.responses["https://upload.invalid/phrase.wav"] = Response(method: "PUT", type: "application/octet-stream", bytes: Data())
            $0.uploads = ["image": image, "audio": audio]
        }
    }
    static func installCover(endpoint: String, output: Data) throws {
        let response = "https://queue.fal.run/fal-ai/flux/requests/" + requestID
        func json(_ value: [String: Any], method: String = "GET") throws -> Response {
            Response(method: method, type: "application/json", bytes: try JSONSerialization.data(withJSONObject: value))
        }
        let responses: [String: Response] = [
            "https://queue.fal.run/" + endpoint: try json(["request_id": requestID,
                "status_url": response + "/status", "response_url": response], method: "POST"),
            response + "/status": try json(["status": "COMPLETED"]),
            response: try json(["images": [["url": "https://media.invalid/cover.png", "content_type": "image/png"]]]),
            "https://media.invalid/cover.png": Response(method: "GET", type: "image/png", bytes: output),
        ]
        state.withLock { $0 = State(responses: responses) }
    }

    static func installImageCatalog(textToImage: [String], imageToImage: [String]) throws {
        let responses = try Dictionary(uniqueKeysWithValues: [("text-to-image", textToImage), ("image-to-image", imageToImage)].map { category, ids in
            let body: [String: Any] = ["models": ids.map { ["endpoint_id": $0] }, "has_more": false]
            return ("https://api.fal.ai/v1/models?category=\(category)&status=active&limit=100",
                Response(method: "GET", type: "application/json", bytes: try JSONSerialization.data(withJSONObject: body)))
        })
        state.withLock { $0 = State(responses: responses) }
    }

    static func installFrameImage(endpoint: String, output: Data, referenceCount: Int) throws {
        guard referenceCount > 0 else { throw GateBlocked("The Frames fixture expects real submitted image references.") }
        let application = endpoint.split(separator: "/").prefix(2).joined(separator: "/")
        let response = "https://queue.fal.run/\(application)/requests/" + requestID
        func json(_ value: [String: Any], method: String = "GET") throws -> Response {
            Response(method: method, type: "application/json", bytes: try JSONSerialization.data(withJSONObject: value))
        }
        var responses: [String: Response] = [
            "https://queue.fal.run/" + endpoint: try json(["request_id": requestID,
                "status_url": response + "/status", "response_url": response], method: "POST"),
            response + "/status": try json(["status": "COMPLETED"]),
            response: try json(["images": [["url": "https://media.invalid/frame.png", "content_type": "image/png"]]]),
            "https://media.invalid/frame.png": Response(method: "GET", type: "image/png", bytes: output),
        ]
        let uploads = try (0..<referenceCount).map { index in
            let upload = "https://upload.invalid/frame-input-\(index).png"
            responses[upload] = Response(method: "PUT", type: "application/octet-stream", bytes: Data())
            return try json(["upload_url": upload, "file_url": "https://media.invalid/frame-input-\(index).png"], method: "POST")
        }
        state.withLock { $0 = State(responses: responses, imageUploads: uploads) }
    }
    static func installAudio(endpoint: String, output: Data) throws {
        let response = "https://queue.fal.run/native-audio/requests/" + requestID
        func json(_ value: [String: Any], method: String = "GET") throws -> Response {
            Response(method: method, type: "application/json", bytes: try JSONSerialization.data(withJSONObject: value))
        }
        let responses: [String: Response] = [
            "https://queue.fal.run/" + endpoint: try json(["request_id": requestID,
                "status_url": response + "/status", "response_url": response], method: "POST"),
            response + "/status": try json(["status": "COMPLETED"]),
            response: try json(["audio": ["url": "https://media.invalid/native-audio.wav", "content_type": "audio/wav"]]),
            "https://media.invalid/native-audio.wav": Response(method: "GET", type: "audio/wav", bytes: output),
        ]
        state.withLock { $0 = State(responses: responses) }
    }
    static func installUpscale(endpoint: String, output: Data) throws {
        let response = "https://queue.fal.run/fal-ai/clarity-upscaler/requests/" + requestID
        func json(_ value: [String: Any], method: String = "GET") throws -> Response {
            Response(method: method, type: "application/json", bytes: try JSONSerialization.data(withJSONObject: value))
        }
        let responses: [String: Response] = [
            "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3": try json([
                "upload_url": "https://upload.invalid/stage.png", "file_url": "https://media.invalid/stage.png"], method: "POST"),
            "https://upload.invalid/stage.png": Response(method: "PUT", type: "application/octet-stream", bytes: Data()),
            "https://queue.fal.run/" + endpoint: try json(["request_id": requestID,
                "status_url": response + "/status", "response_url": response], method: "POST"),
            response + "/status": try json(["status": "COMPLETED"]),
            response: try json(["image": ["url": "https://media.invalid/upscale.png", "content_type": "image/png"]]),
            "https://media.invalid/upscale.png": Response(method: "GET", type: "image/png", bytes: output),
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
            if url == "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3", method == "POST", !state.imageUploads.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               (json["content_type"] as? String)?.hasPrefix("image/") == true { return state.imageUploads.removeFirst() }
            if url == "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3", method == "POST", !state.uploads.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let type = json["content_type"] as? String,
               let response = state.uploads.removeValue(forKey: type.components(separatedBy: "/")[0]) { return response }
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
