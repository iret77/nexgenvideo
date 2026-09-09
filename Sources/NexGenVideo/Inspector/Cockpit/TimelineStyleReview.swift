import Foundation
import NexGenEngine

struct TimelineStyleFinding: Codable, Sendable, Equatable {
    enum Result: String, Codable, CaseIterable {
        case pass
        case fail
        case notApplicable = "not_applicable"
        case notObserved = "not_observed"
    }

    let criterionID: String
    let sourceClause: String
    let dimension: ProductionStyleDimensionV1
    let appliesWhen: String
    let scope: ProductionReviewScopeV1
    let evidenceKind: ProductionReviewEvidenceKindV1
    let targetIDs: [String]
    let expected: String
    let result: Result
    let acceptedDeviation: Bool
    let evidenceReferences: [TimelineStyleEvidenceReference]
    let reviewer: String
    let observation: String

    private enum CodingKeys: String, CodingKey {
        case criterionID = "criterion_id"
        case sourceClause = "source_clause"
        case dimension
        case appliesWhen = "applies_when"
        case scope
        case evidenceKind = "evidence_kind"
        case targetIDs = "target_ids"
        case expected
        case result
        case acceptedDeviation = "accepted_deviation"
        case evidenceReferences = "evidence_references"
        case reviewer
        case observation
    }
}

struct TimelineStyleEvidenceReference: Codable, Sendable, Equatable {
    let clipID: String
    let mediaID: String
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case clipID = "clip_id"
        case mediaID = "media_id"
        case sha256
    }
}

struct TimelineStyleReview: Codable, Sendable {
    static let relativePath = "review/timeline-style.v2.json"
    let schema: String
    let fingerprint: String
    let findings: [TimelineStyleFinding]
    let reviewedAt: String

    struct Snapshot: Sendable {
        let home: URL
        let fingerprint: String
        let style: ResolvedProductionStyleV1
        let targetsByCriterion: [String: [String]]
        let evidenceByCriterion: [String: [TimelineStyleEvidenceReference]]
    }

    @MainActor
    static func capture(timeline: Timeline, resolver: MediaResolver) async throws -> Snapshot? {
        guard let home = resolver.projectHome, let root = DataRootResolver.dataRoot(of: home) else { return nil }
        let clips = timeline.tracks.flatMap(\.clips)
        let references = Set(clips.filter { $0.mediaType != .text }.map(\.mediaRef)).sorted()
        let urls = references.map { ($0, resolver.resolveURL(for: $0)) }
        return try await Task.detached(priority: .utility) { () throws -> Snapshot? in
            guard let style = try ProductionStyleStoreV1.load(dataRoot: root) else { return nil }
            let before = try ProductionStyleStoreV1.snapshot(dataRoot: root)
            guard style == (try ProductionStyleStoreV1.load(dataRoot: root)) else {
                throw ToolError("Production Design changed during review. Refresh the review.")
            }
            guard !clips.isEmpty else { throw ToolError("Add the intended cut to the timeline before reviewing its production style.") }
            let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
            guard gates.get("production_design").approved else { throw ToolError("Approve Production Design before reviewing the finished timeline's style.") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(timeline)
            data.append(Data((before.inputFingerprint + ":" + before.artifactFingerprint).utf8))
            var hashByMediaID: [String: String] = [:]
            for (id, url) in urls {
                try Task.checkCancellation()
                guard let url else { throw ToolError("Restore the timeline's offline media before style review.") }
                let sha256 = try FileDigest.sha256(of: url)
                hashByMediaID[id] = sha256
                data.append(Data((id + ":" + sha256).utf8))
            }
            guard before == (try ProductionStyleStoreV1.snapshot(dataRoot: root)) else { throw ToolError("Production Design changed during review. Refresh the review.") }
            let evidence = Dictionary(uniqueKeysWithValues: style.criteria.map { criterion in
                let targets = Self.eligibleClips(for: criterion, clips: clips)
                return (criterion.auditKey, targets.compactMap { clip in
                    guard let sha256 = hashByMediaID[clip.mediaRef] else { return nil }
                    return TimelineStyleEvidenceReference(
                        clipID: clip.id,
                        mediaID: clip.mediaRef,
                        sha256: sha256
                    )
                })
            })
            return Snapshot(
                home: home,
                fingerprint: FileDigest.sha256(of: data),
                style: style,
                targetsByCriterion: evidence.mapValues { $0.map(\.clipID) },
                evidenceByCriterion: evidence
            )
        }.value
    }

    @MainActor
    static func revalidate(_ expected: Snapshot?, timeline: Timeline, resolver: MediaResolver) async throws {
        let current = try await capture(timeline: timeline, resolver: resolver)
        guard current?.fingerprint == expected?.fingerprint, current?.home == expected?.home else {
            throw ToolError("The export's media or production style changed. Review the current cut before exporting again.")
        }
        if let current { try requireCurrent(current) }
    }

    static func requireCurrent(_ snapshot: Snapshot) throws {
        guard let root = DataRootResolver.dataRoot(of: snapshot.home) else { throw ToolError("The review project is unavailable.") }
        guard let path = try? ProjectLocalFile.resolve(relativePath, dataRoot: root), let data = try? Data(contentsOf: path), let review = try? JSONDecoder().decode(Self.self, from: data),
              review.schema == "timeline-style-review/v2", review.fingerprint == snapshot.fingerprint else {
            throw ToolError("Review the current timeline's production-style criteria in Review before exporting. Changed cuts, media or style require a new review.")
        }
        try validate(review.findings, snapshot: snapshot)
        let unresolved = review.findings.filter {
            $0.result == .notObserved
                || ($0.result == .fail && !$0.acceptedDeviation)
        }
        guard unresolved.isEmpty else {
            throw ToolError(
                "The current timeline has \(unresolved.count) unobserved or failed production-style "
                    + "criteria. Review actual matching media before export."
            )
        }
    }

    static func validate(
        _ findings: [TimelineStyleFinding],
        snapshot: Snapshot
    ) throws {
        let criteriaByID = Dictionary(uniqueKeysWithValues:
            snapshot.style.criteria.map { ($0.auditKey, $0) }
        )
        guard findings.count == criteriaByID.count,
              Set(findings.map(\.criterionID)) == Set(criteriaByID.keys) else {
            throw ToolError("Review every style criterion against the current timeline, with an observation or an explicit reason for accepting the deviation.")
        }
        for finding in findings {
            guard let criterion = criteriaByID[finding.criterionID],
                  finding.sourceClause == criterion.source.sourceClause,
                  finding.dimension == criterion.source.dimension,
                  finding.appliesWhen == appliesWhen(criterion),
                  finding.scope == criterion.scope,
                  finding.evidenceKind == criterion.evidenceKind,
                  finding.targetIDs == snapshot.targetsByCriterion[finding.criterionID] ?? [],
                  finding.expected == criterion.expected,
                  finding.evidenceReferences
                    == snapshot.evidenceByCriterion[finding.criterionID] ?? [],
                  finding.reviewer == "project-owner",
                  !finding.observation.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty else {
                throw ToolError(
                    "The style review for \(finding.criterionID) does not match its exact "
                        + "criterion, evidence, targets, or reviewer."
                )
            }
            let hasEvidence = !finding.targetIDs.isEmpty
                && !finding.evidenceReferences.isEmpty
            if !hasEvidence, finding.result != .notObserved {
                throw ToolError(
                    "Style criterion \(finding.criterionID) has no matching "
                        + "\(finding.evidenceKind.rawValue) evidence and must remain not_observed."
                )
            }
            if finding.result != .fail, finding.acceptedDeviation {
                throw ToolError("Only an observed failed criterion can carry an accepted deviation.")
            }
        }
    }

    static func makeFinding(
        criterion: ResolvedProductionStyleCriterionV1,
        result: TimelineStyleFinding.Result,
        acceptedDeviation: Bool,
        observation: String,
        snapshot: Snapshot
    ) -> TimelineStyleFinding {
        TimelineStyleFinding(
            criterionID: criterion.auditKey,
            sourceClause: criterion.source.sourceClause,
            dimension: criterion.source.dimension,
            appliesWhen: appliesWhen(criterion),
            scope: criterion.scope,
            evidenceKind: criterion.evidenceKind,
            targetIDs: snapshot.targetsByCriterion[criterion.auditKey] ?? [],
            expected: criterion.expected,
            result: result,
            acceptedDeviation: acceptedDeviation,
            evidenceReferences: snapshot.evidenceByCriterion[criterion.auditKey] ?? [],
            reviewer: "project-owner",
            observation: observation
        )
    }

    @MainActor
    static func save(snapshot: Snapshot, findings: [TimelineStyleFinding], editor: EditorViewModel) async throws {
        guard editor.workingRoot == snapshot.home, let root = DataRootResolver.dataRoot(of: snapshot.home),
              let key = editor.openWorkingCopyKey else { throw ToolError("The review project changed. Review the active project again.") }
        let timeline = editor.timeline
        guard let current = try await capture(timeline: timeline, resolver: editor.mediaResolver.snapshot()),
              editor.workingRoot == snapshot.home, editor.timeline == timeline,
              current.fingerprint == snapshot.fingerprint else { throw ToolError("The timeline changed during review. Refresh and review the changed cut.") }
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Record timeline style review") else {
            throw ToolError("Wait for the current pipeline operation before recording the review.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        _ = try ProjectPackGate.requireLiveMutation(projectURL: snapshot.home, declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        try validate(findings, snapshot: snapshot)
        let review = Self(schema: "timeline-style-review/v2", fingerprint: snapshot.fingerprint, findings: findings, reviewedAt: currentTimestamp())
        let path = root.appendingPathComponent(relativePath)
        guard path.resolvingSymlinksInPath() == root.resolvingSymlinksInPath().appendingPathComponent(relativePath) else {
            throw ToolError("The review cannot be saved through a symbolic link.")
        }
        try ProjectWorkingCopy.markDirty(key: key)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(review).write(to: path, options: .atomic)
        editor.onPipelineChanged?()
    }

    private static func appliesWhen(
        _ criterion: ResolvedProductionStyleCriterionV1
    ) -> String {
        "The selected \(criterion.source.recipeID) recipe applies and matching "
            + "\(criterion.evidenceKind.rawValue) evidence exists at \(criterion.scope.rawValue) scope."
    }

    private static func eligibleClips(
        for criterion: ResolvedProductionStyleCriterionV1,
        clips: [Clip]
    ) -> [Clip] {
        let selected: [Clip]
        switch criterion.evidenceKind {
        case .image:
            selected = clips.filter {
                [.video, .image, .lottie].contains($0.sourceClipType)
            }
        case .video:
            selected = clips.filter { $0.sourceClipType == .video }
        case .audio:
            selected = clips.filter { $0.mediaType == .audio }
        case .audiovisual:
            let video = clips.filter { $0.sourceClipType == .video }
            let audio = clips.filter { $0.mediaType == .audio }
            selected = video.isEmpty || audio.isEmpty ? [] : video + audio
        }
        return selected.sorted {
            if $0.startFrame == $1.startFrame { return $0.id < $1.id }
            return $0.startFrame < $1.startFrame
        }
    }
}
