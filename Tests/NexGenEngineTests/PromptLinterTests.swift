import Foundation
import Testing
@testable import NexGenEngine

/// Native Swift ports of the linter/compliance/ledger test cases from
/// engine/tests/test_prompt.py + test_ledger_prompt.py. These assert behavior
/// (codes/severities) rather than byte-exact strings — the byte-exact bar is
/// PromptGoldenTests.
@Suite("PromptLinter")
struct PromptLinterTests {
    // MARK: - builder / dispatcher (test_prompt.py)

    @Test("build_image_prompt strips slop and frames negatives positively")
    func buildImageStripsSlopFramesPositively() throws {
        let payload = PromptPayload(
            subject: "a weathered detective standing in a doorway, arrested mid-step",
            setting: "a dim office, blinds half-drawn",
            camera: "static eye-level camera",
            style: "muted noir illustration",
            light: "warm morning light from the left, long soft shadow",
            negatives: ["no text"]
        )
        let out = try PromptGenerator.buildImagePrompt(modelID: "openai:gpt-image-2", payload: payload)
        #expect(!out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(out.contains("clean untyped surfaces"))
        #expect(!out.lowercased().contains("no text"))
    }

    @Test("build_video_prompt emits reference tags and total")
    func buildVideoEmitsReferenceTags() throws {
        let payload = PromptPayload(
            subject: "@Image1 waves while the camera holds",
            light: "soft overcast daylight",
            durationS: 6.0,
            aspectRatio: "16:9"
        )
        let out = PromptGenerator.buildVideoPrompt(
            modelID: "runway:seedance-2", payload: payload,
            referenceTags: [ReferenceTag(role: "character", bibleId: "hero", hint: "the hero")]
        )
        #expect(out.contains("@Image1"))
        #expect(out.contains("Total: 6s"))
    }

    // MARK: - lint_prompt (test_prompt.py)

    @Test("lint_prompt flags a short prompt as blocking")
    func lintFlagsShortPrompt() {
        let findings = PromptLinter.lintPrompt("tiny")
        #expect(PromptLinter.hasBlocking(findings))
        #expect(findings.contains { $0.code == "PROMPT_TOO_SHORT" })
    }

    @Test("lint_prompt is clean on a well-formed prompt")
    func lintCleanOnWellFormed() {
        let good = "a weathered detective standing in a doorway. a dim office, blinds "
            + "half-drawn. static eye-level camera. warm morning light from the "
            + "left, long soft shadow. muted noir illustration."
        let findings = PromptLinter.lintPrompt(good)
        #expect(!PromptLinter.hasBlocking(findings))
    }

    // MARK: - content_block_linter (test_prompt.py)

    @Test("content-block linter flags a violence token")
    func contentBlockFlagsViolence() {
        let findings = ContentBlockLinter.lintProviderPrompt("a figure draws a gun in the alley")
        #expect(findings.contains { $0.code == "BLOCKING_RISK_VIOLENCE" })
    }

    @Test("multi-character block check reads duck-typed shot fields")
    func multiCharBlockDuckTyped() {
        let findings = ContentBlockLinter.lintShotForMultiCharacterBlock(
            characterRefs: ["hero", "rival"], framing: "ms", visualMedium: "2d_animation"
        )
        #expect(findings.contains { $0.code == "BLOCKING_RISK_MULTI_CHARACTER" })
    }

    // MARK: - compliance_linter (test_prompt.py)

    @Test("compliance linter detects a camera-height mismatch")
    func complianceCameraHeightMismatch() {
        let shot = ComplianceLinter.ShotSpec(
            framing: "ms", cameraHeight: "eye_level", blockingGazes: [], notes: ""
        )
        let findings = ComplianceLinter.lintPromptAgainstShot("aerial view of the rooftop", shot)
        #expect(findings.contains { $0.code == "CAMERA_HEIGHT_MISMATCH" })
    }

    // MARK: - ledger → prompt (test_ledger_prompt.py)

    /// Port of `test_ledger_prompt.py::_ledger()`.
    private static func makeLedger() -> Ledger {
        var led = Ledger()
        led.objects = [
            "film": ["palette": Attribute(tag: "Muted teal-and-rust palette")],
            "look": ["grain": Attribute(tag: "Heavy 16mm grain", locked: true)],
            "character:mara": [
                "wardrobe": Attribute(
                    tag: "Red jacket",
                    directive: "Mara wears her faded red canvas jacket",
                    locked: true
                )
            ],
            "shot:s001": ["pace": Attribute(tag: "Slow, deliberate movement")],
            "prop:dagger": ["state": Attribute(tag: "The dagger stays sheathed")],
        ]
        return led
    }

    /// Port of `_shot()`.
    private static func makeShotRefs(
        id: String = "s001", characterRefs: [String] = ["mara"],
        locationRef: String? = nil, propRefs: [String] = ["dagger"]
    ) -> LedgerDirectives.ShotRefs {
        LedgerDirectives.ShotRefs(
            id: id, characterRefs: characterRefs, locationRef: locationRef, propRefs: propRefs
        )
    }

    @Test("directives collect broad→specific and mark the locked subset")
    func collectsBroadToSpecificAndMarksLocked() {
        let result = LedgerDirectives.directivesForShot(ledger: Self.makeLedger(), shot: Self.makeShotRefs())
        #expect(result.directives == [
            "Muted teal-and-rust palette",
            "Heavy 16mm grain",
            "Mara wears her faded red canvas jacket",
            "The dagger stays sheathed",
            "Slow, deliberate movement",
        ])
        #expect(result.locked == [
            "Heavy 16mm grain",
            "Mara wears her faded red canvas jacket",
        ])
    }

    @Test("unknown refs contribute nothing")
    func unknownRefsContributeNothing() {
        let result = LedgerDirectives.directivesForShot(
            ledger: Self.makeLedger(),
            shot: Self.makeShotRefs(id: "s999", characterRefs: ["ghost"], propRefs: [])
        )
        #expect(result.directives == ["Muted teal-and-rust palette", "Heavy 16mm grain"])
    }

    @Test("builders carry directives and the locked-directive lint passes")
    func buildersCarryDirectivesLintPasses() throws {
        let result = LedgerDirectives.directivesForShot(ledger: Self.makeLedger(), shot: Self.makeShotRefs())
        let payload = PromptPayload(subject: "Mara stands at the rooftop edge", directives: result.directives)
        let prompt = try ImageBuilders.nanoBanana(payload)
        #expect(prompt.contains("faded red canvas jacket"))
        #expect(prompt.contains("16mm grain"))
        #expect(ComplianceLinter.lintLockedDirectives(prompt, lockedDirectives: result.locked).isEmpty)
    }

    @Test("lint flags a missing locked directive as error")
    func lintFlagsMissingLockedDirective() throws {
        let prompt = try ImageBuilders.nanoBanana(PromptPayload(subject: "Mara stands at the rooftop edge"))
        let findings = ComplianceLinter.lintLockedDirectives(
            prompt, lockedDirectives: ["Mara wears her faded red canvas jacket"]
        )
        #expect(findings.count == 1)
        #expect(findings[0].severity == "error")
        #expect(findings[0].code == "LOCKED_DIRECTIVE_MISSING")
    }
}
