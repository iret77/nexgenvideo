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

## Migration (automatic, on open)

- Fold a legacy in-package `_studio/` (or a loose sibling `_studio/`) into `pipeline/`.
- Move a `project-registry.json` found in the projects folder to Application Support.
- Remove orphaned `_studio` / `final` / `inbox` / `review` directories left loose in the
  projects folder by older builds.
- Drop the vestigial home-level `inbox` / `review` / `final` user dirs (the app never used
  them).
