import Foundation

/// Compliance linter. Port of `render/prompt/compliance_linter.py`. Checks that
/// the built provider prompt matches the shot spec via five drift heuristics,
/// plus `lint_locked_directives`.
///
/// Python duck-types `shot` with `getattr`; Swift models the read surface as a
/// small protocol so callers can pass a real `Shot` or a lightweight stand-in.
public enum ComplianceLinter {
    /// The gaze the drift check reads from `character_blocking[]`.
    public struct BlockingGaze: Sendable, Equatable {
        public let gaze: String
        public init(gaze: String) { self.gaze = gaze }
    }

    /// Read surface the compliance linter needs from a shot. Field names/values
    /// map to Python's `_enum_val(...)` normalization: framing/height are the
    /// lowercased enum raw values (or nil).
    public struct ShotSpec: Sendable, Equatable {
        public let framing: String?
        public let cameraHeight: String?
        public let blockingGazes: [String]
        public let notes: String

        public init(framing: String?, cameraHeight: String?, blockingGazes: [String], notes: String) {
            self.framing = framing
            self.cameraHeight = cameraHeight
            self.blockingGazes = blockingGazes
            self.notes = notes
        }
    }

    /// Port of `compliance_linter.py::ComplianceFinding`.
    public struct ComplianceFinding: Sendable, Equatable {
        public let severity: String
        public let code: String
        public let matched: String
        public let message: String
    }

    // Token patterns (case-insensitive, word boundaries).
    static let aerialTokens = Rx.compile(
        #"\b(aerial(?:\s+view)?|bird'?s[\s-]?eye|top[\s-]?down|drone\s+shot|overhead)\b"#,
        caseInsensitive: true
    )
    static let lowAngleTokens = Rx.compile(
        #"\b(low\s+angle|from\s+below|looking\s+up|ground[\s-]?level|worm'?s[\s-]?eye)\b"#,
        caseInsensitive: true
    )
    static let highAngleTokens = Rx.compile(
        #"\b(high\s+angle|looking\s+down|down\s+at|from\s+above)\b"#, caseInsensitive: true
    )
    static let closeUpTokens = Rx.compile(
        #"\b(close[\s-]?up|extreme\s+close[\s-]?up|tight\s+on|detail\s+of\s+(?:his|her|their)\s+(?:face|eyes|hand|hands))\b"#,
        caseInsensitive: true
    )
    static let wideTokens = Rx.compile(
        #"\b(wide\s+shot|establishing\s+shot|from\s+far\s+away|long\s+shot|full[\s-]?body\s+shot)\b"#,
        caseInsensitive: true
    )
    static let gazeTokens = Rx.compile(
        #"\b(?:looking|gazing|staring|peering|glancing)\s+(?:off\s+)?(?:toward|towards|at|into|over|across|away|down|up|out)(?:\s+\w+)?"#,
        caseInsensitive: true
    )
    static let settingTokens = Rx.compile(
        #"\b(sunset|sunrise|golden\s+hour|magic\s+hour|dusk|dawn|twilight|midnight|nighttime|night[\s-]?time|moonlit|moonlight|blue\s+hour|harsh\s+noon|backlit\s+silhouette)\b"#,
        caseInsensitive: true
    )
    static let settingEscapeRE = Rx.compile(#"\bsetting_ok\s*:"#, caseInsensitive: true)
    static let wordRE = Rx.compile(#"\w+"#)

    static let wideFamilyFramings: Set<String> = ["wide", "full", "aerial"]
    static let closeFamilyFramings: Set<String> = ["cu", "ecu", "mcu", "insert"]
    static let nonAerialHeights: Set<String> = ["eye_level", "low", "knee", "worm"]
    static let nonLowHeights: Set<String> = ["high", "overhead"]
    static let nonHighHeights: Set<String> = ["low", "worm", "knee"]

    /// Gaze-token stopwords (Python inline set in the gaze heuristic).
    static let gazeStopwords: Set<String> = [
        "look", "looks", "looking", "gaze", "gazing",
        "staring", "stare", "toward", "towards", "into",
        "from", "over", "across", "down",
    ]

    /// Port of `lint_prompt_against_shot`.
    public static func lintPromptAgainstShot(
        _ providerPrompt: String, _ shot: ShotSpec
    ) -> [ComplianceFinding] {
        var out: [ComplianceFinding] = []
        let text = providerPrompt

        let framingVal = shot.framing
        let heightVal = shot.cameraHeight
        let blocking = shot.blockingGazes

        // 1. Camera height vs aerial/overhead.
        if let m = Rx.firstMatchGroup0(text, aerialTokens),
           let heightVal, nonAerialHeights.contains(heightVal) {
            out.append(ComplianceFinding(
                severity: "warn", code: "CAMERA_HEIGHT_MISMATCH", matched: m,
                message: "Provider-Prompt enthaelt \(pythonRepr(m)), aber "
                    + "shot.camera_setup.height = \(pythonRepr(heightVal)). Aerial/"
                    + "overhead-Tokens widersprechen einer eye-level/low-"
                    + "Kamera. Entweder Prompt anpassen oder camera_setup "
                    + "in der Shotlist auf high/overhead aendern."
            ))
        }

        // 2. Low-angle vs height.
        if let m = Rx.firstMatchGroup0(text, lowAngleTokens),
           let heightVal, nonLowHeights.contains(heightVal) {
            out.append(ComplianceFinding(
                severity: "warn", code: "CAMERA_LOW_HIGH_MISMATCH", matched: m,
                message: "Provider-Prompt enthaelt \(pythonRepr(m)) (low angle), "
                    + "aber shot.camera_setup.height = \(pythonRepr(heightVal)). "
                    + "Inkonsistent."
            ))
        }
        if let m = Rx.firstMatchGroup0(text, highAngleTokens),
           let heightVal, nonHighHeights.contains(heightVal) {
            out.append(ComplianceFinding(
                severity: "warn", code: "CAMERA_LOW_HIGH_MISMATCH", matched: m,
                message: "Provider-Prompt enthaelt \(pythonRepr(m)) (high angle), "
                    + "aber shot.camera_setup.height = \(pythonRepr(heightVal)). "
                    + "Inkonsistent."
            ))
        }

        // 3. Framing vs close/wide tokens.
        if let framingVal, wideFamilyFramings.contains(framingVal) {
            if let m = Rx.firstMatchGroup0(text, closeUpTokens) {
                out.append(ComplianceFinding(
                    severity: "warn", code: "FRAMING_MISMATCH", matched: m,
                    message: "Provider-Prompt enthaelt \(pythonRepr(m)) "
                        + "(Close-Up-Wortschatz), aber shot.framing = "
                        + "\(pythonRepr(framingVal)) ist Wide-Familie. Entweder "
                        + "Close-Up-Tokens raus oder framing anpassen."
                ))
            }
        }
        if let framingVal, closeFamilyFramings.contains(framingVal) {
            if let m = Rx.firstMatchGroup0(text, wideTokens) {
                out.append(ComplianceFinding(
                    severity: "warn", code: "FRAMING_MISMATCH", matched: m,
                    message: "Provider-Prompt enthaelt \(pythonRepr(m)) "
                        + "(Wide-Wortschatz), aber shot.framing = "
                        + "\(pythonRepr(framingVal)) ist Close-Familie."
                ))
            }
        }

        // 4. Gaze mismatch.
        if !blocking.isEmpty {
            if let gazeMatch = Rx.firstMatchGroup0(text, gazeTokens) {
                let promptGaze = gazeMatch.lowercased()
                let specGazes = blocking.map { $0.lowercased() }.filter { !$0.isEmpty }
                if !specGazes.isEmpty {
                    var shared = false
                    let promptTokens = Set(
                        Rx.allGroup0(promptGaze, wordRE)
                            .filter { $0.count > 3 && !gazeStopwords.contains($0) }
                    )
                    for sg in specGazes {
                        let sgTokens = Set(Rx.allGroup0(sg, wordRE).filter { $0.count > 3 })
                        if !promptTokens.isDisjoint(with: sgTokens) {
                            shared = true
                            break
                        }
                    }
                    if !shared {
                        out.append(ComplianceFinding(
                            severity: "warn", code: "GAZE_MISMATCH", matched: gazeMatch,
                            message: "Provider-Prompt enthaelt Blick-Phrase "
                                + "\(pythonRepr(gazeMatch)), aber keiner "
                                + "der character_blocking[].gaze-Eintraege "
                                + "(\(pythonListRepr(specGazes))) teilt damit ein "
                                + "thematisches Wort. Pruefen: ist der "
                                + "Blick im Prompt der gleiche wie in der "
                                + "Spec?"
                        ))
                    }
                }
            }
        }

        // 5. Setting drift.
        let settingEscape = Rx.search(shot.notes, settingEscapeRE)
        if !settingEscape, let m = Rx.firstMatchGroup0(text, settingTokens) {
            out.append(ComplianceFinding(
                severity: "warn", code: "SETTING_DRIFT", matched: m,
                message: "Provider-Prompt enthaelt Zeit-/Lighting-Token "
                    + "\(pythonRepr(m)). Setting ist fast immer eine bewusste "
                    + "Story-Entscheidung — pruefen ob Section/Treatment "
                    + "diese Stimmung verlangt. Wenn nein: aus dem "
                    + "visual_prompt nehmen, sonst bekommt der Renderer "
                    + "(und der NLE-Editor bei still-only) einen "
                    + "Sonnenuntergang/Nacht-Block, den die Story nicht "
                    + "vorgesehen hat."
            ))
        }

        return out
    }

    /// Port of `_normalize`: `" ".join(text.lower().split())`.
    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
            || $0 == "\u{0B}" || $0 == "\u{0C}" }).joined(separator: " ")
    }

    /// Port of `lint_locked_directives`. Error severity — a lock is a promise.
    public static func lintLockedDirectives(
        _ providerPrompt: String, lockedDirectives: [String]
    ) -> [ComplianceFinding] {
        let promptNorm = normalize(providerPrompt)
        var out: [ComplianceFinding] = []
        for directive in lockedDirectives {
            if !promptNorm.contains(normalize(directive)) {
                out.append(ComplianceFinding(
                    severity: "error", code: "LOCKED_DIRECTIVE_MISSING", matched: directive,
                    message: "Locked directive missing from the prompt: \(pythonRepr(directive)). "
                        + "Compose the payload with the ledger directives "
                        + "(render.prompt.ledger_directives.directives_for_shot)."
                ))
            }
        }
        return out
    }
}
