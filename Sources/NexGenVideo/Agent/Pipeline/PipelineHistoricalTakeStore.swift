import Foundation
import NexGenEngine

enum PipelineHistoricalTakeStore {
    struct Item: Identifiable, Sendable {
        let historyID: String
        let take: PipelineRenderTakeV1
        let previouslySelected: Bool
        let media: CanonicalArtifactReferenceV1
        let shotLabel: String
        let shotName: String?
        var id: String { historyID + ":" + take.phase + ":" + take.id }
    }

    struct Snapshot: Sendable {
        let items: [Item]
        let unavailableCount: Int
    }

    static func load(home: URL) throws -> Snapshot {
        guard let root = DataRootResolver.dataRoot(of: home) else { return .init(items: [], unavailableCount: 0) }
        let histories = try ProductionWorkflowRecoveryMigration.readCommittedHistories(staging: home)
        var items: [Item] = []
        var unavailableCount = 0
        for history in histories {
            let prefix = "migration-history/" + history.intent.fingerprint + "/"
            let archive = root.appendingPathComponent(prefix + DataRootResolver.pipelineDirname)
            let projectionPrefix = DataRootResolver.pipelineDirname + "/shotlist/v"
            let revisions = history.intent.archivePaths.compactMap { path -> Int? in
                guard path.hasPrefix(projectionPrefix), path.hasSuffix(".v5.yaml") else { return nil }
                return Int(path.dropFirst(projectionPrefix.count).dropLast(".v5.yaml".count))
            }
            let projection: ProductionPlanProjectionV1?
            if let revision = revisions.max(), revision > 0 {
                let path = ProductionPlanProjectionV1.versionPath(revision)
                let original = DataRootResolver.pipelineDirname + "/" + path
                guard let recorded = history.intent.files.first(where: { $0.path == original }) else {
                    throw ToolError("The historical production plan has no original file evidence.")
                }
                let url = try ProjectLocalFile.requireHash(recorded.sha256, at: path, dataRoot: archive)
                projection = try YAMLCoding.decode(ProductionPlanProjectionV1.self, from: String(contentsOf: url, encoding: .utf8))
            } else { projection = nil }
            for phase in ["preview", "final"] {
                let indexPath = PipelineRenderTakeStore.indexPath(phase: phase)
                let packagePath = DataRootResolver.pipelineDirname + "/" + indexPath
                guard history.intent.archivePaths.contains(packagePath) else { continue }
                let indexURL = try ProjectLocalFile.resolve(indexPath, dataRoot: archive)
                let stored = try JSONDecoder().decode(PipelineTakeIndexV1.self, from: Data(contentsOf: indexURL))
                let index = try PipelineRenderTakeStore.load(dataRoot: archive, project: stored.project, phase: phase)
                for id in index.takeIDs {
                    let take = try PipelineRenderTakeStore.take(id: id, dataRoot: archive, phase: phase)
                    let originalPath = DataRootResolver.pipelineDirname + "/" + take.output.path
                    guard let recorded = history.intent.files.first(where: { $0.path == originalPath }),
                          recorded.sha256 == take.output.sha256 else {
                        throw ToolError("A historical take is missing its original output evidence.")
                    }
                    let path = history.intent.archivePaths.contains(originalPath)
                        ? DataRootResolver.pipelineDirname + "/" + prefix + originalPath : originalPath
                    do {
                        _ = try ProjectLocalFile.requireHash(recorded.sha256, at: path, dataRoot: home)
                    } catch {
                        unavailableCount += 1
                        continue
                    }
                    let number = projection?.shots.firstIndex { $0.id == take.shotID }
                    items.append(.init(historyID: history.intent.fingerprint, take: take,
                        previouslySelected: index.selected[take.shotID] == take.id,
                        media: .init(id: take.id, role: "historical.video-take", path: path, sha256: recorded.sha256),
                        shotLabel: number.map { "Shot \($0 + 1)" } ?? take.shotID,
                        shotName: number.flatMap { projection?.shots[$0].primaryAction }))
                }
            }
        }
        return .init(items: items.sorted { $0.take.recordedAt > $1.take.recordedAt }, unavailableCount: unavailableCount)
    }
}
