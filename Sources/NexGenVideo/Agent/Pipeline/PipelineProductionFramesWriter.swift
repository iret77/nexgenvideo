import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionFramesWriter {
    struct RecordResult: Sendable {
        let frame: FrameEntry
        let candidateID: String
        let isActive: Bool
    }

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

    nonisolated static func boundaryIntent(shot: ExecutionShotV1, role: String, endBoundary: ProductionFrameBoundaryV1? = nil) -> String {
        let state = role == "end" ? shot.endState : shot.startState
        let camera = role == "end" ? shot.camera.endpoint : shot.camera.placement
        return PromptComposer.normalize(([state.summary, state.spatialState, camera].compactMap { $0 }
            + state.entityStateIDs.map { "Entity state: " + $0 }
            + (role == "end" ? endBoundary?.promptConstraints ?? [] : []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "; "))
    }

    nonisolated static func boundaryRole(intent: String, requestedRole: String?, shot: ExecutionShotV1,
                                        requiredRoles: [String], endBoundary: ProductionFrameBoundaryV1? = nil) throws -> String {
        let bytes = Data(PromptComposer.normalize(intent).utf8)
        let matches = requiredRoles.filter { ["start", "end"].contains($0)
            && Data(boundaryIntent(shot: shot, role: $0, endBoundary: endBoundary).utf8) == bytes }
        if let requestedRole {
            guard matches.contains(requestedRole) else {
                throw ToolError("Compile the exact canonical intent for the requested required frameRole (start or end).")
            }
            return requestedRole
        }
        guard matches.count == 1, let role = matches.first else {
            throw ToolError("Pass frameRole from next_render_shot and its exact canonical visual_prompt. A shared start/end intent requires an explicit role.")
        }
        return role
    }

    nonisolated static func nextPending(dataRoot: URL) throws -> (shot: ExecutionShotV1, role: String)? {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let frames = try loadFramesManifest(dataRoot: dataRoot)
        guard frames.project == projection.header.projectID else { throw changed() }
        for shot in projection.shots {
            for role in projection.requiredFrameRoles(for: shot.id) {
                if let iteration = try PipelineProductionFrameCandidates.currentIteration(shotID: shot.id, role: role, dataRoot: dataRoot) {
                    let ref = try PipelineProductionFrameCandidates.iterationReference(iteration)
                    let index = try PipelineProductionFrameCandidates.load(shotID: shot.id, role: role,
                        project: projection.header.projectID, dataRoot: dataRoot)
                    let completed = try index.candidates.contains { candidate in
                        try PipelineProductionFrameCandidates.candidate(candidate, index: index, dataRoot: dataRoot).receipt.inputs.contains(ref)
                    }
                    if !completed { return (shot, role) }
                }
                guard frames.shot(shot.id)?.frames.contains(where: { $0.role == role }) == true else { return (shot, role) }
                _ = try requireFrame(shotID: shot.id, role: role, projection: projection, dataRoot: dataRoot)
            }
        }
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
              boundaryIntent(shot: shot, role: role, endBoundary: projection.endFrameBoundaries[shot.id]) == subject else { throw changed() }
    }

    static func record(shotID: String, role: String, media: MediaAsset, access: PipelinePlanningWriteAccess,
                       editor: EditorViewModel) async throws -> RecordResult {
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
              package.payload.outputCount == 1, package.payload.modality == "image", package.payload.generationInput == completed.input,
              package.payload.references == input.referenceReceipts,
              package.payload.references.count == plan.bindings.count,
              zip(package.payload.references, plan.bindings).allSatisfy({ $0.0.sourceSHA256 == $0.1.sha256 && $0.0.submittedSHA256 == $0.1.sha256 }),
              try compilerSubject(compiled) == boundaryIntent(shot: shot, role: role, endBoundary: projection.endFrameBoundaries[shot.id]),
              try await PipelineProductionPromptCompiler.framePlan(shotID: shotID, modelID: input.model,
                dataRoot: root, catalog: editor.generationBatchCoordinator.modelCatalog, frameRole: role) == plan else { throw changed() }
        try access.revalidate()
        guard editor.workingRoot == home, media.generationInput == input,
              try ProductionPlanningLineageV2.projection(dataRoot: root) == projection else { throw changed() }
        let source = try ProjectLocalFile.requireHash(completed.output.sha256, at: completed.output.path, dataRoot: home)
        guard source.standardizedFileURL == media.url.standardizedFileURL else { throw changed() }
        var candidateIndex = try PipelineProductionFrameCandidates.load(shotID: shotID, role: role,
            project: projection.header.projectID, dataRoot: root)
        for ref in candidateIndex.candidates {
            let existing = try PipelineProductionFrameCandidates.candidate(ref, index: candidateIndex, dataRoot: root)
            if existing.receipt.generation.assetID == completed.assetID {
                guard existing.receipt.generation == completed else { throw changed() }
                let frame = try requireEvidence(receipt: existing.receipt, usage: existing.usage, projection: projection, dataRoot: root)
                return .init(frame: frame, candidateID: ref.id, isActive: candidateIndex.active == ref.id)
            }
        }
        _ = try FrameRasterizer.loadImage(at: source)
        let bytes = try Data(contentsOf: source)
        guard FileDigest.sha256(of: bytes) == completed.output.sha256 else { throw changed() }
        let output = try ProductionWorkflowRecoveryMigration.outputPath(area: "frames",
            leaf: "\(shotID)-\(role)-\(UUID().uuidString.lowercased()).\(source.pathExtension.lowercased())", dataRoot: root)
        let frame = FrameEntry(role: role, path: output, prompt: input.intent ?? "", runwayModel: input.model,
            providerPrompt: input.prompt, multiRefHints: PromptComposer.frameReferenceHints(plan.bindings))
        let reference = try PlanningWriterIO.reference(ProductionPlanProjectionV1.versionPath(projection.header.revision),
            id: "production-plan", role: "core.production-plan", dataRoot: root)
        let generationRef = try PlanningWriterIO.reference(GenerationOutputReceipt.path(assetID: completed.assetID),
            id: completed.assetID, role: "host.generation-output-receipt", dataRoot: home)
        let evidence = try PipelineGenerationEvidenceSnapshot.capture(completed: completed, receipt: generationRef, home: home, area: .frames)
        let evidenceFiles = try evidence.unpublishedFiles(dataRoot: root)
        let iteration = try PipelineProductionFrameCandidates.currentIteration(shotID: shotID, role: role, dataRoot: root)
        let iterationInputs = try iteration.map { [try PipelineProductionFrameCandidates.iterationReference($0)] + $0.sources.map(\.candidate) } ?? []
        let inputs = [reference, compilation] + evidence.references + iterationInputs
            + plan.bindings.map { CanonicalArtifactReferenceV1(id: $0.entityID + "." + $0.viewID,
                role: $0.role, path: $0.path, sha256: $0.sha256) }
        let receipt = Receipt(schema: "production-frame-receipt/v1", shotID: shotID, role: role,
            projection: reference, compilation: compilation, generation: completed, inputs: inputs, frame: frame)
        let usage = FrameReferenceUsageV1(shotID: shotID, role: role, outputPath: output,
            outputSHA256: completed.output.sha256, modelID: input.model, generationPackageID: packageID, plan: plan)
        let candidate = PipelineProductionFrameCandidates.Candidate(receipt: receipt, usage: usage)
        let candidateFiles = try PipelineProductionFrameCandidates.archive(candidate, index: &candidateIndex, dataRoot: root)
        let files = candidateFiles + evidenceFiles
        let canonical = [manifestPath(), PipelineLayout.framesManifestFile,
            RenderRecordPublicationV1.artifactPath(phase: "frames"), RenderShotProvenancePublicationV1.artifactPath(phase: "frames"),
            receiptPath(shotID: shotID, role: role), FrameReferenceUsageStoreV1.path(shotID: shotID, role: role),
            PipelineLayout.gatesFile, PipelineLayout.lineageFile, output] + files.map(\.path)
        try ArtifactTransaction.perform(paths: canonical.map { root.appendingPathComponent($0) }, dataRoot: root) {
            try access.revalidate()
            try ProductionWorkflowRecoveryMigration.requireNewOutput(output, dataRoot: root)
            _ = try ProjectLocalFile.ensureDirectory((output as NSString).deletingLastPathComponent, dataRoot: root)
            try bytes.write(to: root.appendingPathComponent(output), options: .withoutOverwriting)
            if candidateIndex.active == (try candidate.id) {
                try publish(candidate: candidate, files: files, access: access)
            } else {
                try access.publish(files) {
                    _ = try requireEvidence(receipt: receipt, usage: usage, projection: projection, dataRoot: root)
                    _ = try PipelineProductionFrameCandidates.load(shotID: shotID, role: role,
                        project: projection.header.projectID, dataRoot: root)
                }
            }
        }
        return .init(frame: frame, candidateID: try candidate.id, isActive: candidateIndex.active == (try candidate.id))
    }

    nonisolated static func publish(candidate: PipelineProductionFrameCandidates.Candidate,
        files: [(path: String, bytes: Data)], access: PipelinePlanningWriteAccess) throws {
        try access.revalidate()
        let root = access.dataRoot, receipt = candidate.receipt, usage = candidate.usage
        let shotID = receipt.shotID, role = receipt.role, frame = receipt.frame
        for file in files {
            _ = try ProjectLocalFile.ensureDirectory((file.path as NSString).deletingLastPathComponent, dataRoot: root)
            try file.bytes.write(to: root.appendingPathComponent(file.path), options: .atomic)
        }
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        let snapshot = try PipelineRenderRecordWriter.loadMutationSnapshot(dataRoot: root, phase: "frames",
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
        guard let old = snapshot.framesManifest else { throw changed() }
        let roles = projection.requiredFrameRoles(for: shotID)
        let frames = try old.reconciled(with: projection, generated: old.generated)
            .upserting(shotId: shotID, keyframeStrategy: ProductionPlanFramesV1.strategy(roles), frame: frame)
        let references = try (frames.shot(shotID)?.frames ?? []).flatMap { current -> [String] in
            let bound: FrameReferenceUsageV1
            if current.role == role { bound = usage }
            else { bound = try FrameReferenceUsageStoreV1.load(shotID: shotID, role: current.role, dataRoot: root) }
            guard bound.outputPath == current.path else { throw changed() }
            return bound.plan.bindings.map(\.path)
        }
        var ledger = snapshot.manifest
        ledger.entries[shotID] = RenderEntry(shotId: shotID, phase: "frames", status: .rendered,
            output: frame.path, costEur: 0, updatedAt: currentTimestamp(), referencePaths: Array(Set(references)).sorted())
        let artifacts = [receiptPath(shotID: shotID, role: role): try PlanningWriterIO.json(receipt),
            FrameReferenceUsageStoreV1.path(shotID: shotID, role: role): try FrameReferenceUsageStoreV1.encode(usage)]
        _ = try PipelineRenderRecordWriter.publish(manifest: ledger, proof: nil, routingProof: nil,
            framesManifest: frames, replacingShotID: shotID, preparedLastFrame: nil, additionalArtifacts: artifacts,
            expectedPublicationTransactionID: snapshot.publication?.transactionID, dataRoot: root,
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
        _ = try requireFrame(shotID: shotID, role: role, projection: projection, dataRoot: root)
        try access.revalidate()
        try PipelinePhaseMutationRecorder.record(phase: "frames", dataRoot: root, captureLineage: true,
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
    }

    nonisolated static func requireFrame(shotID: String, role: String, projection: ProductionPlanProjectionV1,
                                        dataRoot: URL) throws -> FrameEntry {
        guard projection.shots.contains(where: { $0.id == shotID }), projection.requiredFrameRoles(for: shotID).contains(role),
              let frame = try loadFramesManifest(dataRoot: dataRoot).shot(shotID)?.frames.first(where: { $0.role == role }) else { throw changed() }
        let receipt = try PlanningWriterIO.read(Receipt.self, at: receiptPath(shotID: shotID, role: role), dataRoot: dataRoot)
        var recorded = receipt.frame
        recorded.approved = frame.approved
        guard recorded == frame else { throw changed() }
        let usage = try FrameReferenceUsageStoreV1.load(shotID: shotID, role: role, dataRoot: dataRoot)
        _ = try requireEvidence(receipt: receipt, usage: usage, projection: projection, dataRoot: dataRoot)
        try PipelineProductionFrameCandidates.requireActive(receipt: receipt, usage: usage, dataRoot: dataRoot)
        return frame
    }

    nonisolated static func requireEvidence(receipt: Receipt, usage: FrameReferenceUsageV1,
        projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> FrameEntry {
        let shotID = receipt.shotID, role = receipt.role, frame = receipt.frame
        guard let shot = projection.shots.first(where: { $0.id == shotID }),
              projection.requiredFrameRoles(for: shotID).contains(role) else { throw changed() }
        let completed = try GenerationOutputReceipt.load(assetID: receipt.generation.assetID, home: FrameInventory.projectHome(of: dataRoot))
        let package = try GenerationPackageV1.load(id: completed.package.id, home: FrameInventory.projectHome(of: dataRoot))
        let compiled = try ProductionCompiledPromptStore.load(receipt.compilation, dataRoot: dataRoot)
        guard receipt.schema == "production-frame-receipt/v1", receipt.shotID == shotID, receipt.role == role, frame.role == role,
              completed == receipt.generation, compiled.binding == package.payload.binding,
              receipt.projection.path == ProductionPlanProjectionV1.versionPath(projection.header.revision),
              compiled.binding.shotFingerprint == FileDigest.sha256(of: try PlanningWriterIO.json(projection)),
              compiled.binding.projectKey == completed.projectKey, compiled.binding.shotId == shotID,
              compiled.modality == "image", compiled.text == frame.providerPrompt, compiled.modelID == frame.runwayModel,
              try compilerSubject(compiled) == boundaryIntent(shot: shot, role: role, endBoundary: projection.endFrameBoundaries[shot.id]),
              usage.plan == completed.input.frameReferencePlan, usage.plan.isExecutable,
              usage.schema == FrameReferenceUsageV1.schemaVersion, usage.shotID == shotID, usage.role == role,
              usage.plan.shotID == shotID,
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
        let home = FrameInventory.projectHome(of: dataRoot)
        let originals = [generationRef, completed.package, completed.output]
        let evidence = try PipelineGenerationEvidenceSnapshot.requireReferences(originals: originals, inputs: receipt.inputs,
            home: home, dataRoot: dataRoot, area: .frames)
        guard ([receipt.projection, receipt.compilation] + evidence)
            .allSatisfy({ receipt.inputs.contains($0) }), usage.plan.bindings.allSatisfy({ binding in
                receipt.inputs.contains(where: { $0.path == binding.path && $0.sha256 == binding.sha256 })
            }) else { throw changed() }
        for reference in receipt.inputs { _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot) }
        _ = try FrameRasterizer.loadImage(at: ProjectLocalFile.resolve(frame.path, dataRoot: dataRoot))
        for ref in usage.plan.bindings { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot) }
        try PipelineProductionFrameCandidates.requireIterationEvidence(inputs: receipt.inputs, usage: usage, projection: projection, dataRoot: dataRoot)
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
