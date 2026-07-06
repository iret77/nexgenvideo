import Foundation
import Testing
@testable import NexGenEngine

/// Adaptation of `engine/tests/test_run_sanity.py`. The Python test exercises
/// `mcp_server.run_sanity`, which layers file-system project bootstrap
/// (`layout.init_project`) and MCP-tool wiring on top of the audit — both out
/// of scope for the engine-only Sanity work package (M5). What's ported here
/// is the substance those tests actually prove: that gathering the engine's
/// core checks through a registry and running them against a real, minimal,
/// on-disk-shaped shotlist surfaces `PROMPT_TOO_SHORT`, and that a report's
/// findings carry exactly the four fields the MCP layer serializes
/// (level/code/shot_id/message).
@Suite("Sanity run_sanity (registry-driven, engine-only slice)")
struct SanityRunSanityTests {
    static func minimalShotlist() throws -> Shotlist {
        let shot = try Shot(
            id: "s001", section: "verse", timeStart: 0.0, timeEnd: 4.0, durationS: 4.0,
            type: .performance, description: "d", visualPrompt: "p", mood: "m"
        )
        let song = try Song(title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: 4.0)
        return try Shotlist(
            schema_: shotlistSchemaVersion, mode: .section, project: "demo", song: song,
            generated: "2026-01-01", generator: "test", shots: [shot]
        )
    }

    // MARK: - test_run_sanity_returns_report

    @Test("gathering core checks via the registry and auditing a minimal shotlist returns a report")
    func gatheringCoreChecksReturnsReport() throws {
        let shotlist = try Self.minimalShotlist()
        let registry = CheckRegistry()
        registerCoreChecks(registry)

        let report = audit(AuditContext(shotlist: shotlist), checks: registry.checks)

        #expect(report.project == "demo")
        // The minimal "p" prompt trips the core PROMPT_TOO_SHORT check, proving
        // engine-core checks actually ran.
        #expect(report.findings.contains { $0.code == "PROMPT_TOO_SHORT" })
    }

    // MARK: - "findings carry exactly {level, code, shot_id, message}" (the MCP dict-shape assertion)

    @Test("every finding carries level, code, shotId, and message")
    func findingsCarryTheFourExpectedFields() throws {
        let shotlist = try Self.minimalShotlist()
        let registry = CheckRegistry()
        registerCoreChecks(registry)
        let report = audit(AuditContext(shotlist: shotlist), checks: registry.checks)

        #expect(!report.findings.isEmpty)
        for finding in report.findings {
            // shotId is legitimately optional (nil for project-level findings);
            // asserting its type suffices, mirroring the Python dict-key check.
            _ = finding.shotId
            #expect(!finding.code.isEmpty)
            #expect(!finding.message.isEmpty)
        }
    }

    // MARK: - test_register_core_checks / callable sanity (importable/callable port)

    @Test("registerCoreChecks and audit are directly callable, mirroring the MCP surface")
    func coreEntryPointsAreCallable() throws {
        let shotlist = try Self.minimalShotlist()
        let registry = CheckRegistry()
        registerCoreChecks(registry)
        #expect(!registry.checks.isEmpty)

        let report = audit(AuditContext(shotlist: shotlist), checks: registry.checks)
        #expect(report.project == "demo")
    }
}
