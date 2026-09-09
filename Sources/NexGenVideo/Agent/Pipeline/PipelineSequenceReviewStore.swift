import Foundation
import NexGenEngine

enum PipelineSequenceReviewStore {
    struct Snapshot: Sendable {
        let home: URL
        let projectID: String
        let plan: AssemblyPlanV1
        let reel: ReviewReelV1
        let executionPlanSHA256: String
        let canonSHA256: String
        let referencePlanSHA256: String
    }

    private struct ReferenceBinding: Codable {
        let shotID: String
        let sourceKind: SelectedShotMediaKindV1
        let fingerprint: String

        private enum CodingKeys: String, CodingKey {
            case shotID = "shot_id"
            case sourceKind = "source_kind"
            case fingerprint
        }
    }

    private static let archiveDirectory = "reviews/sequence/archive"

    @MainActor
    static func capture(editor: EditorViewModel) async throws -> Snapshot {
        guard let home = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: home) else {
            throw ToolError("Open a project before reviewing its sequence.")
        }
        let assembly = try requireCurrentAssembly(
            dataRoot: dataRoot,
            timeline: editor.timeline
        )
        let fingerprints = try productionFingerprints(
            selectedMedia: assembly.plan.selectedMedia,
            dataRoot: dataRoot
        )
        let reel = try await ReviewReelBuilder.build(
            plan: assembly.plan,
            dataRoot: dataRoot
        )
        return Snapshot(
            home: home,
            projectID: assembly.plan.projectID,
            plan: assembly.plan,
            reel: reel,
            executionPlanSHA256: fingerprints.execution,
            canonSHA256: fingerprints.canon,
            referencePlanSHA256: fingerprints.references
        )
    }

    @MainActor
    static func save(
        snapshot: Snapshot,
        adjacentPairCompleted: Bool,
        wholePlaybackCompleted: Bool,
        findings: [SequenceReviewFindingV1],
        editor: EditorViewModel
    ) async throws {
        guard editor.workingRoot == snapshot.home,
              let dataRoot = DataRootResolver.dataRoot(of: snapshot.home),
              let workingCopyKey = editor.openWorkingCopyKey else {
            throw ToolError("The active project changed. Start the sequence review again.")
        }
        let current = try await capture(editor: editor)
        guard current.plan == snapshot.plan,
              current.reel == snapshot.reel,
              current.executionPlanSHA256 == snapshot.executionPlanSHA256,
              current.canonSHA256 == snapshot.canonSHA256,
              current.referencePlanSHA256 == snapshot.referencePlanSHA256 else {
            throw ToolError("The cut or its production inputs changed. Review the current sequence again.")
        }
        let review = SequenceReviewV1(
            projectID: snapshot.projectID,
            selectedMedia: snapshot.plan.selectedMedia,
            reviewReel: snapshot.reel,
            executionPlanSHA256: snapshot.executionPlanSHA256,
            canonSHA256: snapshot.canonSHA256,
            referencePlanSHA256: snapshot.referencePlanSHA256,
            adjacentPairCompleted: adjacentPairCompleted,
            wholePlaybackCompleted: wholePlaybackCompleted,
            findings: findings,
            reviewedAt: currentTimestamp()
        )
        try SequenceReviewValidatorV1.validate(
            review,
            selectedMedia: snapshot.plan.selectedMedia,
            executionPlanSHA256: snapshot.executionPlanSHA256,
            canonSHA256: snapshot.canonSHA256,
            referencePlanSHA256: snapshot.referencePlanSHA256
        )
        try validateReelAgainstPlan(snapshot.reel, plan: snapshot.plan)
        let bytes = try PipelineAssemblyStore.canonical(review)
        let archivePath = "\(archiveDirectory)/\(FileDigest.sha256(of: bytes)).v1.json"
        let currentURL = dataRoot.appendingPathComponent(SequenceReviewV1.relativePath)
        let archiveURL = dataRoot.appendingPathComponent(archivePath)
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(
            projectRoot: dataRoot,
            label: "Record sequence review"
        ) else {
            throw ToolError("Wait for the active pipeline operation before recording the review.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: dataRoot, id: lease) }
        _ = try ProjectPackGate.requireLiveMutation(
            projectURL: snapshot.home,
            declaredPack: editor.declaredPluginName,
            declaredBinding: editor.declaredPluginBinding
        )
        try ProjectWorkingCopy.markDirty(key: workingCopyKey)
        try ArtifactTransaction.perform(paths: [currentURL, archiveURL], dataRoot: dataRoot) {
            try FileManager.default.createDirectory(
                at: archiveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                guard try Data(contentsOf: archiveURL) == bytes else {
                    throw ToolError("An immutable sequence review has different bytes.")
                }
            } else {
                try bytes.write(to: archiveURL, options: .atomic)
            }
            try bytes.write(to: currentURL, options: .atomic)
        }
        editor.onPipelineChanged?()
    }

    static func requireCurrent(dataRoot: URL, timeline: Timeline) throws -> SequenceReviewV1 {
        let assembly = try requireCurrentAssembly(dataRoot: dataRoot, timeline: timeline)
        let fingerprints = try productionFingerprints(
            selectedMedia: assembly.plan.selectedMedia,
            dataRoot: dataRoot
        )
        return try loadStoredReview(
            selectedMedia: assembly.plan.selectedMedia,
            plan: assembly.plan,
            fingerprints: fingerprints,
            rejectBlocking: true,
            dataRoot: dataRoot
        )
    }

    static func repairInstructions(dataRoot: URL, phase: String) -> String? {
        guard phase == "render",
              FileManager.default.fileExists(
                  atPath: dataRoot.appendingPathComponent(SequenceReviewV1.relativePath).path
              ) else { return nil }
        do {
            guard let assembly = try PipelineAssemblyStore.load(dataRoot: dataRoot) else {
                return nil
            }
            try PipelineAssemblyStore.requireCurrentSources(
                assembly.plan.selectedMedia,
                dataRoot: dataRoot
            )
            let fingerprints = try productionFingerprints(
                selectedMedia: assembly.plan.selectedMedia,
                dataRoot: dataRoot
            )
            let review = try loadStoredReview(
                selectedMedia: assembly.plan.selectedMedia,
                plan: assembly.plan,
                fingerprints: fingerprints,
                rejectBlocking: false,
                dataRoot: dataRoot
            )
            let findings = review.findings.filter {
                $0.severity != .info || $0.recommendedAction != .accept
            }
            guard !findings.isEmpty else { return nil }
            let data = try PipelineAssemblyStore.canonical(findings)
            guard let payload = String(data: data, encoding: .utf8) else { return nil }
            return """
            Sequence review evidence for repair planning: \(payload)
            Treat these as attributed observations about the exact reviewed reel. Propose only the recorded action for the affected shots and ranges. Do not mutate a take, timeline, canon, approval or budget from a finding; paid generation still requires the host-owned decision and spend boundary.
            """
        } catch {
            Log.agent.warning(
                "sequence review repair context ignored because it is stale error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private static func loadStoredReview(
        selectedMedia: [SelectedShotMediaV1],
        plan: AssemblyPlanV1,
        fingerprints: (execution: String, canon: String, references: String),
        rejectBlocking: Bool,
        dataRoot: URL
    ) throws -> SequenceReviewV1 {
        let currentURL = dataRoot.appendingPathComponent(SequenceReviewV1.relativePath)
        guard FileManager.default.fileExists(atPath: currentURL.path) else {
            throw GateBlocked("Review the assembled sequence before continuing.")
        }
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(
            SequenceReviewV1.relativePath,
            dataRoot: dataRoot
        ))
        let review = try JSONDecoder().decode(SequenceReviewV1.self, from: bytes)
        try SequenceReviewValidatorV1.validate(
            review,
            selectedMedia: selectedMedia,
            executionPlanSHA256: fingerprints.execution,
            canonSHA256: fingerprints.canon,
            referencePlanSHA256: fingerprints.references
        )
        if rejectBlocking,
           review.findings.contains(where: { $0.severity == .blocking }) {
            throw GateBlocked("Resolve or explicitly supersede every blocking sequence finding before continuing.")
        }
        try validateReelAgainstPlan(review.reviewReel, plan: plan)
        let archivePath = "\(archiveDirectory)/\(FileDigest.sha256(of: bytes)).v1.json"
        guard try Data(contentsOf: ProjectLocalFile.resolve(archivePath, dataRoot: dataRoot)) == bytes else {
            throw GateBlocked("The current sequence review has no matching immutable record.")
        }
        let reelURL = try ProjectLocalFile.requireHash(
            review.reviewReel.sha256,
            at: review.reviewReel.path,
            dataRoot: dataRoot
        )
        let values = try reelURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              values.fileSize.map(Int64.init) == review.reviewReel.byteCount else {
            throw GateBlocked("The reviewed reel bytes changed or are missing.")
        }
        let edlURL = try ProjectLocalFile.requireHash(
            review.reviewReel.edlSHA256,
            at: review.reviewReel.edlPath,
            dataRoot: dataRoot
        )
        let edl = try JSONDecoder().decode(ReviewReelEDLV1.self, from: Data(contentsOf: edlURL))
        guard edl.schema == ReviewReelEDLV1.schemaVersion,
              edl.fps == review.reviewReel.fps,
              edl.entries == review.reviewReel.entries else {
            throw GateBlocked("The reviewed reel EDL is stale or malformed.")
        }
        return review
    }

    private static func requireCurrentAssembly(
        dataRoot: URL,
        timeline: Timeline
    ) throws -> PipelineAssemblyStore.ExistingState {
        guard let assembly = try PipelineAssemblyStore.load(dataRoot: dataRoot) else {
            throw GateBlocked("Assemble the selected media before reviewing the sequence.")
        }
        try PipelineAssemblyStore.requireCurrentSources(
            assembly.plan.selectedMedia,
            dataRoot: dataRoot
        )
        guard try PipelineAssemblyStore.fingerprint(timeline: timeline)
                == assembly.manifest.timelineFingerprint else {
            throw GateBlocked("The assembled cut changed. Adopt or rebuild it before sequence review.")
        }
        return assembly
    }

    static func productionFingerprints(
        selectedMedia: [SelectedShotMediaV1],
        dataRoot: URL
    ) throws -> (execution: String, canon: String, references: String) {
        let (plan, _) = try PipelineExecutionPlanWriter.load(dataRoot: dataRoot)
        let executionURL = try ProjectLocalFile.resolve(
            PipelineLayout.executionPlanFile,
            dataRoot: dataRoot
        )
        var bindings: [ReferenceBinding] = []
        for selected in selectedMedia {
            let fingerprint: String
            if let takeID = selected.takeID {
                let take = try PipelineRenderTakeStore.take(id: takeID, dataRoot: dataRoot)
                if let route = take.generationInput.productionRouting {
                    fingerprint = route.referencePlanSHA256
                } else if let framePlan = take.generationInput.frameReferencePlan {
                    fingerprint = FileDigest.sha256(of: try PipelineAssemblyStore.canonical(framePlan))
                } else {
                    fingerprint = selected.sourceSHA256
                }
            } else {
                fingerprint = selected.sourceSHA256
            }
            bindings.append(.init(
                shotID: selected.shotID,
                sourceKind: selected.sourceKind,
                fingerprint: fingerprint
            ))
        }
        return (
            execution: try FileDigest.sha256(of: executionURL),
            canon: plan.creativeContext.sha256,
            references: FileDigest.sha256(of: try PipelineAssemblyStore.canonical(bindings))
        )
    }

    private static func validateReelAgainstPlan(
        _ reel: ReviewReelV1,
        plan: AssemblyPlanV1
    ) throws {
        guard let firstStart = plan.placements.map(\.timelineStartFrame).min(),
              reel.entries.count == plan.placements.count else {
            throw GateBlocked("The sequence review reel does not match its assembly plan.")
        }
        for (entry, placement) in zip(reel.entries, plan.placements) {
            guard entry.shotID == placement.shotID,
                  entry.reelStartFrame == placement.timelineStartFrame - firstStart,
                  entry.reelEndFrame == entry.reelStartFrame
                    + placement.sourceEndFrame - placement.sourceStartFrame,
                  entry.transitionIn == placement.transitionIn else {
                throw GateBlocked("The sequence review EDL does not match the current cut.")
            }
        }
    }
}
