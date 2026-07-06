import Foundation

/// Pre-call linter for built provider prompts. Port of
/// `render/prompt/linter.py`. All 13 numbered checks with the same finding
/// codes, severities, and messages.
public enum PromptLinter {
    public enum Severity: String, Sendable, Equatable { case error, warn, info }

    /// Port of `linter.py::LintFinding`.
    public struct LintFinding: Sendable, Equatable {
        public let severity: Severity
        public let code: String
        public let message: String
    }

    /// Port of `_LIGHT_MARKERS`.
    static let lightMarkers = [
        "light", "lit", "lighting", "sunlight", "moonlight", "lamp",
        "backlit", "rim light", "rim-light", "shadow", "silhouette",
        "golden hour", "blue hour", "neon", "fluorescent", "overcast",
        "candle", "spot", "key light", "ambient", "diffuse", "harsh",
        "soft", "hard light", "natural light", "volumetric",
        "practical light", "tungsten", "daylight", "dusk", "dawn", "twilight",
        "licht", "beleucht", "schatten", "sonnenlicht", "mondlicht",
        "mittagslicht", "gegenlicht", "kerzenlicht", "lampenlicht",
        "sonnenaufgang", "sonnenuntergang", "daemmer", "dämmer",
        "morgenlicht", "abendlicht", "goldene stunde", "blaue stunde",
        "weich", "hart", "diffus",
    ]

    /// Port of `_RESIDUAL_SLOP`.
    static let residualSlop = [
        "cinematic", "epic", "stunning", "amazing", "breathtaking",
        "masterpiece", "gorgeous", "magnificent", "spectacular",
        "incredible", "awesome", "ultra-detailed", "highly detailed",
        "award-winning",
    ]

    /// Port of `_HARD_BLOCK`.
    static let hardBlock = ["fast", "very fast", "super fast", "lightning fast"]

    /// Port of `_META_PATTERNS`.
    static let metaPatterns: [NSRegularExpression] = [
        Rx.compile(#"\bthis\s+is\s+(?:the\s+)?(?:first|start|beginning|opening)\s+frame\b"#, caseInsensitive: true),
        Rx.compile(#"\bstrict[:\s]+no\b"#, caseInsensitive: true),
        Rx.compile(#"\bit\s+is\s+not\s+(?:a\s+)?(?:static|still|comic|drawing)\b"#, caseInsensitive: true),
        Rx.compile(#"\b(?:please|try\s+to|if\s+possible)\b"#, caseInsensitive: true),
    ]

    static let numberedLabelRE = Rx.compile(#"\b\d+\.\s*[A-Z][A-Z/\-_]+[A-Z]:\s*"#)
    static let techLingoRE = Rx.compile(
        #"\b(?:\d+\s*mm|f[/.]?\d+(?:\.\d+)?|iso\s*\d+|\d+\s*fps|\d+\s*°)\b"#, caseInsensitive: true
    )
    static let negationPattern = Rx.compile(#"\b(no|not|avoid|without|kein|keine)\b"#, caseInsensitive: true)
    static let styleTagRE = Rx.compile(#"\bStyle:\s"#)
    static let imageIndexRE = Rx.compile(#"Image\s+(\d+):"#)

    /// Port of `_GRID_TRIGGERS`.
    static let gridTriggers = ["panel", "panels", "triptych", "grid", "split screen", "sheet"]

    /// Port of `_SINGLE_OUTPUT_PATTERNS`.
    static let singleOutputPatterns: [NSRegularExpression] = [
        Rx.compile(#"single\s+full[-\s]frame\s+image"#),
        Rx.compile(#"unified\s+continuous\s+picture"#),
        Rx.compile(#"edge[-\s]to[-\s]edge"#),
        Rx.compile(#"not\s+a\s+triptych"#),
        Rx.compile(#"not\s+a\s+grid"#),
        Rx.compile(#"output\s+one\s+image"#),
    ]

    /// Python `str.strip()` (whitespace) length.
    private static func strippedCount(_ s: String) -> Int {
        s.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// Port of `lint_prompt`.
    public static func lintPrompt(
        _ providerPrompt: String,
        multiRefHints: [String]? = nil,
        referencePaths: [String]? = nil,
        minLength: Int = 40
    ) -> [LintFinding] {
        var out: [LintFinding] = []
        let p = providerPrompt
        let pLow = p.lowercased()

        // 1. Empty / too short.
        let strippedLen = strippedCount(p)
        if strippedLen < minLength {
            out.append(LintFinding(
                severity: .error, code: "PROMPT_TOO_SHORT",
                message: "Final prompt is \(strippedLen) chars (< \(minLength)). "
                    + "Builder hat vermutlich keinen Subject bekommen oder Slop-"
                    + "Strip hat alles weggeloescht."
            ))
            if strippedLen == 0 { return out }
        }

        // 2. Double Style tag.
        let styleCount = Rx.allGroup0(p, styleTagRE).count
        if styleCount > 1 {
            out.append(LintFinding(
                severity: .error, code: "DOUBLE_STYLE_TAG",
                message: "'Style:' kommt \(styleCount)x im Prompt vor. Builder muss "
                    + "Style-Slot ueberspringen, wenn Subject bereits Style nennt. "
                    + "Style-Drift im Output sehr wahrscheinlich."
            ))
        }

        // 3. Residual slop.
        for tok in residualSlop {
            let pat = Rx.compile("\\b\(Rx.escape(tok))\\b")
            if Rx.search(pLow, pat) {
                out.append(LintFinding(
                    severity: .warn, code: "RESIDUAL_SLOP",
                    message: "Slop-Token '\(tok)' ist im finalen Prompt — Strip hat "
                        + "es uebersehen. Output wird Richtung Generic-Stockfoto "
                        + "gezogen."
                ))
                break
            }
        }

        // 4. Hard-block tokens.
        for tok in hardBlock {
            let pat = Rx.compile("\\b\(Rx.escape(tok))\\b")
            if Rx.search(pLow, pat) {
                out.append(LintFinding(
                    severity: .error, code: "HARD_BLOCK_TOKEN",
                    message: "Hard-Block-Token '\(tok)' ist im finalen Prompt — "
                        + "Apiyi-Guide: erzeugt reproduzierbar Jitter."
                ))
                break
            }
        }

        // 5. Meta-instructions survived.
        for pat in metaPatterns {
            if Rx.search(p, pat) {
                out.append(LintFinding(
                    severity: .error, code: "META_INSTRUCTION_SURVIVED",
                    message: "Meta-Anweisung matched Pattern \(pythonRepr(pat.pattern)) — Strip hat "
                        + "es nicht erwischt. Modell wird verwirrt."
                ))
                break
            }
        }

        // 6. Numbered labels.
        if let m = Rx.firstMatchGroup0(p, numberedLabelRE) {
            out.append(LintFinding(
                severity: .error, code: "NUMBERED_LABEL_SURVIVED",
                message: "Numeriertes Storyboard-Label \(pythonRepr(m)) im finalen "
                    + "Prompt — Strip hat versagt. Modell sieht Storyboard-"
                    + "Vokabular, neigt zu Multi-Panel-Output."
            ))
        }

        // 7. Technical lingo.
        if let m = Rx.firstMatchGroup0(p, techLingoRE) {
            out.append(LintFinding(
                severity: .warn, code: "TECH_LINGO_SURVIVED",
                message: "Technisches Lingo \(pythonRepr(m)) im finalen Prompt — "
                    + "Modell parst das nicht. Strip uebersehen."
            ))
        }

        // 8. Lighting marker missing.
        if !lightMarkers.contains(where: { pLow.contains($0) }) {
            out.append(LintFinding(
                severity: .warn, code: "MISSING_LIGHTING",
                message: "Kein Lighting-Marker im finalen Prompt. Apiyi: hoechster "
                    + "Quality-Hebel — ohne Lighting wird Output generisch."
            ))
        }

        // 9. Grid trigger without single-output directive.
        let hasGridTrigger = gridTriggers.contains { t in
            Rx.search(pLow, Rx.compile("\\b\(Rx.escape(t))\\b"))
        }
        let hasSingleOutput = singleOutputPatterns.contains { Rx.search(pLow, $0) }
        if hasGridTrigger && !hasSingleOutput {
            out.append(LintFinding(
                severity: .warn, code: "GRID_TRIGGER_WITHOUT_SINGLE_OUTPUT_DIRECTIVE",
                message: "Prompt enthaelt grid-/panel-/sheet-Trigger, aber keine "
                    + "Single-Output-Direktive ('single full-frame image', 'not a "
                    + "triptych'). Triptychon-Risiko."
            ))
        }

        // 10. Multi-ref without single-output directive.
        if let multiRefHints, multiRefHints.count >= 2, !hasSingleOutput {
            out.append(LintFinding(
                severity: .error, code: "MULTIREF_WITHOUT_SINGLE_OUTPUT_DIRECTIVE",
                message: "\(multiRefHints.count) References im Call, aber keine "
                    + "Single-Output-Direktive im Prompt. Gemini 3 Pro Image "
                    + "neigt empirisch zu Composite/Collage bei 2+ Refs ohne "
                    + "explizite Anti-Grid-Klausel."
            ))
        }

        // 11. Negations in the final prompt.
        let negHits = Set(Rx.allGroup0(p, negationPattern).map { $0.lowercased() }).sorted()
        if !negHits.isEmpty {
            out.append(LintFinding(
                severity: .warn, code: "PROMPT_CONTAINS_NEGATION",
                message: "Final prompt enthaelt Negation(en): \(pythonListRepr(negHits)). Image-/"
                    + "Videomodelle ignorieren oder verstaerken Negationen — "
                    + "stattdessen den ERWUENSCHTEN Zustand positiv beschreiben "
                    + "(siehe builder._positive_phrasing-Tabelle)."
            ))
        }

        // 12. Ref-hint count vs. actual "Image N:" entries.
        // Python guards on `if multi_ref_hints:` (truthy = non-empty list).
        if let multiRefHints, !multiRefHints.isEmpty {
            let imageN = Set(
                Rx.allMatches(p, imageIndexRE).compactMap { m -> Int? in
                    guard let g = Rx.group(m, 1, in: p) else { return nil }
                    return Int(g)
                }
            ).sorted()
            let expected = Array(1...multiRefHints.count)
            if !imageN.isEmpty && imageN != expected {
                out.append(LintFinding(
                    severity: .warn, code: "REF_HINT_INDEX_MISMATCH",
                    message: "Image-Indices im Prompt=\(pythonIntListRepr(imageN)), "
                        + "erwartet=\(pythonIntListRepr(expected)). "
                        + "Builder-Bug oder Reihenfolge wurde manipuliert."
                ))
            }
        }

        // 13. Content-block risk (violence / real-name / brand + real-photo paths).
        for br in ContentBlockLinter.lintProviderPrompt(p) {
            out.append(LintFinding(
                severity: mapSeverity(br.severity), code: br.code,
                message: br.message + " (Umschreib-Vorschlag: '\(br.suggestion)')"
            ))
        }
        if let referencePaths {
            for br in ContentBlockLinter.lintReferencePaths(referencePaths) {
                out.append(LintFinding(
                    severity: mapSeverity(br.severity), code: br.code,
                    message: br.message + " (Umschreib-Vorschlag: '\(br.suggestion)')"
                ))
            }
        }

        return out
    }

    private static func mapSeverity(_ s: ContentBlockLinter.Severity) -> Severity {
        switch s {
        case .error: return .error
        case .warn: return .warn
        case .info: return .info
        }
    }

    /// Port of `has_blocking`.
    public static func hasBlocking(_ findings: [LintFinding]) -> Bool {
        findings.contains { $0.severity == .error }
    }
}

extension Rx {
    static func allMatches(_ text: String, _ pattern: NSRegularExpression) -> [NSTextCheckingResult] {
        pattern.matches(in: text, range: fullRange(text))
    }
}

/// Python `repr(str)` for a single string: wraps in single quotes and escapes.
/// Used to reproduce the linter's `{x!r}` message interpolations byte-for-byte.
func pythonRepr(_ s: String) -> String {
    var body = ""
    for ch in s {
        switch ch {
        case "\\": body += "\\\\"
        case "'": body += "\\'"
        case "\n": body += "\\n"
        case "\r": body += "\\r"
        case "\t": body += "\\t"
        default: body.append(ch)
        }
    }
    return "'\(body)'"
}

/// Python `repr(list[str])`: `['a', 'b']`.
func pythonListRepr(_ items: [String]) -> String {
    "[" + items.map { pythonRepr($0) }.joined(separator: ", ") + "]"
}

/// Python `repr(list[int])`: `[1, 2, 3]`.
func pythonIntListRepr(_ items: [Int]) -> String {
    "[" + items.map(String.init).joined(separator: ", ") + "]"
}
