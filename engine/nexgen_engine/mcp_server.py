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
from nexgen_engine.brief import schema as brief_schema
from nexgen_engine.core.gates import CORE_PHASES
from nexgen_engine.pack import discover_packs
from nexgen_engine.sanity.audit import AuditContext, SanityCheck, audit
from nexgen_engine.sanity.checks import register_core_checks
from nexgen_engine.shotlist import schema as shotlist_schema
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


def _gather_checks() -> dict[str, SanityCheck]:
    """Engine core checks plus every active pack's checks, merged by name
    (pack checks may override a core check of the same name)."""
    registry = discover_packs().engine
    register_core_checks(registry)
    return dict(registry.sanity_checks)


def run_sanity(project_dir: str) -> dict[str, Any]:
    """Run the full consistency audit (engine core + active-pack checks) for a
    project. Returns a report dict, or an error dict when no shotlist exists."""
    root = Path(project_dir)
    shotlist = shotlist_schema.load(root)
    if shotlist is None:
        return {"error": "no shotlist", "project_dir": project_dir}

    try:
        brief = brief_schema.load(root)
    except FileNotFoundError:
        brief = None
    bible_obj = bible_schema.load(root)

    ctx = AuditContext(shotlist=shotlist, brief=brief, bible=bible_obj)
    report = audit(ctx, _gather_checks())
    return {
        "project": report.project,
        "findings": [
            {
                "level": f.level,
                "code": f.code,
                "shot_id": f.shot_id,
                "message": f.message,
            }
            for f in report.findings
        ],
    }


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


@mcp.tool(name="run_sanity")
def run_sanity_tool(project_dir: str) -> dict[str, Any]:
    """Run the full consistency audit for the project and return its findings.

    Loads the latest shotlist plus any brief/bible, runs every engine-core check
    AND every active-pack check, and returns `{project, findings:[{level, code,
    shot_id, message}]}`. If the project has no shotlist yet, returns
    `{"error": "no shotlist", ...}` instead of raising. Read-only. `project_dir`
    is the `_studio/` data root."""
    return run_sanity(project_dir)


def main() -> None:  # pragma: no cover
    """Run the engine MCP server over stdio (default FastMCP transport)."""
    mcp.run()
