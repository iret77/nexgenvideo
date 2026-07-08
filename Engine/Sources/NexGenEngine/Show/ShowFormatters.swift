import Foundation

/// Markdown formatters for project artifacts, rendered directly into chat before
/// an approval gate. Port of `nexgen_engine/show/formatters.py`. German section
/// headers/labels are part of the display contract — the app renders them.
enum ShowFormatters {

    /// Regex-consistent with the dispatcher's still-only discipline: a bare
    /// substring match would flag `xstill_only_approved`. Port of `_STILL_ONLY_RE`.
    private static let stillOnlyPattern = #"\bstill_only_approved\s*:"#

    static func shorten(_ text: String, _ length: Int = 80) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count <= length ? t : String(t.prefix(length - 1)) + "…"
    }

    static func mmSS(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        let s = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(m):" + String(format: "%02d", s)
    }

    /// Port of Python's `f"{x:g}"`.
    private static func g(_ value: Double) -> String { String(format: "%g", value) }

    /// `paths.display_name`: the `project` field from `project.yaml`, else the
    /// project home's folder name.
    private static func displayName(_ dataRoot: URL) -> String {
        FrameInventory.projectName(of: dataRoot) ?? FrameInventory.projectHome(of: dataRoot).lastPathComponent
    }

    // MARK: - Brief

    static func showBrief(_ dataRoot: URL) throws -> String {
        let b = try YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: StudioLayout.briefFile)
        var lines: [String] = []
        lines.append("## Brief · \(b.project)")
        lines.append("")
        lines.append("| Feld | Wert |")
        lines.append("|---|---|")
        let missionOther = b.missionOther.map { " · \($0)" } ?? ""
        lines.append("| Mission | `\(b.mission.rawValue)`\(missionOther) → \(b.targetPlatform) |")
        if let audience = b.targetAudience, !audience.isEmpty {
            lines.append("| Zielpublikum | \(audience) |")
        }
        lines.append("| Format | \(b.aspectRatio.rawValue) · \(b.lengthMode) |")
        lines.append("| Modus | `\(b.projectMode)` |")
        let model = b.modelPreference.rawValue + (b.modelPreferenceOther.map { " · \($0)" } ?? "")
        lines.append("| Runway-Modell | \(model) |")
        let frameOther = b.frameImageModelOther.map { " · \($0)" } ?? ""
        lines.append("| Frame-Image-Modell | `\(b.frameImageModel.rawValue)`\(frameOther) |")
        lines.append("| Stems-Provider | `\(b.stemsProvider.rawValue)` |")
        lines.append("| Chord-Analyse | \(b.enableChordAnalysis ? "an" : "aus") |")
        lines.append("| Budget | \(String(format: "%.2f", b.budgetEur)) € |")
        let conceptOther = b.conceptTypeOther.map { " · \($0)" } ?? ""
        lines.append("| Konzept-Typ | `\(b.conceptType.rawValue)`\(conceptOther) |")
        var medium = "`\(b.visualMedium.rawValue)`"
        if let other = b.visualMediumOther, !other.isEmpty { medium += " · \(other)" }
        if let notes = b.visualMediumNotes, !notes.isEmpty { medium += " — \(notes)" }
        lines.append("| Medium | \(medium) |")
        let tone = b.tone.isEmpty ? "—" : b.tone.map(\.rawValue).joined(separator: ", ")
        let toneOther = b.toneOther.map { " · \($0)" } ?? ""
        lines.append("| Ton | \(tone)\(toneOther) |")
        if !b.styleReferences.isEmpty {
            lines.append("| Stil-Referenzen | \(b.styleReferences.joined(separator: " · ")) |")
        }
        var figures = b.figures.rawValue + (b.figuresOther.map { " · \($0)" } ?? "")
        if let hint = b.figureCountHint, !hint.isEmpty { figures += " (\(hint))" }
        lines.append("| Figuren | \(figures) |")
        var lyrics = b.lyricsIntegration.rawValue
        if let other = b.lyricsIntegrationOther, !other.isEmpty { lyrics += " · \(other)" }
        lines.append("| Lyrics-Integration | \(lyrics) |")
        lines.append("| Cut-Handles | `\(b.cutHandlesMode.rawValue)` |")
        let patternId = (b.directorPattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !patternId.isEmpty {
            lines.append("| Director-Pattern | `\(patternId)` |")
        }
        if let notes = b.notes, !notes.isEmpty {
            lines.append("")
            lines.append("**Notes:**")
            lines.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Treatment

    static func showTreatment(_ dataRoot: URL, version: Int? = nil) throws -> String {
        let t = try TreatmentStore.load(dataRoot: dataRoot, version: version)
        var lines: [String] = []
        lines.append("## Treatment · \(t.meta.project) · v\(t.meta.version)")
        if let title = t.meta.title, !title.isEmpty {
            lines.append("### \(title)")
        }
        lines.append("")
        lines.append("**Origin:** `\(t.meta.origin.rawValue)` · **Generator:** \(t.meta.generator) · **Generated:** \(t.meta.generated)")
        lines.append("")
        lines.append("> \(t.meta.summaryOneline)")
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append(t.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))
        if let notes = t.meta.notes, !notes.isEmpty {
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append("_Notes: \(notes)_")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Bible

    static func showBible(_ dataRoot: URL) -> String {
        guard let bible = (try? loadBible(dataRoot: dataRoot)) ?? nil else {
            return "_Keine bible.yaml vorhanden._"
        }
        var lines: [String] = []
        lines.append("## Bible · \(bible.project)")
        lines.append("")
        let look = bible.look
        let anyLook = [look.style, look.palette, look.lighting, look.lens,
                       look.filmStock, look.grain, look.motionStyle, look.additional].contains { !$0.isEmpty }
        if anyLook {
            lines.append("### Look-Guide")
            lines.append("")
            lines.append("| Feld | Wert |")
            lines.append("|---|---|")
            if !look.style.isEmpty { lines.append("| **Style** | \(look.style) |") }
            if !look.palette.isEmpty { lines.append("| Palette | \(look.palette) |") }
            if !look.lighting.isEmpty { lines.append("| Lighting | \(look.lighting) |") }
            if !look.lens.isEmpty { lines.append("| Lens | \(look.lens) |") }
            if !look.filmStock.isEmpty { lines.append("| Film-Stock | \(look.filmStock) |") }
            if !look.grain.isEmpty { lines.append("| Grain | \(look.grain) |") }
            if !look.motionStyle.isEmpty { lines.append("| Motion-Style | \(look.motionStyle) |") }
            if !look.additional.isEmpty { lines.append("| Additional | \(look.additional) |") }
            lines.append("")
        }

        func coverageCell(referenceImages: [String], sheets: [String: String]) -> String {
            var parts: [String] = []
            if !referenceImages.isEmpty { parts.append("\(referenceImages.count) ref") }
            if !sheets.isEmpty { parts.append("sheets: \(sheets.keys.sorted().joined(separator: ", "))") }
            return parts.isEmpty ? "⚠️ KEINE" : parts.joined(separator: " · ")
        }

        func attributesCell(_ attributes: [String: String]) -> String {
            attributes.isEmpty ? "—" : attributes.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }

        if !bible.characters.isEmpty {
            lines.append("### Characters")
            lines.append("")
            lines.append("| id | name | prompt (gekürzt) | attributes | Coverage |")
            lines.append("|---|---|---|---|---|")
            for it in bible.characters {
                let cov = coverageCell(referenceImages: it.referenceImages, sheets: it.sheets)
                lines.append("| `\(it.id)` | \(it.name) | \(shorten(it.visualPrompt, 60)) | \(attributesCell(it.attributes)) | \(cov) |")
            }
            lines.append("")
        }
        if !bible.ensembles.isEmpty {
            lines.append("### Ensembles")
            lines.append("")
            lines.append("| id | name | n | prompt (gekürzt) | attributes | Coverage |")
            lines.append("|---|---|---:|---|---|---|")
            for it in bible.ensembles {
                let cov = coverageCell(referenceImages: it.referenceImages, sheets: it.sheets)
                lines.append("| `\(it.id)` | \(it.name) | \(it.memberCount) | \(shorten(it.visualPrompt, 60)) | \(attributesCell(it.attributes)) | \(cov) |")
            }
            lines.append("")
        }
        if !bible.props.isEmpty {
            lines.append("### Props")
            lines.append("")
            lines.append("| id | name | prompt (gekürzt) | attributes | Coverage |")
            lines.append("|---|---|---|---|---|")
            for it in bible.props {
                let cov = coverageCell(referenceImages: it.referenceImages, sheets: it.sheets)
                lines.append("| `\(it.id)` | \(it.name) | \(shorten(it.visualPrompt, 60)) | \(attributesCell(it.attributes)) | \(cov) |")
            }
            lines.append("")
        }
        if !bible.locations.isEmpty {
            lines.append("### Locations")
            lines.append("")
            lines.append("| id | name | prompt (gekürzt) | attributes | Coverage |")
            lines.append("|---|---|---|---|---|")
            for it in bible.locations {
                let cov = coverageCell(referenceImages: it.referenceImages, sheets: it.sheets)
                lines.append("| `\(it.id)` | \(it.name) | \(shorten(it.visualPrompt, 60)) | \(attributesCell(it.attributes)) | \(cov) |")
            }
            lines.append("")
        }
        if let notes = bible.notes, !notes.isEmpty {
            lines.append("**Notes:**")
            lines.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Shotlist

    static func showShotlist(_ dataRoot: URL) -> String {
        guard let sl = (try? loadShotlist(dataRoot: dataRoot)) ?? nil else {
            return "_Keine shotlist/current.yaml vorhanden._"
        }
        var lines: [String] = []
        lines.append("## Shotlist · \(sl.project) · current · mode=\(sl.mode.rawValue)")
        lines.append("")

        let durations = sl.shots.map(\.durationS)
        let asl = durations.isEmpty ? 0.0 : durations.reduce(0, +) / Double(durations.count)
        let perceived = sl.song.perceivedBpm
        var bpmStr = "\(String(format: "%.1f", sl.song.bpm)) BPM"
        if abs(perceived - sl.song.bpm) > 0.1 {
            let mult = sl.song.tempoMultiplier
            bpmStr = "\(String(format: "%.1f", perceived)) BPM (×\(g(mult)) aus \(String(format: "%.1f", sl.song.bpm)))"
        }
        lines.append(
            "**\(sl.shots.count) Shots** · ASL \(String(format: "%.1f", asl))s · Budget \(String(format: "%.2f", sl.budgetEur)) € "
            + "· \(bpmStr) · Dauer \(mmSS(sl.song.durationS))"
        )
        lines.append("")

        // Section grouping preserves first-seen order, matching Python's dict insertion order.
        var sectionOrder: [String] = []
        var bySection: [String: [Shot]] = [:]
        for shot in sl.shots {
            let key = shot.section ?? "(none)"
            if bySection[key] == nil { sectionOrder.append(key) }
            bySection[key, default: []].append(shot)
        }

        lines.append("### Section-Übersicht")
        lines.append("")
        lines.append("| Section | Zeit | Shots | ASL | KF-Mix |")
        lines.append("|---|---|---|---|---|")
        for sec in sectionOrder {
            let shots = bySection[sec] ?? []
            let start = mmSS(shots.first!.timeStart)
            let end = mmSS(shots.last!.timeEnd)
            let secAsl = shots.map(\.durationS).reduce(0, +) / Double(shots.count)
            let kfMix = mostCommon(shots.map(\.keyframeStrategy.rawValue))
                .map { "\($0.key)×\($0.count)" }.joined(separator: " ")
            lines.append("| `\(sec)` | \(start)–\(end) | \(shots.count) | \(String(format: "%.1f", secAsl))s | \(kfMix) |")
        }
        lines.append("")

        let sanityURL = dataRoot.appendingPathComponent("sanity-report.yaml")
        if FileManager.default.fileExists(atPath: sanityURL.path) {
            if let text = try? String(contentsOf: sanityURL, encoding: .utf8),
               case .mapping(let srep)? = try? YAMLCoding.canonical(text) {
                let nErr = sequenceCount(srep["errors"])
                let nWarn = sequenceCount(srep["warnings"])
                let badge = nErr == 0 ? "✓" : "✗"
                lines.append("**Sanity-Snapshot:** \(badge) \(nErr) Errors · ⚠ \(nWarn) Warns (siehe sanity-report.yaml)")
                lines.append("")
            }
        }

        lines.append("### Shots")
        lines.append("")
        for sec in sectionOrder {
            let shots = bySection[sec] ?? []
            lines.append("#### `\(sec)` · \(mmSS(shots.first!.timeStart))–\(mmSS(shots.last!.timeEnd)) · \(shots.count) Shots")
            lines.append("")
            for shot in shots {
                let kf = shot.keyframeStrategy.rawValue
                let kfBadge = ["none": "–", "start": "▶︎", "start_end": "▶︎▶︎"][kf] ?? kf
                var flags: [String] = []
                switch shot.sourceMode {
                case .generated: break
                case .imported: flags.append("📥 imported")
                case .aiEnhanced: flags.append("✨ enhanced")
                }
                if shot.redo { flags.append("⟳ redo") }
                if shot.chainWithPreviousEnd { flags.append("⛓ chain") }
                let notesStr = shot.notes ?? ""
                if notesStr.range(of: stillOnlyPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    flags.append("🖼 still-only (NLE)")
                }
                let flagStr = flags.isEmpty ? "" : " · " + flags.joined(separator: " · ")
                lines.append(
                    "- **`\(shot.id)`** · \(mmSS(shot.timeStart)) · \(String(format: "%.1f", shot.durationS))s "
                    + "· \(shot.type.rawValue) · KF \(kfBadge)\(flagStr)"
                )

                var refParts: [String] = []
                if !shot.characterRefs.isEmpty {
                    refParts.append("👤 " + shot.characterRefs.joined(separator: ", "))
                }
                if let locationRef = shot.locationRef {
                    var loc = locationRef
                    if let view = shot.locationView { loc = "\(loc)/\(view)" }
                    refParts.append("📍 \(loc)")
                }
                if !shot.propRefs.isEmpty {
                    refParts.append("🎒 " + shot.propRefs.joined(separator: ", "))
                }
                let mood = shot.mood.trimmingCharacters(in: .whitespacesAndNewlines)
                if !mood.isEmpty { refParts.append("_\(mood)_") }
                if !refParts.isEmpty {
                    lines.append("  " + refParts.joined(separator: " · "))
                }

                let desc = shot.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if !desc.isEmpty { lines.append("  > \(shorten(desc, 140))") }
                lines.append("")
            }
        }

        if let notes = sl.notes, !notes.isEmpty {
            lines.append("### Notes")
            lines.append("")
            lines.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var out = lines.joined(separator: "\n")
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out + "\n"
    }

    // MARK: - Analysis (raw JSON, no typed model)

    static func showAnalysis(_ dataRoot: URL) -> String {
        let anaDir = dataRoot.appendingPathComponent("analysis")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: anaDir.path, isDirectory: &isDir), isDir.boolValue else {
            return "_Kein analysis/-Ordner vorhanden — Phase A noch nicht durch._"
        }
        let entries = (try? FileManager.default.contentsOfDirectory(at: anaDir, includingPropertiesForKeys: nil)) ?? []
        let candidates = entries
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = candidates.first else {
            return "_Keine analysis/<song>.json vorhanden — Analyse-Lauf ausführen._"
        }
        guard let raw = try? Data(contentsOf: first),
              let parsed = try? JSONSerialization.jsonObject(with: raw),
              let data = parsed as? [String: Any] else {
            return "_Keine analysis/<song>.json vorhanden — Analyse-Lauf ausführen._"
        }

        var lines: [String] = []
        let project = (data["project"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? displayName(dataRoot)
        lines.append("## Analyse · \(project)")
        lines.append("")

        lines.append("| Feld | Wert |")
        lines.append("|---|---|")
        if let bpm = asDouble(data["bpm"]) {
            lines.append("| BPM | \(String(format: "%.1f", bpm)) |")
        }
        if let key = data["key"] as? String, !key.isEmpty {
            lines.append("| Tonart | \(key) |")
        }
        if let duration = asDouble(data["duration_s"]) {
            lines.append("| Dauer | \(mmSS(duration)) (\(String(format: "%.1f", duration))s) |")
        }
        let downbeats = data["downbeats"] as? [Any] ?? []
        let dbSource = data["downbeat_source"] as? String
        if !downbeats.isEmpty {
            let src = dbSource.map { " (\($0))" } ?? ""
            lines.append("| Downbeats | \(downbeats.count)\(src) |")
        } else if let dbSource, !dbSource.isEmpty {
            lines.append("| Downbeat-Quelle | `\(dbSource)` |")
        }
        if let stems = data["stems"] as? [String: Any], !stems.isEmpty {
            let present = ["vocals", "drums", "bass", "other"].filter { stems[$0] != nil }
            if !present.isEmpty {
                lines.append("| Stems | \(present.joined(separator: ", ")) |")
            } else if let provider = stems["provider"] as? String {
                lines.append("| Stems | `\(provider)` |")
            }
        }
        let alignment = data["alignment"] as? [Any] ?? []
        if !alignment.isEmpty {
            lines.append("| Alignment-Zeilen | \(alignment.count) |")
        }
        lines.append("")

        let sections = data["sections"] as? [[String: Any]] ?? []
        let interpretation = data["interpretation"] as? [String: Any] ?? [:]
        let sectionLabels = interpretation["section_labels"] as? [[String: Any]] ?? []

        if let firstSection = sections.first, firstSection["start"] != nil {
            lines.append("### Sections")
            lines.append("")
            lines.append("| # | Label | Start | Dauer |")
            lines.append("|---|---|---|---|")
            for s in sections {
                let idx = scalarString(s["index"])
                let label = (s["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                let start = asDouble(s["start"]) ?? 0.0
                let end = asDouble(s["end"]) ?? start
                let dur = max(0.0, end - start)
                lines.append("| \(idx) | \(label) | \(mmSS(start)) | \(String(format: "%.0f", dur))s |")
            }
            lines.append("")
        } else if !sectionLabels.isEmpty {
            lines.append("### Sections")
            lines.append("")
            lines.append("| # | Label | Confidence |")
            lines.append("|---|---|---|")
            for s in sectionLabels {
                let idx = scalarString(s["index"])
                let label = (s["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                let confS = asDouble(s["confidence"]).map { String(format: "%.2f", $0) } ?? "—"
                lines.append("| \(idx) | \(label) | \(confS) |")
            }
            lines.append("")
        }

        let anomalies = interpretation["anomalies"] as? [Any] ?? []
        if !anomalies.isEmpty {
            let kinds = mostCommon(anomalies.compactMap { anomaly -> String? in
                guard let dict = anomaly as? [String: Any] else { return nil }
                return (dict["kind"] as? String) ?? "unknown"
            })
            lines.append("### Anomalien (\(anomalies.count))")
            lines.append("")
            for entry in kinds {
                let samples = anomalies
                    .compactMap { $0 as? [String: Any] }
                    .filter { ($0["kind"] as? String) == entry.key }
                    .prefix(2)
                    .compactMap { $0["note"] as? String }
                let sampleS = samples.filter { !$0.isEmpty }.map { shorten($0, 90) }.joined(separator: " · ")
                if sampleS.isEmpty {
                    lines.append("- **\(entry.count)× \(entry.key)**")
                } else {
                    lines.append("- **\(entry.count)× \(entry.key)** — \(sampleS)")
                }
            }
            lines.append("")
        }

        if let overall = interpretation["overall_character"] {
            let overallS = scalarString(overall)
            lines.append("### Charakter")
            lines.append("")
            lines.append(overallS.count > 400 ? shorten(overallS, 400) : overallS)
            lines.append("")
        }

        let structureCands = data["structure_candidates"] as? [Any] ?? []
        if !structureCands.isEmpty {
            lines.append("_Structure-Detector-Kandidaten: \(structureCands.count)_")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Production Design (raw YAML, no typed model)

    static func showProductionDesign(_ dataRoot: URL) -> String {
        let pdURL = dataRoot.appendingPathComponent("production_design").appendingPathComponent("production_design.yaml")
        guard FileManager.default.fileExists(atPath: pdURL.path) else {
            return "_Keine production_design.yaml vorhanden — Phase K2 noch nicht durch._"
        }
        let data: [String: YAMLValue]
        if let text = try? String(contentsOf: pdURL, encoding: .utf8),
           case .mapping(let mapping)? = try? YAMLCoding.canonical(text) {
            data = mapping
        } else {
            data = [:]
        }
        var lines: [String] = []
        let project = mappingString(data["project"]).flatMap { $0.isEmpty ? nil : $0 } ?? displayName(dataRoot)
        lines.append("## Production Design · \(project)")
        lines.append("")
        lines.append("| Feld | Wert |")
        lines.append("|---|---|")
        if let vm = mappingString(data["visual_medium"]), !vm.isEmpty {
            lines.append("| Visual Medium | `\(vm)` |")
        }
        if let notes = mappingString(data["visual_medium_notes"]), !notes.isEmpty {
            lines.append("| Notes | \(shorten(notes, 200)) |")
        }
        if let gen = mappingString(data["generator"]), !gen.isEmpty {
            lines.append("| Generator | \(gen) |")
        }
        lines.append("")

        if case .sequence(let refs)? = data["refs"], !refs.isEmpty {
            lines.append("### Style-Refs")
            lines.append("")
            lines.append("| # | Pfad | Notiz |")
            lines.append("|---:|---|---|")
            for (i, ref) in refs.enumerated() {
                let path: String
                let note: String
                if case .mapping(let refMap) = ref {
                    path = mappingString(refMap["path"]) ?? ""
                    note = mappingString(refMap["note"]) ?? ""
                } else {
                    path = valueString(ref)
                    note = ""
                }
                lines.append("| \(i + 1) | `\(path)` | \(note) |")
            }
            lines.append("")
        }

        if case .mapping(let colorScript)? = data["color_script"], !colorScript.isEmpty {
            lines.append("### Color Script")
            lines.append("")
            lines.append("| Section | Stimmung |")
            lines.append("|---|---|")
            for (section, mood) in colorScript {
                lines.append("| \(section) | \(valueString(mood)) |")
            }
            lines.append("")
        }

        if let notes = mappingString(data["notes"]), !notes.isEmpty {
            lines.append("**Notes:**")
            lines.append("")
            lines.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Storyboard

    static func showStoryboard(_ dataRoot: URL, version: String = "current") -> String {
        let resolvedVersion: StoryboardStore.Version
        if version == "current" {
            resolvedVersion = .current
        } else if version.hasPrefix("v"), let n = Int(version.dropFirst()) {
            resolvedVersion = .number(n)
        } else if let n = Int(version) {
            resolvedVersion = .number(n)
        } else {
            resolvedVersion = .current
        }
        guard let sb = (try? StoryboardStore.load(dataRoot: dataRoot, version: resolvedVersion)) ?? nil else {
            return "_Kein Storyboard `\(version)` vorhanden — Phase K4 noch nicht durch._"
        }
        var lines: [String] = []
        lines.append("## Storyboard · \(sb.meta.project) · v\(sb.meta.version) · \(sb.meta.origin)")
        lines.append("")
        if !sb.meta.summaryOneline.isEmpty {
            lines.append("> \(sb.meta.summaryOneline)")
            lines.append("")
        }
        let totalSteps = sb.sections.reduce(0) { $0 + $1.steps.count }
        lines.append("**\(sb.sections.count) Sektionen · \(totalSteps) Steps**")
        lines.append("")

        lines.append("### Sektionen")
        lines.append("")
        lines.append("| ID | Label | Energy | Funktion | Steps | Zeit |")
        lines.append("|---|---|---|---|---:|---|")
        for s in sb.sections {
            var zeit = ""
            if s.timeStart != 0 || s.timeEnd != 0 {
                zeit = "\(mmSS(s.timeStart))-\(mmSS(s.timeEnd))"
            }
            let label = s.label.isEmpty ? "—" : s.label
            let energy = s.energy.isEmpty ? "—" : s.energy
            let function = s.function.isEmpty ? "—" : s.function
            lines.append("| `\(s.id)` | \(label) | \(energy) | \(function) | \(s.steps.count) | \(zeit) |")
        }
        lines.append("")

        for sec in sb.sections {
            if sec.steps.isEmpty { continue }
            lines.append("### Steps · \(sec.id)")
            lines.append("")
            lines.append("| Step | Funktion | Subject | Camera | Location-View |")
            lines.append("|---|---|---|---|---|")
            for st in sec.steps {
                let subj = shorten(st.subject, 60)
                let cam = shorten(st.camera, 50)
                let view = st.locationViewRequest.isEmpty ? "—" : st.locationViewRequest
                lines.append("| `\(st.id)` | \(st.function.rawValue) | \(subj) | \(cam) | \(view) |")
            }
            lines.append("")
        }

        let demand = sb.locationViewDemand()
        if !demand.isEmpty {
            lines.append("### Bible-Bedarf (Location-Views)")
            lines.append("")
            lines.append("| Location-Hint | benötigte Views |")
            lines.append("|---|---|")
            for loc in demand.keys.sorted() {
                let views = (demand[loc] ?? []).sorted().joined(separator: ", ")
                lines.append("| `\(loc)` | \(views) |")
            }
            lines.append("")
        }

        if let notes = sb.meta.notes, !notes.isEmpty {
            lines.append("**Notes:**")
            lines.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Renders (raw JSON, then YAML fallback)

    static func showRenders(_ dataRoot: URL, phase: String = "preview") -> String {
        var lines: [String] = []
        let projectName = displayName(dataRoot)
        lines.append("## Renders · \(projectName) · \(phase)")
        lines.append("")
        let rendersDir = dataRoot.appendingPathComponent("renders")
        var manifestURL = rendersDir.appendingPathComponent("manifest-\(phase).json")
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            manifestURL = rendersDir.appendingPathComponent("manifest-\(phase).yaml")
        }
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            let r = phase == "preview" ? "1" : "2"
            lines.append("_Kein Manifest unter `renders/manifest-\(phase).*` —_ Render-Phase R\(r) noch nicht gelaufen.")
            return lines.joined(separator: "\n")
        }

        let mapping: [String: YAMLValue]
        if manifestURL.pathExtension == "json" {
            guard let raw = try? Data(contentsOf: manifestURL),
                  let parsed = try? JSONSerialization.jsonObject(with: raw) else {
                lines.append("_Manifest defekt: ValueError_")
                return lines.joined(separator: "\n")
            }
            mapping = jsonToMapping(parsed)
        } else {
            guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
                lines.append("_Manifest defekt: OSError_")
                return lines.joined(separator: "\n")
            }
            if case .mapping(let m)? = (try? YAMLCoding.canonical(text)) {
                mapping = m
            } else {
                mapping = [:]
            }
        }

        guard case .sequence(let results)? = mapping["results"], !results.isEmpty else {
            lines.append("_Manifest leer._")
            return lines.joined(separator: "\n")
        }
        lines.append("| Shot | Status | Modell | EUR | Pfad |")
        lines.append("|---|---|---|---|---|")
        var totalEur = 0.0
        for r in results {
            guard case .mapping(let row) = r else { continue }
            let shotId = mappingString(row["shot_id"]) ?? "?"
            let status = mappingString(row["status"]) ?? "?"
            let model = mappingString(row["runway_model"]) ?? ""
            let eur = yamlDouble(row["eur_spent"]) ?? 0.0
            let outPath = mappingString(row["out_path"]).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
            totalEur += eur
            lines.append("| `\(shotId)` | \(status) | \(model) | \(String(format: "%.3f", eur)) | `\(outPath)` |")
        }
        lines.append("")
        lines.append("**Gesamt:** \(String(format: "%.2f", totalEur)) EUR · \(results.count) Shots")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Port of `collections.Counter.most_common()`: descending by count, ties in
    /// first-seen order.
    private static func mostCommon(_ items: [String]) -> [(key: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for item in items {
            if counts[item] == nil { order.append(item) }
            counts[item, default: 0] += 1
        }
        return order.map { (key: $0, count: counts[$0]!) }
            .enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map { $0.element }
    }

    private static func sequenceCount(_ value: YAMLValue?) -> Int {
        if case .sequence(let items)? = value { return items.count }
        return 0
    }

    private static func asDouble(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func yamlDouble(_ value: YAMLValue?) -> Double? {
        switch value {
        case .number(let n)?: return n
        case .string(let s)?: return Double(s)
        default: return nil
        }
    }

    /// Python `str(x)` for a JSON scalar the way the analysis formatter prints
    /// `index`/`overall_character`.
    private static func scalarString(_ value: Any?) -> String {
        switch value {
        case nil: return ""
        case let s as String: return s
        case let b as Bool: return b ? "True" : "False"
        case let i as Int: return String(i)
        case let d as Double: return d == d.rounded() ? String(Int(d)) : String(d)
        case let n as NSNumber: return n.stringValue
        default: return String(describing: value!)
        }
    }

    private static func mappingString(_ value: YAMLValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private static func valueString(_ value: YAMLValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "True" : "False"
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .sequence, .mapping: return ""
        }
    }

    private static func jsonToMapping(_ parsed: Any) -> [String: YAMLValue] {
        guard let dict = parsed as? [String: Any] else { return [:] }
        return dict.mapValues { YAMLValue(any: $0) }
    }
}
