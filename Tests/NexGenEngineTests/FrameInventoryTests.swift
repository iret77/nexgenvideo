import Foundation
import Testing
@testable import NexGenEngine

@Suite("FrameInventory")
struct FrameInventoryTests {
    /// A throwaway v2-layout project home with a `pipeline/frames/` tree built
    /// to order, so each test controls exactly which shots/images/audits exist.
    static func makeProject() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexgen-frame-inventory-\(UUID().uuidString)", isDirectory: true)
        let studio = home.appendingPathComponent("pipeline", isDirectory: true)
        try FileManager.default.createDirectory(at: studio, withIntermediateDirectories: true)
        try "project: inventory-fixture\nmode: beat\n".write(
            to: studio.appendingPathComponent("project.yaml"), atomically: true, encoding: .utf8
        )
        return home
    }

    @Test("empty frames dir yields no shots")
    func emptyFramesDirYieldsNoShots() throws {
        let home = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: home) }
        let framesDir = home.appendingPathComponent("pipeline/frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        let result = try FrameInventory.inventory(projectDir: home)
        #expect(result.project == "inventory-fixture")
        #expect(result.shots.isEmpty)
    }

    @Test("missing frames dir yields no shots (not an error)")
    func missingFramesDirYieldsNoShots() throws {
        let home = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: home) }

        let result = try FrameInventory.inventory(projectDir: home)
        #expect(result.shots.isEmpty)
    }

    @Test("lists image candidates sorted by name, relative to the project home")
    func listsImageCandidatesSortedByName() throws {
        let home = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: home) }
        let shotDir = home.appendingPathComponent("pipeline/frames/shot-02", isDirectory: true)
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        for name in ["b.png", "a.png", "c.txt", "d.webp"] {
            try Data().write(to: shotDir.appendingPathComponent(name))
        }

        let result = try FrameInventory.inventory(projectDir: home)
        let shot = try #require(result.shots.first)
        #expect(shot.shotId == "shot-02")
        #expect(shot.frames.map(\.name) == ["a.png", "b.png", "d.webp"])
        #expect(shot.frames[0].path == "pipeline/frames/shot-02/a.png")
        #expect(shot.audit == nil)
    }

    @Test("shots are sorted by directory name")
    func shotsSortedByDirectoryName() throws {
        let home = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: home) }
        for shotId in ["shot-b", "shot-a"] {
            let dir = home.appendingPathComponent("pipeline/frames/\(shotId)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("frame.png"))
        }

        let result = try FrameInventory.inventory(projectDir: home)
        #expect(result.shots.map(\.shotId) == ["shot-a", "shot-b"])
    }

    @Test("passes through a well-formed _frame_audit.yaml as a mapping")
    func passesThroughFrameAudit() throws {
        let home = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: home) }
        let shotDir = home.appendingPathComponent("pipeline/frames/shot-01", isDirectory: true)
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        try Data().write(to: shotDir.appendingPathComponent("frame.png"))
        try """
        schema: frame_audit/v1
        notes: looks good
        """.write(
            to: shotDir.appendingPathComponent(FrameInventory.auditFilename), atomically: true,
            encoding: .utf8
        )

        let result = try FrameInventory.inventory(projectDir: home)
        let shot = try #require(result.shots.first)
        guard case .mapping(let mapping) = try #require(shot.audit) else {
            Issue.record("expected a mapping audit")
            return
        }
        #expect(mapping["schema"] == .string("frame_audit/v1"))
        #expect(mapping["notes"] == .string("looks good"))
    }

    @Test("a shot with only a malformed audit and no images is treated as absent")
    func malformedAuditWithNoImagesIsAbsent() throws {
        let home = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: home) }
        let shotDir = home.appendingPathComponent("pipeline/frames/shot-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        try "- not\n- a\n- mapping\n".write(
            to: shotDir.appendingPathComponent(FrameInventory.auditFilename), atomically: true,
            encoding: .utf8
        )

        let result = try FrameInventory.inventory(projectDir: home)
        #expect(result.shots.isEmpty)
    }

    @Test("a shot with a valid audit but no images is still reported")
    func auditOnlyShotIsReported() throws {
        let home = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: home) }
        let shotDir = home.appendingPathComponent("pipeline/frames/shot-audit-only", isDirectory: true)
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        try "schema: frame_audit/v1\n".write(
            to: shotDir.appendingPathComponent(FrameInventory.auditFilename), atomically: true,
            encoding: .utf8
        )

        let result = try FrameInventory.inventory(projectDir: home)
        let shot = try #require(result.shots.first)
        #expect(shot.frames.isEmpty)
        #expect(shot.audit != nil)
    }

    @Test("resolving from the data root itself (not the project home) works the same")
    func resolvesFromDataRootDirectly() throws {
        let home = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: home) }
        let shotDir = home.appendingPathComponent("pipeline/frames/shot-01", isDirectory: true)
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        try Data().write(to: shotDir.appendingPathComponent("frame.png"))

        let dataRoot = home.appendingPathComponent("pipeline", isDirectory: true)
        let result = try FrameInventory.inventory(projectDir: dataRoot)
        #expect(result.shots.map(\.shotId) == ["shot-01"])
    }

    @Test("a directory without a project marker throws noProject")
    func noProjectThrows() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexgen-no-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: FrameInventory.InventoryError.self) {
            try FrameInventory.inventory(projectDir: tmp)
        }
    }
}
