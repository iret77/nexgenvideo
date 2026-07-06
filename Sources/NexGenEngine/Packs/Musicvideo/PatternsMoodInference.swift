import Foundation

/// Mood inference for pattern suggestions (v0.13.0). Port of
/// `nexgen_pack_musicvideo/patterns_mood_inference.py`.
///
/// Hybrid, brief-priority inference:
/// 1. **Primary** — `brief.tone` (the `ToneTag` list) as the source. The
///    enum values are mapped onto `MoodBand`.
/// 2. **Override / refinement** — a treatment-markdown heuristic (stopword
///    lists) for cases where the brief is vague or the treatment text
///    suggests a different tone.
///
/// No NLP models, no hallucination source — pure lexicon heuristic with
/// clear thresholds.
public enum PatternsMoodInference {
    /// ToneTag -> MoodBand mapping.
    ///
    /// `Brief.tone` is the canonical user answer. The enums semantically
    /// overlap; one `ToneTag` can imply multiple `MoodBand`s (e.g. "dark" ->
    /// aggressive OR melancholic). We take the DOMINANT MoodBand candidate
    /// per ToneTag.
    private static let toneToMood: [ToneTag: MoodBand] = [
        .melancholic: .melancholic,
        .ironic: .narrative,      // ironic ~ narrative distance
        .euphoric: .euphoric,
        .dark: .aggressive,
        .surreal: .dreamy,
        .poetic: .introspective,
        .energetic: .highEnergy,
        .quiet: .intimate,
        // .other falls through unmapped
    ]

    /// Primary mood inference from `Brief.tone` (v0.13.0).
    ///
    /// Multiple tones: the first mapped one wins — the user set the order
    /// deliberately. Empty / nil / only `.other`: nil — caller falls back to
    /// the treatment heuristic. Port of `mood_from_tone_tags`.
    public static func moodFromToneTags(_ tones: [ToneTag]?) -> MoodBand? {
        guard let tones, !tones.isEmpty else { return nil }
        for t in tones {
            if let mapped = toneToMood[t] { return mapped }
        }
        return nil
    }

    // Stopword lists per MoodBand. If the treatment text has more hits for
    // mood A than mood B, A is the dominant tone. Threshold: at least 2 hits
    // for a MoodBand, otherwise nil.
    private static let moodKeywords: [MoodBand: [String]] = [
        .introspective: [
            // English
            "reflect", "introspect", "thought", "memory", "remember",
            "inner", "alone", "solitude", "quiet contemplation",
            // German
            "nachdenk", "erinnerung", "innen", "stille", "alleine",
            "still", "ruhig",
        ],
        .melancholic: [
            "melanchol", "sad", "longing", "yearn", "wistful", "bittersweet",
            "lonely", "tear", "heartache", "grief",
            "trauer", "wehmut", "sehnsucht", "einsam",
        ],
        .euphoric: [
            "euphoric", "joy", "joyful", "celebration", "celebrate",
            "exhilarat", "ecstatic", "uplift", "triumphant",
            "freude", "feier", "rausch", "ekstatisch",
        ],
        .highEnergy: [
            "energetic", "energy", "kinetic", "explosive", "frantic", "pulse",
            "drive", "speed", "rush", "movement",
            "energie", "rasant", "treibend", "schnell",
        ],
        .aggressive: [
            "aggressive", "anger", "rage", "fierce", "violent", "dark",
            "brutal", "intense", "ominous", "menacing",
            "aggressiv", "wut", "duester", "dunkel", "brutal",
        ],
        .dreamy: [
            "dream", "dreamy", "ethereal", "surreal", "hazy", "floating",
            "otherworldly", "mysterious", "fog", "mist",
            "traum", "traeumerisch", "schwebend", "nebel", "surreal",
        ],
        .intimate: [
            "intimate", "tender", "soft", "vulnerable", "whisper", "close",
            "bedroom", "quiet moment",
            "intim", "zart", "verletzlich", "fluester", "nah",
        ],
        .narrative: [
            "story", "narrative", "character arc", "plot", "scene", "act",
            "chapter", "tale",
            "geschichte", "erzaehl", "kapitel", "figur",
        ],
        .cinematic: [
            "cinematic", "epic", "grand", "sweeping", "panoramic",
            "filmic", "cinema",
            "filmisch", "episch", "kinoreif", "monumental",
        ],
    ]

    /// Order matches `patterns_mood_inference.py::_MOOD_KEYWORDS`'s
    /// declaration order, needed so a genuine tie between the two runners-up
    /// resolves identically to Python's dict-iteration order.
    private static let moodOrder: [MoodBand] = [
        .introspective, .melancholic, .euphoric, .highEnergy, .aggressive, .dreamy, .intimate, .narrative,
        .cinematic,
    ]

    /// Heuristic inference from treatment markdown text.
    ///
    /// Counts stopword hits per MoodBand. The winner needs at least 2 hits
    /// AND at least 1 more than the runner-up (otherwise too ambiguous). nil
    /// on a flat ratio. Port of `mood_from_treatment`.
    public static func moodFromTreatment(_ text: String) -> MoodBand? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lower = text.lowercased()
        var counts: [MoodBand: Int] = [:]
        for mood in moodOrder {
            guard let keywords = moodKeywords[mood] else { continue }
            var total = 0
            for kw in keywords {
                total += countPrefixWordBoundaryMatches(of: kw, in: lower)
            }
            counts[mood] = total
        }
        guard !counts.isEmpty else { return nil }
        // Stable sort by count desc, ties broken by declaration order (moodOrder),
        // mirroring Python's Counter.most_common() (insertion-order stable sort).
        let ranked = moodOrder.map { ($0, counts[$0] ?? 0) }.sorted { $0.1 > $1.1 }
        guard let top = ranked.first, top.1 >= 2 else { return nil }
        if ranked.count > 1, ranked[1].1 == top.1 { return nil }  // Tie — too ambiguous.
        return top.0
    }

    /// `\b<keyword>` case-insensitive match count — Python's
    /// `re.findall(rf"\b{re.escape(kw)}", lower)` has no closing `\b`, so a
    /// keyword like "melanchol" also matches inside "melancholic".
    private static func countPrefixWordBoundaryMatches(of keyword: String, in text: String) -> Int {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: keyword)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        let ns = text as NSString
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
    }

    /// Hybrid inference: brief priority + treatment override (v0.13.0).
    ///
    /// Returns `(MoodBand?, sourceLabel)`. `sourceLabel` for user display:
    /// "brief.tone", "treatment", "fallback (no match)". `treatmentText` is
    /// the already-loaded treatment markdown (the engine has no filesystem
    /// project-dir walking of its own — the host resolves and passes the
    /// text in). Port of `infer_mood`.
    public static func inferMood(brief: Brief?, treatmentText: String? = nil) -> (mood: MoodBand?, source: String) {
        if let brief, let m = moodFromToneTags(brief.tone) {
            return (m, "brief.tone")
        }
        if let treatmentText, let m = moodFromTreatment(treatmentText) {
            return (m, "treatment")
        }
        return (nil, "fallback (no match)")
    }
}
