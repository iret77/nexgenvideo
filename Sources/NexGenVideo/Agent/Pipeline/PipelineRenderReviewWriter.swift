import Foundation
import NexGenEngine

@MainActor
enum PipelineRenderReviewWriter {
    struct SourceInputRange: Codable, Sendable, Equatable {
        let timebase: RationalTimebaseV1
        let startTicks: Int64
        let durationTicks: Int64
    }

    struct CapturedShot: Codable, Sendable, Equatable {
        let shotID: String
        let sourceMode: ExecutionSourceModeV1
        let compiledPrompt: String?
        let modelID: String?
        let sourceInput: CanonicalArtifactReferenceV1?
        let sourceInputRange: SourceInputRange?
        let review: RenderReviewV1.ShotReview
    }

    struct Snapshot: Codable, Sendable, Equatable {
        let fingerprint: String
        let workflow: HostWorkflowKey
        let projectKey: String
        let projection: ProductionPlanProjectionV1
        let shots: [CapturedShot]
        let references: [CanonicalArtifactReferenceV1]
        let absentPaths: [String]
    }

    private struct Receipt: Codable, Sendable, Equatable {
        let schema: String
        let id: String
        let snapshot: Snapshot
        let reviewer: SequenceReviewerProvenanceV1
        let findings: [RenderReviewV1.Finding]
        let submittedFindings: [RenderReviewV1.Finding]
        let previousReview: CanonicalArtifactReferenceV1?
        let agentEvidence: HostAgentReviewEvidence?
        let context: CanonicalArtifactReferenceV1?
        let reviewedAt: String
        let aggregate: CanonicalArtifactReferenceV1?
    }

    private struct Acceptance: Codable, Sendable, Equatable {
        let schema: String
        let id: String
        let projectID: String
        let projectKey: String
        let workflow: HostWorkflowKey
        let originalReview: CanonicalArtifactReferenceV1
        let finding: RenderReviewV1.Finding
        let reason: String
    }

    static func capture(editor: EditorViewModel,
                        revalidate: (@MainActor @Sendable () throws -> Void)? = nil) async throws -> Snapshot {
        try Task.checkCancellation()
        try revalidate?()
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
              let workflow = try PipelineProductionPromptCompiler.workflow(editor: editor), workflow.isProductionV2 else {
            throw GateBlocked("Open a production project first.")
        }
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: root, order: PhaseContractRuntime.order(workflow: workflow))
        if state.nextPhase != "render_review" {
            let snapshot = try await background {
                guard let review = try loadIfPresent(dataRoot: root) else { throw GateBlocked("Reach Render Review before preparing its inputs.") }
                try requireCurrent(review, root)
                return try PlanningWriterIO.read(Receipt.self, at: review.reviewEvidence.path, dataRoot: root).snapshot
            }
            try revalidate?()
            guard editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) == root,
                  editor.projectId == snapshot.projectKey else { throw GateBlocked("The active project changed while loading the review.") }
            return snapshot
        }
        let access = try access(editor: editor)
        var nativeLease: UUID?
        if revalidate == nil {
            guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Prepare render review") else {
                throw GateBlocked("Wait for the current production job before preparing the review.")
            }
            nativeLease = lease
        }
        defer { if let nativeLease { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: nativeLease) } }
        guard let projectKey = ProjectIdentity.existingUUID(for: FrameInventory.projectHome(of: root)),
              editor.projectId == projectKey, let workingCopyKey = editor.openWorkingCopyKey,
              let workingCopyGeneration = editor.openWorkingCopyGeneration else {
            throw GateBlocked("The review has no current project identity.")
        }
        let ownedNativeLease = nativeLease
        let validatePreparation: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try revalidate?()
            guard editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) == root,
                  editor.projectId == projectKey,
                  editor.openWorkingCopyKey == workingCopyKey, editor.openWorkingCopyGeneration == workingCopyGeneration,
                  try PipelineProductionPromptCompiler.workflow(editor: editor) == workflow else {
                throw GateBlocked("The active project changed while preparing the review.")
            }
            if let ownedNativeLease,
               !editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: ownedNativeLease) {
                throw GateBlocked("The native review preparation is no longer active.")
            }
        }
        try validatePreparation()
        let preparation = Task.detached(priority: .userInitiated) {
            try requirePriorEvidence(access: access)
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
            let board = try PlanningWriterIO.storyboard(dataRoot: root)
            let frames = try ProductionPlanFramesV1.requireCurrent(projection: projection, dataRoot: root)
            _ = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: root)
            let projectionRef = try reference(ProductionPlanProjectionV1.versionPath(projection.header.revision), root: root)
            let refs = try ProductionPlanFramesV1.artifactReferences(projection: projection, dataRoot: root)
                + ProductionPlanAuditV1.artifactReferences(projection: projection, dataRoot: root)
                + [reference(PipelineLayout.sanityReportFile, root: root)]
            return (projection, board, frames, projectionRef, refs)
        }
        let (projection, board, frames, projectionRef, initialRefs) = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        try validatePreparation()
        var refs = initialRefs
        var shots: [CapturedShot] = []
        for shot in projection.shots {
            try validatePreparation()
            try access.revalidate()
            var evidence = [projectionRef]
            if let source = projection.source(for: shot.id) { evidence.append(source) }
            if let planned = board.timing.shots.first(where: { $0.id == shot.id }) {
                evidence += planned.moments.compactMap(\.asset).flatMap { [$0.image, $0.proof] }
            }
            let framePaths = (frames.shot(shot.id)?.frames ?? []).map(\.path)
            evidence += try await background { try framePaths.map { try reference($0, root: root) } }
            try validatePreparation()
            let reviewed: RenderReviewV1.ShotReview
            let promptText: String?
            let modelID: String?
            if shot.sourceMode == .imported {
                reviewed = .init(shotID: shot.id, evidence: evidence)
                promptText = nil
                modelID = nil
            } else if ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill {
                guard let frame = frames.shot(shot.id)?.frames.first(where: { $0.role == "start" }) else {
                    throw GateBlocked("The animated still has no reviewed start image.")
                }
                let stillEvidence = evidence
                let captured = try await background {
                    let usage = try FrameReferenceUsageStoreV1.load(shotID: shot.id, role: "start", dataRoot: root)
                    guard usage.schema == FrameReferenceUsageV1.schemaVersion, usage.shotID == shot.id,
                          usage.role == "start", usage.outputPath == frame.path, usage.modelID == frame.runwayModel,
                          usage.generationPackageID.count == 64, usage.generationPackageID.allSatisfy(\.isHexDigit),
                          usage.plan.isExecutable, usage.plan.shotID == shot.id else {
                        throw GateBlocked("The animated still's reference proof does not belong to its reviewed start image.")
                    }
                    _ = try ProjectLocalFile.requireHash(usage.outputSHA256, at: frame.path, dataRoot: root)
                    let packagePath = "generation-packages/\(usage.generationPackageID).json"
                    let packageBytes = try Data(contentsOf: ProjectLocalFile.resolve(packagePath, dataRoot: root))
                    let package = try JSONDecoder().decode(GenerationPackageV1.self, from: packageBytes)
                    guard package.id == usage.generationPackageID, package.payload.binding.projectKey == projectKey,
                          package.payload.binding.shotId == shot.id, package.payload.prompt == frame.providerPrompt,
                          package.payload.target.modelId == frame.runwayModel else {
                        throw GateBlocked("The animated still does not bind its original compiled generation request.")
                    }
                    let path = try ProductionCompiledPromptStore.path(binding: package.payload.binding,
                        modelID: package.payload.target.modelId, text: package.payload.prompt)
                    let promptRef = try reference(path, root: root)
                    let compiled = try ProductionCompiledPromptStore.load(promptRef, dataRoot: root)
                    guard compiled.modality == "image", compiled.projectID == projection.header.projectID,
                          compiled.shotID == shot.id, compiled.binding.frameRole == "start" else {
                        throw GateBlocked("The animated still's compiler evidence is invalid.")
                    }
                    var capturedEvidence = stillEvidence
                    let usagePath = FrameReferenceUsageStoreV1.path(shotID: shot.id, role: "start")
                    capturedEvidence.append(PlanningWriterIO.reference(usagePath,
                        id: "review-input." + FileDigest.sha256(of: Data(usagePath.utf8)), role: "host.render-review-input",
                        bytes: try FrameReferenceUsageStoreV1.encode(usage)))
                    capturedEvidence.append(PlanningWriterIO.reference(packagePath,
                        id: "review-input." + FileDigest.sha256(of: Data(packagePath.utf8)), role: "host.render-review-input", bytes: packageBytes))
                    let conditioning = usage.plan.bindings.enumerated().map { index, item in
                        CanonicalArtifactReferenceV1(id: "still-reference-\(index)", role: item.role, path: item.path, sha256: item.sha256)
                    }
                    let reviewed = RenderReviewV1.ShotReview(shotID: shot.id, evidence: capturedEvidence, compiledPrompt: promptRef,
                        promptIRSHA256: compiled.binding.promptIRSHA256, conditioning: conditioning)
                    return (reviewed, compiled.text, compiled.modelID)
                }
                try validatePreparation()
                reviewed = captured.0
                promptText = captured.1
                modelID = captured.2
            } else {
                if let chain = projection.chains.first(where: { $0.shotID == shot.id }) {
                    let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: root)
                    let template = try PipelineShotPlanningPromotionStore.inputTemplate(for: shot.id, promotion: promotion, dataRoot: root)
                    if let mode = template.coreInputs.audioTimingModeID {
                        guard chain.kind == .nativeExtension else { throw GateBlocked("Frame continuation accepts only its predecessor's actual last frame, without audio timing inputs.") }
                        try ProjectWorkingCopy.markDirty(key: workingCopyKey)
                        _ = try await PipelineProductionKnownAudio.prepare(shotID: shot.id, projection: projection, modeID: mode,
                            access: access, revalidate: validatePreparation)
                        try validatePreparation()
                    }
                }
                if projection.chains.allSatisfy({ $0.shotID != shot.id }) {
                    try ProjectWorkingCopy.markDirty(key: workingCopyKey)
                    _ = try await PipelineProductionInputMaterializer.prepare(shotID: shot.id, editor: editor,
                        catalog: editor.generationBatchCoordinator.modelCatalog, revalidate: validatePreparation)
                    try validatePreparation()
                }
                let inputs = try PipelineProductionPromptCompiler.videoInputs(shotID: shot.id, dataRoot: root,
                    editor: editor, catalog: editor.generationBatchCoordinator.modelCatalog)
                guard let timing = projection.timing(for: shot.id) else { throw GateBlocked("The production shot has no exact timing.") }
                try ProjectWorkingCopy.markDirty(key: workingCopyKey)
                let compiled = try await PromptCompiler.compile(intent: shot.primaryAction, modelId: inputs.modelID,
                    modality: .video, aspectRatio: shot.generationRequirement?.aspectRatio ?? "",
                    durationSeconds: projection.timebase.seconds(for: timing.nativeDurationTicks ?? timing.durationTicks),
                    editor: editor, shotId: shot.id,
                    shot: PipelineProductionPromptCompiler.shotProjection(shotID: shot.id, dataRoot: root),
                    modelCatalog: editor.generationBatchCoordinator.modelCatalog, revalidate: validatePreparation)
                try validatePreparation()
                try access.revalidate()
                try ProjectWorkingCopy.markDirty(key: workingCopyKey)
                let promptRef = try ProductionCompiledPromptStore.record(compiled, modelID: inputs.modelID,
                    modality: "video", projectID: projection.header.projectID, dataRoot: root)
                let routeRef = inputs.routeReference
                refs += inputs.artifactReferences
                reviewed = .init(shotID: shot.id, evidence: evidence, compiledPrompt: promptRef,
                    promptIRSHA256: compiled.binding.promptIRSHA256, route: routeRef,
                    conditioning: inputs.conditioning, predecessor: inputs.predecessor)
                promptText = compiled.text
                modelID = inputs.modelID
            }
            refs += reviewed.evidence + reviewed.conditioning + [reviewed.compiledPrompt, reviewed.route].compactMap { $0 }
                + (reviewed.predecessor?.permittedOriginalReferences ?? [])
            let sourceInput = projection.source(for: shot.id)
            let sourceRange: SourceInputRange?
            if shot.sourceMode == .imported {
                guard sourceInput != nil, let timing = projection.timing(for: shot.id) else {
                    throw GateBlocked("The imported shot has no exact source and range.")
                }
                sourceRange = .init(timebase: projection.timebase, startTicks: timing.sourceInTicks, durationTicks: timing.durationTicks)
            } else if shot.sourceMode == .aiEnhanced {
                guard let selected = projection.sourceInputRanges.first(where: { $0.shotID == shot.id }), selected.source == sourceInput else {
                    throw GateBlocked("Choose the AI-enhanced shot's actual source input range before reviewing it.")
                }
                sourceRange = .init(timebase: selected.timebase, startTicks: selected.startTicks, durationTicks: selected.durationTicks)
            } else { sourceRange = nil }
            shots.append(.init(shotID: shot.id, sourceMode: shot.sourceMode,
                compiledPrompt: promptText, modelID: modelID, sourceInput: sourceInput, sourceInputRange: sourceRange, review: reviewed))
        }
        var absent: [String] = []
        for path in [PipelineLayout.ledgerFile, ResolvedProductionStyleV1.relativePath] {
            let candidate = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                refs.append(try reference(path, root: root))
            } else { absent.append(path) }
        }
        refs = try unique(refs)
        let snapshot = Snapshot(fingerprint: try snapshotFingerprint(workflow: access.workflow, projectKey: projectKey,
            projection: projection, shots: shots, references: refs, absentPaths: absent),
            workflow: access.workflow, projectKey: projectKey, projection: projection,
            shots: shots, references: refs, absentPaths: absent)
        let checking = Task.detached(priority: .userInitiated) {
            try PipelineRenderReviewSnapshotCheck.capture(snapshot, root: root)
        }
        let check = try await withTaskCancellationHandler { try await checking.value } onCancel: { checking.cancel() }
        try validatePreparation()
        try check.requireCurrent()
        try access.revalidate()
        guard editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) == root,
              editor.projectId == projectKey else { throw GateBlocked("The active project changed while preparing the review.") }
        return snapshot
    }

    static func recordNativeReview(snapshot: Snapshot, findings: [RenderReviewV1.Finding],
                                   editor: EditorViewModel) async throws -> RenderReviewV1 {
        let access = try access(editor: editor)
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: access.dataRoot, label: "render_review") else {
            throw GateBlocked("Wait for the current production job before recording the native review.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: access.dataRoot, id: lease) }
        return try await publishTransaction(snapshot: snapshot, access: access, lease: lease, editor: editor) { writer in
            try publishValue(snapshot: snapshot, findings: findings,
                reviewer: .init(kind: .nativeUser, reviewerID: "nexgenvideo.native-render-review/v1"),
                agentEvidence: nil, aggregate: nil, verifiedAggregate: nil, access: writer)
        }
    }

    static func recordAgentReview(snapshot: Snapshot, findings: [RenderReviewV1.Finding],
                                  evidence: HostAgentReviewEvidence, editor: EditorViewModel) throws -> RenderReviewV1 {
        throw GateBlocked("New model reviews must complete the host-owned page review and synthesis. Prepare the review in its workspace.")
    }

    static func recordAggregateReview(snapshot: Snapshot, aggregate: CanonicalArtifactReferenceV1,
                                      binding: AgentReviewChildBinding, editor: EditorViewModel,
                                      revalidate: @escaping @MainActor @Sendable () throws -> Void) async throws -> RenderReviewV1 {
        try revalidate()
        try editor.agentService.requireReviewChildBinding(binding)
        let access = try access(editor: editor)
        guard access.dataRoot == binding.dataRoot else { throw GateBlocked("The review project changed.") }
        return try await publishTransaction(snapshot: snapshot, access: access, lease: binding.mutationLeaseID,
            editor: editor, revalidate: {
                try revalidate()
                try editor.agentService.requireReviewChildBinding(binding)
            }) { writer in
                let verified = try PipelineRenderReviewRunVerification.verify(aggregate, snapshot: snapshot, dataRoot: writer.dataRoot)
                return try publishValue(snapshot: snapshot, findings: verified.aggregate.findings,
                    reviewer: .init(kind: .model, reviewerID: verified.responseID, modelID: verified.modelID),
                    agentEvidence: nil, aggregate: aggregate, verifiedAggregate: verified, access: writer)
            }
    }

    private static func publishTransaction(snapshot: Snapshot, access: PipelinePlanningWriteAccess, lease: UUID,
        editor: EditorViewModel, revalidate: @escaping @MainActor @Sendable () throws -> Void = {},
        mutation: @escaping @Sendable (PipelinePlanningWriteAccess) throws -> RenderReviewV1) async throws -> RenderReviewV1 {
        let root = access.dataRoot
        guard editor.projectId == snapshot.projectKey, let key = editor.openWorkingCopyKey,
              let generation = editor.openWorkingCopyGeneration else { throw GateBlocked("Reopen the review project.") }
        let validate: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try revalidate()
            guard editor.projectId == snapshot.projectKey, editor.openWorkingCopyKey == key,
                  editor.openWorkingCopyGeneration == generation,
                  editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) == root,
                  editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease) else {
                throw GateBlocked("The review publication no longer owns this project.")
            }
            try access.revalidate()
        }
        try validate()
        let verification = Task.detached(priority: .userInitiated) {
            let check = try PipelineRenderReviewSnapshotCheck.capture(snapshot, root: root)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: access.phase)
                return try mutation(writer)
            }
            do { try check.requireCurrent(); return (transaction, check) }
            catch { transaction.discard(); throw error }
        }
        let (transaction, check) = try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
        do {
            let review = try transaction.commit { _ in
                try validate()
                try check.requireCurrent()
                try ProjectWorkingCopy.markDirty(key: key)
            }
            editor.onPipelineChanged?()
            await Task.detached(priority: .utility) { transaction.discard() }.value
            return review
        } catch {
            await Task.detached(priority: .utility) { transaction.discard() }.value
            throw error
        }
    }

    nonisolated static func loadIfPresent(dataRoot: URL) throws -> RenderReviewV1? {
        let candidate = dataRoot.appendingPathComponent(RenderReviewV1.currentPath)
        guard FileManager.default.fileExists(atPath: candidate.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil else { return nil }
        let value = try PlanningWriterIO.read(RenderReviewV1.self, at: RenderReviewV1.currentPath, dataRoot: dataRoot)
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(RenderReviewV1.currentPath, dataRoot: dataRoot))
        guard bytes == (try Data(contentsOf: ProjectLocalFile.resolve(RenderReviewV1.versionPath(value.header.revision), dataRoot: dataRoot))),
              try PlanningWriterIO.nextRevision(directory: "render-review", suffix: ".v1.json", dataRoot: dataRoot) == value.header.revision + 1 else {
            throw GateBlocked("The current Render Review does not match its complete immutable history.")
        }
        return value
    }

    nonisolated static func fingerprint(_ review: RenderReviewV1) throws -> String {
        FileDigest.sha256(of: try PlanningWriterIO.json(review))
    }

    static func acceptFinding(id: String, reason: String, expectedFingerprint: String,
                              editor: EditorViewModel) async throws -> RenderReviewV1 {
        let access = try access(editor: editor)
        let root = access.dataRoot
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "render_review") else {
            throw GateBlocked("Wait for the current production job before accepting a finding.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        guard let current = try loadIfPresent(dataRoot: root), try fingerprint(current) == expectedFingerprint,
              let finding = current.findings.first(where: { $0.id == id }),
              finding.kind == .creativeAdvice || finding.kind == .semanticConcern,
              finding.acceptance == nil, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GateBlocked("Only a current semantic concern or creative suggestion can be explicitly accepted with a reason.")
        }
        guard let projectKey = ProjectIdentity.existingUUID(for: FrameInventory.projectHome(of: root)),
              editor.projectId == projectKey else { throw GateBlocked("Reopen the review project.") }
        let snapshot = try PlanningWriterIO.read(Receipt.self, at: current.reviewEvidence.path, dataRoot: root).snapshot
        return try await publishTransaction(snapshot: snapshot, access: access, lease: lease, editor: editor) { writer in
            try acceptValue(current: current, finding: finding, reason: reason, projectKey: projectKey, access: writer)
        }
    }

    nonisolated private static func acceptValue(current: RenderReviewV1, finding: RenderReviewV1.Finding, reason: String,
        projectKey: String, access: PipelinePlanningWriteAccess) throws -> RenderReviewV1 {
        let root = access.dataRoot
        try requireCurrent(current, root, approval: false)
        let receiptID = UUID().uuidString.lowercased()
        let receiptPath = "render-review/acceptances/\(receiptID).v1.json"
        let original = try reference(RenderReviewV1.versionPath(current.header.revision), root: root)
        let receipt = Acceptance(schema: "render-review-finding-acceptance/v1", id: receiptID,
            projectID: current.header.projectID, projectKey: projectKey, workflow: access.workflow,
            originalReview: original, finding: finding, reason: reason)
        let receiptBytes = try PlanningWriterIO.json(receipt)
        let accepted = PlanningWriterIO.reference(receiptPath, id: receiptID, role: "host.render-review-acceptance", bytes: receiptBytes)
        let findings = current.findings.map { item in
            guard item.id == finding.id else { return item }
            return RenderReviewV1.Finding(id: item.id, kind: item.kind, category: item.category, shotIDs: item.shotIDs,
                message: item.message, evidence: item.evidence, acceptance: accepted, acceptanceReason: reason)
        }
        let revision = try PlanningWriterIO.nextRevision(directory: "render-review", suffix: ".v1.json", dataRoot: root)
        let next = RenderReviewV1(header: .init(projectID: current.header.projectID, revision: revision, origin: .userRevision,
            inputs: try unique(current.header.inputs + [original])), productionPlan: current.productionPlan,
            reviewer: current.reviewer, reviewEvidence: current.reviewEvidence, shots: current.shots, findings: findings)
        try RenderReviewValidatorV1.validate(next, projection: ProductionPlanningLineageV2.projection(dataRoot: root))
        let bytes = try PlanningWriterIO.json(next)
        try access.publish([(receiptPath, receiptBytes), (RenderReviewV1.versionPath(revision), bytes), (RenderReviewV1.currentPath, bytes)]) {
            try requireCurrent(next, root, approval: false)
        }
        return next
    }

    nonisolated static func requireCurrent(_ review: RenderReviewV1, _ root: URL, approval: Bool = true) throws {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        try RenderReviewValidatorV1.validate(review, projection: projection, approval: approval)
        guard try loadIfPresent(dataRoot: root) == review else { throw GateBlocked("The Render Review changed.") }
        try review.header.requireCurrentInputs(dataRoot: root)
        try verifyEvidence(review, root)
    }

    nonisolated static func verifyEvidence(_ review: RenderReviewV1, _ root: URL) throws {
        let receipt = try PlanningWriterIO.read(Receipt.self, at: review.reviewEvidence.path, dataRoot: root)
        _ = try ProjectLocalFile.requireHash(review.reviewEvidence.sha256, at: review.reviewEvidence.path, dataRoot: root)
        let version = receipt.aggregate == nil ? "v1" : "v2"
        guard receipt.schema == "render-review-receipt/\(version)", UUID(uuidString: receipt.id) != nil,
              review.reviewEvidence.path == "render-review/receipts/\(receipt.id).\(version).json",
              receipt.snapshot.projection.header.projectID == review.header.projectID,
              receipt.snapshot.shots.map(\.review) == review.shots,
              receipt.snapshot.references.contains(review.productionPlan) else { throw GateBlocked("The review has no exact host evidence receipt.") }
        try requireSnapshot(receipt.snapshot, root: root)
        if let aggregate = receipt.aggregate {
            let verified = try PipelineRenderReviewRunVerification.verify(aggregate, snapshot: receipt.snapshot, dataRoot: root)
            guard receipt.agentEvidence == nil, receipt.context == verified.aggregate.manifest,
                  try PlanningWriterIO.json(receipt.submittedFindings) == PlanningWriterIO.json(verified.aggregate.findings),
                  receipt.reviewer.kind == .model, receipt.reviewer.modelID == verified.modelID,
                  receipt.reviewer.reviewerID == verified.responseID,
                  review.reviewer.kind == .model, review.reviewer.modelID == verified.modelID,
                  review.reviewer.reviewerID == verified.responseID,
                  review.reviewer.promptPath == verified.aggregate.manifest.path,
                  review.reviewer.promptSHA256 == verified.aggregate.manifest.sha256,
                  review.reviewer.responsePath == review.reviewEvidence.path,
                  review.reviewer.responseSHA256 == review.reviewEvidence.sha256,
                  (verified.references + [aggregate]).allSatisfy({ reference in
                      review.header.inputs.contains { $0.path == reference.path && $0.sha256 == reference.sha256 }
                  }) else { throw GateBlocked("The model review has no complete host-bound page and synthesis evidence.") }
        } else if let model = receipt.agentEvidence {
            guard let arguments = try JSONSerialization.jsonObject(with: Data(model.response.toolInputJSON.utf8)) as? [String: Any],
                  let rawFindings = arguments["findings"], model.response.matchesHostTool("write_render_review") else {
                throw GateBlocked("The review has no actual structured model response.")
            }
            let proposed = try JSONDecoder().decode([RenderReviewV1.Finding].self,
                from: JSONSerialization.data(withJSONObject: rawFindings))
            guard model.response.toolInputSHA256 == (try AgentModelResponseEvidence.inputHash(model.response.toolInputJSON)),
                  arguments["expected_fingerprint"] as? String == receipt.snapshot.fingerprint,
                  proposed == receipt.submittedFindings else { throw GateBlocked("The review findings do not match the actual model tool response.") }
            guard receipt.reviewer.kind == .model, model.response.messageID == receipt.reviewer.reviewerID,
                  model.response.modelID == receipt.reviewer.modelID,
                  model.chatSessionID == model.response.sessionID, model.logicalTurnID == model.response.turnID else {
                throw GateBlocked("The review does not bind its actual model response.")
            }
            guard let context = receipt.context, review.reviewer.promptPath == context.path,
                  review.reviewer.promptSHA256 == context.sha256 else { throw GateBlocked("The model review lost its actual delivered inputs.") }
            let delivered = try PipelineRenderReviewContextDelivery.verify(context, snapshot: receipt.snapshot,
                evidence: model, dataRoot: root)
            guard delivered.allSatisfy({ ref in review.header.inputs.contains { $0.path == ref.path && $0.sha256 == ref.sha256 } }) else {
                throw GateBlocked("The review does not bind every actual delivered input byte.")
            }
            guard review.reviewer.kind == .model, review.reviewer.reviewerID == receipt.reviewer.reviewerID,
                  review.reviewer.modelID == receipt.reviewer.modelID,
                  review.reviewer.responsePath == review.reviewEvidence.path,
                  review.reviewer.responseSHA256 == review.reviewEvidence.sha256 else { throw GateBlocked("The review model provenance changed.") }
        } else {
            guard receipt.context == nil, receipt.reviewer.kind == .nativeUser, review.reviewer == receipt.reviewer else {
                throw GateBlocked("The native review cannot claim a model execution.")
            }
        }
        if let previous = receipt.previousReview {
            let priorBytes = try Data(contentsOf: ProjectLocalFile.requireHash(previous.sha256, at: previous.path, dataRoot: root))
            let prior = try JSONDecoder().decode(RenderReviewV1.self, from: priorBytes)
            guard previous.path == RenderReviewV1.versionPath(prior.header.revision), prior.header.revision < review.header.revision,
                  review.header.inputs.contains(previous), prior.findings.allSatisfy({ finding in
                      review.findings.contains { unaccepted($0) == unaccepted(finding) && (finding.acceptance == nil || $0.acceptance == finding.acceptance) }
                  }) else { throw GateBlocked("The review discarded findings on unchanged captured inputs.") }
            let priorReceipt = try PlanningWriterIO.read(Receipt.self, at: prior.reviewEvidence.path, dataRoot: root)
            guard priorReceipt.snapshot.fingerprint == receipt.snapshot.fingerprint else { throw GateBlocked("Carried findings belong to different inputs.") }
            try verifyEvidence(prior, root)
        }
        guard receipt.findings.map(unaccepted) == review.findings.map(unaccepted) else {
            throw GateBlocked("The recorded review findings were replaced without a new review.")
        }
        for finding in review.findings {
            guard let acceptance = finding.acceptance else { continue }
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(acceptance.sha256, at: acceptance.path, dataRoot: root))
            let value = try JSONDecoder().decode(Acceptance.self, from: bytes)
            let priorBytes = try Data(contentsOf: ProjectLocalFile.requireHash(value.originalReview.sha256,
                at: value.originalReview.path, dataRoot: root))
            let prior = try JSONDecoder().decode(RenderReviewV1.self, from: priorBytes)
            guard value.schema == "render-review-finding-acceptance/v1", UUID(uuidString: value.id) != nil,
                  acceptance.path == "render-review/acceptances/\(value.id).v1.json",
                  value.projectID == review.header.projectID, value.projectKey == receipt.snapshot.projectKey,
                  value.workflow == receipt.snapshot.workflow, value.reason == finding.acceptanceReason,
                  value.finding.acceptance == nil, unaccepted(value.finding) == unaccepted(finding),
                  prior.findings.contains(value.finding), prior.productionPlan == review.productionPlan,
                  prior.header.revision < review.header.revision else { throw GateBlocked("The finding has no exact native acceptance receipt.") }
            let priorReceipt = try PlanningWriterIO.read(Receipt.self, at: prior.reviewEvidence.path, dataRoot: root)
            guard priorReceipt.snapshot.fingerprint == receipt.snapshot.fingerprint else {
                throw GateBlocked("The finding acceptance belongs to different captured inputs.")
            }
        }
        for ref in review.references { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: root) }
    }

    nonisolated private static func publishValue(snapshot: Snapshot, findings: [RenderReviewV1.Finding], reviewer: SequenceReviewerProvenanceV1,
                                agentEvidence: HostAgentReviewEvidence?, aggregate: CanonicalArtifactReferenceV1?,
                                verifiedAggregate: PipelineRenderReviewRunVerification.Verified?,
                                access: PipelinePlanningWriteAccess) throws -> RenderReviewV1 {
        let root = access.dataRoot
        guard (aggregate == nil) == (verifiedAggregate == nil) else { throw GateBlocked("The model review is missing its verified aggregate.") }
        try requireSnapshot(snapshot, root: root)
        guard access.workflow == snapshot.workflow,
              findings.allSatisfy({ $0.acceptance == nil && $0.acceptanceReason == nil
                && $0.evidence.allSatisfy { ref in snapshot.references.contains { $0.path == ref.path && $0.sha256 == ref.sha256 } } }) else {
            throw GateBlocked("The review must use the current captured evidence; only a native action can accept findings.")
        }
        var mergedFindings = findings
        var previousReview: CanonicalArtifactReferenceV1?
        if let prior = try loadIfPresent(dataRoot: root) {
            let priorReceipt = try PlanningWriterIO.read(Receipt.self, at: prior.reviewEvidence.path, dataRoot: root)
            if priorReceipt.snapshot.fingerprint == snapshot.fingerprint {
                try requireCurrent(prior, root, approval: false)
                for existing in prior.findings {
                    if let proposed = findings.first(where: { $0.id == existing.id }) {
                        guard unaccepted(proposed) == unaccepted(existing) else {
                            throw GateBlocked("A finding on unchanged inputs cannot be rewritten or silently resolved. Revise the actual inputs or explicitly accept an eligible concern.")
                        }
                        mergedFindings = mergedFindings.map { $0.id == existing.id ? existing : $0 }
                    } else { mergedFindings.append(existing) }
                }
                previousReview = try reference(RenderReviewV1.versionPath(prior.header.revision), root: root)
            }
        }
        let revision = try PlanningWriterIO.nextRevision(directory: "render-review", suffix: ".v1.json", dataRoot: root)
        let id = UUID().uuidString.lowercased()
        let version = aggregate == nil ? "v1" : "v2"
        let receiptPath = "render-review/receipts/\(id).\(version).json"
        let context: CanonicalArtifactReferenceV1?
        let delivered: [CanonicalArtifactReferenceV1]
        if let aggregate, let verifiedAggregate {
            context = verifiedAggregate.aggregate.manifest
            delivered = verifiedAggregate.references + [aggregate]
        } else if let agentEvidence {
            let actual = try PipelineRenderReviewContextDelivery.reference(snapshot: snapshot, evidence: agentEvidence, dataRoot: root)
            context = actual
            delivered = try PipelineRenderReviewContextDelivery.verify(actual, snapshot: snapshot, evidence: agentEvidence, dataRoot: root)
        } else { context = nil; delivered = [] }
        let receipt = Receipt(schema: "render-review-receipt/\(version)", id: id, snapshot: snapshot,
            reviewer: reviewer, findings: mergedFindings, submittedFindings: findings, previousReview: previousReview,
            agentEvidence: agentEvidence, context: context, reviewedAt: currentTimestamp(), aggregate: aggregate)
        let receiptBytes = try PlanningWriterIO.json(receipt)
        let receiptRef = PlanningWriterIO.reference(receiptPath, id: id, role: "host.render-review-receipt", bytes: receiptBytes)
        guard let planRef = snapshot.references.first(where: { $0.path == ProductionPlanProjectionV1.versionPath(snapshot.projection.header.revision) }) else {
            throw GateBlocked("The review lost its captured production plan.")
        }
        let actualReviewer: SequenceReviewerProvenanceV1
        var files: [(path: String, bytes: Data)] = [(receiptPath, receiptBytes)]
        if reviewer.kind == .model, let context {
            actualReviewer = .init(kind: .model, reviewerID: reviewer.reviewerID, modelID: reviewer.modelID,
                promptPath: context.path, promptSHA256: context.sha256,
                responsePath: receiptPath, responseSHA256: receiptRef.sha256)
        } else { actualReviewer = reviewer }
        let review = RenderReviewV1(header: .init(projectID: snapshot.projection.header.projectID,
            revision: revision, origin: reviewer.kind == .model ? .agentProposal : .userRevision,
            inputs: try unique(snapshot.references + delivered + [previousReview].compactMap { $0 })), productionPlan: planRef,
            reviewer: actualReviewer, reviewEvidence: receiptRef, shots: snapshot.shots.map(\.review), findings: mergedFindings)
        try RenderReviewValidatorV1.validate(review, projection: snapshot.projection)
        let bytes = try PlanningWriterIO.json(review)
        files += [(RenderReviewV1.versionPath(revision), bytes), (RenderReviewV1.currentPath, bytes)]
        try access.publish(files) { try requireCurrent(review, root, approval: false) }
        return review
    }

    nonisolated private static func background<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func access(editor: EditorViewModel) throws -> PipelinePlanningWriteAccess {
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { throw GateBlocked("Open a production project first.") }
        return try PipelinePlanningWriteAccess(dataRoot: root, declaration: .init(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract), phase: "render_review")
    }

    nonisolated private static func requirePriorEvidence(access: PipelinePlanningWriteAccess) throws {
        let registry = PackCatalog.registry(activePack: access.workflow.packID)
        for phase in ["shotlist", "sanity", "frames"] {
            try PipelineGateEvidenceValidator.requireCurrent(phase: phase, dataRoot: access.dataRoot,
                requirement: PhaseContractRuntime.gateRequirement(workflow: access.workflow, phase: phase, registry: registry), workflow: access.workflow)
        }
    }

    nonisolated static func requireSnapshot(_ value: Snapshot, root: URL) throws {
        guard value.projectKey == ProjectIdentity.existingUUID(for: FrameInventory.projectHome(of: root)),
              try PhaseContractRuntime.resolveWorkflow(dataRoot: root,
                expectedPack: value.workflow.packID.flatMap { id in value.workflow.packVersion.flatMap { ProjectPackBinding(id: id, version: $0, projectSchema: value.workflow.projectSchema) } },
                expectedProductionContract: value.workflow.packID == nil ? .current : nil) == value.workflow,
              value.projection == (try ProductionPlanningLineageV2.projection(dataRoot: root)),
              value.fingerprint == (try snapshotFingerprint(workflow: value.workflow, projectKey: value.projectKey,
                projection: value.projection, shots: value.shots, references: value.references, absentPaths: value.absentPaths)) else {
            throw GateBlocked("The review snapshot belongs to an earlier project or production plan.")
        }
        for path in value.absentPaths {
            let candidate = root.appendingPathComponent(path)
            guard !FileManager.default.fileExists(atPath: candidate.path),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) == nil else {
                throw GateBlocked("The project direction changed after review capture.")
            }
        }
        for ref in value.references { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: root) }
        for shot in value.shots {
            if let ref = shot.review.compiledPrompt {
                let record = try ProductionCompiledPromptStore.load(ref, dataRoot: root)
                guard record.projectID == value.projection.header.projectID, record.shotID == shot.shotID,
                      record.binding.projectKey == value.projectKey, record.modelID == shot.modelID,
                      record.text == shot.compiledPrompt, record.binding.promptIRSHA256 == shot.review.promptIRSHA256 else {
                    throw GateBlocked("The captured compiler evidence changed.")
                }
            }
        }
    }

    nonisolated private static func snapshotFingerprint(workflow: HostWorkflowKey, projectKey: String,
        projection: ProductionPlanProjectionV1, shots: [CapturedShot], references: [CanonicalArtifactReferenceV1], absentPaths: [String]) throws -> String {
        struct Inputs: Encodable {
            let workflow: HostWorkflowKey
            let projectKey: String
            let projection: ProductionPlanProjectionV1
            let shots: [CapturedShot]
            let references: [CanonicalArtifactReferenceV1]
            let absentPaths: [String]
        }
        return FileDigest.sha256(of: try PlanningWriterIO.json(Inputs(workflow: workflow, projectKey: projectKey,
            projection: projection, shots: shots, references: references, absentPaths: absentPaths)))
    }

    nonisolated private static func unaccepted(_ value: RenderReviewV1.Finding) -> RenderReviewV1.Finding {
        .init(id: value.id, kind: value.kind, category: value.category, shotIDs: value.shotIDs,
            message: value.message, evidence: value.evidence)
    }

    nonisolated private static func reference(_ path: String, root: URL) throws -> CanonicalArtifactReferenceV1 {
        try PlanningWriterIO.reference(path, id: "review-input." + FileDigest.sha256(of: Data(path.utf8)),
            role: "host.render-review-input", dataRoot: root)
    }

    nonisolated private static func unique(_ refs: [CanonicalArtifactReferenceV1]) throws -> [CanonicalArtifactReferenceV1] {
        var paths: [String: CanonicalArtifactReferenceV1] = [:]
        for ref in refs {
            if let prior = paths[ref.path], prior.sha256 != ref.sha256 { throw GateBlocked("Review inputs claim different bytes at the same path.") }
            if paths[ref.path] == nil { paths[ref.path] = ref }
        }
        return paths.values.sorted { $0.path < $1.path }
    }
}
