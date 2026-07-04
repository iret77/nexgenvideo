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
from nexgen_engine.core import gates as gates_mod
from nexgen_engine.core import layout as layout_mod
from nexgen_engine.core.gates import CORE_PHASES
from nexgen_engine.core.modes import Mode
from nexgen_engine.pack import discover_packs
from nexgen_engine.render import costs as costs_mod
from nexgen_engine.render import manifest as manifest_mod
from nexgen_engine.sanity.audit import AuditContext, SanityCheck, audit
from nexgen_engine.sanity.checks import register_core_checks
from nexgen_engine.core import router as core_router
from nexgen_engine.core import ui_contract as core_ui_contract
from nexgen_engine.ledger import schema as ledger_schema
from nexgen_engine.shotlist import schema as shotlist_schema
from nexgen_engine.show.dispatch import show_gate_artifact
from nexgen_engine.state import build_snapshot

mcp = FastMCP("engine")


def project_state(project_dir: str) -> dict[str, Any]:
    # Merged phase order: pack phases (e.g. musicvideo's analysis) appear in the pipeline too.
    return build_snapshot(Path(project_dir), tuple(phases())).model_dump()


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


def init_project(home_dir: str, name: str, mode: str = "beat", budget_eur: float = 50.0) -> dict[str, Any]:
    """Scaffold a fresh project under *home_dir*, merging the active pack's dirs."""
    data_root = layout_mod.init_project(
        Path(home_dir),
        name,
        Mode(mode),
        budget_eur,
        extra_dirs=tuple(discover_packs().engine.project_dirs),
    )
    return {"data_root": str(data_root), "project": name, "created": True}


def approve_gate(project_dir: str, phase: str, notes: str | None = None) -> dict[str, Any]:
    """Approve *phase* and return that phase's updated gate status."""
    g = gates_mod.approve(Path(project_dir), phase, notes=notes)
    gate = g.get(phase)
    return {
        "project": g.project,
        "phase": phase,
        "approved": gate.approved,
        "state": gate.state,
        "approved_at": gate.approved_at,
        "approved_by": gate.approved_by,
        "notes": gate.notes,
    }


def rewind(project_dir: str, target_phase: str) -> dict[str, Any]:
    """Reset *target_phase* and every following phase; return the reset phases."""
    reset = gates_mod.rewind_to(Path(project_dir), target_phase, order=tuple(phases()))
    return {"target": target_phase, "reset_phases": reset}


def estimate_cost(project_dir: str) -> dict[str, Any]:
    """The project's budget picture from the render ledger (no forward estimate)."""
    root = Path(project_dir)
    snap = build_snapshot(root, tuple(phases()))  # merged order — pack phases count too
    spent = costs_mod.already_spent_in_project(root)
    return {
        "project": snap.project,
        "budget_eur": snap.budget_eur,
        "spent_eur": spent,
        "remaining_eur": max(0.0, snap.budget_eur - spent),
        "over_budget": spent > snap.budget_eur,
        "next_phase": snap.next_phase,
    }


def show_artifact(project_dir: str, gate: str) -> dict[str, Any]:
    """The Markdown a gate's artifact formatter produces (or a 'nothing yet' note)."""
    return {"gate": gate, "markdown": show_gate_artifact(Path(project_dir), gate)}


def _dump_phase_result(result: Any) -> Any:
    """Best-effort JSON-friendly form of whatever a phase runner returns."""
    dump = getattr(result, "model_dump", None)
    if callable(dump):
        return dump(mode="json")
    if isinstance(result, (dict, list, str, int, float, bool)) or result is None:
        return result
    return str(result)


def run_phase(project_dir: str, phase: str) -> dict[str, Any]:
    """Run a pack-registered pipeline phase runner, dispatched generically by name."""
    runner = discover_packs().engine.phases.get(phase)
    if runner is None:
        return {
            "phase": phase,
            "runner": None,
            "note": "no code runner registered; this phase is agent-driven",
        }
    try:
        result = runner(Path(project_dir))
    except (ModuleNotFoundError, ImportError) as e:
        return {
            "phase": phase,
            "error": "missing_dependencies",
            "detail": str(e),
            "hint": "This phase needs optional dependencies. Install the plugin's "
            "extra (e.g. the musicvideo [audio] stack) to run it.",
        }
    except Exception as e:
        return {"phase": phase, "error": "phase_failed", "detail": str(e)}
    return {"phase": phase, "ok": True, "result": _dump_phase_result(result)}


def _ordered_shot_ids(project_dir: Path) -> list[str]:
    """Ordered shot IDs from the latest shotlist (empty if no shotlist yet).

    Only the ordered IDs are read — no music/song fields are touched."""
    shotlist = shotlist_schema.load(project_dir)
    return [s.id for s in shotlist.shots] if shotlist is not None else []


def next_render_shot(project_dir: str, phase: str) -> dict[str, Any]:
    """The next unrendered shot for *phase*, plus its prompt/framing for the agent."""
    root = Path(project_dir)
    shotlist = shotlist_schema.load(root)
    ordered = [s.id for s in shotlist.shots] if shotlist is not None else []
    man = manifest_mod.load(root, phase)
    shot_id = manifest_mod.next_unrendered(ordered, man)
    if shot_id is None:
        return {"phase": phase, "shot_id": None, "done": True}
    shot = next((s for s in shotlist.shots if s.id == shot_id), None) if shotlist else None
    return {
        "phase": phase,
        "shot_id": shot_id,
        "done": False,
        "visual_prompt": shot.visual_prompt if shot else None,
        "framing": shot.framing.value if shot and shot.framing else None,
    }


def record_render(
    project_dir: str,
    phase: str,
    shot_id: str,
    output: str | None,
    cost_eur: float = 0.0,
    status: str = "rendered",
) -> dict[str, Any]:
    """Upsert a shot's render result into the phase manifest and persist it."""
    root = Path(project_dir)
    man = manifest_mod.load(root, phase)
    manifest_mod.record(
        man, shot_id, output=output, cost_eur=cost_eur, status=status, phase=phase
    )
    manifest_mod.save(root, man)
    entry = man.entries[shot_id]
    return {
        "phase": phase,
        "shot_id": shot_id,
        "status": entry.status,
        "output": entry.output,
        "cost_eur": entry.cost_eur,
        "updated_at": entry.updated_at,
        "spent_eur": manifest_mod.spent(man),
    }


def get_render_manifest(project_dir: str, phase: str) -> dict[str, Any]:
    """The phase manifest's entries plus its rendered/pending/failed/spend summary."""
    root = Path(project_dir)
    ordered = _ordered_shot_ids(root)
    man = manifest_mod.load(root, phase)
    return {
        "project": man.project,
        "phase": phase,
        "entries": {sid: e.model_dump() for sid, e in man.entries.items()},
        "summary": manifest_mod.summary(ordered, man),
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


@mcp.tool(name="init_project")
def init_project_tool(
    home_dir: str, name: str, mode: str = "beat", budget_eur: float = 50.0
) -> dict[str, Any]:
    """Scaffold a fresh project under `home_dir` and return `{data_root, project,
    created}`. WRITES.

    Creates the `_studio/` data root with the engine's format-neutral core subdirs
    PLUS the active pack's own subdirs (e.g. musicvideo adds audio/lyrics/analysis),
    and writes `project.yaml` (mode, budget) and `gates.yaml`. `mode` is one of
    beat/phrase/section/multicam. Fails if `home_dir` already holds a project."""
    return init_project(home_dir, name, mode, budget_eur)


@mcp.tool(name="approve_gate")
def approve_gate_tool(project_dir: str, phase: str, notes: str | None = None) -> dict[str, Any]:
    """Approve a production gate so the next phase may run. WRITES.

    Stamps `phase`'s gate approved (with optional `notes`) and returns the updated
    `{project, phase, approved, approved_at, approved_by, notes}`. `project_dir` is
    the `_studio/` data root."""
    return approve_gate(project_dir, phase, notes)


@mcp.tool(name="rewind")
def rewind_tool(project_dir: str, target_phase: str) -> dict[str, Any]:
    """Rewind the pipeline to `target_phase`. WRITES.

    Resets `target_phase` and every following phase (in the merged core+pack phase
    order, so pack phases like `analysis` sit in the right place) to unapproved;
    artifacts are kept. Returns `{target, reset_phases}`. `project_dir` is the
    `_studio/` data root."""
    return rewind(project_dir, target_phase)


@mcp.tool(name="estimate_cost")
def estimate_cost_tool(project_dir: str) -> dict[str, Any]:
    """The project's budget picture. Read-only.

    Sums EUR already spent across the render ledger and compares against the
    project budget, returning `{project, budget_eur, spent_eur, remaining_eur,
    over_budget}`. This is the spent/remaining view (not a forward per-shot
    estimate — that requires a shotlist and a priced cost config). `project_dir`
    is the `_studio/` data root."""
    return estimate_cost(project_dir)


@mcp.tool(name="show_artifact")
def show_artifact_tool(project_dir: str, gate: str) -> dict[str, Any]:
    """The Markdown for a gate's artifact, for user review before approval. Read-only.

    Dispatches `gate` (brief/production_design/treatment/storyboard/bible/shotlist/
    analysis/render) to its formatter and returns `{gate, markdown}`. A gate with no
    formatter, or one whose artifact isn't written yet, yields a clear "nothing yet"
    string instead of raising. `project_dir` is the `_studio/` data root."""
    return show_artifact(project_dir, gate)


@mcp.tool(name="run_phase")
def run_phase_tool(project_dir: str, phase: str) -> dict[str, Any]:
    """Run a registered pipeline phase for the project. WRITES.

    Dispatches to whatever phase runner the active pack registered under `phase`
    (e.g. musicvideo's `analysis`) and runs it — heavy compute may be involved.
    A phase runner may write artifacts into the project. The planning phases
    (brief/treatment/storyboard/…) are agent-driven and have no code runner; for
    those this returns `{phase, runner: null, note: ...}` rather than raising.

    If a runner exists but its optional dependencies are absent (e.g. analysis
    needs the musicvideo `[audio]` stack), returns `{phase, error:
    "missing_dependencies", detail, hint}`; any other failure returns `{phase,
    error: "phase_failed", detail}`. On success returns `{phase, ok: true,
    result}`. `project_dir` is the `_studio/` data root."""
    return run_phase(project_dir, phase)


@mcp.tool(name="next_render_shot")
def next_render_shot_tool(project_dir: str, phase: str) -> dict[str, Any]:
    """The next shot to render for `phase`, in shotlist order. Read-only.

    Loads the latest shotlist (for ordered shot IDs) and the phase's render manifest,
    then returns the first shot whose entry is missing or not yet `rendered`, with its
    `visual_prompt` and `framing` so the agent can drive nexgen's own
    generateImage/generateVideo. Returns `{phase, shot_id: null, done: true}` once every
    shot is rendered (or when there's no shotlist). `project_dir` is the `_studio/` data
    root; `phase` is the render phase (e.g. preview/final)."""
    return next_render_shot(project_dir, phase)


@mcp.tool(name="record_render")
def record_render_tool(
    project_dir: str,
    phase: str,
    shot_id: str,
    output: str | None,
    cost_eur: float = 0.0,
    status: str = "rendered",
) -> dict[str, Any]:
    """Record a shot's render result into the phase manifest. WRITES.

    Upserts `shot_id`'s entry (status, `output` path-or-URL, `cost_eur`) into
    `renders/manifest-<phase>.json`, stamps `updated_at`, and returns the saved entry
    plus the manifest's running `spent_eur`. `status` is one of rendered/pending/failed.
    `project_dir` is the `_studio/` data root."""
    return record_render(project_dir, phase, shot_id, output, cost_eur, status)


@mcp.tool(name="get_render_manifest")
def get_render_manifest_tool(project_dir: str, phase: str) -> dict[str, Any]:
    """The phase's render manifest and its progress summary. Read-only.

    Returns `{project, phase, entries, summary}` where `entries` maps shot_id → its
    render record and `summary` is `{total, rendered, pending, failed, spent_eur}`
    (`total` from the latest shotlist's shot count). `project_dir` is the `_studio/`
    data root."""
    return get_render_manifest(project_dir, phase)


@mcp.tool(name="get_ledger")
def get_ledger_tool(project_dir: str) -> dict[str, Any]:
    """The Intent Ledger: the director's durable creative decisions per object. Read-only.

    Returns `{schema, objects}` where `objects` maps `<kind>:<id>` (or the `look`/`film`
    singletons) to named attributes `{tag, directive, source, locked, updated}`. Locked
    attributes are hard facts generation MUST honor. `project_dir` is the `_studio/` data root."""
    return ledger_schema.load(project_dir).model_dump(by_alias=True, mode="json")


@mcp.tool(name="set_ledger_attribute")
def set_ledger_attribute_tool(
    project_dir: str,
    kind: str,
    key: str,
    tag: str,
    object_id: str | None = None,
    directive: str = "",
    source: str = "",
    locked: bool | None = None,
) -> dict[str, Any]:
    """Create or update ONE ledger attribute (reconcile — update the existing key rather than
    inventing near-duplicate keys). WRITES.

    `kind` is one of character/ensemble/prop/location/shot (needs `object_id` = the Bible/shot
    id) or look/film (singletons, no `object_id`). `tag` is the short visible handle
    ("Wardrobe: faded red canvas jacket"); `directive` the model-ready phrasing (defaults to
    the tag); `source` the user's original words. An existing lock survives unless `locked` is
    passed explicitly. `project_dir` is the `_studio/` data root."""
    return ledger_schema.set_attribute(
        project_dir, kind, object_id, key, tag,
        directive=directive, source=source, locked=locked,
    )


@mcp.tool(name="lock_ledger_attribute")
def lock_ledger_attribute_tool(
    project_dir: str, kind: str, key: str, object_id: str | None = None, locked: bool = True
) -> dict[str, Any]:
    """Lock (or unlock) an existing ledger attribute. WRITES. A locked attribute is a promise:
    the prompt generator must include it and reviews check it; it cannot be removed while
    locked. `project_dir` is the `_studio/` data root."""
    return ledger_schema.set_locked(project_dir, kind, object_id, key, locked)


@mcp.tool(name="remove_ledger_attribute")
def remove_ledger_attribute_tool(
    project_dir: str, kind: str, key: str, object_id: str | None = None
) -> dict[str, Any]:
    """Remove an UNLOCKED ledger attribute (locked ones must be unlocked first). WRITES.
    `project_dir` is the `_studio/` data root."""
    return ledger_schema.remove_attribute(project_dir, kind, object_id, key)


@mcp.tool(name="resolve_model")
def resolve_model_tool(task_class: str, escalate: bool = False, project_dir: str = "") -> dict[str, Any]:
    """Which model + effort a task gets (docs/UI_UX_CONCEPT.md §6). Read-only.

    `task_class` is one of distill/classification/assembly/review/planning/interpretation.
    Returns `{task_class, tier, model, effort, escalated}` — the fixed floor, or with
    `escalate=true` exactly ONE tier up (use only after a concrete gate failure: lint error,
    schema violation, user reject; never speculatively). Optional `project_dir` (the `_studio/`
    data root) applies the project's models.yaml manifest override."""
    return core_router.resolve(task_class, escalate=escalate, project_dir=project_dir or None)


@mcp.tool(name="get_ui_contract")
def get_ui_contract_tool() -> dict[str, Any]:
    """Per-phase UI contract: the default interaction surface (choice/prose/review) and router
    task class for every phase (engine core + installed packs). Read-only."""
    return core_ui_contract.full_contract()


@mcp.tool(name="set_gate_state")
def set_gate_state_tool(
    project_dir: str, phase: str, state: str, notes: str | None = None
) -> dict[str, Any]:
    """Record the multi-state gate verdict (docs/UI_UX_CONCEPT.md §4). WRITES.

    `state` is one of approved / approved_with_notes / needs_revision / pending. Only the two
    approve states unblock the pipeline; `needs_revision` keeps the phase blocked and carries
    the reviewer's notes. `project_dir` is the `_studio/` data root."""
    g = gates_mod.set_state(Path(project_dir), phase, state, notes=notes)
    gate = g.get(phase)
    return {
        "project": g.project,
        "phase": phase,
        "state": gate.state,
        "approved": gate.approved,
        "notes": gate.notes,
    }


def main() -> None:  # pragma: no cover
    """Run the engine MCP server over stdio (default FastMCP transport)."""
    mcp.run()


if __name__ == "__main__":  # `python -m nexgen_engine.mcp_server` must actually start the server
    main()
