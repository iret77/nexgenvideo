import Foundation

public struct ProductionSpatialInventoryV1: Codable, Sendable, Equatable {
    public static let currentPath = "production_design/spatial/inventory.v1.json"
    public let schema: String
    public let projectID: String
    public let references: [CanonicalArtifactReferenceV1]

    public init(projectID: String, references: [CanonicalArtifactReferenceV1]) {
        schema = "production-spatial-inventory/v1"
        self.projectID = projectID
        self.references = references
    }

    public func requireCurrent(dataRoot: URL) throws {
        try PlanningValidation.require(schema == "production-spatial-inventory/v1", "spatial.inventory.schema")
        let meta = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        try PlanningValidation.require(projectID == meta.project, "spatial.inventory.project")
        try PlanningValidation.unique(references.map(\.path), "spatial.inventory.paths")
        try PlanningValidation.require(references.contains { $0.path == "production_design/spatial/index.v1.json" }, "spatial.inventory.index")
        for reference in references {
            try PlanningValidation.reference(reference)
            try PlanningValidation.require(reference.path.hasPrefix("production_design/spatial/")
                && reference.path != Self.currentPath, "spatial.inventory.reference")
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
        }
    }

    public static func loadIfPresent(dataRoot: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("production_design/spatial").path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: ProjectLocalFile.resolve(currentPath, dataRoot: dataRoot)))
        try value.requireCurrent(dataRoot: dataRoot)
        return value
    }
}
