import Foundation
import NexGenEngine

private let lowDensitySecondsPerBeat = 4.0
private let highDensityBeatsPerSecond = 0.9
private let minDurationForLowDensityCheck = 5.0
private let minBeatsForHighDensityCheck = 3

private let actionVerbLemmas: [String: String] = [
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

private let actionVerbPattern: NSRegularExpression = {
    let alternatives = actionVerbLemmas.keys.sorted { $0.count > $1.count }
        .map(NSRegularExpression.escapedPattern(for:))
    return try! NSRegularExpression(
        pattern: "\\b(" + alternatives.joined(separator: "|") + ")\\b",
        options: [.caseInsensitive]
    )
}()

private let sequenceConnectorPattern = try! NSRegularExpression(
    pattern: "\\b(then|after that|next|finally|before)\\b",
    options: [.caseInsensitive]
)

private let pacingOverridePattern = try! NSRegularExpression(
    pattern: "\\bpacing_ok\\s*:",
    options: [.caseInsensitive]
)

private func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
    let value = text as NSString
    return regex.matches(
        in: text,
        range: NSRange(location: 0, length: value.length)
    ).map { value.substring(with: $0.range) }
}

private func matchCount(_ regex: NSRegularExpression, in text: String) -> Int {
    let value = text as NSString
    return regex.numberOfMatches(
        in: text,
        range: NSRange(location: 0, length: value.length)
    )
}

public func countActionBeats(
    visualPrompt: String?,
    motion: String?,
    blockingText: String?
) -> Int {
    let text = [visualPrompt, motion, blockingText]
        .compactMap { $0 }
        .joined(separator: " ")
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return 0
    }
    let verbs = Set(matches(actionVerbPattern, in: text).compactMap {
        actionVerbLemmas[$0.lowercased()]
    })
    return verbs.count + matchCount(sequenceConnectorPattern, in: text)
}

private func blockingText(
    _ blocking: [CharacterBlocking],
    plan: ShotProductionPlan?
) -> String? {
    let parts = blocking.flatMap { item in
        [
            item.position,
            item.pose,
            item.gaze,
            plan?.setAnchor(for: item.characterRef) ?? "",
            item.relationToSet,
        ]
    }.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

extension MusicvideoChecks {
    public static let tempoCheck: SanityCheck = { ctx in
        if ctx.shotlist.mode == .multicam { return [] }
        let bpm = perceivedBPM(ctx)
        guard bpm > 0 else { return [] }
        let band = classifyTempo(bpm, mode: ctx.shotlist.mode.rawValue)
        let durations = ctx.shotlist.shots.map(\.durationS)
        let stats = aslViolation(durations, band: band)
        var findings = ctx.shotlist.shots.compactMap { shot -> Finding? in
            shot.durationS > band.hardCap
                ? Finding(
                    level: .warn,
                    code: "SHOT_OVER_TEMPO_CAP",
                    shotId: shot.id,
                    message: String(
                        format: "%.1fs over hard_cap %.1fs (%@, BPM %.1f). Deliberate breaker or split the phrase?",
                        shot.durationS,
                        band.hardCap,
                        band.label,
                        bpm
                    )
                )
                : nil
        }
        if stats.status == "too_many_breakers" {
            findings.append(Finding(
                level: .warn,
                code: "PACING_TOO_MANY_BREAKERS",
                message: String(
                    format: "\(stats.overCapCount) of \(durations.count) shots over hard_cap (%.0f%%). "
                        + "Tempo band %@ expects ASL %@-%@s, here %.1fs. Split long phrases into more atomic shots.",
                    stats.overCapRatio * 100,
                    band.label,
                    pythonFloatString(band.aslMin),
                    pythonFloatString(band.aslMax),
                    stats.asl
                )
            ))
        } else if stats.status == "pacing_drift" {
            findings.append(Finding(
                level: .warn,
                code: "PACING_DRIFT",
                message: String(
                    format: "ASL %.1fs exceeds tempo-band maximum %@s (%@, BPM %.1f).",
                    stats.asl,
                    pythonFloatString(band.aslMax),
                    band.label,
                    bpm
                )
            ))
        }
        return findings
    }

    public static let pacingCheck: SanityCheck = { ctx in
        ctx.shotlist.shots.compactMap { shot -> Finding? in
            let notes = shot.notes ?? ""
            guard matchCount(pacingOverridePattern, in: notes) == 0,
                  shot.durationS > 0 else { return nil }
            let action = shot.productionPlan?.primaryAction ?? shot.motion
            let beats = countActionBeats(
                visualPrompt: shot.visualPrompt,
                motion: action,
                blockingText: blockingText(
                    shot.characterBlocking,
                    plan: shot.productionPlan
                )
            )
            if shot.durationS >= minDurationForLowDensityCheck {
                let secondsPerBeat = shot.durationS / Double(max(beats, 1))
                if secondsPerBeat > lowDensitySecondsPerBeat {
                    return Finding(
                        level: .warn,
                        code: "SHOT_PACING_IMPLAUSIBLE",
                        shotId: shot.id,
                        message: String(
                            format: "Shot %@ (%.1fs) has ~\(beats) action beat(s), %.1fs per beat. "
                                + "Shorten or split the shot; use pacing_ok only for deliberate stillness.",
                            shot.id,
                            shot.durationS,
                            secondsPerBeat
                        )
                    )
                }
            }
            if beats >= minBeatsForHighDensityCheck {
                let beatsPerSecond = Double(beats) / shot.durationS
                if beatsPerSecond >= highDensityBeatsPerSecond {
                    return Finding(
                        level: .warn,
                        code: "SHOT_PACING_IMPLAUSIBLE",
                        shotId: shot.id,
                        message: String(
                            format: "Shot %@ (%.1fs) packs ~\(beats) action beats, %.2f beats/s. "
                                + "Split the shot or reduce it to the approved primary action.",
                            shot.id,
                            shot.durationS,
                            beatsPerSecond
                        )
                    )
                }
            }
            return nil
        }
    }
}
