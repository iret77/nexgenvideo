"""The NexGenVideo pack contract — the standard interface a format pack implements
to extend the Generic Engine.

Layering (see docs/PLUGIN_STANDARD.md, CONCEPT.md §4.1):
- **Core** = nexgen-video (editor/timeline/generation) + the Generic Engine
  (Bible, consistency/reference, sanity framework, render-dispatch, frame-compliance).
  Always bundled + loaded. THIS is the quality motor.
- **Pack** (thin, e.g. musicvideo) = only domain specifics. It registers behavior
  into the engine; it does NOT re-implement Bible/consistency/render, and it does
  NOT call generators itself — generation/timeline go through nexgen's own tools,
  driven by Claude.

This is the v0 contract: the registration *mechanism* is firm; individual runner /
check signatures firm up as the engine extraction (Tier 2) lands.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Protocol, runtime_checkable


@dataclass(frozen=True)
class DurationBand:
    """A min/max shot-duration window for a given mode."""
    label: str
    min_s: float
    max_s: float


@runtime_checkable
class DurationPolicy(Protocol):
    """Seam 1 (music-assumption decoupling): the engine's Shot/sanity logic is
    generic; a pack supplies how a mode maps to a duration band (e.g. music makes
    it BPM-aware via `context`)."""

    def band_for(self, mode: str, context: dict) -> DurationBand: ...


# A phase runner and a sanity check are opaque callables the engine invokes; their
# precise signatures are pinned during the Tier-2 extraction.
PhaseRunner = Callable[..., object]
SanityCheck = Callable[..., object]


class EngineRegistry:
    """Handed to each pack's `register()`; collects the pack's contributions so the
    engine can expose them (phases/checks) through its core MCP surface."""

    def __init__(self) -> None:
        self.phases: dict[str, PhaseRunner] = {}
        self.sanity_checks: dict[str, SanityCheck] = {}
        self.duration_policy: DurationPolicy | None = None
        self.libraries: dict[str, object] = {}
        self.project_dirs: list[str] = []

    def register_phase(self, name: str, runner: PhaseRunner) -> None:
        self.phases[name] = runner

    def register_project_dirs(self, dirs: list[str]) -> None:
        """Extra project-layout subdirs the pack needs (e.g. music: audio/lyrics/analysis).
        The engine creates its own core dirs (bible, treatment, frames, …) regardless."""
        self.project_dirs.extend(dirs)

    def register_sanity_check(self, name: str, check: SanityCheck) -> None:
        self.sanity_checks[name] = check

    def register_duration_policy(self, policy: DurationPolicy) -> None:
        self.duration_policy = policy

    def register_library(self, name: str, library: object) -> None:
        """Domain reference data (e.g. music genre/mood pattern library)."""
        self.libraries[name] = library


@runtime_checkable
class Pack(Protocol):
    """A format pack (e.g. musicvideo). Thin by contract: it registers only
    domain-specific behavior into the engine."""

    name: str
    version: str

    def register(self, registry: EngineRegistry) -> None: ...


class PackRegistry:
    """Loads packs and aggregates their contributions for the engine core."""

    def __init__(self) -> None:
        self.engine = EngineRegistry()
        self.packs: list[Pack] = []

    def load(self, pack: Pack) -> None:
        pack.register(self.engine)
        self.packs.append(pack)
