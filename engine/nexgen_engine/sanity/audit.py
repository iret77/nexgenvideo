"""Registry-driven sanity audit runner.

Unlike the legacy orchestrator (which hardcoded ~27 check imports and called
them in a fixed order), the engine runs whatever checks are registered on an
`EngineRegistry`. The engine ships a small set of format-neutral built-in
checks (see `register_core_checks`); a format pack adds its own domain checks
via `registry.register_sanity_check(name, check)`.

Check contract
--------------
A sanity check is a plain callable::

    def check(ctx: AuditContext) -> list[Finding]: ...

It receives an `AuditContext` (the loaded project artifacts a check may read)
and returns zero or more `Finding`s. Checks are pure: they read the context and
return findings, they never mutate it. A check that needs an artifact the
context does not carry (e.g. `brief is None`) returns `[]`.

The runner calls every registered check, concatenates the findings (sorted by
registration name for deterministic order) into a `SanityReport`, and returns
it. A check that raises is isolated: the runner records an `AUDIT_CHECK_FAILED`
error finding for that check and continues, so one broken check cannot abort the
whole audit.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Mapping

from nexgen_engine.bible.schema import Bible
from nexgen_engine.brief.schema import Brief
from nexgen_engine.render.costs import CostsConfig
from nexgen_engine.sanity.models import Finding, Level, SanityReport
from nexgen_engine.shotlist.schema import Shotlist

__all__ = [
    "AuditContext",
    "SanityCheck",
    "Finding",
    "Level",
    "SanityReport",
    "audit",
]


@dataclass(frozen=True)
class AuditContext:
    """Everything a sanity check may read about a project.

    Kept minimal and format-neutral: the shotlist plus the optional concept
    artifacts. A pack check that needs more (audio analysis, render manifests)
    pulls it from `extra` or reads its own pack project dirs — the engine does
    not bake domain knowledge into this struct.

    `brief` / `bible` are optional because not every project has reached those
    phases; a check that needs one returns `[]` when it is absent.
    """

    shotlist: Shotlist
    brief: Brief | None = None
    bible: Bible | None = None
    costs: CostsConfig | None = None
    extra: Mapping[str, object] | None = None


# A check reads the context and returns findings. Opaque to the runner.
SanityCheck = Callable[[AuditContext], list[Finding]]


def audit(
    ctx: AuditContext,
    checks: Mapping[str, SanityCheck],
) -> SanityReport:
    """Run every registered check over `ctx` and aggregate a `SanityReport`.

    Args:
        ctx: the loaded project artifacts the checks read.
        checks: the registered checks, name -> callable. Pass an
            `EngineRegistry.sanity_checks` dict (or any mapping) here.

    Checks run in name order for a stable report. A check that raises is caught
    and surfaced as an `AUDIT_CHECK_FAILED` error rather than aborting the run.
    """
    report = SanityReport(project=ctx.shotlist.project)
    for name in sorted(checks):
        check = checks[name]
        try:
            findings = check(ctx)
        except Exception as exc:  # one bad check must not sink the audit
            report.findings.append(
                Finding(
                    "error",
                    "AUDIT_CHECK_FAILED",
                    None,
                    f"sanity check {name!r} raised {type(exc).__name__}: {exc}",
                )
            )
            continue
        report.findings.extend(findings)
    return report
