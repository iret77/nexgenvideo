import Foundation
import NexGenEngine

struct TakeReviewQueue: Sendable {
    struct Shot: Sendable, Equatable {
        let id: String
        let number: Int
        let takeID: String?
    }

    let shots: [Shot]
    let selectedShotIDs: Set<String>

    static func load(takes: [PipelineRenderTakeV1], dataRoot: URL) async throws -> Self {
        try Task.checkCancellation()
        let work = Task.detached(priority: .utility) { try read(takes: takes, dataRoot: dataRoot) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func read(takes: [PipelineRenderTakeV1], dataRoot: URL) throws -> Self {
        try Task.checkCancellation()
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let projectionPath = ProductionPlanProjectionV1.versionPath(projection.header.revision)
        let stills = ShotDeliveryModeResolverV1.stillShotIDs(in: projection.executionPlan)
        let shots = projection.shots.enumerated().filter { $0.element.sourceMode != .imported && !stills.contains($0.element.id) }
        let ordered = takes.filter { $0.phase == "final" }.sorted { $0.recordedAt > $1.recordedAt }
        return try assemble(shots: shots.map { .init(id: $0.element.id, number: $0.offset + 1, takeID: nil) },
            isSelected: { shotID in
                (try? PipelineProductionRenderWriter.requireSelected(shotID: shotID, dataRoot: dataRoot)) != nil
            }, candidate: { shotID in
                for take in ordered where take.shotID == shotID {
                    try Task.checkCancellation()
                    guard let record = try? PlanningWriterIO.read(PipelineProductionRenderWriter.Record.self,
                        at: PipelineProductionRenderWriter.recordPath(take.id), dataRoot: dataRoot),
                        record.projection.path == projectionPath else { continue }
                    if (try? PipelineProductionRenderWriter.requireRecord(takeID: take.id, dataRoot: dataRoot)) != nil {
                        return take.id
                    }
                }
                return nil
            })
    }

    static func assemble(shots: [Shot], isSelected: (String) throws -> Bool,
                         candidate: (String) throws -> String?) throws -> Self {
        var selected: Set<String> = [], result: [Shot] = []
        for shot in shots {
            try Task.checkCancellation()
            if try isSelected(shot.id) {
                selected.insert(shot.id)
                result.append(.init(id: shot.id, number: shot.number, takeID: nil))
            } else {
                try Task.checkCancellation()
                result.append(.init(id: shot.id, number: shot.number, takeID: try candidate(shot.id)))
            }
        }
        return Self(shots: result, selectedShotIDs: selected)
    }

    func next(after shotID: String) -> Shot? {
        guard let current = shots.firstIndex(where: { $0.id == shotID }),
              selectedShotIDs.contains(shotID) else { return nil }
        let ordered = Array(shots.dropFirst(current + 1)) + Array(shots.prefix(current))
        return ordered.first { !selectedShotIDs.contains($0.id) }
    }
}
