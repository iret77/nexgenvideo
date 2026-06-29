"""Timeline coverage: gaps and overlaps between shots.

- UNCOVERED_GAP (info): a stretch of the timeline with no shot covering it.
- UNCOVERED_TAIL (info): the timeline ends after the last shot.
- SHOT_OVERLAP (warn): two shots overlap in time.

Only meaningful for timeline-laid-out modes (BEAT, SECTION) where shots tile a
continuous duration; modes like MULTICAM (every shot spans the whole duration)
are skipped.
"""

from __future__ import annotations

from nexgen_engine.core.modes import Mode
from nexgen_engine.sanity.audit import AuditContext
from nexgen_engine.sanity.models import Finding


def check(ctx: AuditContext) -> list[Finding]:
    out: list[Finding] = []
    shotlist = ctx.shotlist
    if shotlist.mode not in {Mode.BEAT, Mode.SECTION}:
        return out

    sorted_shots = sorted(shotlist.shots, key=lambda s: s.time_start)

    last_end = 0.0
    for s in sorted_shots:
        if s.time_start > last_end + 0.5:
            out.append(
                Finding(
                    "info", "UNCOVERED_GAP", None,
                    f"gap with no shot: {last_end:.2f}s -> {s.time_start:.2f}s "
                    f"({s.time_start - last_end:.2f}s)",
                )
            )
        last_end = max(last_end, s.time_end)

    timeline_end = shotlist.song.duration_s
    if last_end < timeline_end - 0.5:
        out.append(
            Finding(
                "info", "UNCOVERED_TAIL", None,
                f"timeline ends at {timeline_end:.2f}s, last shot ends at {last_end:.2f}s",
            )
        )

    for a, b in zip(sorted_shots, sorted_shots[1:], strict=False):
        if b.time_start < a.time_end - 0.01:
            out.append(
                Finding(
                    "warn", "SHOT_OVERLAP", b.id,
                    f"overlaps {a.id} ({a.time_end:.2f}s vs {b.time_start:.2f}s)",
                )
            )

    return out
