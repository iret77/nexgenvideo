import Foundation
import NexGenEngine

// Batch 2 sanity checks — faithful ports of the self-contained `sanity/checks/`
// modules that read only shotlist/brief/bible data. Finding `code` strings and
// severities are byte-identical to the Python. Helpers are `b2`-prefixed to
// avoid redeclaration across the other check files.
//
// (expanding_camera now lives in ExpandingCamera.swift — its blocker, a model-capability registry, is
// resolved via CostsConfig.bundledDefault.runwayModel + ModelCapabilities.supportsKeyframeEnd.)
extension MusicvideoChecks {

    // MARK: - provider_consistency.py (Block 17)

    /// Provider/Seedance-input-mode consistency. Reference-mode is fal-only,
    /// needs at least one image reference, its declared bible IDs must resolve,
    /// and it ignores keyframe_strategy. Port of
    /// `sanity/checks/provider_consistency.py`.
    public static let providerConsistencyCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        let bible = ctx.bible
        for shot in ctx.shotlist.shots {
            guard shot.seedanceInputMode == .reference else { continue }

            // 1. Reference-Mode nur auf fal.
            if shot.sceneVideoProvider != .fal {
                out.append(Finding(level: .error, code: "REFERENCE_MODE_REQUIRES_FAL", shotId: shot.id,
                    message: "Shot hat seedance_input_mode=reference, aber "
                        + "scene_video_provider=\(shot.sceneVideoProvider.rawValue). "
                        + "Reference-Mode (Multi-Image-Refs per @image1-Mention) ist "
                        + "NUR ueber fal.ai verfuegbar — Runway exposed den Modus "
                        + "nicht. Entweder Provider auf fal aendern ODER Mode auf "
                        + "keyframe."))
            }

            // 2. Reference-Mode braucht Refs.
            let hasRefs = !shot.characterRefs.isEmpty
                || (shot.locationRef.map { !$0.isEmpty } ?? false)
                || !shot.propRefs.isEmpty
                || !shot.referenceImageRefs.isEmpty
            if !hasRefs {
                out.append(Finding(level: .error, code: "REFERENCE_MODE_NEEDS_REFS", shotId: shot.id,
                    message: "Shot hat seedance_input_mode=reference, aber weder "
                        + "character_refs/location_ref/prop_refs noch explizite "
                        + "reference_image_refs gesetzt. Im Reference-Mode braucht "
                        + "fal mindestens eine Image-Ref — sonst gibt es nichts, "
                        + "worauf das Modell die Identitaet locken koennte."))
            }

            // 2b. Deklarierte Bible-IDs muessen in der Bible existieren.
            if let bible, hasRefs {
                var missing: [String] = []
                let charIds = Set(bible.characters.map(\.id))
                let locIds = Set(bible.locations.map(\.id))
                let propIds = Set(bible.props.map(\.id))
                for cid in shot.characterRefs where !charIds.contains(cid) {
                    missing.append("character_refs['\(cid)']")
                }
                if let loc = shot.locationRef, !loc.isEmpty, !locIds.contains(loc) {
                    missing.append("location_ref['\(loc)']")
                }
                for pid in shot.propRefs where !propIds.contains(pid) {
                    missing.append("prop_refs['\(pid)']")
                }
                if !missing.isEmpty {
                    out.append(Finding(level: .error, code: "REFERENCE_MODE_BIBLE_ID_UNRESOLVED",
                        shotId: shot.id,
                        message: "Shot referenziert Bible-IDs, die NICHT in der "
                            + "Bible existieren: \(missing). Der Resolver wuerde "
                            + "diese Refs ueberspringen und der fal-Wrapper "
                            + "raised zur Render-Zeit 'braucht mindestens eine "
                            + "Reference'. Entweder die Bible erweitern (Sheets "
                            + "fuer die fehlenden IDs anlegen) oder die "
                            + "Shotlist-Refs korrigieren."))
                }
            }

            // 3. Reference-Mode ignoriert keyframe_strategy.
            if shot.keyframeStrategy != .none {
                out.append(Finding(level: .info, code: "REFERENCE_MODE_IGNORES_KEYFRAME",
                    shotId: shot.id,
                    message: "Shot hat seedance_input_mode=reference und "
                        + "keyframe_strategy=\(shot.keyframeStrategy.rawValue). "
                        + "Im Reference-Mode wird `keyframe_strategy` IGNORIERT — "
                        + "fal nimmt die Bible-Sheets per @image1-Mention als "
                        + "Anker, kein Frame wird gerendert. Setze "
                        + "keyframe_strategy=none, damit das Schema die Wahrheit "
                        + "abbildet und die Frame-Phase nichts versucht zu "
                        + "produzieren."))
            }
        }
        return out
    }

    // MARK: - reference_mode_prompt.py (Block 23)

    /// Reference-mode prompt discipline: identity redundancy, verbose settings,
    /// name-not-@ImageN-tag usage, and story proper nouns in the visual_prompt.
    /// Port of `sanity/checks/reference_mode_prompt.py`.
    public static let referenceModePromptCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        let bible = ctx.bible
        for shot in ctx.shotlist.shots {
            guard shot.seedanceInputMode == .reference else { continue }
            let vp = shot.visualPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if vp.isEmpty { continue }
            let notes = shot.notes ?? ""
            let charNames = b2BibleCharNames(bible, shot.characterRefs)
            let locName = b2BibleLocationName(bible, shot.locationRef)
            let locationNames = locName.map { [$0] } ?? []
            let propNames = b2BiblePropNames(bible, shot.propRefs)

            // 1. Identity-Redundanz pro Char-Name (nur 1 Finding pro Shot).
            if !b2Search(b2IdentityOk, notes) {
                for nm in charNames where b2IdentityPhraseMatches(nm, in: vp) {
                    out.append(Finding(level: .warn, code: "REFERENCE_MODE_IDENTITY_REDUNDANT",
                        shotId: shot.id,
                        message: "Shot \(shot.id) ist Reference-Mode "
                            + "(Bible-Sheet von '\(nm)' ist Anker), aber "
                            + "der visual_prompt enthaelt Identitaets-"
                            + "Beschreibung direkt nach dem Namen "
                            + "(z.B. 'X, an upright humanoid grey cat "
                            + "with ...', 'X wears ...', 'X, dressed "
                            + "in ...'). Diese Beschreibung untergewichtet "
                            + "die Refs und kann den ByteDance-Filter "
                            + "triggern (lange Character-Beschreibungen "
                            + "sind empirisch ein Trigger). Empfehlung: "
                            + "Identitaet aus dem visual_prompt streichen "
                            + "— Sheets tragen sie. Im visual_prompt nur "
                            + "die Aktion stehen lassen "
                            + "('X walks in from the right and holds "
                            + "out the bouquet'). Escape: "
                            + "`ref_identity_ok: <Grund>` in Shot.notes, "
                            + "wenn die Beschreibung wirklich neue Info "
                            + "traegt (z.B. Outfit-Wechsel im Shot)."))
                    break
                }
            }

            // 2. Verbose Setting bei vorhandenem location_ref.
            if let loc = shot.locationRef, !loc.isEmpty,
               !b2Search(b2SettingOk, notes), b2Search(b2VerboseSetting, vp) {
                out.append(Finding(level: .warn, code: "REFERENCE_MODE_VERBOSE_SETTING",
                    shotId: shot.id,
                    message: "Shot \(shot.id) ist Reference-Mode mit "
                        + "location_ref='\(loc)', aber der "
                        + "visual_prompt enthaelt eine detaillierte Setting-"
                        + "Beschreibung (Komma-Liste mit 3+ Items, z.B. "
                        + "Architektur-Aufzaehlung oder beschreibende "
                        + "Hintergrund-Elemente). Heuristik unterscheidet "
                        + "nicht zwischen Architektur und Farb-/Atmosphaere-"
                        + "Listen — beides bindet den Renderer an Text-"
                        + "Inhalte, die der Location-Reference visuell "
                        + "ohnehin tragt. Text-Verdopplung untergewichtet "
                        + "die Ref und kann Konflikte mit dem Sheet-Stand "
                        + "erzeugen. Empfehlung: detaillierte Listen aus "
                        + "dem visual_prompt streichen, nur Action/Camera/"
                        + "Light beibehalten. Escape: `ref_setting_ok: "
                        + "<Grund>` in Shot.notes, wenn ein bestimmtes "
                        + "Detail unbedingt im Prompt stehen muss."))
            }

            // 3a. Bible-Char-Namen im Prompt OHNE entsprechende @ImageN-Tags.
            if !b2Search(b2TagsOk, notes) {
                let hasTags = b2Search(b2AtTagRe, vp)
                let namedChars = charNames.filter { b2WordMatches($0, in: vp) }
                if !namedChars.isEmpty, !hasTags {
                    out.append(Finding(level: .warn, code: "REFERENCE_MODE_USES_NAMES_NOT_TAGS",
                        shotId: shot.id,
                        message: "Shot \(shot.id) ist Reference-Mode und "
                            + "visual_prompt nennt Bible-Char-Namen "
                            + "(\(namedChars)), aber KEINE @ImageN-Tags. "
                            + "Der Project-Agent kennt die Resolver-"
                            + "Reihenfolge (character_refs[0] → @Image1, "
                            + "[1] → @Image2, dann location_ref → "
                            + "@Image{n+1}, dann prop_refs). Im Reference-"
                            + "Mode sollte er direkt @ImageN-Tags im "
                            + "visual_prompt schreiben — der Seedance-"
                            + "Filter bindet die Refs ueber die Tags, "
                            + "Namen im Text sind redundant (s. "
                            + "REFERENCE_MODE_IDENTITY_REDUNDANT) und "
                            + "fuehren bei Multi-Char-Shots zu falscher "
                            + "Akteur-Zuordnung. Beispiel: statt "
                            + "'Claude Mouse waves while AI Cat watches' "
                            + "schreibt der Agent "
                            + "'@Image2 waves while @Image1 watches'. "
                            + "Escape: `ref_tags_ok: <Grund>` (z.B. fuer "
                            + "Bestands-Shotlists in Migrations-Phase)."))
                }
            }

            // 3. Story-Eigennamen (info — false-positive-Risiko hoch).
            if !b2Search(b2NamesOk, notes) {
                let properNouns = b2ProperNounFindings(
                    vp, charNames: charNames, locationNames: locationNames, propNames: propNames)
                if !properNouns.isEmpty {
                    out.append(Finding(level: .info, code: "REFERENCE_MODE_STORY_PROPER_NOUNS",
                        shotId: shot.id,
                        message: "Shot \(shot.id): visual_prompt enthaelt "
                            + "Title-Case-Mehrwort-Phrasen "
                            + "(\(properNouns)), die wie Story-Eigennamen "
                            + "aussehen (Ortsnamen, Marken, Titel). Wenn "
                            + "diese Worte im Bild NICHT sichtbar sind "
                            + "(z.B. 'Silicon Gulch' ohne Schild), gehoeren "
                            + "sie nicht in den Provider-Prompt — das Modell "
                            + "versucht sie zu interpretieren und drueckt "
                            + "Render-Budget in unsichtbare Tokens. Wenn "
                            + "der Name als Schild/Tafel im Bild stehen "
                            + "soll, ist es ok — Escape: `ref_names_ok: "
                            + "<Grund>` in Shot.notes."))
                }
            }
        }
        return out
    }

    // MARK: - literal_check.py (via prompts.py wiring)

    /// Literality + bible completeness on shot prompts: metaphors rendered
    /// literally, undefined crowds, and title cards / text overlays. Port of the
    /// three literal_check findings wired from `sanity/checks/prompts.py`
    /// (PROMPT_TOO_SHORT/THIN/GENERIC and NO_BLOCKING_AT_T0 stay in their own
    /// checks and are out of scope here).
    public static let literalCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        let bible = ctx.bible
        let allowOverlays = ctx.brief?.allowTextOverlays ?? false
        let ensembleIds: Set<String> = bible.map { Set($0.ensembles.map(\.id)) } ?? []
        for shot in ctx.shotlist.shots {
            let combined = "\(shot.visualPrompt)\n\(shot.description)\n\(shot.notes ?? "")"

            // 1. Metaphorische Sprache (ein Finding pro Pattern-Treffer).
            for hit in b2MetaphorFindings(combined) {
                out.append(Finding(level: .warn, code: "METAPHORICAL_PROMPT", shotId: shot.id,
                    message: "\(hit.message)  ['\(hit.excerpt)']"))
            }

            // 2. Undefinierte Gruppe / Crowd. Ensemble-IDs duerfen in
            // character_refs stehen (prompts.py-Verdrahtung); ein separates
            // ensemble_refs-Feld existiert im Schema nicht.
            let ensemblesViaChars = shot.characterRefs.filter { ensembleIds.contains($0) }
            if let ug = b2UndefinedGroup(
                visualPrompt: shot.visualPrompt, description: shot.description,
                ensembleRefs: ensemblesViaChars) {
                out.append(Finding(level: .error, code: "UNDEFINED_GROUP", shotId: shot.id,
                    message: "\(ug.message)  ['\(ug.excerpt)']"))
            }

            // 3. Title Cards / Text-Overlays.
            if let th = b2TitleCardHits(text: combined, allowTextOverlays: allowOverlays) {
                out.append(Finding(level: .warn, code: "TITLE_CARD_USED", shotId: shot.id,
                    message: "\(th.message)  ['\(th.excerpt)']"))
            }
        }
        return out
    }

    // MARK: - plausibility.py (+ plausibility_check.py, Block 7f)

    /// Motion-plausibility heuristic: a shot introduces a figure via a
    /// direction phrase ("enters from the left") without a `plausibility_ok:`
    /// note attesting the location geometry allows it. Port of
    /// `sanity/checks/plausibility.py` + `sanity/plausibility_check.py`.
    public static let plausibilityCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        for shot in ctx.shotlist.shots {
            if b2Search(b2PlausibilityOk, shot.notes ?? "") { continue }
            let text = shot.visualPrompt + " " + (shot.motion ?? "")
            var phrases: [String] = []
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let re = b2DePattern {
                for m in re.matches(in: text, range: full) { phrases.append(ns.substring(with: m.range)) }
            }
            if let re = b2EnPattern {
                for m in re.matches(in: text, range: full) { phrases.append(ns.substring(with: m.range)) }
            }
            guard let first = phrases.first else { continue }
            out.append(Finding(level: .warn, code: "PLAUSIBILITY_UNCHECKED", shotId: shot.id,
                message: "Shot \(shot.id) fuehrt eine Figur ueber eine Richtungs-"
                    + "Phrase ein ('\(first)'). Geometrie der Location pruefen: "
                    + "kann die Figur dort tatsaechlich her kommen (Tuer, Eingang, "
                    + "freier Rand)? Wenn ja: `plausibility_ok: <kurzer Grund>` in "
                    + "Shot.notes vermerken, dann verstummt der Warn. Wenn nein: "
                    + "Eintritts-Richtung aendern."))
        }
        return out
    }

    // MARK: - Helpers (b2-prefixed)

    private static func b2Marker(_ key: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "\\b\(key)\\s*:", options: [.caseInsensitive])
    }

    private static func b2Search(_ re: NSRegularExpression?, _ text: String) -> Bool {
        guard let re, !text.isEmpty else { return false }
        let ns = text as NSString
        return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// `\bnm\b` case-insensitive membership of a bible name in the prompt.
    private static func b2WordMatches(_ name: String, in text: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let ns = text as NSString
        return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    // reference_mode_prompt.py escape markers + tag/setting patterns.
    private static let b2IdentityOk = b2Marker("ref_identity_ok")
    private static let b2SettingOk = b2Marker("ref_setting_ok")
    private static let b2NamesOk = b2Marker("ref_names_ok")
    private static let b2TagsOk = b2Marker("ref_tags_ok")
    private static let b2AtTagRe = try! NSRegularExpression(
        pattern: #"@(?:Image|Video|Audio)\d+"#, options: [.caseInsensitive])
    private static let b2VerboseSetting = try? NSRegularExpression(
        pattern: #"(?:row of\s+\w+|line of\s+\w+|(?:a|an|the)\s+(?:\w+\s+){0,2}\w+(?:,\s+(?:a|an|the)\s+(?:\w+\s+){0,2}\w+){2,})"#,
        options: [.caseInsensitive])
    private static let b2ProperNounPhrase = try? NSRegularExpression(
        pattern: #"(?<!^)(?<![\.\?\!]\s)\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3})\b"#)

    /// Port of `_PROPER_NOUN_ALLOWLIST`.
    private static let b2ProperNounAllowlist: Set<String> = [
        "AI Cat", "Claude Mouse",
        "Wide Shot", "Full Shot", "Medium Shot", "Medium Close",
        "Close Up", "Close-Up", "Extreme Close", "Extreme Close-Up",
        "Over Shoulder", "Over The Shoulder", "Insert Shot", "Aerial Shot",
        "Establishing Shot", "Long Shot", "Master Shot",
        "Golden Hour", "Magic Hour", "Blue Hour", "Harsh Noon",
        "Warm Light", "Cool Light", "Soft Light", "Hard Light",
        "Natural Light", "Backlit Silhouette", "Key Light", "Fill Light",
        "Rim Light",
        "Eye Level", "Low Angle", "High Angle", "Bird Eye", "Worm Eye",
        "Dutch Angle", "Three Quarter", "Three-Quarter",
        "Rule Of Thirds", "Shallow Depth", "Deep Focus",
        "Day Exterior", "Night Exterior", "Day Interior", "Night Interior",
    ]

    /// Port of `_primary_name`: reduce a bible `name` to its main part.
    private static func b2PrimaryName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        for sep in ["(", ",", "/", " — ", " - "] {
            if let r = s.range(of: sep) {
                s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    private static func b2BibleCharNames(_ bible: Bible?, _ charRefs: [String]) -> [String] {
        guard let bible, !charRefs.isEmpty else { return [] }
        var names: [String] = []
        for cid in charRefs {
            guard let ch = bible.characters.first(where: { $0.id == cid }) else { continue }
            let nm = b2PrimaryName(ch.name)
            if !nm.isEmpty { names.append(nm) }
        }
        return names
    }

    private static func b2BibleLocationName(_ bible: Bible?, _ locationRef: String?) -> String? {
        guard let bible, let locationRef, !locationRef.isEmpty else { return nil }
        guard let loc = bible.locations.first(where: { $0.id == locationRef }) else { return nil }
        let nm = b2PrimaryName(loc.name)
        return nm.isEmpty ? nil : nm
    }

    private static func b2BiblePropNames(_ bible: Bible?, _ propRefs: [String]) -> [String] {
        guard let bible, !propRefs.isEmpty else { return [] }
        var names: [String] = []
        for pid in propRefs {
            guard let pr = bible.props.first(where: { $0.id == pid }) else { continue }
            let nm = b2PrimaryName(pr.name)
            if !nm.isEmpty { names.append(nm) }
        }
        return names
    }

    /// Port of `_identity_phrase_after(name).search(vp)`.
    private static func b2IdentityPhraseMatches(_ name: String, in text: String) -> Bool {
        let nm = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\b" + nm + "\\b\\s*(?:"
            + ",\\s+(?:an?|the)\\s+(?:\\w+\\s+){0,6}(?:with|wearing|in)\\b"
            + "|,\\s+(?:dressed|clad)\\s+in\\b"
            + "|\\s+(?:wears?|wearing)\\b"
            + ")"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let ns = text as NSString
        return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Port of `_proper_noun_findings`.
    private static func b2ProperNounFindings(
        _ text: String, charNames: [String], locationNames: [String], propNames: [String]
    ) -> [String] {
        guard let re = b2ProperNounPhrase else { return [] }
        var allowlist = b2ProperNounAllowlist
        allowlist.formUnion(charNames)
        allowlist.formUnion(locationNames)
        allowlist.formUnion(propNames)
        var found: [String] = []
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let phrase = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if allowlist.contains(phrase) { continue }
            if allowlist.contains(where: { !$0.isEmpty && phrase.contains($0) }) { continue }
            if found.contains(phrase) { continue }
            found.append(phrase)
        }
        return found
    }

    // literal_check.py metaphor patterns (matched on lowercased text).
    private static let b2MetaphorPatterns: [(NSRegularExpression, String)] = {
        let raw: [(String, String)] = [
            (#"\b(im uebertragenen sinn(e)?|im übertragenen sinn(e)?|metaphorisch|symbolisch|im sinne von|bildlich gesprochen|abstrakt gesprochen)\b"#,
             "Marker fuer uebertragene Bedeutung - Video-Modell rendert woertlich. "
                + "Beschreibe konkret, was zu sehen ist."),
            (#"\b(fegt|fegen|wischt weg|loescht aus|löscht aus|putzt weg)\s+\w+\s+\b(raus|aus|weg)\b"#,
             "'fegen/ausloeschen/wegputzen + raus/weg' - wenn das nicht woertlich "
                + "gemeint ist (echter Besen, echte Bewegung), dann durch die konkrete "
                + "sichtbare Handlung ersetzen."),
            (#"\b(briefe|aufgaben|akten|gedanken|geld|ideen|sorgen)\s+\b(fliegen|fliegt|fliegend)\b"#,
             "Nicht-fliegfaehiges Subjekt + 'fliegen' - Modell rendert das woertlich. "
                + "Wenn wirklich fliegende Briefe gemeint sind: ok. Sonst durch konkrete "
                + "Bewegung ersetzen (auf den Tisch geworfen, gestapelt, etc.)."),
            (#"\b(funkeln|sterne)\s+in\s+(den\s+)?(augen|herzen)\b"#,
             "Klassische Anime-Metapher - kann bei `visual_medium=2d_animation` "
                + "gewollt sein; bei live_action/realistisch Slop. Konsumenten muessen "
                + "den Kontext pruefen."),
            (#"\bschmetterlinge\s+im\s+bauch\b"#,
             "Idiom, nicht woertlich. Konkrete sichtbare Aktion stattdessen."),
            (#"\b(herzsymbol|herz-symbol|herz symbol)\b"#,
             "Symbolisches Herz - bei realistischem visual_medium fragwuerdig, "
                + "Modell koennte ein gezeichnetes Herz halluzinieren."),
        ]
        var out: [(NSRegularExpression, String)] = []
        for (pat, msg) in raw {
            if let re = try? NSRegularExpression(pattern: pat) { out.append((re, msg)) }
        }
        return out
    }()

    /// Port of `find_metaphor_hits`. One hit per matching pattern; excerpt is a
    /// ±20-char window of the original text around the match.
    private static func b2MetaphorFindings(_ text: String) -> [(message: String, excerpt: String)] {
        var out: [(String, String)] = []
        if text.isEmpty { return out }
        let lower = text.lowercased()
        let lowerNS = lower as NSString
        let origNS = text as NSString
        let full = NSRange(location: 0, length: lowerNS.length)
        for (re, msg) in b2MetaphorPatterns {
            guard let m = re.firstMatch(in: lower, range: full) else { continue }
            let s = min(max(0, m.range.location - 20), origNS.length)
            let e = min(max(s, m.range.location + m.range.length + 20), origNS.length)
            let excerpt = origNS.substring(with: NSRange(location: s, length: e - s))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append((msg, excerpt))
        }
        return out
    }

    /// Port of `GENERIC_PERSON_PHRASES`.
    private static let b2GenericPersonPhrases = [
        "crowd", "menge", "zuschauer", "publikum", "zuschauermenge",
        "statisten", "passanten", "passantinnen", "leute",
        "spectators", "audience", "bystanders", "extras",
    ]

    /// Port of `find_undefined_groups`. Returns a finding only when a generic
    /// person phrase is present AND no ensemble is referenced.
    private static func b2UndefinedGroup(
        visualPrompt: String, description: String, ensembleRefs: [String]
    ) -> (message: String, excerpt: String)? {
        let text = (visualPrompt + " " + description).lowercased()
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for phrase in b2GenericPersonPhrases {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            if re.firstMatch(in: text, range: full) != nil {
                if ensembleRefs.isEmpty {
                    let msg = "Personen-Gruppe '\(phrase)' im Prompt, aber kein "
                        + "ensemble_refs gesetzt - die KI erfindet eine "
                        + "beliebige Crowd. Definiere ein Ensemble in der "
                        + "Bible und referenziere es."
                    return (msg, phrase)
                }
            }
        }
        return nil
    }

    // literal_check.py title-card patterns.
    private static let b2TitleCardPatterns: [NSRegularExpression] = [
        #"\btitle\s*card\b"#, #"\btitel-?karte\b"#, #"\btext-?overlay\b"#,
        #"\btext-?einblendung\b"#, #"\bschrift-?einblendung\b"#, #"\bschrift-?tafel\b"#,
        #"\btext-?tafel\b"#, #"\binsert(-|\s)title\b"#, #"\bbauchbinde\b"#, #"\blower\s+third\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Port of `TITLE_CARD_QUOTED_PATTERN` (case-sensitive — targets ALL-CAPS).
    private static let b2TitleCardQuoted = try? NSRegularExpression(
        pattern: "[\"'„“”‘’‚][A-ZÄÖÜ][A-ZÄÖÜ\\s!?]{3,80}[!?][\"'„“”‘’‚]")

    /// Port of `find_title_card_hits` + `_title_finding` (at most one per shot).
    private static func b2TitleCardHits(
        text: String, allowTextOverlays: Bool
    ) -> (message: String, excerpt: String)? {
        if allowTextOverlays { return nil }
        if text.isEmpty { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for re in b2TitleCardPatterns {
            if let m = re.firstMatch(in: text, range: full) {
                return b2TitleFinding(text: text, matchRange: m.range, hint: "")
            }
        }
        if let re = b2TitleCardQuoted, let m = re.firstMatch(in: text, range: full) {
            return b2TitleFinding(
                text: text, matchRange: m.range, hint: "ALL-CAPS-Phrase in Quotes mit '!'")
        }
        return nil
    }

    private static func b2TitleFinding(
        text: String, matchRange: NSRange, hint: String
    ) -> (message: String, excerpt: String) {
        let ns = text as NSString
        let s = min(max(0, matchRange.location - 10), ns.length)
        let e = min(max(s, matchRange.location + matchRange.length + 30), ns.length)
        let excerpt = ns.substring(with: NSRange(location: s, length: e - s))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var base = "Title Card / Text-Overlay erkannt - Video-Modelle rendern Text "
            + "schlecht. Wenn das Konzept Text-Overlays braucht: "
            + "`brief.allow_text_overlays = true` setzen. Sonst durch sichtbare "
            + "Aktion ersetzen."
        if !hint.isEmpty { base += " (\(hint))" }
        return (base, excerpt)
    }

    // plausibility_check.py escape marker + motion-phrase patterns.
    private static let b2PlausibilityOk = b2Marker("plausibility_ok")
    private static let b2DePattern = try? NSRegularExpression(
        pattern: #"\b(kommt|kommen|tritt(?:\s+ein)?|stuermt|stürmt|laeuft|läuft|rennt|schiebt\s+sich|gleitet|erscheint|taucht\s+auf)\s+(?:von|aus|durch)\s+(?:der\s+|dem\s+|den\s+)?(links|rechts|hinten|vorne|hinter\s+der\s+kamera|aus\s+dem\s+(?:hintergrund|vordergrund)|durch\s+die\s+(?:tür|tuer|wand|fenster)|von\s+oben|von\s+unten)\b"#,
        options: [.caseInsensitive])
    private static let b2EnPattern = try? NSRegularExpression(
        pattern: #"\b(enters?|comes?|walks?\s+in|runs?\s+in|appears?|emerges?|steps?\s+in)\s+(?:from\s+(?:the\s+)?|through\s+the\s+)?(left|right|behind|background|foreground|through\s+the\s+(?:door|wall|window)|above|below|off-screen)\b"#,
        options: [.caseInsensitive])
}
