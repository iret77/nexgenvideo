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

from nexgen_engine.core.gates import CORE_PHASES
from nexgen_engine.state import build_snapshot

mcp = FastMCP("engine")


def project_state(project_dir: str) -> dict[str, Any]:
    return build_snapshot(Path(project_dir)).model_dump()


def phases() -> list[str]:
    return list(CORE_PHASES)


@mcp.tool()
def get_project_state(project_dir: str) -> dict[str, Any]:
    """Where a project stands: meta, gate/phase status, next open phase. Read-only.
    `project_dir` is the project's data root (the `_studio/` folder)."""
    return project_state(project_dir)


@mcp.tool()
def list_phases() -> list[str]:
    """The production pipeline phases, in order (engine core + active pack)."""
    return phases()


def main() -> None:  # pragma: no cover
    """Run the engine MCP server over stdio (default FastMCP transport)."""
    mcp.run()
