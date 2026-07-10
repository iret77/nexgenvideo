import Foundation
import Testing
@testable import NexGenEngine

@Suite("DataRootResolver")
struct DataRootResolverTests {
    /// Locate the bundled fixture project home (`Fixtures/basic-project/`).
    static func fixtureHome() throws -> URL {
        let dir = try #require(
            Bundle.module.url(forResource: "basic-project", withExtension: nil, subdirectory: "Fixtures"),
            "fixture Fixtures/basic-project not found in test bundle"
        )
        return dir
    }

    @Test("v2 project home resolves to its pipeline data root")
    func resolvesPipelineLayout() throws {
        let home = try Self.fixtureHome()
        let root = try #require(DataRootResolver.dataRoot(of: home))
        #expect(root.lastPathComponent == DataRootResolver.pipelineDirname)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(DataRootResolver.projectMarker).path
        ))
    }

    @Test("the data root itself resolves as a legacy flat root")
    func pipelineDirResolvesFlat() throws {
        // Python semantics: pipeline/project.yaml is a valid flat marker, so
        // data_root_of(pipeline) returns pipeline itself (paths.py flat branch).
        let studio = try Self.fixtureHome().appendingPathComponent("pipeline", isDirectory: true)
        #expect(DataRootResolver.dataRoot(of: studio) == studio.standardizedFileURL)
    }

    @Test("a directory without a marker resolves to nil")
    func noMarkerIsNil() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexgen-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(DataRootResolver.dataRoot(of: tmp) == nil)
    }

    @Test("a flat legacy project resolves to itself")
    func flatLegacyResolvesToSelf() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexgen-flat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let marker = tmp.appendingPathComponent(DataRootResolver.projectMarker)
        try "project: legacy-flat\nmode: beat\n".write(to: marker, atomically: true, encoding: .utf8)

        let root = try #require(DataRootResolver.dataRoot(of: tmp))
        #expect(root.standardizedFileURL == tmp.standardizedFileURL)
    }

    @Test("a project.yaml missing the mandatory fields is not a valid marker")
    func incompleteMarkerRejected() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexgen-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // `project` present but `mode` missing → falsy, per _is_project_marker.
        let marker = tmp.appendingPathComponent(DataRootResolver.projectMarker)
        try "project: no-mode\n".write(to: marker, atomically: true, encoding: .utf8)
        #expect(DataRootResolver.dataRoot(of: tmp) == nil)
    }
}
