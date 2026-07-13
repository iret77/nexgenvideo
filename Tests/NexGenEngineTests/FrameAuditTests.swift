import Foundation
import Testing
@testable import NexGenEngine

@Suite("FrameAudit")
struct FrameAuditTests {
    private func make(
        overall: AuditStatus, checks: [String: AuditCheck] = [:],
        attempt: Int = 0, role: String = "start", schema: String = frameAuditSchemaVersion
    ) throws -> FrameAudit {
        try FrameAudit(
            schema: schema, shotId: "s001", role: role, renderPath: "media/s001-start.png",
            renderSha256: "abc", generated: "2026-07-13T00:00:00+00:00", auditor: "orchestrator-claude",
            checks: checks, overall: overall, autoRerenderAttempt: attempt)
    }

    // MARK: - Validators

    @Test("clean overall with a blocking check is rejected")
    func blockingCheckNeedsBlockingOverall() {
        #expect(throws: FrameAudit.ValidationError.blockingCheckOverallNotBlocking(overall: "clean")) {
            _ = try make(overall: .clean, checks: ["framing": AuditCheck(status: .blocking)])
        }
    }

    @Test("overall=pending is not a valid end state")
    func overallPendingRejected() {
        #expect(throws: FrameAudit.ValidationError.overallPending) {
            _ = try make(overall: .pending)
        }
    }

    @Test("any check=pending is rejected")
    func checkPendingRejected() {
        #expect(throws: FrameAudit.ValidationError.checkPending) {
            _ = try make(overall: .clean, checks: ["gaze": AuditCheck(status: .pending)])
        }
    }

    @Test("minor check without blocking demands overall minor (or blocking)")
    func minorNeedsMinorOverall() {
        #expect(throws: FrameAudit.ValidationError.minorCheckOverallNotMinor(overall: "clean")) {
            _ = try make(overall: .clean, checks: ["gaze": AuditCheck(status: .minor)])
        }
        // overall=blocking is allowed to carry a minor check (blocking dominates).
        #expect(throws: Never.self) {
            _ = try make(overall: .blocking, checks: [
                "gaze": AuditCheck(status: .minor), "framing": AuditCheck(status: .blocking),
            ])
        }
    }

    @Test("negative attempt is rejected")
    func negativeAttemptRejected() {
        #expect(throws: FrameAudit.ValidationError.attemptNegative) {
            _ = try make(overall: .clean, attempt: -1)
        }
    }

    @Test("unknown schema is rejected")
    func unknownSchemaRejected() {
        #expect(throws: FrameAudit.ValidationError.schemaUnknown("frame_audit/v2")) {
            _ = try make(overall: .clean, schema: "frame_audit/v2")
        }
    }

    @Test("unknown role is rejected")
    func unknownRoleRejected() {
        #expect(throws: FrameAudit.ValidationError.roleUnknown("middle")) {
            _ = try make(overall: .clean, role: "middle")
        }
    }

    // MARK: - YAML round-trip

    @Test("round-trips YAML with the n/a rawValue and snake_case keys")
    func yamlRoundTrip() throws {
        let audit = try make(overall: .minor, checks: [
            "character_count": AuditCheck(status: .notApplicable, expected: "", observed: "", note: "figure-free"),
            "framing": AuditCheck(status: .clean, expected: "ms", observed: "ms"),
            "gaze": AuditCheck(status: .minor, expected: "away", observed: "3/4 toward", note: "close enough"),
        ])
        let yaml = try YAMLCoding.encode(audit)
        #expect(yaml.contains("render_sha256"))
        #expect(yaml.contains("n/a"))
        let back = try YAMLCoding.decode(FrameAudit.self, from: yaml)
        #expect(back == audit)
        #expect(back.checks["character_count"]?.status == .notApplicable)
    }

    @Test("load returns nil when the audit file is absent, round-trips on disk otherwise")
    func loadSaveDisk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("frameaudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try loadFrameAudit(dataRoot: root, shotId: "s001") == nil)
        let audit = try make(overall: .clean, checks: ["framing": AuditCheck(status: .clean)])
        try saveFrameAudit(audit, dataRoot: root)
        let loaded = try loadFrameAudit(dataRoot: root, shotId: "s001")
        #expect(loaded == audit)
    }

    // MARK: - Routing table

    @Test("routing verdict for clean/minor/blocking across attempts 0/1/2")
    func routingTable() throws {
        // clean, no minor → APPROVE at any attempt.
        let clean = try make(overall: .clean, checks: ["framing": AuditCheck(status: .clean)])
        #expect(clean.verdict == .approve)
        #expect(!clean.needsRerender && !clean.needsUserDecision)

        // minor → USER_DECIDES, never re-render.
        let minor = try make(overall: .minor, checks: ["gaze": AuditCheck(status: .minor)])
        #expect(minor.verdict == .userDecides)
        #expect(!minor.needsRerender)

        // blocking with budget → RERENDER; budget exhausted → USER_DECIDES.
        for attempt in 0...2 {
            let blocking = try make(
                overall: .blocking, checks: ["framing": AuditCheck(status: .blocking)], attempt: attempt)
            #expect(blocking.hasBlocking)
            if attempt < maxAutoRerenderAttempts {
                #expect(blocking.verdict == .rerender)
                #expect(blocking.attemptsLeft == maxAutoRerenderAttempts - attempt)
            } else {
                #expect(blocking.verdict == .userDecides)
                #expect(blocking.attemptsLeft == 0)
            }
        }
    }
}
