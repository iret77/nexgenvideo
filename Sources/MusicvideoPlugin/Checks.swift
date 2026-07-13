import Foundation
import NexGenEngine

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

    /// Bible reference integrity: every shot's character/location/prop reference must resolve to a real
    /// bible entity. `sanity.md` claims `run_sanity` covers this, but no such check existed — the agent
    /// could ship a shotlist referencing entities the bible never defines. Port of
    /// `sanity/checks/bible_integration.py`: MISSING_BIBLE_REF + NO_FRONT_SHEET. The Python's NO_ANCHOR
    /// case is intentionally dropped: `Bible.validate()` already throws `.missingAnchors` for any
    /// character/ensemble/location without an anchor at EVERY construction and decode boundary, so an
    /// anchorless entity can't reach a sanity check here — the type invariant enforces it more strongly
    /// than a warning ever could. (Props stay exempt, matching the Bible validator.)
    public static let bibleReferenceIntegrityCheck: SanityCheck = { ctx in
        guard let bible = ctx.bible else { return [] }
        var out: [Finding] = []
        for shot in ctx.shotlist.shots {
            var refs: [(kind: String, ref: String)] =
                shot.characterRefs.map { ("character", $0) } + shot.propRefs.map { ("prop", $0) }
            if let loc = shot.locationRef, !loc.isEmpty { refs.append(("location", loc)) }
            for r in refs where bible.lookupId(r.ref) == nil {
                out.append(Finding(level: .error, code: "MISSING_BIBLE_REF", shotId: shot.id,
                    message: "shot \(shot.id) references \(r.kind) \"\(r.ref)\" which isn't in the bible."))
            }
        }
        // NO_FRONT_SHEET: a 'front' sheet is the recommended default anchor.
        for character in bible.characters where !character.sheets.isEmpty && character.sheets["front"] == nil {
            out.append(Finding(level: .warn, code: "NO_FRONT_SHEET", shotId: nil,
                message: "character \"\(character.id)\" has sheets but no 'front' — recommended as the default anchor."))
        }
        return out
    }

    /// NO_BLOCKING_AT_T0: a keyframe start/start_end shot whose visual_prompt doesn't structurally cover
    /// the three blocking axes (pose/vector/camera) — its start frame isn't a clear t=0 state. `sanity.md`
    /// / `frame.md` claim this is engine-enforced; it wasn't. Port of `prompts.py`'s use of
    /// `blocking_validator.validate_blocking`.
    public static let noBlockingAtT0Check: SanityCheck = { ctx in
        var out: [Finding] = []
        for shot in ctx.shotlist.shots
        where shot.keyframeStrategy == .start || shot.keyframeStrategy == .startEnd {
            let r = BlockingValidator.validate(
                visualPrompt: shot.visualPrompt, hasCharacters: !shot.characterRefs.isEmpty)
            if !r.ok {
                out.append(Finding(level: .error, code: "NO_BLOCKING_AT_T0", shotId: shot.id,
                    message: "shot \(shot.id) start frame isn't a clear t=0 blocking: "
                        + r.reasons.joined(separator: " ")))
            }
        }
        return out
    }

    /// Content-block risk: run the already-ported `ContentBlockLinter` (violence / real-name / brand /
    /// real-photo tokens + multi-character block-rate risk) over each shot's RAW fields, pre-build. The
    /// linter existed but was never wired into the audit. Advisory (warn) per the phase docs' severity
    /// note — it informs, it doesn't hard-block the gate.
    public static let contentBlockRiskCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        for shot in ctx.shotlist.shots {
            let findings = ContentBlockLinter.lintShotForMultiCharacterBlock(
                characterRefs: shot.characterRefs, framing: shot.framing?.rawValue,
                visualMedium: ctx.brief?.visualMedium.rawValue)
                + ContentBlockLinter.lintProviderPrompt(shot.visualPrompt)
            for f in findings {
                let level: Level = (f.severity == .info) ? .info : .warn
                out.append(Finding(level: level, code: f.code, shotId: shot.id, message: f.message))
            }
        }
        return out
    }

    private static let germanStopwordRegex = try? NSRegularExpression(
        pattern: #"\b(?:und|oder|aber|sondern|denn|mit|von|nach|bei|seit|ueber|unter|vor|hinter|neben|zwischen|fuer|gegen|ohne|um|der|die|das|den|dem|des|ein|eine|einer|eines|einem|einen|sich|ihn|ihr|ihm|ihnen|uns|euch|mein|dein|sein|unser|auch|nicht|noch|schon|sehr|nur|doch|ja|nein|ist|sind|war|waren|wird|werden|hat|haben|kann|koennen|soll|sollen|muss|muessen|darf|duerfen|dass|weil|wenn|wie|wo|im|ins|am|ans|zum|zur|vom|beim)\b"#,
        options: [.caseInsensitive])

    /// PROMPT_NOT_ENGLISH (warn): image/video models are trained on English captions; a German
    /// visual_prompt yields softer, camera/lighting-ignoring output. Heuristic: ≥2 unique German
    /// stopwords, OR 1 umlaut + 1 stopword. Escape via `non_english_ok:` in notes. Port of
    /// `sanity/checks/prompt_language.py`.
    public static let promptLanguageCheck: SanityCheck = { ctx in
        guard let re = germanStopwordRegex else { return [] }
        var out: [Finding] = []
        for shot in ctx.shotlist.shots {
            if let notes = shot.notes,
               notes.range(of: #"\bnon_english_ok\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }
            let prompt = shot.visualPrompt
            let ns = prompt as NSString
            let unique = Set(re.matches(in: prompt, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range).lowercased() })
            let hasUmlaut = prompt.range(of: "[äöüÄÖÜß]", options: .regularExpression) != nil
            if unique.count >= 2 || (hasUmlaut && unique.count >= 1) {
                out.append(Finding(level: .warn, code: "PROMPT_NOT_ENGLISH", shotId: shot.id,
                    message: "shot \(shot.id) visual_prompt looks non-English (German tokens: "
                        + "\(unique.sorted().prefix(4).joined(separator: ", "))). Write it in English "
                        + "(or set notes 'non_english_ok: <reason>')."))
            }
        }
        return out
    }

    private static let motionTokensPattern = #"\b(running|runs|ran|flying|flies|flew|leaping|leaps|leapt|jumping|jumps|jumped|falling|falls|fell|mid[\s-]?stride|sprinting|sprints|dashing|dashes|galloping|gallops|rushing|rushes|rushed|dancing|dances|danced|twirling|twirls|twirled|twisting|twists|twisted|spinning|spins|spun|skipping|skips|skipped|swinging|swings|swung|diving|dives|dove)\b"#

    /// Still-only discipline. Port of `sanity/checks/still_only_discipline.py`:
    ///  - STILL_ONLY_FORBIDDEN_LIVE_ACTION_WITH_CHARS (error): the still-only workaround is used on a
    ///    live-action shot that has characters.
    ///  - STILL_ONLY_MOTION_TOKEN (warn): a still-only shot's prompt still describes motion (unless
    ///    `still_only_motion_ok:` escapes it).
    public static let stillOnlyDisciplineCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        let liveAction: Set<String> = ["live_action_realistic", "live_action_stylized"]
        let vm = ctx.brief?.visualMedium.rawValue
        for shot in ctx.shotlist.shots {
            let notes = shot.notes ?? ""
            guard notes.range(of: #"\bstill_only_approved\s*:"#,
                              options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            if let vm, liveAction.contains(vm), !shot.characterRefs.isEmpty {
                out.append(Finding(level: .error, code: "STILL_ONLY_FORBIDDEN_LIVE_ACTION_WITH_CHARS",
                    shotId: shot.id,
                    message: "shot \(shot.id): the still-only workaround is forbidden for live-action shots "
                        + "with characters."))
            }
            let motionOK = notes.range(of: #"\bstill_only_motion_ok\s*:"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil
            if !motionOK,
               shot.visualPrompt.range(of: motionTokensPattern,
                                       options: [.regularExpression, .caseInsensitive]) != nil {
                out.append(Finding(level: .warn, code: "STILL_ONLY_MOTION_TOKEN", shotId: shot.id,
                    message: "shot \(shot.id): a still-only shot describes motion — still-only frames must "
                        + "show rest positions."))
            }
        }
        return out
    }

    private static let establishingFramings: Set<Framing> = [.wide, .full, .aerial]
    private static let detailFramings: Set<Framing> = [.cu, .ecu, .mcu, .insert, .ots, .ms]

    /// Section dramaturgy. Port of `sanity/checks/variation.py`:
    ///  - POST_ESTABLISHING_NO_VARIATION (warn): an establishing shot (wide/full/aerial) not resolved by
    ///    a detail/reveal within the next 2 shots (escape `cut_ok: no_resolve_intentional`).
    ///  - SECTION_NO_ARC (info): a ≥3-shot section missing an establishing OR a detail framing.
    /// (VISUAL_REDUNDANCY follows with the redundancy port.)
    public static let variationCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        if ctx.shotlist.mode == .multicam { return out }
        var bySection: [String: [Shot]] = [:]
        var order: [String] = []
        for shot in ctx.shotlist.shots {
            let key = shot.section ?? "_unsectioned"
            if bySection[key] == nil { order.append(key) }
            bySection[key, default: []].append(shot)
        }
        let window = 2
        for key in order {
            let shots = bySection[key]!
            for (i, shot) in shots.enumerated() {
                guard let f = shot.framing, establishingFramings.contains(f) else { continue }
                let notesLower = (shot.notes ?? "").lowercased()
                if notesLower.contains("no_resolve_intentional") || notesLower.contains("cut_ok: no_resolve") {
                    continue
                }
                let slice = shots[(i + 1)..<min(i + 1 + window, shots.count)]
                if slice.isEmpty { continue }
                let hasResolve = slice.contains { $0.framing.map { detailFramings.contains($0) } ?? false }
                if !hasResolve {
                    out.append(Finding(level: .warn, code: "POST_ESTABLISHING_NO_VARIATION", shotId: shot.id,
                        message: "shot \(shot.id) (\(f.rawValue)) in section \"\(key)\" stays unresolved — no "
                            + "detail/reveal (ms/mcu/cu/ecu/ots/insert) within the next \(window) shots. Add a "
                            + "detail shot after it, or 'cut_ok: no_resolve_intentional' in notes."))
                }
            }
        }
        for key in order {
            let shots = bySection[key]!
            if shots.count < 3 { continue }
            let framings = Set(shots.compactMap(\.framing))
            let hasEst = !framings.isDisjoint(with: establishingFramings)
            let hasDetail = !framings.isDisjoint(with: detailFramings)
            if hasEst && !hasDetail {
                out.append(Finding(level: .info, code: "SECTION_NO_ARC",
                    message: "section \"\(key)\": only establishing framings, no detail/reveal — it runs at "
                        + "one distance, no arc. Add at least one detail shot."))
            } else if hasDetail && !hasEst && shots.count >= 4 {
                out.append(Finding(level: .info, code: "SECTION_NO_ARC",
                    message: "section \"\(key)\": only detail framings, no establishing (wide/full/aerial) — "
                        + "no spatial anchor. Add an establishing shot."))
            }
        }
        return out
    }

    private static let redundancyStopwords: Set<String> = ["a", "an", "the", "and", "or", "but", "of",
        "in", "on", "at", "to", "from", "with", "by", "for", "as", "is", "are", "was", "were", "be",
        "been", "being", "has", "have", "had", "do", "does", "did", "this", "that", "these", "those",
        "his", "her", "their", "its", "it", "he", "she", "they", "we", "you", "i", "me", "him", "them",
        "us", "shot", "scene", "frame", "image", "camera", "static", "der", "die", "das", "ein", "eine",
        "und", "oder", "aber", "im", "auf", "zu", "von", "mit", "fuer", "ist", "sind", "war", "waren",
        "sein", "haben", "hatte", "diese", "dieser", "sich", "er", "sie", "es", "wir", "ihr"]
    private static let tokenRegex = try? NSRegularExpression(pattern: #"\b[a-zA-ZÀ-ſ]{3,}\b"#)

    private static func contentTokens(_ text: String?) -> Set<String> {
        guard let text, !text.isEmpty, let re = tokenRegex else { return [] }
        let ns = text as NSString
        var out = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range).lowercased()
            if !redundancyStopwords.contains(t) { out.insert(t) }
        }
        return out
    }

    private static func shotContentTokens(_ shot: Shot) -> Set<String> {
        var t = contentTokens(shot.visualPrompt).union(contentTokens(shot.motion))
        let blocking = shot.characterBlocking
            .flatMap { [$0.pose, $0.position, $0.gaze, $0.relationToSet] }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
        if !blocking.isEmpty { t.formUnion(contentTokens(blocking)) }
        return t
    }

    /// VISUAL_REDUNDANCY (warn): two consecutive shots on the same location with ≥55% Jaccard
    /// content-token overlap — near-identical, wasteful renders. Escape `redundancy_ok:` in notes.
    /// Port of `sanity/redundancy.py`.
    public static let redundancyCheck: SanityCheck = { ctx in
        let shots = ctx.shotlist.shots
        guard shots.count >= 2 else { return [] }
        var out: [Finding] = []
        for i in 1..<shots.count {
            let prev = shots[i - 1], shot = shots[i]
            if (shot.notes ?? "").range(of: #"\bredundancy_ok\s*:"#,
                                        options: [.regularExpression, .caseInsensitive]) != nil { continue }
            guard shot.locationRef == prev.locationRef else { continue }
            let a = shotContentTokens(prev), b = shotContentTokens(shot)
            if a.isEmpty || b.isEmpty { continue }
            let sim = Double(a.intersection(b).count) / Double(max(a.union(b).count, 1))
            if sim >= 0.55 {
                let common = a.intersection(b).sorted().prefix(8).joined(separator: ", ")
                out.append(Finding(level: .warn, code: "VISUAL_REDUNDANCY", shotId: shot.id,
                    message: "shot \(shot.id) has \(Int(sim * 100))% token overlap with \(prev.id) on the "
                        + "same location (tokens: \(common)). Near-identical content — differentiate one shot "
                        + "or cut it (or 'redundancy_ok: <reason>' in notes)."))
            }
        }
        return out
    }

    /// MISSING_BIBLE_ANCHOR_FOR_T2V (error): a `keyframe_strategy=none` (pure text-to-video) shot that
    /// still references bible entities has no visual anchor, so the video model invents the world —
    /// inconsistent with image-to-video shots of the same location/character. Reference-mode on fal is
    /// exempt (the bible refs ARE the anchor). Escape `text_to_video_ok:` in notes. Port of
    /// `sanity/checks/keyframe_anchor.py`.
    public static let keyframeAnchorCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        for shot in ctx.shotlist.shots {
            guard shot.keyframeStrategy == .none else { continue }
            var refs: [String] = []
            if let loc = shot.locationRef, !loc.isEmpty { refs.append("location_ref=\(loc)") }
            if !shot.characterRefs.isEmpty { refs.append("character_refs=\(shot.characterRefs)") }
            if !shot.propRefs.isEmpty { refs.append("prop_refs=\(shot.propRefs)") }
            guard !refs.isEmpty else { continue }
            if shot.seedanceInputMode == .reference && shot.sceneVideoProvider == .fal { continue }
            if (shot.notes ?? "").lowercased().contains("text_to_video_ok:") { continue }
            out.append(Finding(level: .error, code: "MISSING_BIBLE_ANCHOR_FOR_T2V", shotId: shot.id,
                message: "shot \(shot.id) is keyframe_strategy=none (pure text-to-video) but references "
                    + "bible entities (\(refs.joined(separator: ", "))). Without a visual anchor the video "
                    + "model invents the world — guaranteed inconsistency with image-to-video shots of the "
                    + "same location/character. Set keyframe_strategy=start + make an anchor frame, or "
                    + "'text_to_video_ok: <reason>' in notes."))
        }
        return out
    }

    /// Location-view coverage + perspective-discipline reminder. Port of `sanity/checks/location_view.py`:
    ///  - LOCATION_VIEW_MISSING (error): a shot's `location_view` isn't in the bible location's sheets.
    ///  - MULTI_VIEW_LOCATION (info): ≥2 distinct views of one location (manual non-overlap check).
    public static let locationViewCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        if let bible = ctx.bible {
            for shot in ctx.shotlist.shots {
                guard let view = shot.locationView, !view.isEmpty,
                      let locRef = shot.locationRef, !locRef.isEmpty else { continue }
                guard case .location(let loc)? = bible.lookupId(locRef) else { continue }
                var available = Set(loc.sheets.keys)
                for i in 0..<loc.referenceImages.count { available.insert("ref_\(i)") }
                if !available.contains(view) {
                    out.append(Finding(level: .error, code: "LOCATION_VIEW_MISSING", shotId: shot.id,
                        message: "shot \(shot.id): location_view=\"\(view)\" for location \"\(locRef)\" is "
                            + "missing in the bible (have: \(loc.sheets.keys.sorted().joined(separator: ", "))). "
                            + "The bible phase must generate the view, or the shot drops this anchor."))
                }
            }
        }
        var locViews: [String: Set<String>] = [:]
        for shot in ctx.shotlist.shots {
            if let locRef = shot.locationRef, let view = shot.locationView, !locRef.isEmpty, !view.isEmpty {
                locViews[locRef, default: []].insert(view)
            }
        }
        for (locRef, views) in locViews where views.count >= 2 {
            out.append(Finding(level: .info, code: "MULTI_VIEW_LOCATION",
                message: "location \"\(locRef)\" is shown from \(views.count) perspectives "
                    + "(\(views.sorted().joined(separator: ", "))). Allowed only if the views share NO common "
                    + "objects (perspective discipline) — verify non-overlap manually."))
        }
        return out
    }

    /// Proportion-anchor plausibility. Port of `sanity/checks/proportion_anchor.py`:
    ///  - PROPORTION_ANCHOR_UNKNOWN (warn): a location's proportion_anchor_shot isn't in the shotlist.
    ///  - PROPORTION_ANCHOR_MISMATCH (warn): the anchor shot's location_ref isn't that location.
    public static let proportionAnchorCheck: SanityCheck = { ctx in
        guard let bible = ctx.bible else { return [] }
        var out: [Finding] = []
        let byId = Dictionary(ctx.shotlist.shots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for loc in bible.locations {
            guard let anchorId = loc.proportionAnchorShot?.trimmingCharacters(in: .whitespaces),
                  !anchorId.isEmpty else { continue }
            guard let anchor = byId[anchorId] else {
                out.append(Finding(level: .warn, code: "PROPORTION_ANCHOR_UNKNOWN",
                    message: "location \"\(loc.id)\": proportion_anchor_shot=\"\(anchorId)\" isn't in the "
                        + "shotlist."))
                continue
            }
            if anchor.locationRef != loc.id {
                out.append(Finding(level: .warn, code: "PROPORTION_ANCHOR_MISMATCH", shotId: anchor.id,
                    message: "location \"\(loc.id)\": proportion_anchor_shot \"\(anchor.id)\" has "
                        + "location_ref=\"\(anchor.locationRef ?? "")\", should be \"\(loc.id)\"."))
            }
        }
        return out
    }

    /// Model capability + aspect compatibility. Port of `sanity/checks/compatibility.py`, using the
    /// bundled cost config for model resolution (`runwayModel`) + `ModelCapabilities`/`AspectResolver`:
    ///  - UNKNOWN_MODEL (error), DURATION_TRUNCATED (warn), KEYFRAME_NOT_SUPPORTED (error),
    ///    KEYFRAME_END_NOT_SUPPORTED (error), TOO_MANY_CHARACTERS (warn), RATIO_NOT_SUPPORTED (error).
    public static let compatibilityCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        let costs = CostsConfig.bundledDefault
        for shot in ctx.shotlist.shots {
            let model = costs.runwayModel(for: shot, phase: .final)
            guard let cap = ModelCapabilities.capability(model) else {
                out.append(Finding(level: .error, code: "UNKNOWN_MODEL", shotId: shot.id,
                    message: "resolved model \"\(model)\" isn't in the capabilities registry."))
                continue
            }
            if shot.durationS > cap.maxDurationS {
                out.append(Finding(level: .warn, code: "DURATION_TRUNCATED", shotId: shot.id,
                    message: "duration_s=\(shot.durationS) > \(model) max=\(cap.maxDurationS)s — truncated."))
            }
            if shot.keyframeStrategy == .start && !cap.supportsKeyframeStart {
                out.append(Finding(level: .error, code: "KEYFRAME_NOT_SUPPORTED", shotId: shot.id,
                    message: "\(model) doesn't support a start keyframe."))
            }
            if shot.keyframeStrategy == .startEnd && !cap.supportsKeyframeEnd {
                out.append(Finding(level: .error, code: "KEYFRAME_END_NOT_SUPPORTED", shotId: shot.id,
                    message: "\(model) doesn't support an end keyframe."))
            }
            if shot.characterRefs.count > cap.maxCharactersInFrame {
                out.append(Finding(level: .warn, code: "TOO_MANY_CHARACTERS", shotId: shot.id,
                    message: "\(shot.characterRefs.count) characters > \(model) stable max "
                        + "\(cap.maxCharactersInFrame)."))
            }
        }
        if let brief = ctx.brief,
           let aspect = AspectResolver.resolveBriefAspect(
               aspectRatio: brief.aspectRatio.rawValue, aspectOther: brief.aspectRatioOther) {
            var used = Set<String>()
            for shot in ctx.shotlist.shots { used.insert(costs.runwayModel(for: shot, phase: .final)) }
            for model in used.sorted() {
                guard let cap = ModelCapabilities.capability(model) else { continue }
                if AspectResolver.resolveForModel(aspect, supportedRatios: cap.supportedRatios) == nil {
                    out.append(Finding(level: .error, code: "RATIO_NOT_SUPPORTED",
                        message: "aspect \(aspect) isn't supported by \(model) "
                            + "(supported: \(cap.supportedRatios.joined(separator: ", ")))."))
                }
            }
        }
        return out
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
