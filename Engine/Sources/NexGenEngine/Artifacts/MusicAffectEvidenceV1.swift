import CoreFoundation
import Foundation

public enum MusicAffectEvidenceV1 {
    public static let schema = "music-affect-evidence/v1"
    public static let path = "analysis/affect.json"
    public static let key = "harmonic_evidence"
    public static let tags = [
        "aggressive", "anthemic", "cinematic", "confrontational", "dark", "dreamy", "euphoric",
        "fragile", "high_energy", "humorous", "intimate", "introspective", "ironic", "melancholic",
        "meditative", "narrative", "playful", "poetic", "rebellious", "romantic", "surreal", "tense",
        "triumphant", "urgent", "warm",
    ]
    public static let signalNames = ["harmony", "key", "rhythm", "energy", "lyrics", "instrumentation", "onsets", "provider", "context"]

    public static func materialize(_ draft: [String: Any], dataRoot: URL) throws -> [String: Any] {
        try keys(draft, allowed: ["schema", "summary", "confidence", "sections"], at: key)
        var evidence = draft
        evidence["source"] = try sourceSnapshot(dataRoot: dataRoot)
        try validateEvidence(evidence)
        return evidence
    }

    public static func read(dataRoot: URL) throws -> [String: Any]? {
        let url = PipelineLayout.url(path, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return nil }
        let profile = try object(at: path, dataRoot: dataRoot)
        if profile[key] != nil { try validateProfile(profile, dataRoot: dataRoot) }
        return profile
    }

    public static func validateProfile(_ profile: [String: Any], dataRoot: URL) throws {
        guard let evidence = profile[key] as? [String: Any] else {
            throw GateBlocked("Affect evidence is missing or invalid. Use record_affect in Brief.")
        }
        try validateEvidence(evidence)
        guard let source = evidence["source"] as? [String: Any],
              try canonical(source) == canonical(sourceSnapshot(dataRoot: dataRoot)) else {
            throw GateBlocked("Affect evidence is stale. Rewind Brief and record it against the approved analysis.")
        }
        try weights(profile["detected"], at: "detected")
        if profile["override"] != nil {
            try weights(profile["override"], at: "override")
            guard !(profile["override"] as? [[String: Any]] ?? []).isEmpty else {
                throw GateBlocked("An affect override must contain a desired affect.")
            }
            try text(profile["override_reason"], at: "override_reason")
        }
        guard profile["basis"] as? String == "inferred" else {
            throw GateBlocked("Emotional meaning is inferred; signal measurements are separate evidence.")
        }
        let sections = evidence["sections"] as? [[String: Any]] ?? []
        for section in sections {
            let desired = tagText(profile["override"] ?? section["detected"])
            guard let direction = section["visual_direction"] as? String, direction.hasPrefix(desired + ": ") else {
                throw GateBlocked("Section visual_direction must begin with '\(desired): ' and implement that effective desired affect.")
            }
        }
        let detected = profile["detected"] as? [[String: Any]] ?? []
        if detected.isEmpty, number(evidence["confidence"]) != 0 {
            throw GateBlocked("An undetermined track affect must have zero confidence.")
        }
        let sectionTags = Set(sections.flatMap { ($0["detected"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String } })
        guard Set(detected.compactMap { $0["value"] as? String }).isSubset(of: sectionTags),
              !sectionTags.isEmpty || detected.isEmpty else {
            throw GateBlocked("Track affect must be supported by the section interpretations; abstention cannot invent a track mood.")
        }
    }

    public static func requiresEvidence(dataRoot: URL) -> Bool {
        let url = FrameInventory.projectHome(of: dataRoot).appendingPathComponent("ngv.json")
        guard let data = try? Data(contentsOf: url),
              let binding = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              binding["activePlugin"] as? String == "musicvideo",
              let version = binding["activePluginVersion"] as? String else { return false }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 && (parts[0] > 0 || parts[1] >= 6)
    }

    public static func requireCurrent(dataRoot: URL) throws {
        _ = try read(dataRoot: dataRoot)
    }

    public static func sourceSnapshot(dataRoot: URL) throws -> [String: Any] {
        guard let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot) else {
            throw GateBlocked("Affect evidence needs the single approved project track.")
        }
        let analysisPath = "analysis/" + analysisURL.lastPathComponent
        let proofPath = "analysis/" + analysisURL.deletingPathExtension().lastPathComponent + ".measurement-proof.json"
        let analysis = try object(at: analysisPath, dataRoot: dataRoot)
        let proof = try object(at: proofPath, dataRoot: dataRoot)
        guard let trackPath = analysis["song_path"] as? String,
              let hash = analysis["song_sha256"] as? String,
              proof["song_sha256"] as? String == hash,
              proof["schema"] as? String == "analysis_measurement_proof/v1",
              proof["project"] as? String == analysis["project"] as? String else {
            throw GateBlocked("Affect evidence needs matching analysis and measurement proof.")
        }
        let track = try ProjectLocalFile.requireHash(hash, at: trackPath, dataRoot: dataRoot)
        guard track.standardizedFileURL == AudioProjectLayout.songFiles(dataRoot: dataRoot).first?.standardizedFileURL else {
            throw GateBlocked("Affect evidence must name the assigned track, not a different project file.")
        }
        var files: [String: String] = [
            analysisPath: try digest(analysisPath, dataRoot), proofPath: try digest(proofPath, dataRoot), trackPath: hash,
        ]
        let lyricsDirectory = dataRoot.appendingPathComponent("lyrics")
        let lyricsEntries = (try? FileManager.default.contentsOfDirectory(at: lyricsDirectory, includingPropertiesForKeys: nil)) ?? []
        let lyrics = lyricsEntries.filter { ["txt", "md", "lrc"].contains($0.pathExtension.lowercased()) }
        guard lyrics.count <= 1 else { throw GateBlocked("Affect evidence cannot choose among multiple lyrics files.") }
        var lyricsHash: String?
        if let lyricsFile = lyrics.first {
            let lyricsPath = "lyrics/" + lyricsFile.lastPathComponent
            lyricsHash = try digest(lyricsPath, dataRoot)
            files[lyricsPath] = lyricsHash
        }
        let aligned = try reliableLyrics(analysis: analysis, proof: proof, lyricsHash: lyricsHash, files: &files, dataRoot: dataRoot)
        guard let sections = analysis["sections"] as? [[String: Any]], !sections.isEmpty,
              let bpm = number(analysis["bpm"]), bpm > 0,
              let multiplier = number(analysis["tempo_multiplier"] ?? 1), multiplier > 0 else {
            throw GateBlocked("Affect evidence needs approved sections and perceived tempo.")
        }
        let chords = analysis["chord_progression"] as? [[String: Any]] ?? []
        let energy = analysis["energy_curve"] as? [[String: Any]] ?? []
        let beats = analysis["beats"] as? [Double] ?? []
        let interpretation = analysis["interpretation"] as? [String: Any] ?? [:]
        let context = interpretation["overall_character"] as? String ?? ""
        var indices = Set<Int>()
        let observations = try sections.map { section -> [String: Any] in
            guard let index = integer(section["index"]), indices.insert(index).inserted,
                  let start = number(section["start"]), let end = number(section["end"]), end > start else {
                throw GateBlocked("Affect section indices and measured bounds must be valid and unique.")
            }
            let localChords = chords.filter { overlaps($0, start: start, end: end) }
            let localEnergy = energy.filter { within($0["t"], start: start, end: end) }
            let localLyrics = aligned.filter { overlaps($0, start: start, end: end) }
            let changes = zip(localChords, localChords.dropFirst()).filter { pair in pair.0["label"] as? String != pair.1["label"] as? String }.count
            var signals: [String: Any] = [
                "harmony": signal(localChords.isEmpty ? "unavailable" : "estimated", value: localChords, note: "Local chord estimates; change rate is derived, emotional tension is inferred.", field: "chord_progression"),
                "key": signal(analysis["key"] is String ? "estimated" : "unavailable", value: analysis["key"] ?? NSNull(), note: "Global key estimate; confidence and modulation are not measured by this field.", field: "key"),
                "rhythm": signal("derived", value: ["perceived_bpm": bpm * multiplier, "beat_count": beats.filter { $0 >= start && $0 < end }.count], note: "Perceived BPM = approved BPM × multiplier; beat count uses measured section bounds.", field: "bpm,tempo_multiplier,beats"),
                "energy": signal(localEnergy.isEmpty ? "unavailable" : "measured", value: localEnergy, note: "Raw RMS samples, not a normalized affect/energy score; compare dynamics within this track.", field: "energy_curve"),
                "lyrics": signal(localLyrics.isEmpty ? "unavailable" : "aligned", value: localLyrics, note: "Only measured alignment with matching source proof permits section attribution.", field: "alignment"),
                "instrumentation": signal("unavailable", value: NSNull(), note: "No verified instrumentation observation in this local analysis; stem names are not instrument recognition.", field: ""),
                "onsets": signal("unavailable", value: NSNull(), note: "No persisted onset density in this analysis; BPM does not stand in for it.", field: ""),
                "provider": signal("unavailable", value: NSNull(), note: "No optional provider evidence is attached; local analysis is sufficient. Do not infer provider success.", field: ""),
                "context": signal(context.isEmpty ? "unavailable" : "inferred", value: context, note: "Recorded analysis interpretation, not independent measurement. Cite only its explicit observations; it may describe instrumentation.", field: "interpretation.overall_character"),
            ]
            if var harmony = signals["harmony"] as? [String: Any], !localChords.isEmpty {
                harmony["changes_per_second"] = Double(changes) / (end - start)
                signals["harmony"] = harmony
            }
            return ["index": index, "start": start, "end": end, "signals": signals]
        }
        return ["analysis_path": analysisPath, "files": files, "sections": observations,
                "stage_diagnostics": analysis["stage_diagnostics"] as? [[String: Any]] ?? []]
    }

    public static func confidence(_ profile: [String: Any]) -> Double? {
        guard let evidence = profile[key] as? [String: Any] else { return nil }
        let values = (evidence["sections"] as? [[String: Any]] ?? []).filter {
            !($0["detected"] as? [[String: Any]] ?? []).isEmpty
        }.compactMap { number($0["confidence"]) }
        return ([number(evidence["confidence"]) ?? 0] + values).min()
    }

    public static func presentation(dataRoot: URL) throws -> String? {
        guard let profile = try read(dataRoot: dataRoot), let evidence = profile[key] as? [String: Any] else { return nil }
        let source = evidence["source"] as? [String: Any] ?? [:]
        let facts = source["sections"] as? [[String: Any]] ?? []
        let sections = evidence["sections"] as? [[String: Any]] ?? []
        var lines = ["### Song affect and visual intent", "", "Detected: \(tagText(profile["detected"])).", "Desired video affect: \(tagText(profile["override"] ?? profile["detected"]))."]
        if let reason = profile["override_reason"] as? String { lines.append("User override: \(reason)") }
        if let reason = profile["override_clear_reason"] as? String { lines.append("User cleared override: \(reason)") }
        let diagnostics = source["stage_diagnostics"] as? [[String: Any]] ?? []
        if !diagnostics.isEmpty {
            lines.append("Analysis stage evidence: " + String(decoding: try canonical(diagnostics), as: UTF8.self))
        }
        lines += ["Track interpretation (inferred, confidence \(number(evidence["confidence"]) ?? 0)): \(evidence["summary"] as? String ?? "")", ""]
        for section in sections {
            let fact = facts.first { integer($0["index"]) == integer(section["index"]) } ?? [:]
            lines += ["Section \(integer(section["index"]) ?? -1), \(number(fact["start"]) ?? 0)–\(number(fact["end"]) ?? 0)s: detected \(tagText(section["detected"])); inference confidence \(number(section["confidence"]) ?? 0).",
                "Harmonic interpretation: \(section["harmony"] as? String ?? "")",
                "Support: \((section["support"] as? [String] ?? []).joined(separator: ", ")); conflict: \((section["conflicts"] as? [String] ?? []).joined(separator: ", ")). \(section["rationale"] as? String ?? "")",
                "Uncertainty: \(section["uncertainty"] as? String ?? "")",
                "Visual direction: \(section["visual_direction"] as? String ?? "")"]
            if let reason = section["abstention_reason"] as? String { lines.append("Abstention: \(reason)") }
            let signals = fact["signals"] as? [String: Any] ?? [:]
            for name in signalNames {
                guard let signal = signals[name] as? [String: Any] else { continue }
                let value = String(decoding: try canonical(signal["value"] ?? NSNull()), as: UTF8.self)
                lines.append("\(name) [\(signal["basis"] as? String ?? "unavailable"), \(signal["field"] as? String ?? "")]: \(value). \(signal["note"] as? String ?? "")")
                if let rate = number(signal["changes_per_second"]) {
                    lines.append("Chord changes/second (derived): \(rate).")
                }
            }
            lines.append("")
        }
        lines.append("Structural evidence is not a subjective creative-quality verdict; creative review must name its reviewer and observations.")
        return lines.joined(separator: "\n")
    }

    public static func requireTreatment(_ body: String, dataRoot: URL) throws {
        try requireCurrent(dataRoot: dataRoot)
        if let block = try presentation(dataRoot: dataRoot), !body.contains(block) {
            throw GateBlocked("Treatment must consume the current song affect and desired visual intent through write_treatment.")
        }
    }

    public static func requireVisualArc(_ arc: MusicVisualArcDraftV1, shotlist: Shotlist, dataRoot: URL) throws {
        try requireCurrent(dataRoot: dataRoot)
        guard let profile = try read(dataRoot: dataRoot), let evidence = profile[key] as? [String: Any],
              let source = evidence["source"] as? [String: Any] else { return }
        let facts = source["sections"] as? [[String: Any]] ?? []
        let interpretations = evidence["sections"] as? [[String: Any]] ?? []
        for section in arc.sections {
            let shots = shotlist.shots.filter { section.shotIDs.contains($0.id) }
            let covered = facts.filter { fact in
                guard let start = number(fact["start"]), let end = number(fact["end"]) else { return false }
                return shots.contains { $0.timeStart < end && $0.timeEnd > start }
            }
            guard !covered.isEmpty else { throw GateBlocked("Visual Arc has no measured affect section.") }
            for fact in covered {
                guard let interpretation = interpretations.first(where: { integer($0["index"]) == integer(fact["index"]) }),
                      let direction = interpretation["visual_direction"] as? String,
                      section.visualFunction.contains(direction) else {
                    throw GateBlocked("Visual Arc visual_function must carry each covered section's approved visual_direction verbatim, including its desired affect.")
                }
            }
        }
    }

    public static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    private static func validateEvidence(_ evidence: [String: Any]) throws {
        try keys(evidence, allowed: ["schema", "summary", "confidence", "sections", "source"], at: key)
        guard evidence["schema"] as? String == schema, let confidence = number(evidence["confidence"]), (0...0.7).contains(confidence),
              let sections = evidence["sections"] as? [[String: Any]], !sections.isEmpty,
              let source = evidence["source"] as? [String: Any], let facts = source["sections"] as? [[String: Any]], sections.count == facts.count else {
            throw GateBlocked("Affect evidence needs its version, all measured sections, and inferred confidence in 0...0.7.")
        }
        try text(evidence["summary"], at: "summary")
        var seen = Set<Int>()
        for section in sections {
            try keys(section, allowed: ["index", "detected", "confidence", "support", "conflicts", "rationale", "harmony", "uncertainty", "visual_direction", "abstention_reason"], at: "sections")
            guard let index = integer(section["index"]), seen.insert(index).inserted,
                  let fact = facts.first(where: { integer($0["index"]) == index }),
                  let confidence = number(section["confidence"]), (0...0.7).contains(confidence),
                  let detected = section["detected"] as? [[String: Any]],
                  let support = section["support"] as? [String], let conflicts = section["conflicts"] as? [String],
                  Set(support).isDisjoint(with: conflicts), Set(support).count == support.count, Set(conflicts).count == conflicts.count else {
                throw GateBlocked("Affect section needs an exact measured index, bounded inference, and distinct support/conflict signals.")
            }
            try weights(detected, at: "section.detected")
            for field in ["rationale", "harmony", "uncertainty", "visual_direction"] { try text(section[field], at: field) }
            let signals = fact["signals"] as? [String: Any] ?? [:]
            for name in support + conflicts {
                guard signalNames.contains(name), let signal = signals[name] as? [String: Any], signal["basis"] as? String != "unavailable" else {
                    throw GateBlocked("Affect cites unavailable signal \(name) in section \(index).")
                }
            }
            if detected.isEmpty {
                guard confidence == 0 else { throw GateBlocked("Abstention has zero inference confidence.") }
                try text(section["abstention_reason"], at: "abstention_reason")
            } else {
                guard confidence > 0, !support.isEmpty, section["abstention_reason"] == nil else {
                    throw GateBlocked("A section inference needs support and positive bounded confidence, or explicit abstention.")
                }
            }
        }
    }

    private static func reliableLyrics(analysis: [String: Any], proof: [String: Any], lyricsHash: String?, files: inout [String: String], dataRoot: URL) throws -> [[String: Any]] {
        guard let alignment = proof["lyrics_alignment"] as? [String: Any] else { return [] }
        guard let sourcePath = alignment["source_path"] as? String, let sourceHash = alignment["source_sha256"] as? String else {
            throw GateBlocked("Lyric alignment proof lacks its source.")
        }
        _ = try ProjectLocalFile.requireHash(sourceHash, at: sourcePath, dataRoot: dataRoot)
        files[sourcePath] = sourceHash
        let lines = analysis["alignment"] as? [[String: Any]] ?? []
        let words = lines.flatMap { $0["words"] as? [[String: Any]] ?? [] }
        let matched = words.filter { number($0["score"]) != nil }.count
        let timing = alignment["timing_evidence"] as? String ?? ""
        guard let lyricsHash, lyricsHash == alignment["lyrics_sha256"] as? String,
              FileDigest.sha256(of: try canonical(lines)) == alignment["alignment_sha256"] as? String,
              integer(alignment["lyric_token_count"]) == words.count,
              integer(alignment["matched_token_count"]) == matched else {
            throw GateBlocked("Lyric evidence does not match its measured alignment proof.")
        }
        guard ["recognized_speech", "known_text_alignment"].contains(timing),
              timing != "known_text_alignment" || alignment["timing_method"] as? String == "attention_dtw",
              !words.isEmpty, Double(matched) / Double(words.count) >= 0.7 else { return [] }
        return lines
    }

    private static func signal(_ basis: String, value: Any, note: String, field: String) -> [String: Any] {
        ["basis": basis, "value": value, "note": note, "field": field]
    }

    private static func object(at path: String, dataRoot: URL) throws -> [String: Any] {
        let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw GateBlocked("Invalid JSON object at \(path).")
        }
        return object
    }

    private static func digest(_ path: String, _ root: URL) throws -> String {
        try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: root))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value.rounded() == value, value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func within(_ value: Any?, start: Double, end: Double) -> Bool {
        guard let value = number(value) else { return false }
        return value >= start && value < end
    }

    private static func overlaps(_ value: [String: Any], start: Double, end: Double) -> Bool {
        guard let a = number(value["start"]), let b = number(value["end"]), a < b else { return false }
        return a < end && b > start
    }

    private static func keys(_ object: [String: Any], allowed: Set<String>, at path: String) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw GateBlocked("Unknown fields in \(path).") }
    }

    private static func text(_ value: Any?, at path: String) throws {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GateBlocked("\(path) must explain the evidence or creative decision.")
        }
    }

    private static func weights(_ value: Any?, at path: String) throws {
        guard let values = value as? [[String: Any]] else { throw GateBlocked("\(path) must be an affect array.") }
        var seen = Set<String>()
        var total = 0.0
        for item in values {
            try keys(item, allowed: ["value", "weight"], at: path)
            guard let tag = item["value"] as? String, tags.contains(tag), seen.insert(tag).inserted,
                  let weight = number(item["weight"]), weight > 0 else { throw GateBlocked("Invalid affect tag or weight in \(path).") }
            total += weight
            guard total.isFinite else { throw GateBlocked("Affect weights must have a finite total in \(path).") }
        }
    }

    private static func tagText(_ value: Any?) -> String {
        let values = (value as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
        return values.isEmpty ? "undetermined" : values.joined(separator: ", ")
    }
}
