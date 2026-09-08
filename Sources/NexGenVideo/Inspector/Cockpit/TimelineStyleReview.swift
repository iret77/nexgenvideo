import Foundation
import NexGenEngine

struct TimelineStyleFinding: Codable, Sendable, Equatable {
    enum Verdict: String, Codable, CaseIterable { case conforms, acceptedDeviation }
    let criterionID: String
    let verdict: Verdict
    let observation: String
}

struct TimelineStyleReview: Codable, Sendable {
    static let relativePath = "review/timeline-style.v1.json"
    let schema: String
    let fingerprint: String
    let findings: [TimelineStyleFinding]
    let reviewedAt: String

    struct Snapshot: Sendable {
        let home: URL
        let fingerprint: String
        let style: ResolvedProductionStyleV1
    }

    @MainActor
    static func capture(timeline: Timeline, resolver: MediaResolver) async throws -> Snapshot? {
        guard let home = resolver.projectHome, let root = DataRootResolver.dataRoot(of: home) else { return nil }
        let clips = timeline.tracks.flatMap(\.clips)
        let references = Set(clips.filter { $0.mediaType != .text }.map(\.mediaRef)).sorted()
        let urls = references.map { ($0, resolver.resolveURL(for: $0)) }
        return try await Task.detached(priority: .utility) {
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
            for (id, url) in urls {
                try Task.checkCancellation()
                guard let url else { throw ToolError("Restore the timeline's offline media before style review.") }
                data.append(Data((id + ":" + (try FileDigest.sha256(of: url))).utf8))
            }
            guard before == (try ProductionStyleStoreV1.snapshot(dataRoot: root)) else { throw ToolError("Production Design changed during review. Refresh the review.") }
            return Snapshot(home: home, fingerprint: FileDigest.sha256(of: data), style: style)
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
              review.schema == "timeline-style-review/v1", review.fingerprint == snapshot.fingerprint else {
            throw ToolError("Review the current timeline's production-style criteria in Review before exporting. Changed cuts, media or style require a new review.")
        }
        try validate(review.findings, style: snapshot.style)
    }

    static func validate(_ findings: [TimelineStyleFinding], style: ResolvedProductionStyleV1) throws {
        guard findings.count == style.criteria.count,
              Set(findings.map(\.criterionID)) == Set(style.criteria.map(\.auditKey)),
              findings.allSatisfy({ !$0.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ToolError("Review every style criterion against the current timeline, with an observation or an explicit reason for accepting the deviation.")
        }
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
        try validate(findings, style: snapshot.style)
        let review = Self(schema: "timeline-style-review/v1", fingerprint: snapshot.fingerprint, findings: findings, reviewedAt: currentTimestamp())
        let path = root.appendingPathComponent(relativePath)
        guard path.resolvingSymlinksInPath() == root.resolvingSymlinksInPath().appendingPathComponent(relativePath) else {
            throw ToolError("The review cannot be saved through a symbolic link.")
        }
        try ProjectWorkingCopy.markDirty(key: key)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(review).write(to: path, options: .atomic)
        editor.onPipelineChanged?()
    }
}
