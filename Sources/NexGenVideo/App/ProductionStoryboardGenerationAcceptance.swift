import AppKit
import NexGenEngine

@MainActor
enum ProductionStoryboardGenerationAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context, generation: ProductionV2GenerationAcceptance,
                    driver: ProductionVisualSourcesDriver) async throws {
        let editor = context.editor, root = context.dataRoot, window = driver.window
        guard let home = editor.workingRoot, let session = editor.agentService.currentSessionId,
              editor.projectState?.nextPhaseName == "storyboard" else {
            throw failed("The actual Storyboard phase and recording conversation must be active.")
        }
        try await generation.discoverImages(driver: driver)
        let modelID = "fal-ai/flux/schnell"
        guard generation.catalog.image.contains(where: { $0.id == modelID }) else {
            throw failed("The packaged catalog has no executable isolated image offering.")
        }
        let initial = try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root) }.value
        guard let shot = initial.timing.shots.first, shot.moments.count >= 2 else {
            throw failed("The native Add moment action must precede automatic sketches.")
        }
        for moment in shot.moments.prefix(2) {
            let before = try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root) }.value
            guard let source = before.timing.shots.first(where: { $0.id == shot.id })?.moments.first(where: { $0.id == moment.id })?.asset else {
                throw failed("The isolated provider output requires its previously inspected source fixture.")
            }
            let bytes = try await Task.detached {
                try Data(contentsOf: ProjectLocalFile.requireHash(source.image.sha256, at: source.image.path, dataRoot: root))
            }.value
            try MusicvideoGenerationHTTP.installCover(endpoint: modelID, output: bytes)
            let compiled = try await object("compile_storyboard_sketch", args: ["shot_id": shot.id,
                "moment_id": moment.id, "model": modelID, "expected_fingerprint": before.fingerprint],
                context: context, session: session)
            guard let prompt = compiled["compiledPrompt"] as? String,
                  let token = compiled["compileToken"] as? String,
                  let compilation = compiled["storyboardCompileReceipt"] as? String,
                  compiled["shotId"] as? String == "none", !prompt.isEmpty, !token.isEmpty else {
                throw failed("The real compile tool returned no exact moment receipt.")
            }
            _ = try await result("prepare_generation_batch", args: ["requestID": UUID().uuidString,
                "items": [["tool": "generate_image", "purpose": "Create the approved Storyboard moment",
                    "request": ["prompt": prompt, "compileToken": token, "shotId": "none", "model": modelID,
                        "storyboardCompileReceipt": compilation, "aspectRatio": "16:9", "numImages": 1,
                        "name": "Isolated provider · Storyboard " + moment.id]]]], context: context, session: session)
            guard let batch = editor.generationBatchCoordinator.pending, batch.payload.phase == "storyboard",
                  batch.payload.items.count == 1, let item = batch.payload.items.first,
                  item.package.payload.prompt == prompt, item.package.payload.target.modelId == modelID,
                  item.package.payload.estimate == nil, MusicvideoGenerationHTTP.requests.isEmpty else {
                throw failed("The genuine image tool changed its compiled request or submitted before native approval.")
            }
            let package = item.package
            try await driver.wait("automatic sketch awaits actual native spend approval") {
                driver.state("generation-batch.approve", in: window) == true
            }
            try await driver.reveal("generation-batch.approve", in: window)
            try driver.visible(["generation-batch.decline", "generation-batch.approve", "generation-batch.cost"], in: window)
            try driver.capture("automatic-sketch-unapproved-" + moment.id, target: window)
            try await driver.click("generation-batch.approve", in: window)
            try await driver.wait("actual automatic sketch output completed", seconds: 60) {
                guard let state = try? GenerationBatchStore.load(id: batch.id, home: home).journal.executions.first?.state else { return false }
                return [.complete, .blocked, .failed, .canceled].contains(state)
                    && editor.generationBatchCoordinator.activeBatchID == nil && !editor.agentService.isStreaming
            }
            let stored = try GenerationBatchStore.load(id: batch.id, home: home)
            guard stored.journal.executions.first?.state == .complete, stored.authorityAvailable,
                  stored.journal.pricingOverrideItemIDs == [item.id],
                  let assetID = stored.journal.executions.first?.outputAssetIDs.first,
                  let asset = editor.mediaAssets.first(where: { $0.id == assetID }),
                  asset.type == .image, asset.generationStatus == .none,
                  asset.generationInput?.generationPackageID == package.id,
                  MusicvideoGenerationHTTP.submittedPrompt == prompt, MusicvideoGenerationHTTP.unexpectedRequests.isEmpty,
                  MusicvideoGenerationHTTP.requests.filter({ $0.method == "POST" && $0.url.hasPrefix("https://queue.fal.run/") }).count == 1,
                  try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: bytes) else {
                throw failed(stored.journal.executions.first?.detail ?? "The real image request did not publish its exact completed output.")
            }
            let completed = try GenerationOutputReceipt.load(assetID: assetID, home: home)
            guard completed.package.id == package.id, completed.output.sha256 == FileDigest.sha256(of: bytes),
                  completed.input.prompt == prompt, completed.providerRequestID == MusicvideoGenerationHTTP.requestID else {
                throw failed("The generated image has no matching host output receipt.")
            }
            let rejected = await context.executor.execute(name: "assign_storyboard_sketch", args: ["media_ref": assetID,
                "compilation_receipt": compilation, "expected_fingerprint": String(repeating: "0", count: 64)],
                origin: .inAppChat(sessionID: session), toolUseID: "stale-sketch-" + UUID().uuidString)
            let unchanged = try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root) }.value
            guard rejected.isError, unchanged.fingerprint == before.fingerprint else {
                throw failed("A stale generated-sketch assignment changed the canonical Storyboard.")
            }
            _ = try await result("assign_storyboard_sketch", args: ["media_ref": assetID,
                "compilation_receipt": compilation, "expected_fingerprint": before.fingerprint], context: context, session: session)
            let after = try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root) }.value
            guard after.fingerprint != before.fingerprint,
                  let assigned = after.timing.shots.first(where: { $0.id == shot.id })?.moments.first(where: { $0.id == moment.id })?.asset else {
                throw failed("The genuine assignment tool did not update its exact moment.")
            }
            let proof = try await Task.detached {
                _ = try ProjectLocalFile.requireHash(assigned.proof.sha256, at: assigned.proof.path, dataRoot: root)
                let value = try PlanningWriterIO.read(StoryboardSketchProofV1.self, at: assigned.proof.path, dataRoot: root)
                try PipelineStoryboardSketchGeneration.requireGenerated(value, dataRoot: root)
                return value
            }.value
            guard proof.shotID == shot.id, proof.momentID == moment.id, proof.image == assigned.image,
                  assigned.image.sha256 == completed.output.sha256,
                  case .generated(let model, let promptReference, let request, let event, let generationReference, _) = proof.source,
                  model == modelID, request == completed.providerRequestID, event == assetID else {
                throw failed("The assigned moment is not bound to this actual compiler and completed provider request.")
            }
            try await driver.wait("automatic sketch visible at its canonical moment") {
                driver.text("storyboard.moment." + moment.id, in: window) == assigned.image.sha256
            }
            try await driver.inspect("storyboard.sketch.inspect." + moment.id, in: window)
            try driver.capture("automatic-sketch-assigned-" + moment.id, target: window)
            let prefix = "automatic-sketch-" + moment.id, evidenceOutput = driver.output
            let files = try await Task.detached { () -> [String: String] in
                let artifacts = [(assigned.proof, root, "proof.json"), (assigned.image, root, "image.png"),
                    (promptReference, root, "prompt.txt"), (generationReference, root, "generation.json"),
                    (completed.package, home, "package.json")]
                var result: [String: String] = [:]
                for (reference, base, suffix) in artifacts {
                    let data = try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: base))
                    let name = prefix + "-" + suffix
                    try data.write(to: evidenceOutput.appendingPathComponent(name), options: .atomic)
                    result[name] = FileDigest.sha256(of: data)
                }
                let receipt = try Data(contentsOf: ProjectLocalFile.resolve(GenerationOutputReceipt.path(assetID: assetID), dataRoot: home))
                let name = prefix + "-output.json"
                try receipt.write(to: evidenceOutput.appendingPathComponent(name), options: .atomic)
                result[name] = FileDigest.sha256(of: receipt)
                return result
            }.value
            try driver.record("automatic Storyboard sketch through actual tools", fields: ["shotID": shot.id, "momentID": moment.id,
                "assetID": assetID, "packageSHA256": package.id, "compilationReceipt": compilation,
                "imageSHA256": assigned.image.sha256, "proofPath": assigned.proof.path, "proofSHA256": assigned.proof.sha256,
                "promptSHA256": FileDigest.sha256(of: Data(prompt.utf8)), "nativeSpendApproval": true,
                "staleAssignmentRejected": true, "files": files, "evidencePrefix": prefix,
                "provider": "isolated Fal HTTP with inspected fixture bytes", "liveProvider": false, "livePricing": false])
        }
    }

    static func result(_ name: String, args: [String: Any], context: ProductionPlanningAcceptanceFixture.Context,
                               session: UUID) async throws -> ToolResult {
        let value = await context.executor.execute(name: name, args: args,
            origin: .inAppChat(sessionID: session), toolUseID: "native-sketch-" + UUID().uuidString)
        guard !value.isError else {
            throw failed(value.content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n"))
        }
        return value
    }

    static func object(_ name: String, args: [String: Any], context: ProductionPlanningAcceptanceFixture.Context,
                               session: UUID) async throws -> [String: Any] {
        let value = try await result(name, args: args, context: context, session: session)
        let text = value.content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw failed("The actual tool result is not a structured object.")
        }
        return object
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native automatic sketches: " + message) }
}
