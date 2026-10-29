import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionSubmissionAuthority {
    static func requireReviewed(input: GenerationInput, proof: ProductionGenerationRoutingProofV1,
                                editor: EditorViewModel, dataRoot: URL) throws {
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let access = try PipelinePlanningWriteAccess(dataRoot: dataRoot, declaration: declaration, phase: "render")
        let gates = try YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        try GateGuard.requirePriorApproved(gates, order: PhaseContractRuntime.order(workflow: access.workflow), phase: "render")
        guard let review = try PipelineRenderReviewWriter.loadIfPresent(dataRoot: dataRoot),
              let shot = review.shots.first(where: { $0.shotID == proof.shotID }),
              let compiledRef = shot.compiledPrompt else { throw changed() }
        try PipelineRenderReviewWriter.requireCurrent(review, dataRoot)
        let compiled = try ProductionCompiledPromptStore.load(compiledRef, dataRoot: dataRoot)
        guard compiled.modality == "video", compiled.modelID == input.model, compiled.text == input.prompt,
              compiled.binding.shotId == input.promptShotId,
              compiled.binding.shotFingerprint == input.promptShotFingerprint,
              compiled.binding.projectKey == input.promptProjectKey,
              compiled.binding.promptIRSHA256 == shot.promptIRSHA256 else { throw changed() }
        let bundle = try PipelineProductionInputMaterializer.requireCurrent(shotID: proof.shotID, dataRoot: dataRoot)
        guard proof.productionMaterialization == bundle.reference, proof.route == bundle.route,
              proof.referencePlan == bundle.plan, proof.requirement == bundle.receipt.requirement else { throw changed() }
        if let recipe = shot.predecessor {
            guard let predecessor = bundle.receipt.predecessor, predecessor.shotID == recipe.predecessorShotID else { throw changed() }
            let actual = bundle.plan.bindings.map { CanonicalArtifactReferenceV1(id: $0.assetID,
                role: $0.semanticJobID, path: $0.path, sha256: $0.sha256) }
            if recipe.strategy == .frameContinuation {
                guard let frame = predecessor.lastFrame, actual == [frame] else { throw changed() }
            } else {
                guard predecessor.lastFrame == nil, actual.contains(predecessor.outputVideo),
                      Set(actual.map(\.path)) == Set(([predecessor.outputVideo] + recipe.permittedOriginalReferences).map(\.path)),
                      recipe.permittedOriginalReferences.allSatisfy({ actual.contains($0) }) else { throw changed() }
            }
        }
        if shot.predecessor == nil {
            let actual = bundle.plan.bindings.map { CanonicalArtifactReferenceV1(id: $0.assetID,
                role: $0.semanticJobID, path: $0.path, sha256: $0.sha256) }
            guard shot.conditioning == actual, shot.route == bundle.receipt.route else { throw changed() }
        }
        try access.revalidate()
    }

    struct Receipt: Codable, Sendable, Equatable {
        let schema: String
        let projectKey: String
        let generation: CanonicalArtifactReferenceV1
        let materialization: CanonicalArtifactReferenceV1
        let binding: RenderSubmissionBindingV1
    }

    struct Prepared: Sendable {
        let binding: RenderSubmissionBindingV1
        let reference: CanonicalArtifactReferenceV1
        let files: [(path: String, bytes: Data)]
    }

    static func prepare(media: MediaAsset, editor: EditorViewModel, dataRoot: URL) throws -> Prepared {
        guard let input = media.generationInput, let routing = input.productionRouting,
              let packageID = input.generationPackageID, media.type == .video, media.generationStatus == .none else { throw changed() }
        try requireReviewed(input: input, proof: routing, editor: editor, dataRoot: dataRoot)
        let home = FrameInventory.projectHome(of: dataRoot)
        let completed = try GenerationOutputReceipt.load(assetID: media.id, home: home)
        let package = try GenerationPackageV1.load(id: packageID, home: home)
        guard completed.input == GenerationPackageV1.normalized(input), package.payload.generationInput == completed.input,
              completed.modality == "video", package.payload.outputCount == 1,
              let review = try PipelineRenderReviewWriter.loadIfPresent(dataRoot: dataRoot),
              let shot = review.shots.first(where: { $0.shotID == routing.shotID }),
              let compiled = shot.compiledPrompt, let route = shot.route, let ir = shot.promptIRSHA256 else { throw changed() }
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let reviewRef = try PlanningWriterIO.reference(RenderReviewV1.versionPath(review.header.revision),
            id: "render-review", role: "core.render-review", dataRoot: dataRoot)
        let actual = routing.referencePlan.bindings.map { CanonicalArtifactReferenceV1(id: $0.assetID,
            role: $0.semanticJobID, path: $0.path, sha256: $0.sha256) }
        let binding = RenderSubmissionBindingV1(projectID: review.header.projectID, requestID: "host-event:" + media.id,
            shotID: routing.shotID, review: reviewRef, compiledPrompt: compiled, route: route,
            promptIRSHA256: ir, inputs: actual,
            predecessor: try PipelineProductionInputMaterializer.requireCurrent(shotID: routing.shotID, dataRoot: dataRoot).receipt.predecessor)
        try binding.validate(review: review, projection: projection)
        let receipt = try receipt(binding: binding, dataRoot: dataRoot)
        let bytes = try PlanningWriterIO.json(receipt)
        let id = FileDigest.sha256(of: bytes)
        let directory = "renders/submissions/" + id
        let bindingBytes = try PlanningWriterIO.json(binding)
        let reference = PlanningWriterIO.reference(directory + "/binding.v1.json", id: id,
            role: "host.render-submission", bytes: bindingBytes)
        return Prepared(binding: binding, reference: reference,
            files: [(directory + "/receipt.v1.json", bytes), (reference.path, bindingBytes)])
    }

    nonisolated static func requireBinding(_ binding: RenderSubmissionBindingV1, _ dataRoot: URL) throws {
        let reviewed = try PlanningWriterIO.read(RenderReviewV1.self, at: binding.review.path, dataRoot: dataRoot)
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        try binding.requireCurrentEvidence(review: reviewed, projection: projection, dataRoot: dataRoot,
            reviewVerifier: { try PipelineRenderReviewWriter.requireCurrent($0, $1) },
            submissionVerifier: verifyReceipt)
    }

    nonisolated private static func verifyReceipt(_ binding: RenderSubmissionBindingV1, _ dataRoot: URL) throws {
        let receipt = try receipt(binding: binding, dataRoot: dataRoot)
        let bytes = try PlanningWriterIO.json(receipt)
        let directory = "renders/submissions/" + FileDigest.sha256(of: bytes)
        guard try Data(contentsOf: ProjectLocalFile.resolve(directory + "/receipt.v1.json", dataRoot: dataRoot)) == bytes,
              try Data(contentsOf: ProjectLocalFile.resolve(directory + "/binding.v1.json", dataRoot: dataRoot)) == PlanningWriterIO.json(binding) else { throw changed() }
        let current = try PipelineProductionInputMaterializer.requireCurrent(shotID: binding.shotID, dataRoot: dataRoot)
        guard current.reference == receipt.materialization, current.receipt.predecessor == binding.predecessor else { throw changed() }
    }

    nonisolated private static func receipt(binding: RenderSubmissionBindingV1, dataRoot: URL) throws -> Receipt {
        let prefix = "host-event:"
        guard binding.requestID.hasPrefix(prefix) else { throw changed() }
        let eventID = String(binding.requestID.dropFirst(prefix.count))
        let home = FrameInventory.projectHome(of: dataRoot)
        let completed = try GenerationOutputReceipt.load(assetID: eventID, home: home)
        guard let routing = completed.input.productionRouting, let materialization = routing.productionMaterialization,
              completed.modality == "video", routing.shotID == binding.shotID,
              completed.input.promptShotId == binding.shotID else { throw changed() }
        let package = try GenerationPackageV1.load(id: completed.package.id, home: home)
        let compiled = try ProductionCompiledPromptStore.load(binding.compiledPrompt, dataRoot: dataRoot)
        guard package.payload.binding == compiled.binding, compiled.modality == "video",
              compiled.text == completed.input.prompt, compiled.modelID == completed.input.model,
              compiled.binding.promptIRSHA256 == binding.promptIRSHA256,
              binding.inputs == routing.referencePlan.bindings.map({ .init(id: $0.assetID,
                role: $0.semanticJobID, path: $0.path, sha256: $0.sha256) }) else { throw changed() }
        let generation = try PlanningWriterIO.reference(GenerationOutputReceipt.path(assetID: eventID),
            id: eventID, role: "host.generation-output-receipt", dataRoot: home)
        _ = try ProjectLocalFile.requireHash(materialization.sha256, at: materialization.path, dataRoot: dataRoot)
        try PipelineProductionRouting.validateHistoricalProof(routing, dataRoot: dataRoot)
        return Receipt(schema: "production-render-submission/v1", projectKey: completed.projectKey,
            generation: generation, materialization: materialization, binding: binding)
    }

    nonisolated private static func changed() -> GateBlocked {
        GateBlocked("The final request differs from the approved Render Review. Review its actual prompt, model, source range and ordered inputs before submitting it.")
    }
}
