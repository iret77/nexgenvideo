"""Per-shot visual-prompt quality (length + generic-slop heuristics).

- PROMPT_TOO_SHORT (error): a prompt this short cannot carry the required
  components (subject+action / position / setting / camera / light+mood).
- PROMPT_THIN (warn): borderline — one of those components is probably too terse.
- PROMPT_GENERIC (warn): generic adjectives ("epic", "cinematic masterpiece")
  without concrete image description — slop risk.

This is the format-neutral core of the music pack's richer `prompts` check; the
metaphor / undefined-group / title-card / blocking heuristics stay in the pack
because they depend on pack-specific validators.
"""

from __future__ import annotations

from nexgen_engine.sanity.audit import AuditContext
from nexgen_engine.sanity.models import Finding

_SHORT_LEN = 60
_THIN_LEN = 120
_GENERIC_TOKENS = ("epic", "cinematic masterpiece")
_GENERIC_MAX_LEN = 200


def check(ctx: AuditContext) -> list[Finding]:
    out: list[Finding] = []
    for shot in ctx.shotlist.shots:
        p = shot.visual_prompt.strip()
        if len(p) < _SHORT_LEN:
            out.append(
                Finding(
                    "error", "PROMPT_TOO_SHORT", shot.id,
                    f"visual_prompt only {len(p)} chars — missing required "
                    "components (subject+action / position / setting / "
                    "camera / light+mood)",
                )
            )
        elif len(p) < _THIN_LEN:
            out.append(
                Finding(
                    "warn", "PROMPT_THIN", shot.id,
                    f"visual_prompt only {len(p)} chars — one of the required "
                    "components is probably too terse",
                )
            )
        lower = p.lower()
        if any(w in lower for w in _GENERIC_TOKENS) and len(p) < _GENERIC_MAX_LEN:
            out.append(
                Finding(
                    "warn", "PROMPT_GENERIC", shot.id,
                    "generic adjectives without concrete image description — slop risk",
                )
            )
    return out
