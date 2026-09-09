import Foundation
import Testing
@testable import NexGenEngine

@Suite("Explicit frame deviation acceptance")
struct FrameAuditAcceptanceTests {
    @Test("acceptance requires a reason and expires on image or audit changes")
    func exactEvidence() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "review")
        let image = root.appendingPathComponent("frames/one.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("image bytes".utf8).write(to: image)
        var audit = try FrameAudit(shotId: "s001", renderPath: "frames/one.png", renderSha256: FileDigest.sha256(of: image),
            generated: "fixture", auditor: "fixture", checks: ["framing": AuditCheck(status: .minor,
                expected: "wide", observed: "medium-wide", note: "Slightly tighter")], overall: .minor)
        try saveFrameAudit(audit, dataRoot: root)
        let snapshot = try FrameAuditAcceptanceStoreV1.snapshot(audit: audit, dataRoot: root)
        #expect(throws: (any Error).self) { try FrameAuditAcceptanceStoreV1.requireResolved(audit: audit, dataRoot: root) }
        #expect(throws: (any Error).self) { try FrameAuditAcceptanceStoreV1.accept(audit: audit, expectedSnapshot: snapshot, reason: " ", dataRoot: root) }
        try FrameAuditAcceptanceStoreV1.accept(audit: audit, expectedSnapshot: snapshot, reason: "The tighter composition preserves the intended action.", dataRoot: root)
        try FrameAuditAcceptanceStoreV1.requireResolved(audit: audit, dataRoot: root)
        let original = try Data(contentsOf: image)
        try Data("changed image".utf8).write(to: image)
        #expect(throws: (any Error).self) { try FrameAuditAcceptanceStoreV1.requireResolved(audit: audit, dataRoot: root) }
        try original.write(to: image)
        audit.checks["framing"]?.observed = "subject partly outside frame"
        try saveFrameAudit(audit, dataRoot: root)
        #expect(throws: (any Error).self) { try FrameAuditAcceptanceStoreV1.requireResolved(audit: audit, dataRoot: root) }
        #expect(throws: (any Error).self) { try FrameAuditAcceptanceStoreV1.accept(audit: audit, expectedSnapshot: snapshot, reason: "Old review", dataRoot: root) }
    }
}
