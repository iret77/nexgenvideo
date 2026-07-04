"""The Intent Ledger: durable creative memory on objects (docs/UI_UX_CONCEPT.md §5).

Each addressable object — a Bible entity (``character``/``ensemble``/``prop``/``location``), a
``shot``, or the ``look``/``film`` singletons — carries named attributes with three layers:

- ``tag``       — the short, always-visible handle ("Wardrobe: faded red canvas jacket")
- ``directive`` — the clean, model-ready phrasing the prompt generator composes from
- ``source``    — the user's original words / provenance, kept as history

``locked`` attributes are facts generation must honor and the compliance linter checks. The
ledger lives in ``<data-root>/ledger.yaml`` (schema ``ledger/v1``) — deliberately outside the
Bible, so regenerating the Bible never wipes the director's decisions. Writes happen through
the agent (MCP tools); the host UI reads.
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, Field

from nexgen_engine.core import paths

SCHEMA = "ledger/v1"
FILENAME = "ledger.yaml"
ENTITY_KINDS = ("character", "ensemble", "prop", "location", "shot")
SINGLETON_KINDS = ("look", "film")
OBJECT_KINDS = ENTITY_KINDS + SINGLETON_KINDS


class Attribute(BaseModel):
    tag: str
    directive: str = ""
    source: str = ""
    locked: bool = False
    updated: str = ""


class Ledger(BaseModel):
    schema_: str = Field(default=SCHEMA, alias="schema")
    objects: dict[str, dict[str, Attribute]] = Field(default_factory=dict)

    model_config = {"populate_by_name": True}


def object_key(kind: str, object_id: str | None = None) -> str:
    """Canonical ledger key: ``<kind>:<id>`` for entities/shots, the bare kind for singletons."""
    if kind not in OBJECT_KINDS:
        raise ValueError(f"unknown object kind {kind!r}; expected one of {', '.join(OBJECT_KINDS)}")
    if kind in SINGLETON_KINDS:
        return kind
    if not object_id:
        raise ValueError(f"object kind {kind!r} requires an object_id")
    return f"{kind}:{object_id}"


def _data_root(project_dir: str | Path) -> Path:
    root = paths.data_root_of(Path(project_dir))
    if root is None:
        raise ValueError(f"no project at {project_dir}")
    return root


def load(project_dir: str | Path) -> Ledger:
    path = _data_root(project_dir) / FILENAME
    if not path.is_file():
        return Ledger()
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        return Ledger()
    return Ledger.model_validate(data)


def save(project_dir: str | Path, ledger: Ledger) -> Path:
    path = _data_root(project_dir) / FILENAME
    path.write_text(
        yaml.safe_dump(
            ledger.model_dump(by_alias=True, mode="json"),
            sort_keys=False,
            allow_unicode=True,
        ),
        encoding="utf-8",
    )
    return path


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def set_attribute(
    project_dir: str | Path,
    kind: str,
    object_id: str | None,
    key: str,
    tag: str,
    directive: str = "",
    source: str = "",
    locked: bool | None = None,
) -> dict[str, Any]:
    """Create or update (reconcile, don't append) one attribute. An existing lock survives an
    update unless ``locked`` is passed explicitly."""
    if not key.strip():
        raise ValueError("attribute key must not be empty")
    if not tag.strip():
        raise ValueError("attribute tag must not be empty")
    ledger = load(project_dir)
    obj_key = object_key(kind, object_id)
    attributes = ledger.objects.setdefault(obj_key, {})
    existing = attributes.get(key)
    attributes[key] = Attribute(
        tag=tag.strip(),
        directive=directive.strip() or tag.strip(),
        source=source.strip() or (existing.source if existing else ""),
        locked=locked if locked is not None else (existing.locked if existing else False),
        updated=_now(),
    )
    save(project_dir, ledger)
    return {"object": obj_key, "key": key, "attribute": attributes[key].model_dump(mode="json")}


def set_locked(
    project_dir: str | Path, kind: str, object_id: str | None, key: str, locked: bool
) -> dict[str, Any]:
    ledger = load(project_dir)
    obj_key = object_key(kind, object_id)
    attribute = ledger.objects.get(obj_key, {}).get(key)
    if attribute is None:
        raise ValueError(f"no attribute {key!r} on {obj_key}")
    attribute.locked = locked
    attribute.updated = _now()
    save(project_dir, ledger)
    return {"object": obj_key, "key": key, "attribute": attribute.model_dump(mode="json")}


def remove_attribute(
    project_dir: str | Path, kind: str, object_id: str | None, key: str
) -> dict[str, Any]:
    """Locked attributes must be unlocked explicitly before removal — a lock is a promise."""
    ledger = load(project_dir)
    obj_key = object_key(kind, object_id)
    attributes = ledger.objects.get(obj_key, {})
    attribute = attributes.get(key)
    if attribute is None:
        raise ValueError(f"no attribute {key!r} on {obj_key}")
    if attribute.locked:
        raise ValueError(f"attribute {key!r} on {obj_key} is locked; unlock it first")
    del attributes[key]
    if not attributes:
        del ledger.objects[obj_key]
    save(project_dir, ledger)
    return {"object": obj_key, "key": key, "removed": True}
