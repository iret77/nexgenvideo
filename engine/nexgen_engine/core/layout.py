"""Project folder layout — init + in-place migration. Generic mechanism.

    <project-home>/
    ├── inbox/  review/  final/   # user-facing zones
    └── _studio/                  # pipeline internals (the data root)

The core subdirs below are format-neutral (bible, treatment, frames, renders, …);
a pack contributes its own (music: audio/lyrics/analysis) via the pack contract's
`register_project_dirs`, passed here as `extra_dirs`. (Extracted from musicvideo
`common.layout`; the music subdirs moved out of `DATA_SUBDIRS`.)
"""

from __future__ import annotations

from datetime import date
from pathlib import Path

from nexgen_engine.core import gates as gates_mod
from nexgen_engine.core import project as project_mod
from nexgen_engine.core.modes import Mode
from nexgen_engine.core.paths import PROJECT_MARKER, STUDIO_DIRNAME, data_root_of

USER_DIRS: tuple[str, ...] = ("inbox", "review", "final")

#: Format-neutral data-root subdirs. Pack-specific dirs come via `extra_dirs`.
CORE_SUBDIRS: tuple[str, ...] = (
    "production_design/refs",
    "treatment",
    "storyboard",
    "bible",
    "shotlist",
    "frames",
    "renders",
    "import",
    "import/characters",
    "import/locations",
)

_HOME_ENTRIES: frozenset[str] = frozenset({*USER_DIRS, STUDIO_DIRNAME, "studio.html"})


def _make_dirs(base: Path, subdirs: tuple[str, ...]) -> None:
    for sub in subdirs:
        d = base / sub
        d.mkdir(parents=True, exist_ok=True)
        (d / ".gitkeep").touch(exist_ok=True)


def init_project(
    home: Path,
    name: str,
    mode: Mode = Mode.BEAT,
    budget_eur: float = 50.0,
    extra_dirs: tuple[str, ...] = (),
) -> Path:
    """Create a fresh project below *home* and return the data root. `extra_dirs`
    are the active pack's subdirs (from `EngineRegistry.project_dirs`)."""
    home = home.expanduser().resolve()
    home.mkdir(parents=True, exist_ok=True)
    if data_root_of(home) is not None:
        raise FileExistsError(f"{home} already contains a project")

    data_root = home / STUDIO_DIRNAME
    _make_dirs(data_root, CORE_SUBDIRS + tuple(extra_dirs))
    _make_dirs(home, USER_DIRS)

    project_mod.save(
        data_root,
        project_mod.ProjectMeta(
            project=name, mode=mode, budget_eur=budget_eur, created=date.today().isoformat()
        ),
    )
    gates_mod.save(data_root, gates_mod.Gates(project=name))
    return data_root


def migrate_layout(home: Path) -> Path:
    """Migrate a flat legacy project folder in place into `_studio/`."""
    home = home.expanduser().resolve()
    if (home / STUDIO_DIRNAME).exists():
        raise FileExistsError(f"{home} already has a {STUDIO_DIRNAME}/ — nothing to migrate")
    if data_root_of(home) != home:
        raise FileNotFoundError(f"{home} is not a flat legacy project (no valid {PROJECT_MARKER})")

    to_move = [
        entry
        for entry in sorted(home.iterdir())
        if entry.name not in _HOME_ENTRIES and not entry.name.startswith(".")
    ]
    data_root = home / STUDIO_DIRNAME
    data_root.mkdir()
    moved: list[Path] = []
    try:
        for entry in to_move:
            target = data_root / entry.name
            entry.rename(target)
            moved.append(target)
    except OSError as exc:
        for target in reversed(moved):
            target.rename(home / target.name)
        data_root.rmdir()
        raise OSError(f"migration of {home} failed at {entry.name!r}, rolled back: {exc}") from exc

    _make_dirs(home, USER_DIRS)
    return data_root
