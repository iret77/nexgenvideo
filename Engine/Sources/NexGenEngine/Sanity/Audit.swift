import Foundation

/// Everything a sanity check may read about a project. Kept minimal and
/// format-neutral: the shotlist plus the optional concept artifacts. A pack
/// check that needs more pulls it from `extra` or reads its own pack project
/// dirs — the engine does not bake domain knowledge into this struct.
///
/// `brief` / `bible` are optional because not every project has reached those
/// phases; a check that needs one returns `[]` when it is absent.
///
/// Port of `sanity/audit.py::AuditContext`. Python's dataclass also carries a
/// `costs: CostsConfig | None` field; the engine-only M5 slice ports none of
/// `render/costs.py` (unused by any core check or its tests), so `costs` is
/// omitted here pending whichever work package ports the render/costs module.
public struct AuditContext: Sendable {
    public var shotlist: Shotlist
    public var brief: Brief?
    public var bible: Bible?
    public var extra: [String: String]?

    public init(
        shotlist: Shotlist, brief: Brief? = nil, bible: Bible? = nil, extra: [String: String]? = nil
    ) {
        self.shotlist = shotlist
        self.brief = brief
        self.bible = bible
        self.extra = extra
    }
}

/// A sanity check reads the context and returns findings; opaque to the
/// runner. Checks are pure: they never mutate `ctx`. Port of
/// `sanity/audit.py::SanityCheck`.
public typealias SanityCheck = @Sendable (AuditContext) throws -> [Finding]

/// Runs every check in `checks` over `ctx` and aggregates a `SanityReport`.
///
/// Checks run in name-sorted order for a stable, deterministic report. A
/// check that throws is isolated: the runner records an `AUDIT_CHECK_FAILED`
/// error finding for that check and continues, so one broken check cannot
/// abort the whole audit. Port of `sanity/audit.py::audit`.
public func audit(_ ctx: AuditContext, checks: [String: SanityCheck]) -> SanityReport {
    var report = SanityReport(project: ctx.shotlist.project)
    for name in checks.keys.sorted() {
        let check = checks[name]!
        do {
            let findings = try check(ctx)
            report.findings.append(contentsOf: findings)
        } catch {
            report.findings.append(
                Finding(
                    level: .error,
                    code: "AUDIT_CHECK_FAILED",
                    shotId: nil,
                    message: "sanity check \"\(name)\" raised \(type(of: error)): \(error)"
                )
            )
        }
    }
    return report
}
