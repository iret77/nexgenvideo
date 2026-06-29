"""Built-in, format-neutral sanity checks shipped with the Generic Engine.

These checks read only the core schema (shotlist + brief) — no PIL, no render
registry, no pack-specific storyboard/pattern modules. Pack-specific checks
(tempo, pacing, pattern-drift, frame-resolution/aspect compliance, …) live in
their pack and register the same way via `EngineRegistry.register_sanity_check`.

`register_core_checks(registry)` installs this default set so an audit has
something to run out of the box.
"""

from __future__ import annotations

from nexgen_engine.pack import EngineRegistry
from nexgen_engine.sanity.checks import coverage, mode_match, prompt_quality

__all__ = ["register_core_checks", "CORE_CHECKS"]


# name -> check callable. Names double as the report ordering key.
CORE_CHECKS = {
    "coverage": coverage.check,
    "mode_match": mode_match.check,
    "prompt_quality": prompt_quality.check,
}


def register_core_checks(registry: EngineRegistry) -> None:
    """Register the engine's built-in generic checks onto `registry`.

    Idempotent per name: re-registering overwrites. A pack may register
    additional checks (or override a core check by name) after calling this.
    """
    for name, check in CORE_CHECKS.items():
        registry.register_sanity_check(name, check)
