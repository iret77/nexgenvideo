import Foundation

/// Universal slop-strip for image and video prompts. Port of
/// `render/prompt/builder.py::_strip_prompt_slop` plus the module constants it
/// depends on. Byte-faithful: emitted strings are the product.
enum SlopStripper {
    /// Seedance mention tags (@Image1, @Video2, @Audio3 …). Port of
    /// `builder._AT_TAG_RE`. Case-insensitive.
    static let atTagRE = Rx.compile(#"@(?:Image|Video|Audio)\d+"#, caseInsensitive: true)

    /// Vague praise + hard-block tokens. Port of `builder._UNIVERSAL_SLOP_TOKENS`.
    /// Order is irrelevant — each is an independent `\bTOKEN\b` → "" deletion.
    /// Sorted for a deterministic Swift iteration (Python iterates a frozenset).
    static let universalSlopTokens: [String] = [
        "cinematic", "epic", "stunning", "amazing", "breathtaking", "masterpiece",
        "beautiful", "gorgeous", "magnificent", "spectacular", "incredible",
        "awesome", "perfect", "ultra-detailed", "highly detailed",
        "award-winning", "professional", "high-quality", "best-quality",
        "8k", "4k",
        "fast", "very fast", "super fast", "lightning fast",
    ]

    /// Meta-instruction sentence patterns. Port of
    /// `builder._META_INSTRUCTION_PATTERNS`. Applied case-insensitively, in order.
    static let metaInstructionPatterns: [NSRegularExpression] = [
        Rx.compile(#"\bthis\s+is\s+(?:the\s+)?(?:first|start|beginning|opening)\s+frame[^.]*\."#, caseInsensitive: true),
        Rx.compile(#"\bit\s+is\s+not\s+(?:a\s+)?(?:static|still|comic|drawing)[^.]*\."#, caseInsensitive: true),
        Rx.compile(#"\bstrict[:\s]+no[^.]*\."#, caseInsensitive: true),
        Rx.compile(#"\b(?:please|try to|if possible|versuche|eventuell)[^.,]*[.,]"#, caseInsensitive: true),
        Rx.compile(#"\b(?:important|note|remember|attention)[:\s]+[A-Z][^.]*\."#, caseInsensitive: true),
    ]

    /// Technical-lingo replacements. Port of `builder._TECH_LINGO_REPLACEMENTS`.
    /// (pattern, replacement) in order, case-insensitive.
    static let techLingoReplacements: [(NSRegularExpression, String)] = [
        (Rx.compile(#"\b\d+\s*mm\b"#, caseInsensitive: true), "normal lens feel"),
        (Rx.compile(#"\bf[/.]?\d+(?:\.\d+)?\b"#, caseInsensitive: true), "shallow depth of field"),
        (Rx.compile(#"\biso\s*\d+\b"#, caseInsensitive: true), ""),
        (Rx.compile(#"\b\d+\s*fps\b"#, caseInsensitive: true), ""),
        (Rx.compile("\\b\\d+\\s*°\\b", caseInsensitive: true), ""),
    ]

    /// Numbered / all-caps storyboard-label patterns. Port of
    /// `builder._NUMBERED_LABEL_RE`. Case-SENSITIVE (Python omits IGNORECASE).
    static let numberedLabelPatterns: [NSRegularExpression] = [
        Rx.compile(#"\b\d+\.\s*[A-Z][A-Z/\-_]+[A-Z]:\s*"#),
        Rx.compile(#"(?:^|\.\s+)([A-Z]{4,}(?:[/\-_][A-Z]+)*:\s*)"#),
    ]

    /// Inline-negative → positive table. Port of the `inline_negative_table`
    /// dict; dict literal order is insertion order in Python 3.7+, preserved here.
    static let inlineNegativeTable: [(NSRegularExpression, String)] = [
        (Rx.compile(#"\bno\s+text\b"#, caseInsensitive: true), "clean untyped surfaces"),
        (Rx.compile(#"\bno\s+watermarks?\b"#, caseInsensitive: true), "clean unmarked image"),
        (Rx.compile(#"\bno\s+signatures?\b"#, caseInsensitive: true), "clean unsigned image"),
        (Rx.compile(#"\bno\s+people\b"#, caseInsensitive: true), "empty environment, only architecture visible"),
        (Rx.compile(#"\bno\s+figures?\b"#, caseInsensitive: true), "empty environment, only setting visible"),
        (Rx.compile(#"\bno\s+humans?\b"#, caseInsensitive: true), "empty environment, only setting visible"),
        (Rx.compile(#"\bno\s+cars?\b"#, caseInsensitive: true), "empty road surface"),
        (Rx.compile(#"\bno\s+logos?\b"#, caseInsensitive: true), "unbranded surfaces"),
    ]

    // Cleanup patterns (step 6).
    private static let doubleSpaceRE = Rx.compile(#"\s{2,}"#)
    private static let spaceBeforePunctRE = Rx.compile(#"\s+([.,;:])"#)
    private static let repeatedPunctRE = Rx.compile(#"([.,;:]){2,}"#)
    // Unmask scan.
    private static let placeholderScanRE = Rx.compile("\u{0000}ATTAG(\\d+)\u{0000}")

    /// Port of `_strip_prompt_slop`. Idempotent, safe on empty input.
    static func strip(_ text: String) -> String {
        if text.isEmpty { return text }

        // Explicit mask/unmask of the Seedance mention tags.
        var placeholders: [String] = []
        var out = Rx.subFunc(text, atTagRE) { match, src in
            let tag = (src as NSString).substring(with: match.range)
            let idx = placeholders.count
            placeholders.append(tag)
            return "\u{0000}ATTAG\(idx)\u{0000}"
        }

        // 1. Meta-instructions (first — they match whole sentences).
        for pat in metaInstructionPatterns {
            out = Rx.sub(out, pat, with: "")
        }

        // 2. Numbered / all-caps labels. The whole match is replaced with " ".
        for pat in numberedLabelPatterns {
            out = Rx.sub(out, pat, with: " ")
        }

        // 3. Vague-praise tokens (word-boundary, case-insensitive).
        for tok in universalSlopTokens {
            let pat = Rx.compile("\\b\(Rx.escape(tok))\\b", caseInsensitive: true)
            out = Rx.sub(out, pat, with: "")
        }

        // 4. Technical lingo.
        for (pat, repl) in techLingoReplacements {
            out = Rx.sub(out, pat, with: repl)
        }

        // 5. Inline-negatives → positive framing.
        for (pat, repl) in inlineNegativeTable {
            out = Rx.sub(out, pat, with: repl)
        }

        // 6. Cleanup: collapse spaces, drop space before punctuation, collapse
        //    repeated punctuation, then strip surrounding " ,.;:".
        out = Rx.sub(out, doubleSpaceRE, with: " ")
        out = Rx.subTemplate(out, spaceBeforePunctRE, template: "$1")
        out = Rx.subTemplate(out, repeatedPunctRE, template: "$1")
        out = strip(out, charset: " ,.;:")

        // Unmask: restore placeholders to original tags, re-append any lost.
        if !placeholders.isEmpty {
            var presentIndices = Set<Int>()
            for g in Rx.allGroup1Ints(out, placeholderScanRE) { presentIndices.insert(g) }

            out = Rx.subFunc(out, placeholderScanRE) { match, src in
                guard let g = Rx.group(match, 1, in: src), let idx = Int(g) else { return "" }
                return placeholders[idx]
            }

            let missing = (0..<placeholders.count)
                .filter { !presentIndices.contains($0) }
                .map { placeholders[$0] }
            if !missing.isEmpty {
                let tail = missing.joined(separator: " ")
                out = out.isEmpty ? tail : (out + " " + tail).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return out
    }

    /// Python `str.strip(chars)`: trims any leading/trailing char in `charset`.
    private static func strip(_ s: String, charset: String) -> String {
        let set = Set(charset)
        var start = s.startIndex
        var end = s.endIndex
        while start < end, set.contains(s[start]) { start = s.index(after: start) }
        while end > start, set.contains(s[s.index(before: end)]) { end = s.index(before: end) }
        return String(s[start..<end])
    }
}

extension Rx {
    /// Group-1 integers over all matches — for the placeholder-index scan.
    static func allGroup1Ints(_ text: String, _ pattern: NSRegularExpression) -> [Int] {
        pattern.matches(in: text, range: fullRange(text)).compactMap { m in
            guard let g = group(m, 1, in: text) else { return nil }
            return Int(g)
        }
    }
}
