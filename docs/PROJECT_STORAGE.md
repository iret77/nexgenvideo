# Project storage model

How NexGenVideo stores a project, where transient data lives, and how unsaved work
survives a crash. Modeled on Final Cut Pro (self-contained library) and ACE Studio
(continuous autosave + crash-restore prompt), and Apple's file-system guidance
(Application Support vs Caches).

## Principles

1. **One self-contained container per project.** Everything durable lives inside the
   `.ngv` package. Copying/moving the `.ngv` takes the whole project — nothing is left
   behind, nothing is shared between projects.
2. **The projects folder holds only projects.** `~/Documents/NexGenVideo/` (user-set)
   contains `*.ngv` and nothing else. No per-project subdirectories, ever.
3. **Transient/runtime data never touches the project or the projects folder.** It goes
   to Caches (recreatable) or a Recovery store (unsaved work), keyed per project/session.

## Where each thing lives

| Data | Location |
|------|----------|
| A project (timeline, media, chat, thumbnail, generation-log, **and** the engine data root: bible, treatment, storyboard, shotlist, frames, renders, import, `project.yaml`, `gates.yaml`, + active pack dirs) | inside the `.ngv` package |
| Registry of known projects (`project-registry.json`), app-global config | `~/Library/Application Support/NexGenVideo/` |
| Installed format-pack versions | `~/Library/Application Support/NexGenVideo/Plugins/<id>/<version>.ngvpack` |
| Render scratch, decode caches, preview proxies, in-flight generation staging, thumbnails/waveforms | `~/Library/Caches/NexGenVideo/…` and `NSTemporaryDirectory()` |
| Live working copy of the open project (unsaved work) | Recovery store: `~/Library/Application Support/NexGenVideo/Recovery/<projectId>/` |

The engine data root is the directory named **`pipeline`** (formerly `_studio` — renamed:
no leading underscore, matches the cockpit "Pipeline" vocabulary). Old projects with a
`_studio` dir are recognized and migrated.

## Working-copy lifecycle (crash recovery)

The engine and editor never write into the `.ngv` package during editing. Instead:

1. **Open** — the package's `pipeline/` is materialized into the Recovery working copy
   `Recovery/<projectId>/`. The editor's `workingRoot` points here.
2. **Edit** — the engine + agent tools read/write only the working copy. The package in
   the projects folder is untouched, so it can never be left half-written.
3. **Autosave** — the working copy is the live journal; a lightweight marker records that
   it is dirty relative to the last package save.
4. **Save (⌘S)** — the durable working state is synced atomically into the `.ngv` package.
   On clean save the dirty marker is cleared.
5. **Clean quit** — after a successful save the working copy/marker is cleared.
6. **Crash** — no clean save ran, so the working copy + dirty marker survive. On next
   launch NexGenVideo finds a working copy newer than its package and offers to restore
   the unsaved work (ACE Studio model).

## Project identity

`<projectId>` above is a UUID stored INSIDE the package (`ngv.json`), not a hash of the
file path. It is minted when the project is created and travels with the package, so:

- moving or renaming the `.ngv` keeps the same working copy;
- a brand-new project — even one saved where a deleted project once lived — gets a fresh
  id, so it can never inherit the old project's pipeline;
- Save As / duplicate mints a new id for the copy (a distinct project).

Pre-identity packages are migrated (an id is generated and written) on first open.

## Idle cleanup (launch)

A crash leaves a working copy behind (step 6 above); one that's never reopened would sit
forever. On launch NexGenVideo retires Recovery working copies untouched — no read *or*
write — for more than 14 days, sparing any project that is open or in Recents. It never
inspects a source path, so a file the user merely moved is never mistaken for deleted.

## Migration (automatic, on open)

- Fold a legacy in-package `_studio/` (or a loose sibling `_studio/`) into `pipeline/`.
- Move a `project-registry.json` found in the projects folder to Application Support.
- Remove orphaned `_studio` / `final` / `inbox` / `review` directories left loose in the
  projects folder by older builds.
- Drop the vestigial home-level `inbox` / `review` / `final` user dirs (the app never used
  them).

### Artifact schemas

Layout is not the only thing that ages. `SchemaMigrator` lifts a project's artifacts to the
schema the engine writes today (`bible/v4 → v5`, `shotlist/v1|v2|v3 → v4`), driven by the
`SchemaVersions` matrix. It runs on the **working copy**, so the `.ngv` package is untouched
until ⌘S — a migration the user never saves is discarded with the copy.

- **Idempotent.** An artifact already on the current schema is not read, written, or backed up.
- **Backed up.** The pre-migration file stays beside the original as
  `<name>.pre-<old-schema>.<timestamp>.yaml`, stamped with the version left behind.
- **Validated by construction.** A migration is decode → re-stamp → `validate()` → encode: the
  readers already decode older versions tolerantly (new fields default to empty) and the writers
  emit the current shape, so a file the reader would reject can never be written. As in the Python
  original, no heuristics — fields a newer schema added stay empty and the sanity pass asks the
  user to fill them.
- **Never migrates down.** A project written by a NEWER engine is a hard stop
  (`projectAheadOfEngine`); the file is left alone rather than stripped of fields this build
  doesn't know.

### Format-pack binding and schema

`ngv.json` pins `activePlugin`, `activePluginVersion`, and
`activePluginProjectSchema`. Updating the global pack library does not change an
existing project. Old and new pack versions remain installed in parallel, and open/save
fail closed unless the exact project binding is live.

An id-only legacy project is pinned to the live legacy-schema version in its Recovery
copy. If only a newer schema is installed, the user must explicitly approve its declared
legacy migration.
A cross-schema pack upgrade requires an explicit user action and a migration declared in
both bundle metadata and the loaded pack runtime; a version-only upgrade on the same
schema updates only the binding. The host copies the complete Recovery working copy to a
transaction directory, runs the pack migration, writes the new binding, validates the
host-owned project files, and atomically replaces the working copy only when every step
succeeds. The source `.ngv` is the rollback source and stays byte-for-byte untouched
until Save. Upgrade intent remains durable until Save; a crash resumes the target
Recovery copy, while closing without saving cancels the upgrade.
The Music Video `musicvideo/2.0.0` migration resets Analysis and every downstream
approval in the transactional Recovery copy because `analysis/v3` requires a newly
measured Music Understanding hierarchy. Existing artifacts remain available for
inspection but cannot authorize further phase execution.
