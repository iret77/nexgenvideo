"""The engine's core MCP server — the standard function-call surface every host
(the embedded `claude -p`, Cursor, any MCP client) drives. Read-only state first;
phase/check tools grow as the engine fills in, and pack-registered phases/checks
surface here too. No LLM calls live here — reasoning stays in the host session.

Registered with the embedded claude alongside the Swift `nexgen` MCP (see
ClaudeCodeLaunch.mcpConfigJSON); together they are the standard surface from
docs/PLUGIN_STANDARD.md.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

from nexgen_engine.bible import schema as bible_schema
from nexgen_engine.core.gates import CORE_PHASES
from nexgen_engine.pack import discover_packs
from nexgen_engine.state import build_snapshot

mcp = FastMCP("engine")


def project_state(project_dir: str) -> dict[str, Any]:
    return build_snapshot(Path(project_dir)).model_dump()


def phases() -> list[str]:
    pack_phases = sorted(p for p in discover_packs().engine.phases if p not in CORE_PHASES)
    return list(CORE_PHASES) + pack_phases


def bible(project_dir: str) -> dict[str, Any] | None:
    b = bible_schema.load(Path(project_dir))
    return b.model_dump(by_alias=True) if b is not None else None


@mcp.tool()
def get_project_state(project_dir: str) -> dict[str, Any]:
    """Where a project stands: meta, gate/phase status, next open phase. Read-only.
    `project_dir` is the project's data root (the `_studio/` folder)."""
    return project_state(project_dir)


@mcp.tool()
def list_phases() -> list[str]:
    """The production pipeline phases, in order (engine core + active pack)."""
    return phases()


@mcp.tool()
def get_bible(project_dir: str) -> dict[str, Any] | None:
    """The asset-graph Bible (characters, ensembles, props, locations, look) — the
    consistency reference for generation — or null if none yet. `project_dir` is the
    `_studio/` data root."""
    return bible(project_dir)


def main() -> None:  # pragma: no cover
    """Run the engine MCP server over stdio (default FastMCP transport)."""
    mcp.run()
