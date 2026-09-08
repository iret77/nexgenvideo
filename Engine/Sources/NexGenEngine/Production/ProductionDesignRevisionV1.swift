import Foundation

public struct ProductionDesignRevisionV1: Codable, Sendable {
    public let schema: String
    public let id: String
    public let design: Data
    public let style: Data?
    public let lineage: Data?

    public static func archive(design: Data, style: Data?, lineage: Data?, dataRoot: URL) throws {
        let directory = dataRoot.appendingPathComponent("production_design/history")
        guard directory.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath().appendingPathComponent("production_design/history") else {
            throw GateBlocked("Production Design history cannot be written through a symbolic link.")
        }
        let revision = Self(schema: "production-design-revision/v1", id: UUID().uuidString,
                            design: design, style: style, lineage: lineage)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(revision).write(to: directory.appendingPathComponent(revision.id + ".revision.json"), options: .atomic)
    }
}
