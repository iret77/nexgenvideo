import Foundation
import NexGenEngine

/// PATTERN_DRIFT measures the shotlist's framing distribution and average shot length against the
/// chosen director pattern. Without it, choosing a pattern is lip service; this
/// makes "chosen" into "executed". Port of `sanity/checks/pattern_drift.py` (Block 7m, section-aware
/// v0.13.0). Fixes the mechanism half of the pattern regression (#185): the ported pattern data now has
/// a live consumer.
///
/// Section-aware: each storyboard `Section.pattern_override` wins over the brief default; sections with
/// an override are checked against their own pattern, the rest against the brief pattern. Escape:
/// `pattern_override: <reason>` in `brief.notes`, or simply no pattern in the brief.
extension MusicvideoChecks {
    /// Per-framing drift tolerance in percentage points (conservative). Port of the Python constant.
    static let patternDriftTolerancePP = 25
    /// Minimum shots before drift measurement is meaningful (small shotlists = high quantization noise).
    static let minShotsForDrift = 6

    public static func patternDriftCheck(_ ctx: AuditContext) throws -> [Finding] {
        var out: [Finding] = []
        guard ctx.shotlist.mode != .multicam else { return out }
        if (ctx.brief?.notes ?? "").lowercased().contains("pattern_override:") { return out }

        let library = (try? Patterns.loadAllPatterns()) ?? []
        guard !library.isEmpty else { return out }
        func pattern(id: String?) -> Pattern? {
            guard let id = id?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
            return library.first { $0.id == id }
        }

        let briefPattern = pattern(id: ctx.brief?.directorPattern)

        // Per-section overrides from the storyboard (needs a data root; passed via ctx.extra).
        var sectionOverrides: [String: String] = [:]
        if let path = ctx.extra?["data_root"],
            let sb = try? StoryboardStore.load(dataRoot: URL(fileURLWithPath: path)) {
            for section in sb.sections {
                let pid = (section.patternOverride ?? "").trimmingCharacters(in: .whitespaces)
                if !pid.isEmpty { sectionOverrides[section.id] = pid }
            }
        }
        if briefPattern == nil && sectionOverrides.isEmpty { return out }

        var sectionShots: [String: [Shot]] = [:]
        for shot in ctx.shotlist.shots {
            sectionShots[shot.section ?? "_unsectioned", default: []].append(shot)
        }
        let sectionsWithOverride = Set(sectionOverrides.keys)

        // Section-specific checks (v0.13.0).
        for (sectionId, shots) in sectionShots.sorted(by: { $0.key < $1.key }) {
            guard sectionsWithOverride.contains(sectionId), shots.count >= minShotsForDrift,
                let sectionPattern = pattern(id: sectionOverrides[sectionId]) else { continue }
            if let finding = driftFinding(sectionPattern, shots: shots, scope: "Section \"\(sectionId)\"") {
                out.append(finding)
            }
        }

        // Project-wide brief check — only over sections WITHOUT an override (overridden ones already checked).
        if let briefPattern {
            let leftover = sectionShots.filter { !sectionsWithOverride.contains($0.key) }.flatMap(\.value)
            if leftover.count >= minShotsForDrift {
                let scope = sectionsWithOverride.isEmpty ? "Project" : "Project (sections without override)"
                if let finding = driftFinding(briefPattern, shots: leftover, scope: scope) {
                    out.append(finding)
                }
            }
        }
        return out
    }

    /// Real framing distribution as integer percentages per `Framing`. Port of `_real_distribution`.
    private static func realDistribution(_ framings: [Framing]) -> [Framing: Int] {
        let total = framings.count
        guard total > 0 else { return [:] }
        var counts: [Framing: Int] = [:]
        for framing in framings { counts[framing, default: 0] += 1 }
        var out: [Framing: Int] = [:]
        for framing in Framing.allCases {
            out[framing] = Int((Double(counts[framing] ?? 0) / Double(total) * 100).rounded())
        }
        return out
    }

    /// Compare the plan with the pattern's framing and pacing targets.
    /// Port of `_drift_finding`.
    private static func driftFinding(_ pattern: Pattern, shots: [Shot], scope: String) -> Finding? {
        let real = realDistribution(shots.compactMap(\.framing))
        var drifts: [(framing: Framing, target: Int, real: Int, delta: Int)] = []
        for (framing, targetPct) in pattern.framingMix.byFraming() {
            let realPct = real[framing] ?? 0
            let delta = realPct - targetPct
            if abs(delta) > patternDriftTolerancePP {
                drifts.append((framing, targetPct, realPct, delta))
            }
        }
        drifts.sort { abs($0.delta) > abs($1.delta) }
        var lines = drifts.prefix(3).map {
            "  \($0.framing.rawValue): real \($0.real)% vs target \($0.target)% "
                + "(\($0.delta > 0 ? "over" : "under") by \(abs($0.delta)) pp)"
        }
        let averageShotLength = shots.map(\.durationS).reduce(0, +) / Double(shots.count)
        if averageShotLength < pattern.aslRange.minS || averageShotLength > pattern.aslRange.maxS {
            lines.append(
                "  average shot length: real \(String(format: "%.2f", averageShotLength))s vs target "
                    + "\(String(format: "%.2f", pattern.aslRange.minS))–"
                    + "\(String(format: "%.2f", pattern.aslRange.maxS))s"
            )
        }
        guard !lines.isEmpty else { return nil }
        return Finding(
            level: .warn, code: "PATTERN_DRIFT", shotId: nil,
            message: "\(scope): pattern \"\(pattern.id)\" (\(pattern.name)) differs from the shotlist. "
                + "Framing tolerance is \(patternDriftTolerancePP)pp; ASL must stay inside its cited range:\n"
                + "\(lines.joined(separator: "\n"))\nFix: revise framing or pacing to match the pattern — or set "
                + "`pattern_override: <reason>` in brief.notes (project-wide), or a Section.pattern_override "
                + "(section-specific).")
    }
}
