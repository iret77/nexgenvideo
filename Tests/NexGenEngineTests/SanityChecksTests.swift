import Foundation
import Testing
@testable import NexGenEngine

/// Focused unit coverage per check, verifying the exact codes/levels/message
/// shapes ported from `sanity/checks/coverage.py`, `mode_match.py`, and
/// `prompt_quality.py`. `test_audit.py` only exercises these checks in
/// combination; these tests isolate each one's boundary conditions.
@Suite("Sanity Checks")
struct SanityChecksTests {
    static let goodPrompt =
        "Alex stands center frame at the bar, pouring a drink, warm tungsten light "
        + "from the left, medium shot, calm reflective mood at dusk."

    static func shot(
        idx: Int, start: Double, end: Double, prompt: String = SanityChecksTests.goodPrompt,
        section: String? = "verse", cameraId: String? = nil, cameraLabel: String? = nil
    ) throws -> Shot {
        try Shot(
            id: String(format: "s%03d", idx), section: section, timeStart: start, timeEnd: end,
            durationS: end - start, type: .performance, description: "d", visualPrompt: prompt, mood: "m",
            cameraId: cameraId, cameraLabel: cameraLabel
        )
    }

    static func shotlist(_ shots: [Shot], mode: Mode = .section, durationS: Double) throws -> Shotlist {
        let song = try Song(
            title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: durationS
        )
        return try Shotlist(
            schema_: shotlistSchemaVersion, mode: mode, project: "proj", song: song,
            generated: "2026-01-01", generator: "test", shots: shots
        )
    }

    // MARK: - coverage: UNCOVERED_GAP

    @Test("coverage flags a gap between shots as info")
    func coverageFlagsGap() throws {
        // s001 covers [0,2], s002 starts at 4 -> 2s gap > 0.5s threshold.
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 2.0), try Self.shot(idx: 2, start: 4.0, end: 6.0)],
            durationS: 6.0
        )
        let findings = try coverageCheck(AuditContext(shotlist: shotlist))
        let gap = findings.first { $0.code == "UNCOVERED_GAP" }
        #expect(gap != nil)
        #expect(gap?.level == .info)
        #expect(gap?.shotId == nil)
    }

    @Test("coverage does not flag a gap at or below the 0.5s threshold")
    func coverageToleratesSmallGap() throws {
        // s001 ends at 2.0, s002 starts at 2.5 -> exactly at the threshold, not > it.
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 2.0), try Self.shot(idx: 2, start: 2.5, end: 6.0)],
            durationS: 6.0
        )
        let findings = try coverageCheck(AuditContext(shotlist: shotlist))
        #expect(!findings.contains { $0.code == "UNCOVERED_GAP" })
    }

    // MARK: - coverage: UNCOVERED_TAIL

    @Test("coverage flags an uncovered tail as info")
    func coverageFlagsTail() throws {
        let shotlist = try Self.shotlist([try Self.shot(idx: 1, start: 0.0, end: 4.0)], durationS: 8.0)
        let findings = try coverageCheck(AuditContext(shotlist: shotlist))
        let tail = findings.first { $0.code == "UNCOVERED_TAIL" }
        #expect(tail != nil)
        #expect(tail?.level == .info)
        #expect(tail?.message.contains("8.00") == true)
    }

    // MARK: - coverage: SHOT_OVERLAP

    @Test("coverage flags overlapping shots as warn, tagged with the later shot's id")
    func coverageFlagsOverlap() throws {
        // s001 covers [0,4], s002 starts at 3.5 -> overlaps by 0.5s (> 0.01s threshold).
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0), try Self.shot(idx: 2, start: 3.5, end: 8.0)],
            durationS: 8.0
        )
        let findings = try coverageCheck(AuditContext(shotlist: shotlist))
        let overlap = findings.first { $0.code == "SHOT_OVERLAP" }
        #expect(overlap != nil)
        #expect(overlap?.level == .warn)
        #expect(overlap?.shotId == "s002")
        #expect(overlap?.message.contains("s001") == true)
    }

    // MARK: - coverage: mode guard (only BEAT/SECTION)

    @Test("coverage is a no-op outside beat/section modes", arguments: [Mode.multicam, Mode.phrase])
    func coverageSkipsNonTimelineModes(_ mode: Mode) throws {
        // Deliberately gappy/overlapping shots that would trip findings under
        // beat/section, but must be silently skipped under multicam/phrase.
        let shots: [Shot]
        if mode == .multicam {
            shots = [
                try Self.shot(idx: 1, start: 0.0, end: 8.0, section: nil, cameraId: "cam01"),
            ]
        } else {
            shots = [try Self.shot(idx: 1, start: 0.0, end: 2.0, section: nil)]
        }
        let shotlist = try Self.shotlist(shots, mode: mode, durationS: 8.0)
        let findings = try coverageCheck(AuditContext(shotlist: shotlist))
        #expect(findings.isEmpty)
    }

    @Test("coverage runs under beat mode")
    func coverageRunsUnderBeatMode() throws {
        let shotlist = try Self.shotlist([try Self.shot(idx: 1, start: 0.0, end: 4.0)], mode: .beat, durationS: 8.0)
        let findings = try coverageCheck(AuditContext(shotlist: shotlist))
        #expect(findings.contains { $0.code == "UNCOVERED_TAIL" })
    }

    // MARK: - mode_match: MODE_MISMATCH

    @Test("mode_match is a no-op when there is no brief")
    func modeMatchNoOpWithoutBrief() throws {
        let shotlist = try Self.shotlist([try Self.shot(idx: 1, start: 0.0, end: 4.0)], durationS: 4.0)
        let findings = try modeMatchCheck(AuditContext(shotlist: shotlist))
        #expect(findings.isEmpty)
    }

    @Test("mode_match is a no-op when brief.projectMode matches the shotlist mode")
    func modeMatchNoOpWhenMatching() throws {
        let shotlist = try Self.shotlist([try Self.shot(idx: 1, start: 0.0, end: 4.0)], mode: .section, durationS: 4.0)
        let brief = try Brief(
            project: "proj", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "section", conceptType: .abstract,
            visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored
        )
        let findings = try modeMatchCheck(AuditContext(shotlist: shotlist, brief: brief))
        #expect(findings.isEmpty)
    }

    @Test("mode_match flags MODE_MISMATCH as error with no shotId, exact message shape")
    func modeMatchFlagsMismatch() throws {
        let shotlist = try Self.shotlist([try Self.shot(idx: 1, start: 0.0, end: 4.0)], mode: .section, durationS: 4.0)
        let brief = try Brief(
            project: "proj", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "beat", conceptType: .abstract,
            visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored
        )
        let findings = try modeMatchCheck(AuditContext(shotlist: shotlist, brief: brief))
        #expect(findings.count == 1)
        #expect(findings[0].level == .error)
        #expect(findings[0].code == "MODE_MISMATCH")
        #expect(findings[0].shotId == nil)
        #expect(findings[0].message == "shotlist mode=section, brief project_mode=beat")
    }

    // MARK: - prompt_quality: length thresholds

    @Test("prompt_quality flags prompts under 60 chars as PROMPT_TOO_SHORT error")
    func promptQualityFlagsTooShort() throws {
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: "too short")], durationS: 4.0
        )
        let findings = try promptQualityCheck(AuditContext(shotlist: shotlist))
        #expect(findings.count == 1)
        #expect(findings[0].level == .error)
        #expect(findings[0].code == "PROMPT_TOO_SHORT")
        #expect(findings[0].shotId == "s001")
    }

    @Test("prompt_quality flags prompts between 60 and 119 chars as PROMPT_THIN warn")
    func promptQualityFlagsThin() throws {
        // Exactly 90 chars: long enough to clear PROMPT_TOO_SHORT (<60), short of PROMPT_THIN's 120 boundary.
        let prompt = String(repeating: "a", count: 90)
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: prompt)], durationS: 4.0
        )
        let findings = try promptQualityCheck(AuditContext(shotlist: shotlist))
        #expect(findings.count == 1)
        #expect(findings[0].level == .warn)
        #expect(findings[0].code == "PROMPT_THIN")
    }

    @Test("prompt_quality does not flag length issues at or above 120 chars")
    func promptQualityCleanAtThinBoundary() throws {
        let prompt = String(repeating: "a", count: 120)
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: prompt)], durationS: 4.0
        )
        let findings = try promptQualityCheck(AuditContext(shotlist: shotlist))
        #expect(!findings.contains { $0.code == "PROMPT_TOO_SHORT" })
        #expect(!findings.contains { $0.code == "PROMPT_THIN" })
    }

    // MARK: - prompt_quality: PROMPT_GENERIC token list + length gate

    @Test("prompt_quality flags a generic token under 200 chars as PROMPT_GENERIC warn")
    func promptQualityFlagsGeneric() throws {
        // 120+ chars so it clears PROMPT_THIN, contains "epic", stays under 200.
        let prompt = "An epic wide shot of the hero standing tall against a dramatic sky, "
            + "camera slowly pushing in, golden hour light."
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: prompt)], durationS: 4.0
        )
        let findings = try promptQualityCheck(AuditContext(shotlist: shotlist))
        #expect(findings.contains { $0.code == "PROMPT_GENERIC" && $0.level == .warn })
    }

    @Test("prompt_quality does not flag PROMPT_GENERIC once the prompt reaches 200 chars")
    func promptQualityGenericLengthGate() throws {
        let prompt = "An epic wide shot. " + String(repeating: "b", count: 190)
        #expect(prompt.count >= 200)
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: prompt)], durationS: 4.0
        )
        let findings = try promptQualityCheck(AuditContext(shotlist: shotlist))
        #expect(!findings.contains { $0.code == "PROMPT_GENERIC" })
    }

    @Test("prompt_quality recognizes the exact generic token list", arguments: ["epic", "cinematic masterpiece"])
    func promptQualityGenericTokenList(_ token: String) throws {
        let prompt = "A \(token) scene unfolds slowly, camera drifting across the room in soft light."
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: prompt)], durationS: 4.0
        )
        let findings = try promptQualityCheck(AuditContext(shotlist: shotlist))
        #expect(findings.contains { $0.code == "PROMPT_GENERIC" })
    }

    @Test("prompt_quality does not flag PROMPT_GENERIC for tokens outside the exact list")
    func promptQualityGenericTokenListIsExact() throws {
        // "cinematic" alone (without "masterpiece") is not in the token list.
        let prompt = "A cinematic scene unfolds slowly, camera drifting across the room in soft light."
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: prompt)], durationS: 4.0
        )
        let findings = try promptQualityCheck(AuditContext(shotlist: shotlist))
        #expect(!findings.contains { $0.code == "PROMPT_GENERIC" })
    }

    // MARK: - prompt_quality: trims whitespace before measuring length

    @Test("prompt_quality measures the trimmed prompt length")
    func promptQualityTrimsWhitespace() throws {
        let padded = "  " + String(repeating: "a", count: 50) + "  "
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0, prompt: padded)], durationS: 4.0
        )
        let findings = try promptQualityCheck(AuditContext(shotlist: shotlist))
        // Trimmed length is 50 (< 60) -> PROMPT_TOO_SHORT, not PROMPT_THIN.
        #expect(findings.contains { $0.code == "PROMPT_TOO_SHORT" })
    }

    // MARK: - source_mode_coverage (hybrid production, issue #129)

    static func shotWithMode(idx: Int, mode: SourceMode) throws -> Shot {
        let end = Double(idx) * 4.0
        return try Shot(
            id: String(format: "s%03d", idx), section: "verse", timeStart: end - 4.0, timeEnd: end,
            durationS: 4.0, type: .performance, sourceMode: mode, description: "d",
            visualPrompt: goodPrompt, mood: "m"
        )
    }

    @Test("source_mode_coverage is silent for an all-generated shotlist")
    func sourceModeCoverageSilentWhenAllGenerated() throws {
        let shotlist = try Self.shotlist(
            [try Self.shot(idx: 1, start: 0.0, end: 4.0), try Self.shot(idx: 2, start: 4.0, end: 8.0)],
            durationS: 8.0
        )
        let findings = try sourceModeCoverageCheck(AuditContext(shotlist: shotlist))
        #expect(findings.isEmpty)
    }

    @Test("source_mode_coverage reports counts and flags live/enhanced shots as info")
    func sourceModeCoverageReportsHybrid() throws {
        let shotlist = try Self.shotlist(
            [
                try Self.shotWithMode(idx: 1, mode: .generated),
                try Self.shotWithMode(idx: 2, mode: .imported),
                try Self.shotWithMode(idx: 3, mode: .aiEnhanced),
            ],
            durationS: 12.0
        )
        let findings = try sourceModeCoverageCheck(AuditContext(shotlist: shotlist))

        let coverage = try #require(findings.first { $0.code == "SOURCE_MODE_COVERAGE" })
        #expect(coverage.level == .info)
        #expect(coverage.shotId == nil)
        #expect(coverage.message.contains("generated: 1"))
        #expect(coverage.message.contains("imported: 1"))
        #expect(coverage.message.contains("ai_enhanced: 1"))

        // Exactly the live + enhanced shots are flagged as needing footage; the generated one isn't.
        let needsFootage = findings.filter { $0.code == "SOURCE_MODE_NEEDS_FOOTAGE" }
        #expect(needsFootage.map(\.shotId) == ["s002", "s003"])
        #expect(needsFootage.allSatisfy { $0.level == .info })
    }

    @Test("source_mode_coverage is registered as a core check")
    func sourceModeCoverageIsCore() {
        #expect(coreChecks["source_mode_coverage"] != nil)
    }
}
