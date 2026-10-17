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
    }

    private final class Run {
        var batchID: String?
        var packageID: String?
        var takeID: String?
        var assetID: String?
        var promptSHA256: String?
        var referenceSHA256: String?
        var outputSHA256: String?
    }

    static func makeDocument() async throws -> (document: VideoProject, fixture: FullflowAcceptanceFixture.Receipt, generation: Receipt) {
        guard WorkspaceUIAcceptance.isRequested else {
            throw FullflowAcceptanceFixture.Failure("The simulated provider is available only in explicit UI acceptance.")
        }
        ModelCatalog.shared.load(entries: ModelCatalog.launchEntries)
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
            _ = try await GenerationBatchStore.approve(batch, editor: editor, approval: .acceptUnknownPrices)
            try prepared.attachBatch(.init(batchID: batch.id, itemID: item.id), editor: editor)
            let outcome = try await GenerationController.submitPrepared(prepared, editor: editor, quoteLoader: noPrice).get()
            await editor.generationService.waitForGeneration(placeholderId: outcome.placeholderId)
            guard let asset = editor.mediaAssets.first(where: { $0.id == outcome.placeholderId }),
                  asset.pendingDownloadURL == nil, asset.generationInput?.generationPackageID == package.id,
                  let transaction = asset.generationInput?.spendTransactionId,
                  try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: outputBytes) else {
                throw FullflowAcceptanceFixture.Failure("The provider output was not finalized with its approved package.")
            }
            let completedBatch = try GenerationBatchStore.load(id: batch.id, home: home)
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
            let findings = TakeReview.Pass.allCases.map { pass in
                TakeReview.Finding(pass: pass, verdict: .conforms,
                    observation: "Supplied acceptance decision: the deterministic moving marker satisfies the \(pass.rawValue) pass; provider audio is muted.",
                    startSeconds: 0, endSeconds: snapshot.durationSeconds)
            }
            try await TakeReview.save(snapshot: snapshot, findings: findings, editor: editor)
            try await TakeReview.select(take: snapshot.take, home: home, editor: editor)
            run.batchID = batch.id; run.packageID = package.id; run.takeID = takeID; run.assetID = asset.id
            run.promptSHA256 = FileDigest.sha256(of: Data(compiled.text.utf8))
            run.referenceSHA256 = FileDigest.sha256(of: referenceBytes); run.outputSHA256 = FileDigest.sha256(of: outputBytes)
        }
        let (document, fixture) = try await FullflowAcceptanceFixture.makeDocument(generatedShot: scenario)
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
            generatedSourceStartFrame: generated.sourceStartFrame, generatedSourceEndFrame: generated.sourceEndFrame, totalFrames: fixture.totalFrames))
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
