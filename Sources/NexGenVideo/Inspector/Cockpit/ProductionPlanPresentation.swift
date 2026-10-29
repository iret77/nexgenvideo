import Foundation
import NexGenEngine

enum ProductionPlanPresentation {
    struct Snapshot: Sendable, Equatable {
        let projection: ProductionPlanProjectionV1
        let draft: ShotPlanningDraftV1
        let storyboard: StoryboardBundleSnapshot
        let inventory: PipelineProductionPlanReadStore.Inventory

        func number(_ id: String) -> Int? { projection.shots.firstIndex { $0.id == id }.map { $0 + 1 } }
    }

    static func projectionIfPresent(dataRoot: URL) throws -> ProductionPlanProjectionV1? {
        let directory = dataRoot.appendingPathComponent("shotlist")
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ToolError("The Shot List folder cannot be read safely. Restore it before continuing.")
        }
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasSuffix(".v5.yaml") }) else { return nil }
        return try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
    }

    static func load(dataRoot: URL) throws -> Snapshot? {
        guard let projection = try projectionIfPresent(dataRoot: dataRoot) else { return nil }
        let board = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: board)
        try ProductionPlanProjectionValidatorV1.validate(projection, storyboard: board, draft: draft)
        let inventory = try PipelineProductionPlanReadStore.inventory(dataRoot: dataRoot)
        guard inventory.projection == projection else { throw ToolError("The Shot List changed. Reload it before reviewing.") }
        return Snapshot(projection: projection, draft: draft, storyboard: board, inventory: inventory)
    }

    static func sourceLabel(_ mode: ExecutionSourceModeV1) -> String {
        switch mode {
        case .generated: "Generated"
        case .imported: "Imported footage"
        case .aiEnhanced: "AI-enhanced footage"
        }
    }
}

struct ProductionPlanSelection: Equatable {
    let home: URL
    let snapshot: ProductionPlanPresentation.Snapshot
    let shotID: String

    var shot: ExecutionShotV1? { snapshot.projection.shots.first { $0.id == shotID } }
    var timing: ProductionPlanProjectionV1.ShotTiming? { snapshot.projection.timing(for: shotID) }
}
