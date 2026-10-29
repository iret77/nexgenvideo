import Foundation
import NexGenEngine

@MainActor
enum PipelineStoryboardSketchGeneration {
    struct CompileSelection: Codable, Sendable, Equatable {
        let schema: String
        let projectKey: String
        let workflow: HostWorkflowKey
        let shotID: String
        let momentID: String
        let intentSHA256: String
        let framingSHA256: String
        let script: CanonicalArtifactReferenceV1
        let compiled: CanonicalArtifactReferenceV1
    }

    struct Compilation {
        let compiled: CompiledPrompt
        let receipt: CanonicalArtifactReferenceV1
    }

    struct GenerationReceipt: Codable, Sendable, Equatable {
        let schema: String
        let projectKey: String
        let shotID: String
        let momentID: String
        let intentSHA256: String
        let framingSHA256: String
        let selection: CanonicalArtifactReferenceV1
        let outputReceipt: CanonicalArtifactReferenceV1
        let image: CanonicalArtifactReferenceV1
        let compiled: CanonicalArtifactReferenceV1
        let inputs: [CanonicalArtifactReferenceV1]
    }

    struct Prepared: Sendable {
        let targetShotID: String
        let targetMomentID: String
        let asset: StoryboardTimingV1.SketchAsset
        let files: [(path: String, bytes: Data)]
        fileprivate init(targetShotID: String, targetMomentID: String, asset: StoryboardTimingV1.SketchAsset,
                         files: [(path: String, bytes: Data)]) {
            self.targetShotID = targetShotID
            self.targetMomentID = targetMomentID
            self.asset = asset
            self.files = files
        }
    }

    static func compile(shotID: String, momentID: String, modelID: String, expectedFingerprint: String,
                        editor: EditorViewModel) async throws -> Compilation {
        let access = try access(editor: editor)
        let board = try PlanningWriterIO.storyboard(dataRoot: access.dataRoot, requireVisuals: false)
        guard board.fingerprint == expectedFingerprint,
              let shot = board.timing.shots.first(where: { $0.id == shotID }),
              let moment = shot.moments.first(where: { $0.id == momentID }),
              let projectKey = ProjectIdentity.existingUUID(for: FrameInventory.projectHome(of: access.dataRoot)),
              editor.projectId == projectKey, editor.generationBatchCoordinator.modelCatalog.image.contains(where: { $0.id == modelID }) else { throw changed() }
        let image = try await PromptCompiler.compile(intent: moment.intent, modelId: modelID, modality: .image,
            editor: editor, setting: shot.framing.composition,
            style: "Storyboard sketch. " + shot.framing.scale + ". " + shot.framing.cameraView,
            shotId: "none", modelCatalog: editor.generationBatchCoordinator.modelCatalog)
        try access.revalidate()
        let current = try PlanningWriterIO.storyboard(dataRoot: access.dataRoot, requireVisuals: false)
        guard current.fingerprint == expectedFingerprint else { throw changed() }
        let record = try ProductionCompiledPromptStore.record(image, modelID: modelID, modality: "image",
            projectID: board.storyboard.header.projectID, dataRoot: access.dataRoot)
        guard let script = board.storyboard.header.inputs.first(where: { $0.path.hasPrefix("script/v") }) else { throw changed() }
        let selection = CompileSelection(schema: "storyboard-sketch-compilation/v1", projectKey: projectKey,
            workflow: access.workflow, shotID: shotID, momentID: momentID,
            intentSHA256: FileDigest.sha256(of: Data(moment.intent.utf8)), framingSHA256: try shot.framing.fingerprint(),
            script: script, compiled: record)
        let bytes = try PlanningWriterIO.json(selection)
        let identity = FileDigest.sha256(of: bytes)
        let path = "storyboard/sketch-compilations/\(identity).v1.json"
        let candidate = access.dataRoot.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: candidate.path) {
            guard try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: access.dataRoot)) == bytes else { throw changed() }
        } else {
            try access.publish([(path, bytes)], captureLineage: false) {
                _ = try requireSelection(path: path, editor: editor)
            }
        }
        return Compilation(compiled: image, receipt: PlanningWriterIO.reference(path, id: identity,
            role: "host.storyboard-sketch-compilation", bytes: bytes))
    }

    static func requireCompileForGeneration(path: String, compiled: (text: String, token: String, binding: PromptBinding)?,
                                            modelID: String, editor: EditorViewModel) throws {
        let (selection, record) = try requireSelection(path: path, editor: editor)
        guard let compiled, let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
              compiled.binding.projectKey == selection.projectKey, compiled.binding.shotId == "none",
              compiled.binding.styleFingerprint == record.binding.styleFingerprint,
              compiled.binding.compilerInputsSHA256 == record.binding.compilerInputsSHA256 else { throw changed() }
        let actualPath = try ProductionCompiledPromptStore.path(binding: compiled.binding, modelID: modelID, text: compiled.text)
        let actualRef = try PlanningWriterIO.reference(actualPath, id: "sketch-current-compiler", role: "host.production-compiled-prompt", dataRoot: root)
        let actual = try ProductionCompiledPromptStore.load(actualRef, dataRoot: root)
        guard actual.sourceIR == record.sourceIR, actual.binding == compiled.binding,
              actual.text == compiled.text, actual.modelID == modelID else { throw changed() }
    }

    static func assign(media: MediaAsset, compilationPath: String, expectedFingerprint: String,
                       editor: EditorViewModel) throws -> StoryboardBundleSnapshot {
        let access = try access(editor: editor)
        let root = access.dataRoot
        let home = FrameInventory.projectHome(of: root)
        let (selection, desired) = try requireSelection(path: compilationPath, editor: editor)
        let board = try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
        guard board.fingerprint == expectedFingerprint, media.type == .image, media.generationStatus == .none,
              editor.mediaAssets.contains(where: { $0 === media }), let input = media.generationInput,
              let packageID = input.generationPackageID else { throw changed() }
        let completed = try GenerationOutputReceipt.load(assetID: media.id, home: home)
        let package = try GenerationPackageV1.load(id: packageID, home: home)
        guard completed.input == GenerationPackageV1.normalized(input), completed.modality == "image",
              package.payload.modality == "image", package.payload.outputCount == 1,
              package.payload.binding.projectKey == selection.projectKey, package.payload.binding.shotId == "none",
              package.payload.binding.promptIRSHA256 == desired.binding.promptIRSHA256 else { throw changed() }
        let actualPath = try ProductionCompiledPromptStore.path(binding: package.payload.binding,
            modelID: package.payload.target.modelId, text: package.payload.prompt)
        let actualRef = try PlanningWriterIO.reference(actualPath, id: "sketch-compiled-image",
            role: "host.production-compiled-prompt", dataRoot: root)
        let actual = try ProductionCompiledPromptStore.load(actualRef, dataRoot: root)
        guard actual.sourceIR == desired.sourceIR, actual.modality == "image", actual.binding.projectKey == selection.projectKey,
              actual.text == package.payload.prompt, actual.modelID == package.payload.target.modelId else { throw changed() }
        let source = try ProjectLocalFile.requireHash(completed.output.sha256, at: completed.output.path, dataRoot: home)
        guard source.standardizedFileURL == media.url.standardizedFileURL else { throw changed() }
        _ = try FrameRasterizer.loadImage(at: source)
        let imageBytes = try Data(contentsOf: source)
        let imagePath = try ProductionWorkflowRecoveryMigration.outputPath(area: "storyboard/sketches",
            leaf: UUID().uuidString.lowercased() + "." + source.pathExtension.lowercased(), dataRoot: root)
        let image = PlanningWriterIO.reference(imagePath, id: "sketch-" + completed.output.sha256,
            role: "core.storyboard-sketch", bytes: imageBytes)
        let selectionRef = try PlanningWriterIO.reference(compilationPath, id: (compilationPath as NSString).lastPathComponent,
            role: "host.storyboard-sketch-compilation", dataRoot: root)
        let outputReceipt = try PlanningWriterIO.reference(GenerationOutputReceipt.path(assetID: media.id),
            id: "generated-output-" + media.id, role: "host.generation-output-receipt", dataRoot: home)
        let promptBytes = Data(actual.text.utf8)
        let promptPath = "storyboard/compiled-prompts/" + FileDigest.sha256(of: promptBytes) + ".txt"
        let promptRef = PlanningWriterIO.reference(promptPath, id: "sketch-prompt-" + FileDigest.sha256(of: promptBytes),
            role: "core.compiled-image-prompt", bytes: promptBytes)
        let evidence = try PipelineGenerationEvidenceSnapshot.capture(completed: completed, receipt: outputReceipt, home: home, area: .storyboard)
        let inputs = [selectionRef, selection.script, selection.compiled, actualRef] + evidence.references
        let receipt = GenerationReceipt(schema: "storyboard-sketch-generation/v1", projectKey: selection.projectKey,
            shotID: selection.shotID, momentID: selection.momentID, intentSHA256: selection.intentSHA256,
            framingSHA256: selection.framingSHA256, selection: selectionRef, outputReceipt: evidence.outputReceipt,
            image: image, compiled: actualRef, inputs: inputs)
        let receiptBytes = try PlanningWriterIO.json(receipt)
        let receiptID = FileDigest.sha256(of: receiptBytes)
        let receiptPath = "storyboard/sketch-generation-receipts/\(receiptID).v1.json"
        let receiptRef = PlanningWriterIO.reference(receiptPath, id: receiptID,
            role: "host.storyboard-sketch-generation", bytes: receiptBytes)
        let proof = StoryboardSketchProofV1(projectID: board.storyboard.header.projectID,
            shotID: selection.shotID, momentID: selection.momentID, intentSHA256: selection.intentSHA256,
            framingSHA256: selection.framingSHA256, image: image,
            source: .generated(modelID: actual.modelID, compiledPrompt: promptRef,
                providerRequestID: completed.providerRequestID, generationEventID: media.id,
                generationReceipt: receiptRef, inputs: inputs))
        let proofBytes = try PlanningWriterIO.json(proof)
        let proofPath = "storyboard/sketch-proofs/" + FileDigest.sha256(of: proofBytes) + ".v1.json"
        let asset = StoryboardTimingV1.SketchAsset(image: image, proof: PlanningWriterIO.reference(proofPath,
            id: "sketch-proof-" + receiptID, role: "core.storyboard-sketch-proof", bytes: proofBytes))
        var files: [(path: String, bytes: Data)] = [(imagePath, imageBytes), (receiptPath, receiptBytes), (proofPath, proofBytes)] + (try evidence.unpublishedFiles(dataRoot: root))
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(promptPath).path) {
            _ = try ProjectLocalFile.requireHash(promptRef.sha256, at: promptPath, dataRoot: root)
        } else { files.append((promptPath, promptBytes)) }
        let prepared = Prepared(targetShotID: selection.shotID, targetMomentID: selection.momentID, asset: asset, files: files)
        try access.revalidate()
        guard try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false).fingerprint == expectedFingerprint else { throw changed() }
        return try PipelineStoryboardBundleWriter.write(PipelineStoryboardBundleWriter.proposal(from: board,
            replacing: selection.momentID, in: selection.shotID, with: asset), origin: .agentRevision,
            access: access, generatedSketches: [prepared])
    }

    nonisolated static func requireGenerated(_ proof: StoryboardSketchProofV1, dataRoot: URL) throws {
        guard case .generated(let model, let prompt, let request, let event, let receiptRef, let inputs) = proof.source else { throw changed() }
        let receipt = try PlanningWriterIO.read(GenerationReceipt.self, at: receiptRef.path, dataRoot: dataRoot)
        _ = try ProjectLocalFile.requireHash(receiptRef.sha256, at: receiptRef.path, dataRoot: dataRoot)
        let home = FrameInventory.projectHome(of: dataRoot)
        guard receiptRef.path == "storyboard/sketch-generation-receipts/" + FileDigest.sha256(of: try PlanningWriterIO.json(receipt)) + ".v1.json",
              receipt.schema == "storyboard-sketch-generation/v1", receipt.projectKey == ProjectIdentity.existingUUID(for: home),
              receipt.shotID == proof.shotID, receipt.momentID == proof.momentID,
              receipt.intentSHA256 == proof.intentSHA256, receipt.framingSHA256 == proof.framingSHA256,
              receipt.image == proof.image, receipt.inputs == inputs,
              inputs.contains(receipt.selection), inputs.contains(receipt.outputReceipt), inputs.contains(receipt.compiled) else { throw changed() }
        for reference in inputs { _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot) }
        let selection = try PlanningWriterIO.read(CompileSelection.self, at: receipt.selection.path, dataRoot: dataRoot)
        guard receipt.selection.path == "storyboard/sketch-compilations/" + FileDigest.sha256(of: try PlanningWriterIO.json(selection)) + ".v1.json",
              inputs.contains(selection.compiled), inputs.contains(selection.script) else { throw changed() }
        let desired = try ProductionCompiledPromptStore.load(selection.compiled, dataRoot: dataRoot)
        let actual = try ProductionCompiledPromptStore.load(receipt.compiled, dataRoot: dataRoot)
        let completed = try GenerationOutputReceipt.load(assetID: event, home: home)
        guard selection.schema == "storyboard-sketch-compilation/v1", selection.projectKey == receipt.projectKey,
              selection.shotID == proof.shotID, selection.momentID == proof.momentID,
              selection.intentSHA256 == proof.intentSHA256, selection.framingSHA256 == proof.framingSHA256,
              desired.sourceIR == actual.sourceIR, actual.modelID == model, completed.providerRequestID == request,
              completed.input.prompt == actual.text, completed.input.model == model,
              completed.output.sha256 == proof.image.sha256,
              try Data(contentsOf: ProjectLocalFile.requireHash(prompt.sha256, at: prompt.path, dataRoot: dataRoot)) == Data(actual.text.utf8) else { throw changed() }
        let originalReceipt = try PlanningWriterIO.reference(GenerationOutputReceipt.path(assetID: event),
            id: "generated-output-" + event, role: "host.generation-output-receipt", dataRoot: home)
        let evidence = try PipelineGenerationEvidenceSnapshot.requireReferences(originals: [originalReceipt, completed.package, completed.output],
            inputs: inputs, home: home, dataRoot: dataRoot, area: .storyboard)
        let package = try GenerationPackageV1.load(id: completed.package.id, home: home)
        guard package.payload.binding == actual.binding, package.payload.generationInput == completed.input,
              package.payload.binding.projectKey == receipt.projectKey, package.payload.modality == "image",
              receipt.outputReceipt == evidence[0] else { throw changed() }
    }

    private static func requireSelection(path: String, editor: EditorViewModel) throws -> (CompileSelection, ProductionCompiledPromptStore.Record) {
        let access = try access(editor: editor)
        let value = try PlanningWriterIO.read(CompileSelection.self, at: path, dataRoot: access.dataRoot)
        let bytes = try PlanningWriterIO.json(value)
        guard path == "storyboard/sketch-compilations/" + FileDigest.sha256(of: bytes) + ".v1.json",
              value.schema == "storyboard-sketch-compilation/v1", value.workflow == access.workflow,
              value.projectKey == editor.projectId, value.projectKey == ProjectIdentity.existingUUID(for: FrameInventory.projectHome(of: access.dataRoot)) else { throw changed() }
        let board = try PlanningWriterIO.storyboard(dataRoot: access.dataRoot, requireVisuals: false)
        guard let shot = board.timing.shots.first(where: { $0.id == value.shotID }),
              let moment = shot.moments.first(where: { $0.id == value.momentID }),
              FileDigest.sha256(of: Data(moment.intent.utf8)) == value.intentSHA256,
              try shot.framing.fingerprint() == value.framingSHA256,
              board.storyboard.header.inputs.contains(value.script) else { throw changed() }
        let record = try ProductionCompiledPromptStore.load(value.compiled, dataRoot: access.dataRoot)
        guard record.modality == "image", record.binding.projectKey == value.projectKey, record.shotID == "none" else { throw changed() }
        return (value, record)
    }

    private static func access(editor: EditorViewModel) throws -> PipelinePlanningWriteAccess {
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { throw changed() }
        return try PipelinePlanningWriteAccess(dataRoot: root, declaration: .init(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract), phase: "storyboard")
    }

    nonisolated private static func changed() -> GateBlocked {
        GateBlocked("Compile the current Storyboard moment, generate its approved image request, then assign that exact completed output. The shot, framing, source or request changed.")
    }
}
