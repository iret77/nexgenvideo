import Foundation
import NexGenEngine

struct TakeRepairPlan: Codable, Sendable, Equatable {
    static func runtimeInstructions(phase: String) -> String? {
        guard phase == "render" else { return nil }
        return """
        Take iteration contract: get_render_manifest exposes recorded takes, attributed review findings and native iteration_decisions. Count observed prompt-revision batches, not imagined model failures. Default four rolls per prompt; three complete same-axis failed iterations require a clean rewrite and another control channel. Pending review is not a failed iteration. Two clean failed iterations across two channels allow investigation of a model/route limit, not a claim of universal impossibility. The host validates the actual request against the native decision before budget reservation and provider dispatch. A stop, rescue or simplify decision must not trigger another generation. Use the existing spend approval; no iteration policy grants spending authority. Approved canon changes require explicit rewind. Native range review can retain independently inspected coverage without accepting a rejected whole take. Never invent local edit support absent from the actual route.
        """
    }
    enum Operation: String, Codable, Sendable, CaseIterable {
        case reroll, revisePrompt, changeReference, changeModel, cleanRewriteWithReference, cleanRewriteWithModel
        case stop, simplifyShot, rescueRange

        var cleanRewrite: Bool { self == .cleanRewriteWithReference || self == .cleanRewriteWithModel }
        var channel: String {
            switch self {
            case .changeReference, .cleanRewriteWithReference: "reference"
            case .changeModel, .cleanRewriteWithModel: "model"
            default: "prompt"
            }
        }
        var label: String {
            switch self {
            case .reroll: String(localized: "Reroll the unchanged prompt")
            case .revisePrompt: String(localized: "Change one prompt line")
            case .changeReference: String(localized: "Change one reference")
            case .changeModel: String(localized: "Change model or provider route")
            case .cleanRewriteWithReference: String(localized: "Clean rewrite and change a reference")
            case .cleanRewriteWithModel: String(localized: "Clean rewrite and change model")
            case .stop: String(localized: "Stop generating this shot")
            case .simplifyShot: String(localized: "Rewind and simplify the shot")
            case .rescueRange: String(localized: "Use reviewed source ranges")
            }
        }
    }
    let schema: String
    let takeID: String
    let reviewSHA256: String
    let operation: Operation
    let reason: String
    let policy: TakeIterationPolicyV1
    let decidedBy: String
    let decidedAt: String

    static func currentPath(shotID: String) throws -> String {
        guard !shotID.isEmpty, shotID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ToolError("Invalid shot identity for an iteration decision.")
        }
        return "renders/repairs/\(shotID).json"
    }
    static func archivePath(id: String) -> String { "renders/repairs/history/\(id).json" }

    static func load(id: String, dataRoot: URL) throws -> Self {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ToolError("Invalid repair-plan identity.") }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: ProjectLocalFile.requireHash(id, at: archivePath(id: id), dataRoot: dataRoot)))
        try value.policy.validate()
        guard value.schema == "take-repair-plan/v1", value.decidedBy == "native-user",
              !value.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError("The repair decision has no attributed reason.") }
        let take = try PipelineRenderTakeStore.take(id: value.takeID, dataRoot: dataRoot)
        let reviewPath = "renders/takes/reviews/\(take.id)/\(value.reviewSHA256).v1.json"
        let review = try JSONDecoder().decode(TakeReview.self,
            from: Data(contentsOf: ProjectLocalFile.requireHash(value.reviewSHA256, at: reviewPath, dataRoot: dataRoot)))
        try TakeReview.validate(review.findings, duration: Double(review.durationValue) / Double(review.durationTimescale))
        guard review.schema == "take-review/v1", review.durationValue > 0, review.durationTimescale > 0,
              review.takeID == take.id, review.outputSHA256 == take.output.sha256, review.reviewer == "native-user" else {
            throw ToolError("The repair decision does not match its observed take.")
        }
        return value
    }

    static func current(shotID: String, dataRoot: URL) throws -> (id: String, plan: Self)? {
        let path = try currentPath(shotID: shotID)
        let target = dataRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: target.path) else {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil { throw ToolError("An iteration decision cannot be a symbolic link.") }
            let directory = dataRoot.appendingPathComponent("renders/repairs/history")
            if FileManager.default.fileExists(atPath: directory.path) {
                guard directory.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath().appendingPathComponent("renders/repairs/history") else {
                    throw ToolError("Iteration history cannot traverse symbolic links.")
                }
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                    let historical = try load(id: url.deletingPathExtension().lastPathComponent, dataRoot: dataRoot)
                    if try PipelineRenderTakeStore.take(id: historical.takeID, dataRoot: dataRoot).shotID == shotID {
                        throw ToolError("This shot's current iteration decision is missing. Record an explicit decision in Video takes before generating again.")
                    }
                }
            }
            return nil
        }
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
        let id = FileDigest.sha256(of: bytes)
        let plan = try load(id: id, dataRoot: dataRoot)
        let take = try PipelineRenderTakeStore.take(id: plan.takeID, dataRoot: dataRoot)
        guard take.shotID == shotID else { throw ToolError("The current repair decision belongs to another shot.") }
        return (id, plan)
    }

    static func assessment(input: GenerationInput, dataRoot: URL, policy: TakeIterationPolicyV1) throws -> TakeIterationAssessmentV1 {
        guard let shotID = input.promptShotId else { throw ToolError("Iteration review requires a planned shot.") }
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile).project
        let takes = try ["preview", "final"].flatMap { phase in
            try PipelineRenderTakeStore.load(dataRoot: dataRoot, project: project, phase: phase).takeIDs.map {
                try PipelineRenderTakeStore.take(id: $0, dataRoot: dataRoot, phase: phase)
            }
        }.filter { $0.shotID == shotID && $0.generationInput.promptShotFingerprint == input.promptShotFingerprint }
            .sorted { $0.recordedAt < $1.recordedAt }
        let rolls: [TakeIterationRollV1] = try takes.map { take in
            let review = try TakeReview.load(take: take, dataRoot: dataRoot)
            let evidence = try iterationEvidence(take: take, dataRoot: dataRoot)
            return .init(eventID: take.generationEventID, promptRevisionID: try PipelineRenderTakeStore.promptRevision(take.generationInput),
                reviewed: review != nil, rejectedAxis: review?.findings.first(where: { $0.verdict == .rejected })?.pass.rawValue,
                cleanRewrite: evidence.cleanRewrite, controlChannel: evidence.channel)
        }
        return try .assess(rolls: rolls, currentPromptRevisionID: PipelineRenderTakeStore.promptRevision(input), policy: policy)
    }

    static func iterationEvidence(take: PipelineRenderTakeV1, dataRoot: URL) throws -> (cleanRewrite: Bool, channel: String?) {
        var current = take
        var visited = Set<String>()
        while let planID = current.generationInput.takeRepairPlanID {
            guard visited.insert(current.id).inserted else { throw ToolError("Iteration history contains a circular decision chain.") }
            let plan = try load(id: planID, dataRoot: dataRoot)
            let parent = try PipelineRenderTakeStore.take(id: plan.takeID, dataRoot: dataRoot)
            try validateChange(from: parent.generationInput, to: current.generationInput, operation: plan.operation)
            if plan.operation != .reroll { return (plan.operation.cleanRewrite, plan.operation.channel) }
            current = parent
        }
        return (false, nil)
    }

    static func validateChange(from parent: GenerationInput, to next: GenerationInput, operation: Operation) throws {
        guard parent.promptShotId == next.promptShotId, parent.promptProjectKey == next.promptProjectKey,
              parent.promptShotFingerprint == next.promptShotFingerprint else {
            throw ToolError("The shot plan changed. Record an iteration decision for the current plan.")
        }
        let promptChanged = parent.prompt != next.prompt
        let sameRecipe = parent.compileRecipe != nil && parent.compileRecipe == next.compileRecipe
        let intentChanged = (parent.compileRecipe?.intent ?? parent.prompt) != (next.compileRecipe?.intent ?? next.prompt)
        let sameRecipeContext = parent.compileRecipe?.setting == next.compileRecipe?.setting
            && parent.compileRecipe?.lighting == next.compileRecipe?.lighting && parent.compileRecipe?.style == next.compileRecipe?.style
            && parent.compileRecipe?.preserveComposition == next.compileRecipe?.preserveComposition
            && parent.compileRecipe?.styleFingerprint == next.compileRecipe?.styleFingerprint
        let modelChanged = parent.model != next.model || parent.productionRouting?.providerID != next.productionRouting?.providerID
            || parent.productionRouting?.endpointID != next.productionRouting?.endpointID
            || parent.productionRouting?.transportID != next.productionRouting?.transportID
            || parent.productionRouting?.modelParam != next.productionRouting?.modelParam
        func references(_ input: GenerationInput) -> [String] {
            if let routing = input.productionRouting { return routing.orderedBindings.map { "\($0.semanticJobID):\($0.sha256)" } }
            return [input.sourceVideoAssetId, input.startFrameAssetId, input.endFrameAssetId].compactMap { $0 }
                + (input.referenceImageAssetIds ?? []) + (input.referenceVideoAssetIds ?? []) + (input.referenceAudioAssetIds ?? [])
        }
        let before = references(parent), after = references(next)
        let changedReferences = before.count == after.count ? zip(before, after).filter { $0.0 != $0.1 }.count : Int.max
        guard parent.duration == next.duration, parent.videoDuration == next.videoDuration,
              parent.aspectRatio == next.aspectRatio, parent.resolution == next.resolution, parent.generateAudio == next.generateAudio else {
            throw ToolError("An iteration changed output settings as well as its declared variable. Plan and review that broader change explicitly.")
        }
        let allowed: Bool
        switch operation {
        case .reroll: allowed = !promptChanged && !modelChanged && changedReferences == 0
        case .revisePrompt:
            let oldLines = parent.prompt.components(separatedBy: .newlines), newLines = next.prompt.components(separatedBy: .newlines)
            allowed = sameRecipeContext && !modelChanged && changedReferences == 0 && oldLines.count == newLines.count && zip(oldLines, newLines).filter { $0.0 != $0.1 }.count == 1
        case .changeReference: allowed = (!promptChanged || sameRecipe) && !modelChanged && changedReferences == 1
        case .changeModel: allowed = (!promptChanged || sameRecipe) && modelChanged && changedReferences == 0
        case .cleanRewriteWithReference: allowed = sameRecipeContext && promptChanged && intentChanged && !modelChanged && changedReferences == 1
        case .cleanRewriteWithModel: allowed = sameRecipeContext && promptChanged && intentChanged && modelChanged && changedReferences == 0
        case .stop, .simplifyShot, .rescueRange: allowed = false
        }
        guard allowed else { throw ToolError("The request does not match the recorded repair decision. Review the intended change before generating again.") }
    }

    static func requireForGeneration(input: GenerationInput, home: URL?) async throws -> String? {
        guard input.productionRouting != nil, let shotID = input.promptShotId, let home,
              let root = DataRootResolver.dataRoot(of: home) else { return nil }
        return try await Task.detached(priority: .utility) {
            let saved = try current(shotID: shotID, dataRoot: root)
            let parent = try saved.map { try PipelineRenderTakeStore.take(id: $0.plan.takeID, dataRoot: root) }
            let applicable = parent?.generationInput.promptShotFingerprint == input.promptShotFingerprint ? saved : nil
            if let operation = applicable?.plan.operation, [.stop, .simplifyShot, .rescueRange].contains(operation) {
                throw ToolError("Generation is paused by the recorded decision: \(operation.label). Change that decision explicitly before another run.")
            }
            let policy = applicable?.plan.policy ?? TakeIterationPolicyV1()
            let result = try assessment(input: input, dataRoot: root, policy: policy)
            let revision = try PipelineRenderTakeStore.promptRevision(input)
            if let iteration = result.iterations.first(where: { $0.promptRevisionID == revision }), iteration.rolls >= policy.rollsPerPrompt {
                throw ToolError("The recorded roll limit for this prompt revision is reached. Review the candidates, change one variable, or explicitly revise the iteration policy in Video takes before another generation.")
            }
            if let applicable, let parent {
                try validateChange(from: parent.generationInput, to: input, operation: applicable.plan.operation)
            }
            if result.recommendation == .cleanRewriteAndChannelChange,
               applicable?.plan.operation.cleanRewrite != true {
                throw ToolError("The configured failed-iteration limit requires a clean prompt rewrite and another control channel. Record that decision in Video takes; no additional run is required.")
            }
            if result.recommendation == .simplifyShot {
                throw ToolError("Review the shot's complexity before another iteration. Rewind and simplify its plan, choose existing coverage, or stop.")
            }
            return applicable?.id
        }.value
    }

    @MainActor
    static func save(snapshot: TakeReview.Snapshot, operation: Operation, reason: String,
                     policy: TakeIterationPolicyV1, editor: EditorViewModel) async throws {
        try policy.validate()
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError("Explain the single change or the decision to stop.") }
        let refreshed = try await TakeReview.capture(takeID: snapshot.take.id, home: snapshot.home)
        guard refreshed.take == snapshot.take, refreshed.durationValue == snapshot.durationValue,
              refreshed.durationTimescale == snapshot.durationTimescale, editor.workingRoot == snapshot.home,
              let root = DataRootResolver.dataRoot(of: snapshot.home), let key = editor.openWorkingCopyKey,
              let review = try TakeReview.load(take: snapshot.take, dataRoot: root),
              review.durationValue == snapshot.durationValue, review.durationTimescale == snapshot.durationTimescale else {
            throw ToolError("Review the exact take before recording an iteration decision.")
        }
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Record iteration decision") else {
            throw ToolError("Wait for the current pipeline operation before changing the iteration decision.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        _ = try ProjectPackGate.requireLiveMutation(projectURL: snapshot.home, declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        try PipelinePhaseAccess.requireCurrentPhaseAndIntake("render", dataRoot: root,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        let reviewBytes = try Data(contentsOf: ProjectLocalFile.resolve(TakeReview.path(takeID: snapshot.take.id), dataRoot: root))
        guard try JSONDecoder().decode(TakeReview.self, from: reviewBytes) == review else { throw ToolError("The take review changed before the decision was saved.") }
        let plan = Self(schema: "take-repair-plan/v1", takeID: snapshot.take.id, reviewSHA256: FileDigest.sha256(of: reviewBytes),
            operation: operation, reason: reason, policy: policy, decidedBy: "native-user", decidedAt: currentTimestamp())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(plan)
        let current = root.appendingPathComponent(try currentPath(shotID: snapshot.take.shotID))
        let archive = root.appendingPathComponent(archivePath(id: FileDigest.sha256(of: bytes)))
        try ProjectWorkingCopy.markDirty(key: key)
        try ArtifactTransaction.perform(paths: [current, archive], dataRoot: root) {
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: archive.path) {
                guard try Data(contentsOf: archive) == bytes else { throw ToolError("An immutable iteration decision has different bytes.") }
            } else { try bytes.write(to: archive, options: .atomic) }
            try bytes.write(to: current, options: .atomic)
        }
        editor.onPipelineChanged?()
    }
}
