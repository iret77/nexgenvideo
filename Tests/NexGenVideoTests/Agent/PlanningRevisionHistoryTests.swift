import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Production revision history rejects malformed and sparse names")
struct PlanningRevisionHistoryTests {
    @Test(arguments: ["v0.v1.json", "v-3.v1.json", "v+1.v1.json", "v01.v1.json", "v.v1.json",
        "v9999999999.v1.json", "v9223372036854775807.v1.json", "v9999999999999999999999.v1.json",
        "v１.v1.json", "v2.v1.json"])
    func invalidHistoryFailsWithoutConstructingARevisionRange(_ filename: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("script")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: directory.appendingPathComponent(filename))
        #expect(throws: GateBlocked.self) {
            try PlanningWriterIO.nextRevision(directory: "script", suffix: ".v1.json", dataRoot: root)
        }
    }

    @Test func contiguousHistoryAndUnrelatedFilesKeepTheNextRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("script")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try PlanningWriterIO.nextRevision(directory: "script", suffix: ".v1.json", dataRoot: root) == 1)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["current.v1.json", "promotion-v1.v1.json"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        #expect(try PlanningWriterIO.nextRevision(directory: "script", suffix: ".v1.json", dataRoot: root) == 1)
        for revision in (1...12).reversed() {
            try Data().write(to: directory.appendingPathComponent("v\(revision).v1.json"))
        }
        #expect(try PlanningWriterIO.nextRevision(directory: "script", suffix: ".v1.json", dataRoot: root) == 13)
        #expect(try PlanningWriterIO.nextRevision(directory: "script", prefix: "promotion-v", suffix: ".v1.json", dataRoot: root) == 2)
    }
}
