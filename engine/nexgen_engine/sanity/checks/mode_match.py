"""Shotlist vs brief consistency: MODE_MISMATCH.

The brief declares the project mode up front; the shotlist carries a concrete
`Mode`. If they disagree the shotlist was generated against a different layout
than the brief asked for. Returns nothing when there is no brief.
"""

from __future__ import annotations

from nexgen_engine.sanity.audit import AuditContext
from nexgen_engine.sanity.models import Finding


def check(ctx: AuditContext) -> list[Finding]:
    out: list[Finding] = []
    brief = ctx.brief
    if brief is None:
        return out
    if brief.project_mode != ctx.shotlist.mode.value:
        out.append(
            Finding(
                "error", "MODE_MISMATCH", None,
                f"shotlist mode={ctx.shotlist.mode.value}, "
                f"brief project_mode={brief.project_mode}",
            )
        )
    return out
