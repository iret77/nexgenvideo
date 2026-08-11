import Foundation
import NexGenEngine

// Block 7a-e: spatial/compositional sanity — world-zone tracking + cut grammar.
// Port of `sanity/checks/composition.py`. The framing-risk tables it depends on
// (`FRAMING_RISK`, `FRAMING_SCALE`, `SPECIAL_FRAMINGS`, `RISKY_FRAMING_LENS`) have
// no engine port yet, so their pure constant data is ported here as helpers.
extension MusicvideoChecks {
    public static let compositionCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        let shots = ctx.shotlist.shots

        // 7a. Framing + zone tracking.
        if let bible = ctx.bible {
            var locById: [String: Location] = [:]
            for loc in bible.locations { locById[loc.id] = loc }
            var establishedByLocation: [String: [String: String]] = [:]
            for shot in shots {
                if let framing = shot.framing {
                    if compRequiresVisibleZones(framing) && shot.visibleZones.isEmpty {
                        out.append(Finding(level: .warn, code: "VISIBLE_ZONES_MISSING", shotId: shot.id,
                            message: "framing=\(framing.rawValue) (bg_coverage=\(compBgCoverage(framing))) "
                                + "requires visible_zones, but it's empty. List the visible location zones "
                                + "explicitly."))
                    }
                } else {
                    out.append(Finding(level: .warn, code: "FRAMING_MISSING", shotId: shot.id,
                        message: "no framing set — image crop undefined. Choose "
                            + "WIDE/MS/MCU/CU/ECU/OTS/POV/INSERT/AERIAL."))
                }
                if let locRef = shot.locationRef, let loc = locById[locRef], !shot.visibleZones.isEmpty {
                    var zoneById: [String: Zone] = [:]
                    for z in loc.zones { zoneById[z.id] = z }
                    for zid in shot.visibleZones {
                        guard let zone = zoneById[zid] else {
                            out.append(Finding(level: .warn, code: "ZONE_UNDEFINED", shotId: shot.id,
                                message: "visible_zone \"\(zid)\" is not defined in bible location "
                                    + "\"\(loc.id)\".zones. Fix the zone inventory or the visible_zones."))
                            continue
                        }
                        let established = zone.status == .dirty
                            ? (zone.establishedByShot ?? "?")
                            : establishedByLocation[locRef]?[zid]
                        if let established {
                            out.append(Finding(level: .error, code: "DIRTY_ZONE_VISIBLE", shotId: shot.id,
                                message: "visible_zone \"\(zid)\" is already established in shot "
                                    + "\(established). A "
                                    + "follow-up shot would break consistency. Change framing to drop the "
                                    + "zone, or pull the establishing frame (\(established)) in as a reference."))
                        } else if zone.status == .undefined,
                                  !shot.zoneIntroduces.contains(zid) {
                            out.append(Finding(level: .warn, code: "ZONE_UNCOVERED", shotId: shot.id,
                                message: "visible_zone \"\(zid)\" is undefined — the model hallucinates the "
                                    + "area freely. Declare it in zone_introduces or add a bible asset."))
                        }
                    }
                }
                if let locRef = shot.locationRef {
                    for zoneID in shot.zoneIntroduces {
                        establishedByLocation[locRef, default: [:]][zoneID] = shot.id
                    }
                }
            }
        }

        // 7b. Framing monoculture (multicam exempt).
        if ctx.shotlist.mode != .multicam {
            var bySection: [String: [Shot]] = [:]
            var order: [String] = []
            for shot in shots {
                let key = shot.section ?? "_unsectioned"
                if bySection[key] == nil { order.append(key) }
                bySection[key, default: []].append(shot)
            }
            for secName in order {
                let secShots = bySection[secName]!
                let framings: [(id: String, framing: Framing)] = secShots.compactMap { s in
                    s.framing.map { (s.id, $0) }
                }
                if framings.count < 3 { continue }
                // Run-of-the-same: 3+ in a row is clearly monoculture.
                var run = 1
                for i in 1..<framings.count {
                    if framings[i].framing == framings[i - 1].framing {
                        run += 1
                        if run >= 3 {
                            out.append(Finding(level: .warn, code: "FRAMING_MONOKULTUR",
                                shotId: framings[i].id,
                                message: "section \"\(secName)\": >=3 shots in a row with "
                                    + "framing=\(framings[i].framing.rawValue) — no visual variety. Vary the "
                                    + "framing choreography."))
                            break
                        }
                    } else {
                        run = 1
                    }
                }
                // Majority: 60% at min 3 shots.
                let framingValues = framings.map { $0.framing }
                if let (common, commonCount) = compMostCommonFraming(framingValues),
                   Double(commonCount) / Double(framingValues.count) >= 0.6, commonCount >= 3 {
                    out.append(Finding(level: .warn, code: "FRAMING_MONOKULTUR", shotId: nil,
                        message: "section \"\(secName)\": \(commonCount)/\(framingValues.count) shots with "
                            + "framing=\(common.rawValue) (>=60%). Crop too monotone — plan varied framings."))
                }
            }
        }

        // 7b2. Two consecutive shots, same location AND same establishing framing.
        if ctx.shotlist.mode != .multicam {
            var prevShot: Shot?
            for shot in shots {
                guard let prev = prevShot else { prevShot = shot; continue }
                let cutOk = (shot.notes ?? "").lowercased().contains("cut_ok:")
                let sameLoc = shot.locationRef != nil && shot.locationRef == prev.locationRef
                let sameSection = shot.section == prev.section
                let sameFraming = shot.framing != nil && shot.framing == prev.framing
                if !cutOk, sameLoc, sameSection, sameFraming,
                   let f = shot.framing, compEstablishingFramings.contains(f) {
                    out.append(Finding(level: .error, code: "CONSECUTIVE_SAME_LOCATION_WIDE",
                        shotId: shot.id,
                        message: "shot \(shot.id): same location (\"\(shot.locationRef ?? "")\") AND same "
                            + "establishing framing (\(f.rawValue)) as predecessor \(prev.id). Two "
                            + "near-identical wides in a row — switch framing (push in to MS/MCU/CU or a "
                            + "detail INSERT), switch location, or drop the second shot. Really intended? "
                            + "`cut_ok: redundant_intentional` in notes."))
                }
                prevShot = shot
            }
        }

        // 7c. Camera setup.
        if ctx.shotlist.mode != .multicam {
            var lastTriplet: (CameraHeight, CameraAngle, LensHint)?
            var run = 1
            for shot in shots {
                guard let cs = shot.cameraSetup else {
                    out.append(Finding(level: .warn, code: "CAMERA_SETUP_MISSING", shotId: shot.id,
                        message: "no camera_setup set — the model's composition defaults (frontal, "
                            + "eye-level, normal lens) take over and shots look uniform. Specify "
                            + "height/angle/lens."))
                    lastTriplet = nil
                    run = 1
                    continue
                }
                if let f = shot.framing, compIsRiskyLens(f, cs.lensHint) {
                    out.append(Finding(level: .warn, code: "CAMERA_LENS_RISKY_FOR_FRAMING", shotId: shot.id,
                        message: "framing=\(f.rawValue) + lens=\(cs.lensHint.rawValue) is a known "
                            + "artifact-prone combination. Review, and switch the lens if needed."))
                }
                let triplet = (cs.height, cs.angle, cs.lensHint)
                if let lt = lastTriplet, lt == triplet {
                    run += 1
                    if run >= 4 {
                        out.append(Finding(level: .warn, code: "CAMERA_SETUP_MONOKULTUR", shotId: shot.id,
                            message: ">=4 shots in a row with identical camera_setup "
                                + "(\(cs.height.rawValue)/\(cs.angle.rawValue)/\(cs.lensHint.rawValue)). "
                                + "Vary the composition — change angle or height."))
                        run = 1
                    }
                } else {
                    run = 1
                }
                lastTriplet = triplet
            }
        }

        // 7d. Character blocking.
        for shot in shots {
            if !shot.characterBlocking.isEmpty {
                let covered = Set(shot.characterBlocking.map { $0.characterRef })
                let missing = Set(shot.characterRefs).subtracting(covered)
                if !missing.isEmpty {
                    out.append(Finding(level: .warn, code: "BLOCKING_INCOMPLETE", shotId: shot.id,
                        message: "character_blocking doesn't cover all character_refs (missing: "
                            + "\(missing.sorted())). The model fills in the default position."))
                }
                for cb in shot.characterBlocking
                where cb.gaze.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unspecified" {
                    out.append(Finding(level: .warn, code: "GAZE_UNSPECIFIED", shotId: shot.id,
                        message: "character_blocking[\"\(cb.characterRef)\"].gaze is 'unspecified'. Models "
                            + "fall back to 'frontal into camera'. Set the gaze direction explicitly ('at "
                            + "notebook', 'toward Mark', 'into camera', 'down at floor')."))
                }
            } else if ProductionDiscipline.visibleCharacterCount(shot, bible: ctx.bible) >= 2 {
                let visibleCharacterCount = ProductionDiscipline.visibleCharacterCount(
                    shot,
                    bible: ctx.bible
                )
                out.append(Finding(level: .warn, code: "MISSING_CHARACTER_BLOCKING", shotId: shot.id,
                    message: "shot with \(visibleCharacterCount) characters but no character_blocking. The "
                        + "model arranges the composition itself — typical slop (characters frontal/centered, "
                        + "set re-arranged). Set position/pose/gaze/set-relation per character."))
            }
        }

        // 7e. Cut grammar.
        // A true jump cut = same framing AND same perspective (height + axis) on
        // the same subject/location/section. Avoid by changing either one.
        if ctx.shotlist.mode != .multicam {
            var prev: Shot?
            var prevSection: String?
            for shot in shots {
                let cutOk = (shot.notes ?? "").lowercased().contains("cut_ok:")
                guard let p = prev else {
                    prev = shot
                    prevSection = shot.section
                    continue
                }
                let sameSection = shot.section == p.section
                let sameLoc = shot.locationRef == p.locationRef && shot.locationRef != nil
                let overlapChars = !Set(shot.characterRefs).intersection(Set(p.characterRefs)).isEmpty
                let sameFraming = shot.framing != nil && shot.framing == p.framing
                let perspectiveKnown = shot.cameraSetup != nil && p.cameraSetup != nil
                let samePerspective = perspectiveKnown
                    && shot.cameraSetup!.height == p.cameraSetup!.height
                    && shot.cameraSetup!.angle == p.cameraSetup!.angle
                if !cutOk, sameSection, sameLoc, overlapChars, sameFraming,
                   (shot.framing.map { !compSpecialFramings.contains($0) } ?? false),
                   samePerspective || !perspectiveKnown {
                    out.append(Finding(level: .error, code: "JUMP_CUT_SAME_FRAMING", shotId: shot.id,
                        message: "shot \(shot.id) has identical framing (\(shot.framing!.rawValue)) AND "
                            + "perspective as predecessor \(p.id) — same section, location, overlapping "
                            + "characters. Classic jump cut. Avoid: change the framing (e.g. CU instead of "
                            + "MS) OR the perspective (camera_setup.height / .angle). Intended? "
                            + "`cut_ok: jump_cut_intentional` in notes."))
                } else if !cutOk, sameSection, sameLoc, overlapChars,
                          let sf = shot.framing, let pf = p.framing {
                    if let dist = compFramingDistance(sf, pf), dist == 1, samePerspective || !perspectiveKnown {
                        out.append(Finding(level: .warn, code: "JUMP_CUT_NEAR_FRAMING", shotId: shot.id,
                            message: "shot \(shot.id) has framing=\(sf.rawValue), predecessor \(p.id) "
                                + "framing=\(pf.rawValue) — only 1 step apart AND same perspective. Risky — "
                                + "widen the framing distance or vary the perspective (height/angle). "
                                + "`cut_ok: near_framing_intentional` silences this."))
                    }
                }
                let sectionChanged = shot.section != prevSection
                let locationChanged = shot.locationRef != p.locationRef
                if !cutOk, sectionChanged, locationChanged, let f = shot.framing,
                   !compEstablishingFramings.contains(f), !compSpecialFramings.contains(f) {
                    out.append(Finding(level: .info, code: "NO_ESTABLISHING_AT_SECTION_START",
                        shotId: shot.id,
                        message: "first shot of section \"\(shot.section ?? "")\" (location change) has "
                            + "framing=\(f.rawValue) instead of WIDE/FULL/AERIAL. Without an establishing "
                            + "shot the location change is hard to read. Intended? `cut_ok: no_establishing`."))
                }
                prev = shot
                prevSection = shot.section
            }
        }

        return out
    }

    // MARK: - Framing-risk tables (port of storyboard/framing_risk.py)

    private static let compSpecialFramings: Set<Framing> = [.ots, .pov, .insert, .aerial]
    private static let compEstablishingFramings: Set<Framing> = [.wide, .full, .aerial]

    /// Port of `FRAMING_RISK[f].requires_visible_zones`.
    private static func compRequiresVisibleZones(_ f: Framing) -> Bool {
        switch f {
        case .wide, .full, .ms, .ots, .pov, .aerial: return true
        case .mcu, .cu, .ecu, .insert: return false
        }
    }

    /// Port of `FRAMING_RISK[f].bg_coverage`.
    private static func compBgCoverage(_ f: Framing) -> String {
        switch f {
        case .wide, .full: return "full"
        case .ms: return "top_only"
        case .mcu: return "minimal"
        case .cu, .ecu, .insert: return "none"
        case .ots, .pov: return "target_zone"
        case .aerial: return "ground"
        }
    }

    /// Port of `RISKY_FRAMING_LENS` / `is_risky_lens`.
    private static func compIsRiskyLens(_ framing: Framing, _ lens: LensHint) -> Bool {
        switch (framing, lens) {
        case (.pov, .wide), (.ots, .long), (.wide, .long), (.ecu, .wide): return true
        default: return false
        }
    }

    /// Port of `FRAMING_SCALE`. `nil` for special framings (not linearly comparable).
    private static func compFramingScale(_ f: Framing) -> Int? {
        switch f {
        case .wide: return 0
        case .full: return 1
        case .ms: return 2
        case .mcu: return 3
        case .cu: return 4
        case .ecu: return 5
        default: return nil
        }
    }

    /// Port of `framing_distance`. `nil` when either framing is special (= axis change).
    private static func compFramingDistance(_ a: Framing, _ b: Framing) -> Int? {
        if compSpecialFramings.contains(a) || compSpecialFramings.contains(b) { return nil }
        guard let sa = compFramingScale(a), let sb = compFramingScale(b) else { return nil }
        return abs(sa - sb)
    }

    /// Port of `Counter(...).most_common(1)[0]`: highest count, first-seen wins ties.
    private static func compMostCommonFraming(_ values: [Framing]) -> (Framing, Int)? {
        var counts: [Framing: Int] = [:]
        var order: [Framing] = []
        for v in values {
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        var best: Framing?
        var bestCount = 0
        for f in order where counts[f]! > bestCount {
            best = f
            bestCount = counts[f]!
        }
        guard let b = best else { return nil }
        return (b, bestCount)
    }
}
