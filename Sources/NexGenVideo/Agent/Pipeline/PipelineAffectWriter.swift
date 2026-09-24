import CoreFoundation
import Foundation
import NexGenEngine

enum PipelineAffectWriter {
    static func write(_ args: [String: Any], dataRoot: URL) throws -> [String: Any] {
        let allowed: Set<String> = ["detected", "override", "override_action", "override_reason", "rationale", "basis", "harmonic_evidence", "project_dir"]
        guard Set(args.keys).isSubset(of: allowed),
              let rationale = args["rationale"] as? String, !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              args["basis"] == nil || args["basis"] as? String == "inferred" else {
            throw ToolError("record_affect needs a rationale and inferred basis; signal measurements stay separate.")
        }
        let detected = try weighted(args["detected"], name: "detected")
        let destination = PipelineLayout.url(MusicAffectEvidenceV1.path, in: dataRoot)
        var prior: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: destination.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            let safe = try ProjectLocalFile.resolve(MusicAffectEvidenceV1.path, dataRoot: dataRoot)
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: safe)) as? [String: Any] else {
                throw ToolError("Existing affect record is unreadable; preserve it and repair the source before recording.")
            }
            prior = object
        }
        var profile: [String: Any] = ["detected": detected, "rationale": rationale, "basis": "inferred"]
        let action = args["override_action"] as? String ?? (args["override"] == nil ? "preserve" : "set")
        switch action {
        case "preserve":
            guard args["override"] == nil, args["override_reason"] == nil else {
                throw ToolError("Use override_action=set to change the desired video affect.")
            }
            if let override = prior["override"] as? [[String: Any]], !override.isEmpty {
                profile["override"] = override
                profile["override_reason"] = prior["override_reason"] ?? "Prior override; its original reason was not recorded."
            }
        case "set":
            let override = try weighted(args["override"], name: "override")
            guard !override.isEmpty, let reason = args["override_reason"] as? String,
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("A deliberate user override requires desired tags and the user's reason.")
            }
            profile["override"] = override
            profile["override_reason"] = reason
        case "clear":
            guard args["override"] == nil, let reason = args["override_reason"] as? String,
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("Clearing an override requires the user's reason and no override tags.")
            }
            profile["override_clear_reason"] = reason
        default:
            throw ToolError("Unknown override_action; use preserve, set or clear.")
        }
        if let draft = args[MusicAffectEvidenceV1.key] as? [String: Any] {
            profile[MusicAffectEvidenceV1.key] = try MusicAffectEvidenceV1.materialize(draft, dataRoot: dataRoot)
            try MusicAffectEvidenceV1.validateProfile(profile, dataRoot: dataRoot)
        } else {
            guard args[MusicAffectEvidenceV1.key] == nil, prior[MusicAffectEvidenceV1.key] == nil,
                  !MusicAffectEvidenceV1.requiresEvidence(dataRoot: dataRoot), !detected.isEmpty else {
                throw ToolError("record_affect requires harmonic_evidence for every measured section; it cannot silently erase existing evidence.")
            }
        }
        _ = try ProjectLocalFile.ensureDirectory("analysis", dataRoot: dataRoot)
        try MusicAffectEvidenceV1.canonical(profile).write(to: destination, options: .atomic)
        return profile
    }

    private static func weighted(_ value: Any?, name: String) throws -> [[String: Any]] {
        guard let entries = value as? [[String: Any]] else { throw ToolError("\(name) must be an array of weighted affect tags.") }
        var seen = Set<String>()
        return try entries.map { entry in
            guard Set(entry.keys).isSubset(of: ["tag", "weight"]),
                  let tag = entry["tag"] as? String, AffectTagVocabulary.all.contains(tag), seen.insert(tag).inserted,
                  let weight = (entry["weight"] ?? 1) as? NSNumber,
                  CFGetTypeID(weight) != CFBooleanGetTypeID(), weight.doubleValue.isFinite, weight.doubleValue > 0 else {
                throw ToolError("\(name) needs distinct vocabulary tags and finite positive weights.")
            }
            return ["value": tag, "weight": weight.doubleValue]
        }
    }
}
