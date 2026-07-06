import Foundation
import Testing
@testable import NexGenEngine

/// Port of `engine/tests/test_audit.py`.
@Suite("Sanity Audit")
struct SanityAuditTests {
    // MARK: - Helpers (port of test_audit.py's _shot / _shotlist / _registry_with_core)

    static let goodPrompt =
        "Alex stands center frame at the bar, pouring a drink, warm tungsten light "
        + "from the left, medium shot, calm reflective mood at dusk."

    static func shot(
        idx: Int, start: Double, end: Double, prompt: String, section: String = "verse"
    ) throws -> Shot {
        try Shot(
            id: String(format: "s%03d", idx), section: section, timeStart: start, timeEnd: end,
            durationS: end - start, type: .performance, description: "d", visualPrompt: prompt, mood: "m"
        )
    }

    static func shotlist(_ shots: [Shot], mode: Mode = .section, durationS: Double = 8.0) throws -> Shotlist {
        let song = try Song(
            title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: durationS
        )
        return try Shotlist(
            schema_: shotlistSchemaVersion, mode: mode, project: "proj", song: song,
            generated: "2026-01-01", generator: "test", shots: shots
        )
    }

    static func registryWithCore() -> CheckRegistry {
        let registry = CheckRegistry()
        registerCoreChecks(registry)
        return registry
    }

    // MARK: - test_register_core_checks_populates_registry

    @Test("registerCoreChecks populates the registry")
    func registerCoreChecksPopulatesRegistry() {
        let registry = Self.registryWithCore()
        let names = Set(registry.checks.keys)
        #expect(Set(["coverage", "mode_match", "prompt_quality"]).isSubset(of: names))
    }

    // MARK: - test_audit_returns_report_clean_for_a_well_formed_project

    @Test("audit returns a clean report for a well-formed project")
    func auditReturnsCleanReportForWellFormedProject() throws {
        // Two back-to-back shots tiling [0,8], good prompts, no brief mismatch.
        let shotlist = try Self.shotlist([
            try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: Self.goodPrompt),
            try Self.shot(idx: 2, start: 4.0, end: 8.0, prompt: Self.goodPrompt),
        ])
        let registry = Self.registryWithCore()
        let report = audit(AuditContext(shotlist: shotlist), checks: registry.checks)

        #expect(report.project == "proj")
        #expect(report.isClean == true)
        #expect(report.errors.isEmpty)
    }

    // MARK: - test_audit_flags_short_prompt_and_uncovered_tail

    @Test("audit flags a short prompt and an uncovered tail")
    func auditFlagsShortPromptAndUncoveredTail() throws {
        // One short prompt (-> PROMPT_TOO_SHORT error) and a tail gap (shot ends
        // at 4s but timeline runs to 8s -> UNCOVERED_TAIL info).
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: "too short")], durationS: 8.0
        )
        let registry = Self.registryWithCore()
        let report = audit(AuditContext(shotlist: shotlist), checks: registry.checks)

        let codes = Set(report.findings.map(\.code))
        #expect(codes.contains("PROMPT_TOO_SHORT"))
        #expect(codes.contains("UNCOVERED_TAIL"))
        #expect(report.isClean == false)  // the short-prompt finding is an error
    }

    // MARK: - test_audit_flags_mode_mismatch_against_brief

    @Test("audit flags a mode mismatch against the brief")
    func auditFlagsModeMismatchAgainstBrief() throws {
        let shotlist = try Self.shotlist(
            [
                try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: Self.goodPrompt),
                try Self.shot(idx: 2, start: 4.0, end: 8.0, prompt: Self.goodPrompt),
            ], mode: .section
        )
        let brief = try Brief(
            project: "proj", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "beat", conceptType: .abstract,
            visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored
        )
        let registry = Self.registryWithCore()
        let report = audit(AuditContext(shotlist: shotlist, brief: brief), checks: registry.checks)

        #expect(report.errors.contains { $0.code == "MODE_MISMATCH" })
    }

    // MARK: - test_audit_isolates_a_raising_check

    struct BoomError: Error {}

    @Test("audit isolates a raising check as AUDIT_CHECK_FAILED")
    func auditIsolatesARaisingCheck() throws {
        let registry = Self.registryWithCore()
        registry.register("boom") { _ in throw BoomError() }
        let shotlist = try Self.shotlist([try Self.shot(idx: 1, start: 0.0, end: 8.0, prompt: Self.goodPrompt)])
        let report = audit(AuditContext(shotlist: shotlist), checks: registry.checks)

        let failed = report.errors.filter { $0.code == "AUDIT_CHECK_FAILED" }
        #expect(failed.count == 1)
        #expect(failed.first?.message.contains("boom") == true)
    }

    // MARK: - test_audit_runs_on_empty_registry

    @Test("audit runs cleanly on an empty registry")
    func auditRunsOnEmptyRegistry() throws {
        let shotlist = try Self.shotlist([try Self.shot(idx: 1, start: 0.0, end: 8.0, prompt: Self.goodPrompt)])
        let report = audit(AuditContext(shotlist: shotlist), checks: [:])
        #expect(report.findings.isEmpty)
        #expect(report.isClean == true)
    }
}
