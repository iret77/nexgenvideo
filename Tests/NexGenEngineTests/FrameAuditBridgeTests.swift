import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// frame_audit_bridge — reads shot×role audit YAMLs off a temp data root and surfaces their
/// findings as `info` (blocking / minor) or a `warn` when the file is corrupt. It never hard-blocks.
@Suite("frame_audit_bridge")
struct FrameAuditBridgeTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fabridge-" + UUID().uuidString)
    }

    private func shot(_ id: String) throws -> Shot {
        try Shot(id: id, section: "verse", timeStart: 0, timeEnd: 4, durationS: 4, type: .performance,
                 description: "d", visualPrompt: "p", mood: "m")
    }

    private func shotlist(_ ids: [String]) throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "p",
            song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "t", generator: "g", shots: try ids.map { try shot($0) })
    }

    private func audit(_ id: String, role: String, overall: AuditStatus, checks: [String: AuditCheck]) throws -> FrameAudit {
        try FrameAudit(shotId: id, role: role, renderPath: "media/\(id)-\(role).png", renderSha256: "sha",
                       generated: "2026-07-13T00:00:00+00:00", auditor: "google-gemini-3-pro",
                       checks: checks, overall: overall, autoRerenderAttempt: 1)
    }

    @Test("blocking audit → info FRAME_AUDIT_ISSUES with auditor + attempts")
    func blockingInfo() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try saveFrameAudit(try audit("s001", role: "start", overall: .blocking,
            checks: ["framing": AuditCheck(status: .blocking)]), dataRoot: root)
        let ctx = AuditContext(shotlist: try shotlist(["s001"]), extra: ["data_root": root.path])
        let findings = try MusicvideoChecks.frameAuditBridgeCheck(ctx)
        let f = try #require(findings.first { $0.code == "FRAME_AUDIT_ISSUES" && $0.shotId == "s001" })
        #expect(f.level == .info)
        #expect(f.message.contains("BLOCKING"))
        #expect(f.message.contains("google-gemini-3-pro"))
        #expect(f.message.contains("Attempts=1"))
    }

    @Test("minor audit → info FRAME_AUDIT_ISSUES (MINOR)")
    func minorInfo() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try saveFrameAudit(try audit("s001", role: "start", overall: .minor,
            checks: ["gaze": AuditCheck(status: .minor)]), dataRoot: root)
        let ctx = AuditContext(shotlist: try shotlist(["s001"]), extra: ["data_root": root.path])
        let findings = try MusicvideoChecks.frameAuditBridgeCheck(ctx)
        let f = try #require(findings.first { $0.code == "FRAME_AUDIT_ISSUES" })
        #expect(f.level == .info)
        #expect(f.message.contains("MINOR"))
    }

    @Test("clean audit → no findings")
    func cleanSilent() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try saveFrameAudit(try audit("s001", role: "start", overall: .clean,
            checks: ["framing": AuditCheck(status: .clean)]), dataRoot: root)
        let ctx = AuditContext(shotlist: try shotlist(["s001"]), extra: ["data_root": root.path])
        #expect(try MusicvideoChecks.frameAuditBridgeCheck(ctx).isEmpty)
    }

    @Test("corrupt audit YAML → warn FRAME_AUDIT_LOAD_FAILED")
    func corruptWarns() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = frameAuditPath(dataRoot: root, shotId: "s001", role: "start")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "schema: frame_audit/v1\nshot_id: s001\noverall: bogus_status\n".write(to: url, atomically: true, encoding: .utf8)
        let ctx = AuditContext(shotlist: try shotlist(["s001"]), extra: ["data_root": root.path])
        let findings = try MusicvideoChecks.frameAuditBridgeCheck(ctx)
        let f = try #require(findings.first { $0.code == "FRAME_AUDIT_LOAD_FAILED" })
        #expect(f.level == .warn)
        #expect(f.message.contains("save_frame_audit"))
    }

    @Test("absent audits and missing data_root → no findings")
    func absentSilent() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let ctx = AuditContext(shotlist: try shotlist(["s001"]), extra: ["data_root": root.path])
        #expect(try MusicvideoChecks.frameAuditBridgeCheck(ctx).isEmpty)
        // No data_root at all → degrade to empty.
        let ctx2 = AuditContext(shotlist: try shotlist(["s001"]))
        #expect(try MusicvideoChecks.frameAuditBridgeCheck(ctx2).isEmpty)
    }
}
