import AVFoundation
import Foundation
import NexGenEngine

extension ToolExecutor {
    func writeScriptTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let access = try planningAccess(editor, args, phase: "script")
        let scenes = try Self.decodePlanningArgument([ScriptV1.Scene].self, value: args["scenes"], field: "scenes")
        let script = try PipelineScriptWriter.write(summary: try args.requireString("summary"), scenes: scenes,
            origin: planningOrigin(args), access: access)
        return try jsonResult(["written": true, "revision": script.header.revision,
            "path": ScriptV1.versionPath(script.header.revision), "current": ScriptV1.currentPath])
    }

    func writeStoryboardBundleTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let access = try planningAccess(editor, args, phase: "storyboard")
        let proposal = try Self.decodePlanningArgument(PipelineStoryboardBundleWriter.Proposal.self, value: args["proposal"], field: "proposal")
        let snapshot = try PipelineStoryboardBundleWriter.write(proposal, origin: planningOrigin(args), access: access)
        return try jsonResult(["written": true, "revision": snapshot.storyboard.header.revision,
            "path": StoryboardV2.versionPath(snapshot.storyboard.header.revision), "current": StoryboardV2.currentPath,
            "planned_shot_ids": snapshot.timing.shots.map(\.id), "fingerprint": snapshot.fingerprint])
    }

    func writeShotPlanningDraftTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let access = try planningAccess(editor, args, phase: "shot_planning")
        let shots = try Self.decodePlanningArgument([ShotPlanningDraftV1.ShotIntent].self, value: args["shots"], field: "shots")
        let draft = try PipelineShotPlanningWriter.write(shots: shots, origin: planningOrigin(args), access: access)
        return try jsonResult(["written": true, "revision": draft.header.revision,
            "path": ShotPlanningDraftV1.versionPath(draft.header.revision), "current": ShotPlanningDraftV1.currentPath])
    }

    func renderReviewInputsTool(_ editor: EditorViewModel, _ args: [String: Any],
                                origin: ToolCallOrigin, toolUseID: String?) async throws -> ToolResult {
        guard let toolUseID else { throw ToolError("The review input request has no originating model tool identity.") }
        let evidence = try await editor.agentService.reviewModelEvidence(origin: origin, toolUseID: toolUseID, expectedTool: .getRenderReviewInputs, arguments: args)
        let proposal = try await editor.renderReviewRun.prepare(editor: editor) {
            try Task.checkCancellation()
            try editor.agentService.requireCurrentReviewEvidence(evidence)
        }
        return .suspended("The host prepared review manifest \(proposal.manifestID) with \(proposal.pageCount) pages. "
            + "The Render Review workspace shows its exact model, remaining work and usage approval. "
            + "The host reviews every page and synthesizes its findings in separate bounded contexts; do not inspect images or submit a replacement review in this conversation.")
    }

    func writeRenderReviewTool(_ editor: EditorViewModel, _ args: [String: Any],
                               origin: ToolCallOrigin, toolUseID: String?) async throws -> ToolResult {
        throw ToolError("New model reviews are recorded only by the host-owned page review and synthesis. Use get_render_review_inputs to prepare the workspace decision.")
    }

    func compileStoryboardSketchTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        guard editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) == root else { throw ToolError("Open the Storyboard project first.") }
        let result = try await PipelineStoryboardSketchGeneration.compile(shotID: args.requireString("shot_id"),
            momentID: args.requireString("moment_id"),
            modelID: ModelCatalog.shared.internalId(forLogical: args.requireString("model")),
            expectedFingerprint: args.requireString("expected_fingerprint"), editor: editor)
        return try jsonResult(["compiledPrompt": result.compiled.text, "compileToken": result.compiled.token,
            "shotId": "none", "storyboardCompileReceipt": result.receipt.path, "notes": result.compiled.notes])
    }

    func assignStoryboardSketchTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        guard editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) == root else { throw ToolError("Open the Storyboard project first.") }
        let media = try asset(args.requireString("media_ref"), editor: editor, label: "Generated Storyboard sketch")
        let result = try PipelineStoryboardSketchGeneration.assign(media: media,
            compilationPath: args.requireString("compilation_receipt"), expectedFingerprint: args.requireString("expected_fingerprint"), editor: editor)
        return try jsonResult(["written": true, "revision": result.storyboard.header.revision, "fingerprint": result.fingerprint,
            "current": StoryboardTimingV1.currentPath])
    }

    func writeProductionPlanTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let access = try planningAccess(editor, args, phase: "shotlist")
        guard args["shots"] == nil, args["execution_shots"] == nil, let raw = args["proposal"] else {
            throw ToolError("This workflow requires the normalized production proposal, not a legacy Shot List.")
        }
        let proposal = try Self.decodePlanningArgument(PipelineProductionPlanWriter.Proposal.self, value: raw, field: "proposal")
        let home = editor.workingRoot
        let projectURL = editor.projectURL
        let key = editor.openWorkingCopyKey
        if projectURL != nil, key == nil {
            throw ToolError("The project working copy is unavailable. Reopen the project before writing.", kind: .reopenProject)
        }
        let declaration = access.declaration
        let plan = try await PipelineProductionPlanWriter.writePrepared(proposal: proposal, origin: planningOrigin(args), access: access,
            candidateProvider: { self.productionRouteCandidates(self.providerActivation()) }, commitValidation: {
                guard editor.workingRoot == home, editor.projectURL == projectURL, editor.openWorkingCopyKey == key,
                      editor.declaredPluginName == declaration.packName, editor.declaredPluginBinding == declaration.binding,
                      editor.declaredProductionContract == declaration.productionContract else {
                    throw ToolError("The project changed while its production plan was being prepared.")
                }
                if editor.projectURL != nil, key == nil {
                    throw ToolError("The project working copy is unavailable. Reopen the project before writing.", kind: .reopenProject)
                }
                if let key {
                    do { try ProjectWorkingCopy.markDirty(key: key) }
                    catch { throw ToolError(error.localizedDescription, kind: .reopenProject) }
                }
            })
        return try jsonResult(["written": true, "revision": plan.header.revision,
            "path": ProductionPlanProjectionV1.versionPath(plan.header.revision), "shot_ids": plan.shots.map(\.id)])
    }

    func prepareProductionAssetsTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let declaration = try mutationPackDeclaration(editor, dataRoot: root)
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: declaration.binding,
            expectedProductionContract: declaration.productionContract), workflow.isProductionV2 else {
            throw ToolError("Production asset preparation requires the current production contract.")
        }
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: root, order: PhaseContractRuntime.order(workflow: workflow))
        guard let phase = state.nextPhase, ["bible", "shotlist"].contains(phase), let inputs = args["assets"] as? [[String: Any]] else {
            throw ToolError("Prepare production assets during Bible or Shot List.")
        }
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: phase)
        let home = editor.workingRoot, projectURL = editor.projectURL, projectID = editor.projectId
        let key = editor.openWorkingCopyKey, generation = editor.openWorkingCopyGeneration
        let validate: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation()
            guard self.editor === editor, editor.workingRoot == home, editor.projectURL == projectURL,
                  editor.projectId == projectID, editor.openWorkingCopyKey == key, editor.openWorkingCopyGeneration == generation,
                  editor.declaredPluginName == declaration.packName, editor.declaredPluginBinding == declaration.binding,
                  editor.declaredProductionContract == declaration.productionContract,
                  projectURL == nil || (key != nil && generation != nil) else {
                throw ToolError("The project changed while its production assets were being prepared.", kind: .reopenProject)
            }
            if let key { try ProjectWorkingCopy.markDirty(key: key) }
        }
        try validate()
        struct AssetInput: Sendable {
            let path: String
            let modality: AssetPhysicalModalityV1
            let entityID: String?
            let canonIDs: [String]
            let stateID: String?
            let viewID: String?
            let allowedUseIDs: [String]
            let duration: Double?
        }
        let project = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        let requests = try inputs.map { raw -> AssetInput in
            guard let modality = AssetPhysicalModalityV1(rawValue: try raw.requireString("modality")) else { throw ToolError("Unknown asset modality.") }
            return AssetInput(path: try raw.requireString("path"), modality: modality, entityID: raw.string("entity_id"),
                canonIDs: raw["canon_ids"] as? [String] ?? [], stateID: raw.string("state_id"), viewID: raw.string("view_id"),
                allowedUseIDs: raw["allowed_use_ids"] as? [String] ?? [], duration: raw["duration_seconds"] as? Double)
        }
        let recordedAt = currentTimestamp()
        let preparationTask = Task.detached(priority: .userInitiated) {
            guard let bible = try loadBible(dataRoot: root) else { throw ToolError("The current Bible is missing.") }
            var prepared: [AssetGraphNodeV1] = []
            for input in requests {
                try Task.checkCancellation()
                let url = try ProjectLocalFile.resolve(input.path, dataRoot: root)
                let duration: Double?
                if input.modality == .video || input.modality == .audio {
                    let media = AVURLAsset(url: url)
                    let measured = try await media.load(.duration)
                    let type: AVMediaType = input.modality == .video ? .video : .audio
                    guard measured.isNumeric, measured.seconds.isFinite, measured.seconds > 0,
                          !(try await media.loadTracks(withMediaType: type)).isEmpty else {
                        throw ToolError("Choose readable media with the required track.")
                    }
                    if let declared = input.duration, declared != measured.seconds {
                        throw ToolError("The measured media duration is \(measured.seconds) seconds. Omit duration_seconds or use that exact value.")
                    }
                    duration = measured.seconds
                } else { duration = input.duration }
                let asset = try AssetGraphContentAddressV1.reidentified(.init(id: "pending", version: 1, path: input.path,
                    sha256: FileDigest.sha256(of: url), modality: input.modality, entityID: input.entityID,
                    canonIDs: input.canonIDs, stateID: input.stateID, viewID: input.viewID,
                    approval: .approved, provenance: .init(kindID: "core.planning-asset", recordedAt: recordedAt),
                    allowedUseIDs: input.allowedUseIDs, durationSeconds: duration))
                prepared.append(try PipelineShotPlanningPromotionStore.normalizeAsset(asset, bible: bible, dataRoot: root))
            }
            return prepared
        }
        let assets = try await withTaskCancellationHandler { try await preparationTask.value } onCancel: { preparationTask.cancel() }
        try validate()
        try access.revalidate()
        let graph = AssetGraphV1(id: try AssetGraphContentAddressV1.graphID(projectID: project.project, assets: assets),
            projectID: project.project, assets: assets)
        let prepared = try await PipelineShotPlanningPromotionStore.prepareAssets(graph: graph, access: access, revalidate: validate)
        return try jsonResult(["prepared": true, "expectedDraftFingerprint": prepared.draft.sha256,
            "expectedAssetGraphFingerprint": prepared.graph.sha256,
            "assets": try JSONSerialization.jsonObject(with: PlanningWriterIO.json(assets))])
    }

    static func decodePlanningArgument<T: Decodable>(_ type: T.Type, value: Any?, field: String) throws -> T {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw ToolError("\(field): expected a valid JSON array or object.")
        }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    private func planningAccess(_ editor: EditorViewModel, _ args: [String: Any], phase: String) throws -> PipelinePlanningWriteAccess {
        let root = try resolveDataRoot(args, editor: editor)
        return try PipelinePlanningWriteAccess(dataRoot: root,
            declaration: mutationPackDeclaration(editor, dataRoot: root), phase: phase)
    }

    private func planningOrigin(_ args: [String: Any]) throws -> PlanningArtifactHeaderV1.Origin {
        guard let origin = PlanningArtifactHeaderV1.Origin(rawValue: try args.requireString("origin")),
              origin == .agentProposal || origin == .agentRevision else {
            throw ToolError("Agent writers use agentProposal or agentRevision; native selection and adoption provenance belongs to the host.")
        }
        return origin
    }
}
