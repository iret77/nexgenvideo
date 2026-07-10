import Foundation

/// Sums EUR already spent across every `renders/manifest-<phase>.json` in a
/// project. Port of `render/costs.py::already_spent_in_project` (Bug 22 /
/// v0.11.5).
///
/// Globs the render manifests (rather than loading one phase) and sums each
/// manifest entry's cost. Faithful to the Python: an unreadable/undecodable
/// manifest file is skipped, the `renders/` dir absent → 0.0, and the total is
/// rounded to 2 places. Each manifest is loaded through the M1 `RenderManifest`
/// decoder, whose `cost_eur ?? eur_spent` mapping reproduces the Python's
/// per-shot `eur_spent` read for engine-written and fixture manifests alike.
///
/// `excludePhase` skips one phase (e.g. the current run being recalculated).
public func alreadySpentInProject(dataRoot: URL, excludePhase: Phase? = nil) -> Double {
    let rendersDir = PipelineLayout.url(PipelineLayout.rendersDir, in: dataRoot)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: rendersDir.path, isDirectory: &isDir),
        isDir.boolValue
    else {
        return 0.0
    }

    let contents =
        (try? FileManager.default.contentsOfDirectory(
            at: rendersDir, includingPropertiesForKeys: nil
        )) ?? []

    var total = 0.0
    for url in contents {
        let name = url.lastPathComponent
        // Match `manifest-*.json` (the glob in the Python).
        guard name.hasPrefix("manifest-"), name.hasSuffix(".json") else { continue }
        // Phase from filename: manifest-preview.json → preview (split on the
        // first "-", mirroring `manifest_path.stem.split("-", 1)`).
        let stem = String(name.dropLast(".json".count))
        let stemParts = stem.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if stemParts.count == 2, let excludePhase, String(stemParts[1]) == excludePhase.rawValue {
            continue
        }
        // Unreadable / undecodable manifest → skip the file (Python catches
        // JSONDecodeError/OSError). The M1 decoder tolerates malformed rows the
        // same way `_from_disk` does.
        guard let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(RenderManifest.self, from: data)
        else {
            continue
        }
        for entry in manifest.entries.values {
            total += entry.costEur
        }
    }
    return pyRound(total, 2)
}

/// Pre-flight cost-guard finding — the caller decides how to react. Port of
/// `render/costs.py::CostGuardVerdict`.
public struct CostGuardVerdict: Sendable, Equatable {
    public var newRunEur: Double
    public var alreadySpentEur: Double
    /// new_run + already_spent (project-wide).
    public var projectTotalEur: Double
    public var budgetEur: Double
    /// project_total > budget.
    public var overBudget: Bool
    /// new_run >= confirm_threshold_eur.
    public var needsConfirmation: Bool
    public var confirmThresholdEur: Double

    public init(
        newRunEur: Double, alreadySpentEur: Double, projectTotalEur: Double, budgetEur: Double,
        overBudget: Bool, needsConfirmation: Bool, confirmThresholdEur: Double
    ) {
        self.newRunEur = newRunEur
        self.alreadySpentEur = alreadySpentEur
        self.projectTotalEur = projectTotalEur
        self.budgetEur = budgetEur
        self.overBudget = overBudget
        self.needsConfirmation = needsConfirmation
        self.confirmThresholdEur = confirmThresholdEur
    }

    /// Pretty-print for CLI output. Port of `CostGuardVerdict.message`.
    /// USD ≈ EUR (the fal prices are noted 1:1 EUR=USD in the costs.yaml header,
    /// so no artificial 0.95 inflation).
    public func message() -> String {
        let newUsd = newRunEur
        let projUsd = projectTotalEur
        var lines = [
            "Geschaetzte Kosten dieses Runs: \(pyFixed2(newRunEur)) EUR "
                + "(~$\(pyFixed2(newUsd)))"
        ]
        if alreadySpentEur > 0 {
            lines.append(
                "Bereits ausgegeben in vorherigen Renders: \(pyFixed2(alreadySpentEur)) EUR"
            )
            lines.append(
                "Projekt-Total nach diesem Run: \(pyFixed2(projectTotalEur)) EUR "
                    + "(~$\(pyFixed2(projUsd))), Budget: \(pyFixed2(budgetEur)) EUR"
            )
        }
        return lines.joined(separator: "\n")
    }
}

/// Pre-flight cost-guard. Port of `render/costs.py::cost_guard_check`.
///
/// Reads project-wide prior spend from the manifests (`excludePhase=phase`,
/// since the current run isn't in a manifest yet — otherwise a previous run of
/// the same phase would double-count), compares (new + spent) against budget,
/// and sets `needsConfirmation` when new_run >= confirm threshold. The hard stop
/// is the caller's; this only returns data + diagnosis.
public func costGuardCheck(
    dataRoot: URL, estimateEur: Double, phase: Phase, budgetEur: Double, guard costGuard: CostGuard
) -> CostGuardVerdict {
    let already =
        costGuard.projectWideBudget
        ? alreadySpentInProject(dataRoot: dataRoot, excludePhase: phase) : 0.0
    let total = pyRound(estimateEur + already, 2)
    return CostGuardVerdict(
        newRunEur: estimateEur,
        alreadySpentEur: already,
        projectTotalEur: total,
        budgetEur: budgetEur,
        overBudget: total > budgetEur,
        needsConfirmation: estimateEur >= costGuard.confirmThresholdEur,
        confirmThresholdEur: costGuard.confirmThresholdEur
    )
}

/// Python's `f"{x:.2f}"` — fixed two decimal places, used by
/// `CostGuardVerdict.message`.
private func pyFixed2(_ value: Double) -> String {
    String(format: "%.2f", value)
}
