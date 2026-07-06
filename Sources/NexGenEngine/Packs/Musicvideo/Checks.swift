import Foundation

/// Mirrors Python's `str(float)` (e.g. `2.0`, not `2`) for band values
/// embedded in a finding message, so `ASL 2.0-4.0s` matches the Python
/// f-string byte-for-byte. Swift's `Double.description` is also a
/// shortest-round-trip formatter and agrees with CPython's `repr` here.
func pythonFloatString(_ value: Double) -> String {
    String(describing: value)
}

/// Music-specific sanity checks (tempo + pacing), ported into the pack. Port
/// of `nexgen_pack_musicvideo/checks.py`.
///
/// These are pure read checks over the `AuditContext`: they look at the
/// song's perceived BPM and the shot durations / prompts and flag pacing
/// problems. No audio DSP, no disk reads.
///
/// BPM is sourced from `ctx.shotlist.song.perceivedBpm`. For robustness the
/// host/pack may instead hand a BPM fallback in via
/// `ctx.extra["analysis.perceived_bpm"]` (a string-encoded `Double`, standing
/// in for Python's `ctx.extra["analysis"]` object with a `perceived_bpm`
/// attribute — the engine's `AuditContext.extra` is `[String: String]?`,
/// not an arbitrary object bag). If neither yields a usable BPM the checks
/// return `[]` (cannot validate) rather than erroring.
public enum MusicvideoChecks {
    /// Resolve perceived BPM. Prefer the shotlist's `Song`, fall back to
    /// `ctx.extra["analysis.perceived_bpm"]`. Returns 0.0 when no usable BPM
    /// is reachable. Port of `checks.py::_perceived_bpm`.
    static func perceivedBPM(_ ctx: AuditContext) -> Double {
        let song = ctx.shotlist.song
        if song.perceivedBpm > 0 {
            return song.perceivedBpm
        }

        if let raw = ctx.extra?["analysis.perceived_bpm"], let bpm = Double(raw), bpm > 0 {
            return bpm
        }
        return 0.0
    }

    /// Tempo-pacing check: ASL drift + per-shot hard-cap. Port of
    /// `checks.py::tempo`.
    ///
    /// Multicam has no per-shot pacing (one camera spans the whole song), so
    /// it is skipped. If BPM is unavailable we cannot classify a tempo band
    /// and return no findings.
    public static let tempoCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        if ctx.shotlist.mode == .multicam { return out }

        let bpm = perceivedBPM(ctx)
        guard bpm > 0 else { return out }

        let band = classifyTempo(bpm, mode: ctx.shotlist.mode.rawValue)
        let durations = ctx.shotlist.shots.map(\.durationS)
        let stats = aslViolation(durations, band: band)

        for shot in ctx.shotlist.shots where shot.durationS > band.hardCap {
            out.append(
                Finding(
                    level: .warn,
                    code: "SHOT_OVER_TEMPO_CAP",
                    shotId: shot.id,
                    message: String(
                        format: "%.1fs over hard_cap %.1fs (%@, BPM %.1f). Deliberate breaker or split the phrase?",
                        shot.durationS, band.hardCap, band.label, bpm
                    )
                )
            )
        }

        if stats.status == "too_many_breakers" {
            out.append(
                Finding(
                    level: .warn,
                    code: "PACING_TOO_MANY_BREAKERS",
                    message: String(
                        format:
                            "\(stats.overCapCount) of \(durations.count) shots over hard_cap (%.0f%%). "
                            + "Tempo band %@ expects ASL %@-%@s, here %.1fs. "
                            + "Long phrases should be split into more shots.",
                        stats.overCapRatio * 100, band.label,
                        pythonFloatString(band.aslMin), pythonFloatString(band.aslMax), stats.asl
                    )
                )
            )
        } else if stats.status == "pacing_drift" {
            out.append(
                Finding(
                    level: .warn,
                    code: "PACING_DRIFT",
                    message: String(
                        format:
                            "ASL %.1fs well above tempo-band maximum %@s (%@, BPM %.1f). Video likely feels too sluggish.",
                        stats.asl, pythonFloatString(band.aslMax), band.label, bpm
                    )
                )
            )
        }
        return out
    }
}

// MARK: - Shot-pacing plausibility
//
// Estimates the action-beat density per shot from visual_prompt + motion +
// character_blocking poses and compares it against `duration_s`. Bidirectional:
// too few beats over a long clip = slow-motion risk; too many beats over a
// short clip = rushed/jitter risk. Port of `checks.py`'s pacing section.

private let lowDensitySecondsPerBeat = 4.0
private let highDensityBeatsPerSecond = 0.9
private let minDurationForLowDensityCheck = 5.0
private let minBeatsForHighDensityCheck = 3

/// Action verbs with a movement character. Inflection -> lemma so "reaches"
/// and "reach" count as ONE beat. Deliberately small and conservative. Port
/// of `checks.py::_VERB_LEMMAS`.
private let verbLemmas: [String: String] = [
    "reach": "reach", "reaches": "reach",
    "grab": "grab", "grabs": "grab",
    "pick": "pick", "picks": "pick",
    "lift": "lift", "lifts": "lift",
    "place": "place", "places": "place",
    "put": "put", "puts": "put",
    "drop": "drop", "drops": "drop",
    "throw": "throw", "throws": "throw",
    "catch": "catch", "catches": "catch",
    "hold": "hold", "holds": "hold",
    "pull": "pull", "pulls": "pull",
    "push": "push", "pushes": "push",
    "press": "press", "presses": "press",
    "tap": "tap", "taps": "tap",
    "type": "type", "types": "type",
    "write": "write", "writes": "write",
    "draw": "draw", "draws": "draw",
    "tear": "tear", "tears": "tear",
    "rip": "rip", "rips": "rip",
    "open": "open", "opens": "open",
    "close": "close", "closes": "close",
    "unroll": "unroll", "unrolls": "unroll",
    "fold": "fold", "folds": "fold",
    "unfold": "unfold", "unfolds": "unfold",
    "wrap": "wrap", "wraps": "wrap",
    "raise": "raise", "raises": "raise",
    "lower": "lower", "lowers": "lower",
    "swing": "swing", "swings": "swing",
    "gesture": "gesture", "gestures": "gesture",
    "slide": "slide", "slides": "slide",
    "read": "read", "reads": "read",
    "speak": "speak", "speaks": "speak",
    "say": "say", "says": "say",
    "shout": "shout", "shouts": "shout",
    "whisper": "whisper", "whispers": "whisper",
    "nod": "nod", "nods": "nod",
    "shake": "shake", "shakes": "shake",
    "smile": "smile", "smiles": "smile",
    "frown": "frown", "frowns": "frown",
    "wink": "wink", "winks": "wink",
    "blink": "blink", "blinks": "blink",
    "yawn": "yawn", "yawns": "yawn",
    "look": "look", "looks": "look",
    "glance": "glance", "glances": "glance",
    "stand": "stand", "stands": "stand",
    "sit": "sit", "sits": "sit",
    "kneel": "kneel", "kneels": "kneel",
    "lean": "lean", "leans": "lean",
    "turn": "turn", "turns": "turn",
    "spin": "spin", "spins": "spin",
    "twist": "twist", "twists": "twist",
    "bend": "bend", "bends": "bend",
    "stretch": "stretch", "stretches": "stretch",
    "crouch": "crouch", "crouches": "crouch",
    "tilt": "tilt", "tilts": "tilt",
    "step": "step", "steps": "step",
    "walk": "walk", "walks": "walk",
    "run": "run", "runs": "run",
    "jump": "jump", "jumps": "jump",
    "land": "land", "lands": "land",
    "rise": "rise", "rises": "rise",
    "climb": "climb", "climbs": "climb",
    "enter": "enter", "enters": "enter",
    "exit": "exit", "exits": "exit",
    "leave": "leave", "leaves": "leave",
    "arrive": "arrive", "arrives": "arrive",
    "appear": "appear", "appears": "appear",
    "vanish": "vanish", "vanishes": "vanish",
    "emerge": "emerge", "emerges": "emerge",
    "approach": "approach", "approaches": "approach",
    "pass": "pass", "passes": "pass",
    "give": "give", "gives": "give",
    "show": "show", "shows": "show",
    "point": "point", "points": "point",
    "wave": "wave", "waves": "wave",
    "hug": "hug", "hugs": "hug",
    "kiss": "kiss", "kisses": "kiss",
    "punch": "punch", "punches": "punch",
    "kick": "kick", "kicks": "kick",
    "strike": "strike", "strikes": "strike",
]

/// Longest-first alternation so e.g. "unrolls" isn't shadowed by "roll" (which
/// isn't even in the table, but mirrors the Python sort-by-length safety).
private let verbPattern: NSRegularExpression = {
    let escaped = verbLemmas.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
    return try! NSRegularExpression(pattern: "\\b(" + escaped.joined(separator: "|") + ")\\b", options: [.caseInsensitive])
}()

private let sequenceConnectorsPattern = try! NSRegularExpression(
    pattern: "\\b(then|after that|next|finally|before)\\b", options: [.caseInsensitive]
)

private let pacingOkMarkerPattern = try! NSRegularExpression(pattern: "\\bpacing_ok\\s*:", options: [.caseInsensitive])

private func regexMatches(_ regex: NSRegularExpression, in text: String) -> [String] {
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
}

private func regexCount(_ regex: NSRegularExpression, in text: String) -> Int {
    let ns = text as NSString
    return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
}

private func isPacingMarked(_ notes: String?) -> Bool {
    guard let notes, !notes.isEmpty else { return false }
    return regexCount(pacingOkMarkerPattern, in: notes) > 0
}

/// Rough count of distinct action beats from the prompt fields. Lemma-dedup:
/// "reaches" and "reach" count as ONE beat. Sequence connectors ("then", ...)
/// count extra because they signal an explicit timeline. Port of
/// `checks.py::count_action_beats`.
public func countActionBeats(visualPrompt: String?, motion: String?, blockingText: String?) -> Int {
    let text = [visualPrompt, motion, blockingText].compactMap { $0 }.joined(separator: " ")
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
    let verbHits = regexMatches(verbPattern, in: text).compactMap { verbLemmas[$0.lowercased()] }
    let verbLemmaSet = Set(verbHits)
    let seqHits = regexCount(sequenceConnectorsPattern, in: text)
    return verbLemmaSet.count + seqHits
}

/// One shot-pacing finding direction. Port of `checks.py::PacingHit`.
struct PacingHit: Sendable, Equatable {
    let code: String
    let direction: String
    let durationS: Double
    let beats: Int
    let secondsPerBeat: Double
    let beatsPerSecond: Double
    let message: String
}

/// Evaluate pacing for one shot. Returns 0 or 1 `PacingHit`. Port of
/// `checks.py::_check_shot`.
private func checkShotPacing(
    shotId: String, durationS: Double, visualPrompt: String?, motion: String?, blockingText: String?, notes: String?
) -> [PacingHit] {
    if isPacingMarked(notes) { return [] }
    if durationS <= 0 { return [] }

    let beats = countActionBeats(visualPrompt: visualPrompt, motion: motion, blockingText: blockingText)

    if durationS >= minDurationForLowDensityCheck {
        let effectiveBeats = max(beats, 1)
        let spb = durationS / Double(effectiveBeats)
        if spb > lowDensitySecondsPerBeat {
            return [
                PacingHit(
                    code: "SHOT_PACING_IMPLAUSIBLE",
                    direction: "slow_motion_risk",
                    durationS: durationS,
                    beats: beats,
                    secondsPerBeat: spb,
                    beatsPerSecond: durationS > 0 ? Double(beats) / durationS : 0.0,
                    message: String(
                        format:
                            "Shot %@ (%.1fs) has only ~\(beats) action beat(s) in the prompt — %.1fs per beat. "
                            + "The video model tends to stretch the single action (looks like slow-motion). "
                            + "Fix: (a) specify more distinct action beats in visual_prompt / motion / "
                            + "character_blocking ('then X, then Y'-mini-timeline), or (b) accept deliberate "
                            + "idle bracketing. If the stillness is intended: `pacing_ok: <reason>` in Shot.notes.",
                        shotId, durationS, spb
                    )
                )
            ]
        }
    }

    if beats >= minBeatsForHighDensityCheck, durationS > 0 {
        let bps = Double(beats) / durationS
        if bps >= highDensityBeatsPerSecond {
            return [
                PacingHit(
                    code: "SHOT_PACING_IMPLAUSIBLE",
                    direction: "rushed_risk",
                    durationS: durationS,
                    beats: beats,
                    secondsPerBeat: beats > 0 ? durationS / Double(beats) : 0.0,
                    beatsPerSecond: bps,
                    message: String(
                        format:
                            "Shot %@ (%.1fs) packs ~\(beats) action beats — %.2f beats/s. The video model tends to "
                            + "jitter or skip beats. Fix: (a) split the shot in two, or (b) reduce beats to the "
                            + "core action. If intended: `pacing_ok: <reason>` in Shot.notes.",
                        shotId, durationS, bps
                    )
                )
            ]
        }
    }

    return []
}

/// Concatenate `CharacterBlocking` fields (pose, gaze, position,
/// relationToSet) into a beat-source text. Pose verbs otherwise live only in
/// this struct and would not feed the beat count. Port of
/// `checks.py::_blocking_text`.
private func blockingText(_ blocking: [CharacterBlocking]) -> String? {
    guard !blocking.isEmpty else { return nil }
    var parts: [String] = []
    for b in blocking {
        for value in [b.position, b.pose, b.gaze, b.relationToSet] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

extension MusicvideoChecks {
    /// Shot-pacing plausibility. Flags `SHOT_PACING_IMPLAUSIBLE` per shot,
    /// bidirectional (slow-motion vs rushed). Reads only prompt fields, no
    /// BPM needed. Port of `checks.py::pacing`.
    public static let pacingCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        for shot in ctx.shotlist.shots {
            let hits = checkShotPacing(
                shotId: shot.id,
                durationS: shot.durationS,
                visualPrompt: shot.visualPrompt,
                motion: shot.motion,
                blockingText: blockingText(shot.characterBlocking),
                notes: shot.notes
            )
            for hit in hits {
                out.append(Finding(level: .warn, code: hit.code, shotId: shot.id, message: hit.message))
            }
        }
        return out
    }
}
