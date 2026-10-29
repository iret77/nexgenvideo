import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionFramesWriter {
    struct Receipt: Codable, Sendable, Equatable {
        let schema: String
        let shotID: String
        let role: String
        let projection: CanonicalArtifactReferenceV1
        let compilation: CanonicalArtifactReferenceV1
        let generation: GenerationOutputReceipt
        let inputs: [CanonicalArtifactReferenceV1]
        let frame: FrameEntry
    }

    nonisolated static func receiptPath(shotID: String, role: String) -> String {
        "frames/production-receipts/\(shotID)-\(role).v1.json"
    }

    nonisolated static func boundaryIntent(shot: ExecutionShotV1, role: String) -> String {
        let state = role == "end" ? shot.endState : shot.startState
        let camera = role == "end" ? shot.camera.endpoint : shot.camera.placement
        return ([state.summary, state.spatialState, camera].compactMap { $0 }
            + state.entityStateIDs.map { "Entity state: " + $0 }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "; ")
    }

    nonisolated static func nextPending(dataRoot: URL) throws -> (shot: ExecutionShotV1, role: String)? {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let frames = try loadFramesManifest(dataRoot: dataRoot)
        for shot in projection.shots {
            for role in projection.requiredFrameRoles(for: shot.id) {
                if (try? requireFrame(shotID: shot.id, role: role, projection: projection, dataRoot: dataRoot)) == nil {
                    return (shot, role)
                }
            }
        }
        guard frames.project == projection.header.projectID else { throw changed() }
        return nil
    }

    nonisolated static func prepare(access: PipelinePlanningWriteAccess) throws {
        try access.revalidate()
        let root = access.dataRoot
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        let manifestPath = PipelineLayout.renderManifestFile(phase: "frames")
        let hasManifest = FileManager.default.fileExists(atPath: root.appendingPathComponent(manifestPath).path)
        let snapshot = hasManifest ? try PipelineRenderRecordWriter.loadMutationSnapshot(dataRoot: root, phase: "frames",
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract) : nil
        let old = snapshot?.framesManifest ?? FramesManifest(project: projection.header.projectID, generated: currentTimestamp())
        guard old.project == projection.header.projectID else { throw changed() }
        let frames = try old.reconciled(with: projection, generated: old.generated)
        let eligible = Set(projection.shots.filter { !projection.requiredFrameRoles(for: $0.id).isEmpty }.map(\.id))
        var ledger = snapshot?.manifest ?? RenderManifest(project: projection.header.projectID, phase: "frames")
        ledger.entries = ledger.entries.filter { eligible.contains($0.key) }
        if snapshot?.publication != nil && frames == old && ledger == snapshot?.manifest { return }
        _ = try PipelineRenderRecordWriter.publish(manifest: ledger, proof: nil, routingProof: nil,
            framesManifest: frames, replacingShotID: nil, preparedLastFrame: nil, reconciledLastFrames: [:],
            expectedPublicationTransactionID: snapshot?.publication?.transactionID, dataRoot: root,
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
    }

    static func requireGeneration(compiled: (text: String, token: String, binding: PromptBinding)?,
                                  modelID: String, editor: EditorViewModel) throws {
        guard let compiled, let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { throw changed() }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        _ = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "frames")
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        guard let shot = projection.shots.first(where: { $0.id == compiled.binding.shotId }),
              let role = compiled.binding.frameRole, projection.requiredFrameRoles(for: shot.id).contains(role) else { throw changed() }
        let path = try ProductionCompiledPromptStore.path(binding: compiled.binding, modelID: modelID, text: compiled.text)
        let ref = try PlanningWriterIO.reference(path, id: "frame-compiler", role: "host.production-compiled-prompt", dataRoot: root)
        let record = try ProductionCompiledPromptStore.load(ref, dataRoot: root)
        let subject = try compilerSubject(record)
        guard record.modality == "image", record.binding == compiled.binding, record.text == compiled.text,
              record.binding.projectKey == editor.projectId,
              record.binding.shotFingerprint == FileDigest.sha256(of: try PlanningWriterIO.json(projection)),
              boundaryIntent(shot: shot, role: role) == subject else { throw changed() }
    }

    static func record(shotID: String, role: String, media: MediaAsset, access: PipelinePlanningWriteAccess,
                       editor: EditorViewModel) async throws -> FrameEntry {
        guard access.phase == "frames", media.type == .image, media.generationStatus == .none,
              editor.mediaAssets.contains(where: { $0 === media }), let input = media.generationInput,
              let packageID = input.generationPackageID, let plan = input.frameReferencePlan else { throw changed() }
        let root = access.dataRoot
        let home = FrameInventory.projectHome(of: root)
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        guard let shot = projection.shots.first(where: { $0.id == shotID }), projection.requiredFrameRoles(for: shotID).contains(role) else { throw changed() }
        let completed = try GenerationOutputReceipt.load(assetID: media.id, home: home)
        let package = try GenerationPackageV1.load(id: packageID, home: home)
        let compiledPath = try ProductionCompiledPromptStore.path(binding: package.payload.binding,
            modelID: input.model, text: input.prompt)
        let compilation = try PlanningWriterIO.reference(compiledPath, id: "frame-compiler-" + shotID,
            role: "host.production-compiled-prompt", dataRoot: root)
        let compiled = try ProductionCompiledPromptStore.load(compilation, dataRoot: root)
        let fingerprint = FileDigest.sha256(of: try PlanningWriterIO.json(projection))
        guard completed.input == GenerationPackageV1.normalized(input), completed.modality == "image",
              compiled.modality == "image", compiled.binding == package.payload.binding,
              compiled.binding.projectKey == editor.projectId, compiled.binding.shotId == shotID,
              compiled.binding.shotFingerprint == fingerprint, compiled.binding.frameRole == role,
              compiled.binding.frameReferencePlanSHA256 == plan.fingerprint,
              package.payload.outputCount == 1, package.payload.generationInput == completed.input,
              package.payload.references == input.referenceReceipts,
              package.payload.references.count == plan.bindings.count,
              zip(package.payload.references, plan.bindings).allSatisfy({ $0.0.sourceSHA256 == $0.1.sha256 && $0.0.submittedSHA256 == $0.1.sha256 }),
              try compilerSubject(compiled) == boundaryIntent(shot: shot, role: role),
              try await PipelineProductionPromptCompiler.framePlan(shotID: shotID, modelID: input.model,
                dataRoot: root, catalog: editor.generationBatchCoordinator.modelCatalog, frameRole: role) == plan else { throw changed() }
        try access.revalidate()
        guard editor.workingRoot == home, media.generationInput == input,
              try ProductionPlanningLineageV2.projection(dataRoot: root) == projection else { throw changed() }
        let source = try ProjectLocalFile.requireHash(completed.output.sha256, at: completed.output.path, dataRoot: home)
        guard source.standardizedFileURL == media.url.standardizedFileURL else { throw changed() }
        _ = try FrameRasterizer.loadImage(at: source)
        let bytes = try Data(contentsOf: source)
        let output = try ProductionWorkflowRecoveryMigration.outputPath(area: "frames",
            leaf: "\(shotID)-\(role)-\(UUID().uuidString.lowercased()).\(source.pathExtension.lowercased())", dataRoot: root)
        let frame = FrameEntry(role: role, path: output, prompt: input.intent ?? "", runwayModel: input.model,
            providerPrompt: input.prompt, multiRefHints: PromptComposer.frameReferenceHints(plan.bindings))
        let reference = try PlanningWriterIO.reference(ProductionPlanProjectionV1.versionPath(projection.header.revision),
            id: "production-plan", role: "core.production-plan", dataRoot: root)
        let generationRef = try PlanningWriterIO.reference(GenerationOutputReceipt.path(assetID: completed.assetID),
            id: completed.assetID, role: "host.generation-output-receipt", dataRoot: home)
        let inputs = [reference, compilation, generationRef, completed.package, completed.output]
            + plan.bindings.map { CanonicalArtifactReferenceV1(id: $0.entityID + "." + $0.viewID,
                role: $0.role, path: $0.path, sha256: $0.sha256) }
        let receipt = Receipt(schema: "production-frame-receipt/v1", shotID: shotID, role: role,
            projection: reference, compilation: compilation, generation: completed, inputs: inputs, frame: frame)
        let usage = FrameReferenceUsageV1(shotID: shotID, role: role, outputPath: output,
            outputSHA256: completed.output.sha256, modelID: input.model, generationPackageID: packageID, plan: plan)
        let snapshot = try PipelineRenderRecordWriter.loadMutationSnapshot(dataRoot: root, phase: "frames",
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
        guard let old = snapshot.framesManifest else { throw changed() }
        let roles = projection.requiredFrameRoles(for: shotID)
        let strategy = roles == ["start", "end"] ? "start_end" : "start"
        let frames = try old.reconciled(with: projection, generated: old.generated)
            .upserting(shotId: shotID, keyframeStrategy: strategy, frame: frame)
        var ledger = snapshot.manifest
        ledger.entries[shotID] = RenderEntry(shotId: shotID, phase: "frames", status: .rendered,
            output: output, costEur: 0, updatedAt: currentTimestamp(), referencePaths: plan.bindings.map(\.path))
        let canonical = [manifestPath(), PipelineLayout.framesManifestFile,
            RenderRecordPublicationV1.artifactPath(phase: "frames"), RenderShotProvenancePublicationV1.artifactPath(phase: "frames"),
            receiptPath(shotID: shotID, role: role), FrameReferenceUsageStoreV1.path(shotID: shotID, role: role),
            PipelineLayout.gatesFile, PipelineLayout.lineageFile, output]
        try ArtifactTransaction.perform(paths: canonical.map { root.appendingPathComponent($0) }, dataRoot: root) {
            try access.revalidate()
            try ProductionWorkflowRecoveryMigration.requireNewOutput(output, dataRoot: root)
            _ = try ProjectLocalFile.ensureDirectory((output as NSString).deletingLastPathComponent, dataRoot: root)
            try bytes.write(to: root.appendingPathComponent(output), options: .withoutOverwriting)
            _ = try PipelineRenderRecordWriter.publish(manifest: ledger, proof: nil, routingProof: nil,
                framesManifest: frames, replacingShotID: shotID, preparedLastFrame: nil,
                additionalArtifacts: [receiptPath(shotID: shotID, role: role): try PlanningWriterIO.json(receipt),
                    FrameReferenceUsageStoreV1.path(shotID: shotID, role: role): try FrameReferenceUsageStoreV1.encode(usage)],
                expectedPublicationTransactionID: snapshot.publication?.transactionID, dataRoot: root,
                declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
                declaredProductionContract: access.declaration.productionContract)
            _ = try requireFrame(shotID: shotID, role: role, projection: projection, dataRoot: root)
            try access.revalidate()
            try PipelinePhaseMutationRecorder.record(phase: "frames", dataRoot: root, captureLineage: true,
                declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
                declaredProductionContract: access.declaration.productionContract)
        }
        return frame
    }

    nonisolated static func requireFrame(shotID: String, role: String, projection: ProductionPlanProjectionV1,
                                        dataRoot: URL) throws -> FrameEntry {
        guard let shot = projection.shots.first(where: { $0.id == shotID }), projection.requiredFrameRoles(for: shotID).contains(role),
              let frame = try loadFramesManifest(dataRoot: dataRoot).shot(shotID)?.frames.first(where: { $0.role == role }) else { throw changed() }
        let receipt = try PlanningWriterIO.read(Receipt.self, at: receiptPath(shotID: shotID, role: role), dataRoot: dataRoot)
        let completed = try GenerationOutputReceipt.load(assetID: receipt.generation.assetID, home: FrameInventory.projectHome(of: dataRoot))
        let package = try GenerationPackageV1.load(id: completed.package.id, home: FrameInventory.projectHome(of: dataRoot))
        let compiled = try ProductionCompiledPromptStore.load(receipt.compilation, dataRoot: dataRoot)
        let usage = try FrameReferenceUsageStoreV1.load(shotID: shotID, role: role, dataRoot: dataRoot)
        var recorded = receipt.frame
        recorded.approved = frame.approved
        guard receipt.schema == "production-frame-receipt/v1", receipt.shotID == shotID, receipt.role == role,
              recorded == frame, completed == receipt.generation, compiled.binding == package.payload.binding,
              receipt.projection.path == ProductionPlanProjectionV1.versionPath(projection.header.revision),
              compiled.binding.shotFingerprint == FileDigest.sha256(of: try PlanningWriterIO.json(projection)),
              compiled.binding.projectKey == completed.projectKey, compiled.binding.shotId == shotID,
              compiled.modality == "image", compiled.text == frame.providerPrompt, compiled.modelID == frame.runwayModel,
              try compilerSubject(compiled) == boundaryIntent(shot: shot, role: role),
              usage.plan == completed.input.frameReferencePlan, usage.plan.isExecutable,
              compiled.binding.frameReferencePlanSHA256 == usage.plan.fingerprint, compiled.binding.frameRole == role,
              package.payload.outputCount == 1, package.payload.modality == "image",
              package.payload.references.count == usage.plan.bindings.count,
              zip(package.payload.references, usage.plan.bindings).allSatisfy({ $0.0.sourceSHA256 == $0.1.sha256 && $0.0.submittedSHA256 == $0.1.sha256 }),
              usage.modelID == frame.runwayModel,
              usage.outputPath == frame.path, usage.outputSHA256 == completed.output.sha256,
              usage.generationPackageID == completed.package.id,
              try FileDigest.sha256(of: ProjectLocalFile.resolve(frame.path, dataRoot: dataRoot)) == completed.output.sha256 else { throw changed() }
        let generationRef = try PlanningWriterIO.reference(GenerationOutputReceipt.path(assetID: completed.assetID),
            id: completed.assetID, role: "host.generation-output-receipt", dataRoot: FrameInventory.projectHome(of: dataRoot))
        guard [receipt.projection, receipt.compilation, generationRef, completed.package, completed.output]
            .allSatisfy({ receipt.inputs.contains($0) }), usage.plan.bindings.allSatisfy({ binding in
                receipt.inputs.contains(where: { $0.path == binding.path && $0.sha256 == binding.sha256 })
            }) else { throw changed() }
        for reference in receipt.inputs { _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot) }
        _ = try FrameRasterizer.loadImage(at: ProjectLocalFile.resolve(frame.path, dataRoot: dataRoot))
        for ref in usage.plan.bindings { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot) }
        return frame
    }

    nonisolated static func requireCurrent(projection: ProductionPlanProjectionV1, dataRoot: URL) throws {
        for shot in projection.shots {
            for role in projection.requiredFrameRoles(for: shot.id) {
                _ = try requireFrame(shotID: shot.id, role: role, projection: projection, dataRoot: dataRoot)
            }
        }
    }

    nonisolated private static func compilerSubject(_ record: ProductionCompiledPromptStore.Record) throws -> String? {
        (try JSONSerialization.jsonObject(with: record.sourceIR) as? [String: Any])?["subject"] as? String
    }

    nonisolated private static func manifestPath() -> String { PipelineLayout.renderManifestFile(phase: "frames") }
    nonisolated private static func changed() -> GateBlocked {
        GateBlocked("Generate the current shot's exact boundary intent through the image compiler, then record its completed host request and unchanged references.")
    }
}
