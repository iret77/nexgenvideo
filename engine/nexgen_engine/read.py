"""Read-only JSON entrypoint for the native host (the Swift cockpit UI).

`python -m nexgen_engine.read <kind> <project_dir>` prints one JSON document to
stdout for the requested *kind*, reusing the engine's existing read functions
(no logic is duplicated here). The contract is deliberately narrow and stable:
stdout is always parseable JSON, errors are `{"error": "<message>"}` and never a
traceback, so the host can decode the result unconditionally.

Kinds:
  state     → project snapshot (mcp_server.project_state)
  bible     → Bible dict or null (mcp_server.bible)
  sanity    → audit findings dict, or {"error":"no shotlist", ...} (mcp_server.run_sanity)
  phases    → ordered phase list incl. active-pack phases (mcp_server.phases)
  shotlist  → latest shotlist dict or null (shotlist.schema.load(...).model_dump)
  frames    → frame candidates per shot from disk (frames.inventory.inventory)
  ledger    → the Intent Ledger (ledger.schema.load)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from nexgen_engine import mcp_server
from nexgen_engine.frames import inventory as frames_inventory
from nexgen_engine.ledger import schema as ledger_schema
from nexgen_engine.shotlist import schema as shotlist_schema

KINDS = ("state", "bible", "sanity", "phases", "shotlist", "frames", "ledger")


def _shotlist(project_dir: str) -> dict[str, Any] | None:
    sl = shotlist_schema.load(Path(project_dir))
    return sl.model_dump(by_alias=True, mode="json") if sl is not None else None


def read(kind: str, project_dir: str | None) -> Any:
    """Return the JSON-serializable value for *kind*. Raises on a bad request;
    the caller turns any exception into an `{"error": ...}` document."""
    if kind == "phases":
        return mcp_server.phases()
    if kind not in KINDS:
        raise ValueError(f"unknown kind {kind!r}; expected one of {', '.join(KINDS)}")
    if not project_dir:
        raise ValueError(f"kind {kind!r} requires a project_dir")
    if kind == "state":
        return mcp_server.project_state(project_dir)
    if kind == "bible":
        return mcp_server.bible(project_dir)
    if kind == "sanity":
        return mcp_server.run_sanity(project_dir)
    if kind == "shotlist":
        return _shotlist(project_dir)
    if kind == "frames":
        return frames_inventory.inventory(project_dir)
    if kind == "ledger":
        return ledger_schema.load(project_dir).model_dump(by_alias=True, mode="json")
    raise ValueError(f"unhandled kind {kind!r}")  # pragma: no cover


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    kind = args[0] if args else None
    project_dir = args[1] if len(args) > 1 else None

    if kind is None:
        print(json.dumps({"error": "usage: <kind> <project_dir>"}))
        return 2
    if kind not in KINDS:
        print(json.dumps({"error": f"unknown kind {kind!r}; expected one of {', '.join(KINDS)}"}))
        return 2
    if kind != "phases" and not project_dir:
        print(json.dumps({"error": f"kind {kind!r} requires a project_dir"}))
        return 2

    try:
        result = read(kind, project_dir)
    except Exception as e:  # never let a traceback reach stdout
        print(json.dumps({"error": str(e) or e.__class__.__name__}))
        return 1

    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":  # `python -m nexgen_engine.read …` must actually run
    sys.exit(main())
