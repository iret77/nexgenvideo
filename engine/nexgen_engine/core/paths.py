"""Project directory resolution.

Since v0.14 (Studio plan, milestone 0d) projects are decoupled from the
toolkit repo. ``project_dir()`` always returns the *data root* of a
project — the directory that contains ``project.yaml`` / ``brief.yaml``
/ ``gates.yaml``:

- Layout v2 ("studio"):   ``<project-home>/_studio/`` — user-facing
  siblings are ``inbox/``, ``review/``, ``final/``, ``studio.html``.
- Legacy standalone:      ``<project-home>/`` (flat layout).
- Legacy repo-relative:   ``<repo>/projects/<name>/`` (tests, _example).

Resolution order (docs/v1-studio-plan.md, section 0.3):

1. Explicit ``name`` with an existing ``<repo>/projects/<name>``
   (legacy repo layout — keeps tests and old projects working).
2. ``MV_PROJECT_DIR`` environment variable (accepts the project home
   or the data root itself).
3. Upward search from the current working directory for
   ``_studio/project.yaml`` (v2) or ``project.yaml`` (legacy flat).
4. Explicit ``name`` without any match → the legacy repo path is
   returned *without* an existence check, so init flows can create it;
   ``require_project`` raises for missing projects.

When ``name`` is given and resolution happens via (2) or (3), the
``project`` field in ``project.yaml`` must match — this guards against
writing into the wrong project from a stale shell. Mismatches fall
through to (4).
"""

from __future__ import annotations

import os
from pathlib import Path

import yaml

ENV_PROJECT_DIR = "MV_PROJECT_DIR"
STUDIO_DIRNAME = "_studio"
PROJECT_MARKER = "project.yaml"


def repo_root() -> Path:
    """Root of the toolkit repo (the directory containing pyproject.toml)."""
    here = Path(__file__).resolve()
    for parent in [here, *here.parents]:
        if (parent / "pyproject.toml").exists():
            return parent
    raise RuntimeError("pyproject.toml not found — not running from the repo?")


def _is_project_marker(path: Path) -> bool:
    """True if *path* is a readable musicvideo project.yaml.

    Requires both ``project`` and ``mode`` (the two mandatory
    ProjectMeta fields) so the upward cwd search cannot latch onto
    unrelated files that happen to be called project.yaml.
    """
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError):
        return False
    return isinstance(data, dict) and bool(data.get("project")) and bool(data.get("mode"))


def data_root_of(path: Path) -> Path | None:
    """Return the data root if *path* is a project home or data root.

    Checks the v2 layout first (``<path>/_studio/project.yaml``), then
    the flat legacy layout (``<path>/project.yaml``). Returns None if
    *path* is neither.
    """
    path = path.expanduser()
    v2_marker = path / STUDIO_DIRNAME / PROJECT_MARKER
    if v2_marker.is_file() and _is_project_marker(v2_marker):
        return path / STUDIO_DIRNAME
    flat_marker = path / PROJECT_MARKER
    if flat_marker.is_file() and _is_project_marker(flat_marker):
        return path
    return None


def project_home(data_root: Path) -> Path:
    """User-facing project folder for a data root (parent of _studio/)."""
    return data_root.parent if data_root.name == STUDIO_DIRNAME else data_root


def project_name(data_root: Path) -> str | None:
    """The ``project`` field from project.yaml, or None if unreadable."""
    try:
        data = yaml.safe_load((data_root / PROJECT_MARKER).read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError):
        return None
    if isinstance(data, dict) and data.get("project"):
        return str(data["project"])
    return None


def display_name(data_root: Path) -> str:
    """Human-readable project name for messages, manifests, and reports.

    Never use ``data_root.name`` for this: in the v2 layout that is the
    literal string ``_studio``. Falls back to the project home's folder
    name when project.yaml is missing or unreadable.
    """
    return project_name(data_root) or project_home(data_root).name


def _from_env() -> Path | None:
    raw = os.environ.get(ENV_PROJECT_DIR, "").strip()
    if not raw:
        return None
    root = data_root_of(Path(raw))
    if root is None:
        raise FileNotFoundError(
            f"{ENV_PROJECT_DIR}={raw!r} does not point to a project "
            f"(no {PROJECT_MARKER} or {STUDIO_DIRNAME}/{PROJECT_MARKER} found there)"
        )
    return root


def _from_cwd(start: Path | None = None) -> Path | None:
    cur = (start or Path.cwd()).resolve()
    for candidate in [cur, *cur.parents]:
        root = data_root_of(candidate)
        if root is not None:
            return root
    return None


def resolve_project_dir(name: str | None = None, cwd: Path | None = None) -> Path:
    """Resolve a project data root per the order documented above."""
    legacy = repo_root() / "projects" / name if name else None
    if legacy is not None and legacy.is_dir():
        # A repo-relative project may itself have been migrated to the
        # v2 layout; data_root_of() then points at its _studio/. For a
        # directory that is not (yet) a valid project — e.g. mid-init —
        # keep returning the directory itself.
        return data_root_of(legacy) or legacy

    for found in (_from_env(), _from_cwd(cwd)):
        if found is None:
            continue
        if name is None or project_name(found) == name:
            return found
        # Name mismatch: never write into a different project. Fall
        # through to the legacy path, whose existence check will fail
        # loudly in require_project().

    if legacy is not None:
        return legacy
    raise FileNotFoundError(
        "no project found: no name given, MV_PROJECT_DIR is unset, and no "
        f"{PROJECT_MARKER} / {STUDIO_DIRNAME}/{PROJECT_MARKER} exists in the "
        "current directory or any parent"
    )


def project_dir(name: str | None = None) -> Path:
    """Data root of a project (see module docstring for the layouts)."""
    return resolve_project_dir(name)


def require_project(name: str | None = None) -> Path:
    p = resolve_project_dir(name)
    if not p.is_dir():
        raise FileNotFoundError(
            f"project {name!r} does not exist at {p} — for projects outside "
            f"the repo, run from inside the project folder or set {ENV_PROJECT_DIR}"
        )
    return p
