import Foundation

/// Content-block-risk linter. Port of `render/prompt/content_block_linter.py`.
/// Token tables verbatim (violence / real-name / brand), the real-photo path
/// check, and the multi-character anthro false-positive tiers.
public enum ContentBlockLinter {
    public enum Severity: String, Sendable, Equatable { case error, warn, info }

    /// Port of `content_block_linter.py::BlockRiskFinding`.
    public struct BlockRiskFinding: Sendable, Equatable {
        public let severity: Severity
        public let code: String
        public let matched: String
        public let suggestion: String
        public let message: String
    }

    /// Port of `_VIOLENCE_KEYWORDS` (keyword, rewrite-suggestion), in order.
    static let violenceKeywords: [(String, String)] = [
        ("shoot", "muzzle flash, tactical gesture"),
        ("shooting", "muzzle flash sequence"),
        ("shot dead", "fallen figure, motionless"),
        ("kill", "subdue, take down"),
        ("killed", "subdued, taken down"),
        ("murder", "violent confrontation aftermath"),
        ("stab", "lunge with sharp object"),
        ("stabbed", "lunged-at, struck"),
        ("blood", "dark stain, red fluid"),
        ("bloody", "stained, marked"),
        ("weapon", "tactical implement"),
        ("gun", "tactical sidearm"),
        ("rifle", "long-barreled implement"),
        ("pistol", "compact tactical implement"),
        ("revolver", "compact tactical sidearm"),
        ("firearm", "tactical implement"),
        ("shotgun", "long-barreled implement"),
        ("holster", "side pouch"),
        ("knife", "sharp implement"),
        ("dead body", "still figure on the ground"),
        ("corpse", "still figure"),
        ("dying", "weakening, fading"),
        ("execute", "subdue dramatically"),
        ("attack", "confront aggressively"),
        ("aim at", "gesture toward, focus attention on"),
        ("aimed at", "gestured toward, focused on"),
        ("aiming at", "gesturing toward"),
        ("point gun", "raise tactical implement"),
        ("pointing gun", "raising tactical implement"),
        ("draw weapon", "produce tactical implement"),
        ("drew weapon", "produced tactical implement"),
        ("cocked gun", "ready tactical implement"),
        ("loaded gun", "ready tactical implement"),
        ("loaded weapon", "ready tactical implement"),
    ]

    /// Port of `_REAL_NAMES_HINTS` (pattern, reason). Patterns applied
    /// case-insensitively against the original-case text.
    static let realNamesHints: [(NSRegularExpression, String)] = [
        (Rx.compile(#"\b(Donald\s+Trump|Joe\s+Biden|Barack\s+Obama|Kamala\s+Harris)\b"#, caseInsensitive: true),
         "US-politische Person"),
        (Rx.compile(#"\b(Vladimir\s+Putin|Volodymyr\s+Zelensky|Xi\s+Jinping)\b"#, caseInsensitive: true),
         "geopolitische Person"),
        (Rx.compile(#"\b(Taylor\s+Swift|Beyonc[eé]|Drake|Kanye\s+West)\b"#, caseInsensitive: true),
         "Pop-Promi"),
        (Rx.compile(#"\b(Elon\s+Musk|Mark\s+Zuckerberg|Jeff\s+Bezos)\b"#, caseInsensitive: true),
         "Tech-CEO"),
        (Rx.compile(#"\b(Lebron\s+James|Cristiano\s+Ronaldo|Lionel\s+Messi)\b"#, caseInsensitive: true),
         "Sport-Promi"),
    ]

    /// Port of `_BRAND_TOKENS` (pattern, rewrite-suggestion).
    static let brandTokens: [(NSRegularExpression, String)] = [
        (Rx.compile(#"\bNike\b"#, caseInsensitive: true), "athletic-brand sneakers"),
        (Rx.compile(#"\bAdidas\b"#, caseInsensitive: true), "three-stripe athletic-brand sneakers"),
        (Rx.compile(#"\bMcDonald'?s\b"#, caseInsensitive: true), "fast-food restaurant"),
        (Rx.compile(#"\bCoca[-\s]?Cola\b"#, caseInsensitive: true), "red soda can"),
        (Rx.compile(#"\bPepsi\b"#, caseInsensitive: true), "blue soda can"),
        (Rx.compile(#"\bStarbucks\b"#, caseInsensitive: true), "coffee chain cafe"),
        (Rx.compile(#"\bApple(?:\s+iPhone)?\b"#, caseInsensitive: true), "smartphone"),
        (Rx.compile(#"\bGoogle\b"#, caseInsensitive: true), "search-engine browser tab"),
        (Rx.compile(#"\bTwitter\b"#, caseInsensitive: true), "microblog-service feed"),
        (Rx.compile(#"\bFacebook\b"#, caseInsensitive: true), "social-network feed"),
        (Rx.compile(#"\bInstagram\b"#, caseInsensitive: true), "social-photo-app feed"),
        (Rx.compile(#"\bDisney(?:land|world)?\b"#, caseInsensitive: true), "themepark"),
        (Rx.compile(#"\bMickey\s+Mouse\b"#, caseInsensitive: true), "stylized cartoon mouse character"),
        (Rx.compile(#"\bSpider[-\s]?Man\b"#, caseInsensitive: true), "masked acrobatic hero"),
        (Rx.compile(#"\bBatman\b"#, caseInsensitive: true), "caped vigilante in dark armor"),
        (Rx.compile(#"\bSuperman\b"#, caseInsensitive: true), "caped hero in primary-colors costume"),
        (Rx.compile(#"\bPok[eé]mon\b"#, caseInsensitive: true), "stylized creature character"),
        (Rx.compile(#"\bMario(?:\s+Bros)?\b"#, caseInsensitive: true), "plumber-style platformer character"),
        (Rx.compile(#"\bLego\b"#, caseInsensitive: true), "interlocking-brick figure"),
    ]

    /// Port of `_REAL_PHOTO_PATH_HINTS`.
    static let realPhotoPathHints = [
        "photo", "photograph", "selfie", "real_person", "real-person", "headshot", "portrait_real",
    ]

    static let multiCharHighRiskFramings: Set<String> = ["ms", "mcu", "cu", "ecu", "ots"]
    static let multiCharWideTierFramings: Set<String> = ["wide", "full", "pov"]
    static let atRiskVisualMedia: Set<String> = [
        "3d_cg", "2d_animation", "illustration", "stop_motion", "mixed", "other",
    ]

    /// Port of `lint_provider_prompt`.
    public static func lintProviderPrompt(_ prompt: String) -> [BlockRiskFinding] {
        var out: [BlockRiskFinding] = []
        let text = prompt
        let textLow = text.lowercased()

        // 1. Violence keywords. `seen_violence` is per-keyword; distinct
        // keywords never collide, so it's a no-op dedup — kept for parity.
        var seenViolence = Set<String>()
        for (kw, suggestion) in violenceKeywords {
            if seenViolence.contains(kw) { continue }
            let pattern: NSRegularExpression
            if kw.contains(" ") {
                pattern = Rx.compile("\\b\(Rx.escape(kw))\\b")
            } else {
                pattern = Rx.compile("\\b\(Rx.escape(kw))(?:s|es|ing|ed)?\\b")
            }
            if Rx.search(textLow, pattern) {
                out.append(BlockRiskFinding(
                    severity: .warn,
                    code: "BLOCKING_RISK_VIOLENCE",
                    matched: kw,
                    suggestion: suggestion,
                    message: "Gewalt-Token '\(kw)' im Prompt — Seedance-Prompt-"
                        + "Filter blockt oder restringiert dieses Pattern. "
                        + "Umschreib-Vorschlag: '\(suggestion)'."
                ))
                seenViolence.insert(kw)
            }
        }

        // 2. Real names.
        for (pattern, kind) in realNamesHints {
            if let matched = Rx.firstMatchGroup0(text, pattern) {
                out.append(BlockRiskFinding(
                    severity: .warn,
                    code: "BLOCKING_RISK_REAL_NAME",
                    matched: matched,
                    suggestion: "fictional figure described by attributes only",
                    message: "Real-Personen-Token '\(matched)' (\(kind)) im "
                        + "Prompt — Seedance blockt das fast immer. Lese: "
                        + "fiktive Figur ueber Attribute beschreiben (Alter, "
                        + "Statur, Kleidung) statt namentlich."
                ))
            }
        }

        // 3. Brand tokens.
        for (pattern, suggestion) in brandTokens {
            if let matched = Rx.firstMatchGroup0(text, pattern) {
                out.append(BlockRiskFinding(
                    severity: .warn,
                    code: "BLOCKING_RISK_BRAND",
                    matched: matched,
                    suggestion: suggestion,
                    message: "Brand/IP-Token '\(matched)' im Prompt — "
                        + "Output-Filter blockt typischerweise. Umschreib-"
                        + "Vorschlag: '\(suggestion)'."
                ))
            }
        }

        return out
    }

    /// Port of `lint_reference_paths`. Each path is checked for a real-photo
    /// hint bounded by non-alphanumeric chars.
    public static func lintReferencePaths(_ paths: [String]) -> [BlockRiskFinding] {
        var out: [BlockRiskFinding] = []
        for p in paths {
            let pathStr = p.lowercased()
            for hint in realPhotoPathHints {
                let pattern = Rx.compile("(?<![a-z0-9])\(Rx.escape(hint))(?![a-z0-9])")
                if Rx.search(pathStr, pattern) {
                    out.append(BlockRiskFinding(
                        severity: .warn,
                        code: "BLOCKING_RISK_REAL_PHOTO_REFERENCE",
                        matched: p,
                        suggestion: "AI-generated, illustrated, cel-shaded or 3D-rendered "
                            + "version of the same character",
                        message: "Reference-Pfad \(p) enthaelt '\(hint)' — Face-"
                            + "Upload-Filter blockt Real-Photo-Faces. Lese: "
                            + "Bible-Sheet im illustrierten Stil rendern (Bible-"
                            + "Style-Guide), echte Photos nur als private "
                            + "Recherche-Quelle behalten."
                    ))
                    break
                }
            }
        }
        return out
    }

    /// Port of `lint_shot_for_multi_character_block`. `framing` and
    /// `visualMedium` are the enum raw values (or nil).
    public static func lintShotForMultiCharacterBlock(
        characterRefs: [String], framing: String?, visualMedium: String? = nil
    ) -> [BlockRiskFinding] {
        var out: [BlockRiskFinding] = []
        let n = characterRefs.count
        if n < 2 { return out }
        guard let framing else { return out }
        let framingVal = framing.lowercased()
        let tier: String
        if multiCharHighRiskFramings.contains(framingVal) {
            tier = "high"
        } else if multiCharWideTierFramings.contains(framingVal) {
            tier = "wide"
        } else {
            return out
        }
        if let visualMedium {
            if !atRiskVisualMedia.contains(visualMedium.lowercased()) { return out }
        }
        let rateText: String
        let framingNote: String
        if tier == "high" {
            rateText = "~90% Block-Rate"
            framingNote = "(nahe Framings triggern den Filter besonders zuverlaessig)"
        } else {
            rateText = "~50% Block-Rate"
            framingNote = "(WIDE/FULL/POV reduziert das Risiko, eliminiert es aber "
                + "NICHT — s027-wide wurde explizit getestet und trotzdem "
                + "geblockt; nicht als zuverlaessiger Workaround verwenden)"
        }
        out.append(BlockRiskFinding(
            severity: .warn,
            code: "BLOCKING_RISK_MULTI_CHARACTER",
            matched: "\(n) character_refs in framing=\(framingVal) [\(tier)-tier]",
            suggestion: "(a) Single-Character Schuss/Gegenschuss "
                + "(p_fail≈0, primary), oder "
                + "(c) Still-Frame + Ken-Burns/Pan-Zoom im NLE "
                + "(nur nach User-Approval, Minimum-Einsatz, "
                + "Ruhepositionen, in Live-Action nur ohne Menschen "
                + "im Frame — Pflicht-Bedingungen siehe Shotlist-Doku "
                + "Block -2)",
            message: "Shot hat \(n) character_refs (framing=\(framingVal), "
                + "\(tier)-tier, \(rateText)) — der ByteDance-Output-Filter "
                + "triggert auf die Praesenz anthropomorpher Figuren-Paare, "
                + "framing-weitgehend-unabhaengig. \(framingNote). "
                + "Token-Linter sieht das nicht (rein visuelle Gestalt). "
                + "Verlaessliche Loesungen: "
                + "(a) Shot splitten in Single-Char-Schuss + Gegenschuss "
                + "(p_fail≈0 bei Single-Char). "
                + "(c) Still-Frame im Image-Modell generieren (Image-Pfad "
                + "hat vermutlich den Seedance-Video-Output-Filter NICHT — "
                + "noch nicht empirisch verifiziert) und Bewegung "
                + "via Ken-Burns/Pan-Zoom im NLE (FCP/DaVinci) machen. "
                + "(c) braucht User-Approval, Minimum-Einsatz, "
                + "Ruhepositionen; in Live-Action nur ohne Menschen im "
                + "Frame. Marker: `still_only_approved:` in Shot.notes. "
                + "NICHT empfohlen: WIDE-Reframing (s.o.) und Brute-Force-"
                + "Retry (p_fail≈0.91 → ~21 Retries fuer 85% Confidence, "
                + "unwirtschaftlich trotz 0-EUR-Fails)."
        ))
        return out
    }

    /// Port of `has_blocking_risk`.
    public static func hasBlockingRisk(_ findings: [BlockRiskFinding]) -> Bool {
        findings.contains { $0.severity == .error }
    }
}
