# Phase K0 — Project Init

> **Orchestrator instruction (main-session context).** Never spawn this
> phase as a sub-agent. Use the **interface language supplied by the host**
> unless the user explicitly requests another language;
> everything written into provider-facing fields is **English**.

## Goal

Confirm the song identity and request approval for Project Init.

The NexGenVideo host owns pipeline creation and startup intake. By the time
you work on this phase, the project is already scaffolded and the Track and
Lyrics cards are complete. Do not call `init_project`, do not create folders,
and do not ask for either file again.

## Canonical startup intake

The locked musicvideo startup contract defines the order. The host implements
its first two decisions through `hardsteps.json` before starting your turn:

1. Track — required
2. Lyrics — optional

The host writes the results deterministically:

- track → `audio/`
- lyrics → `lyrics/lyrics.txt`

Never use `show_dialog` or prose to collect, combine, replace, or duplicate
these inputs. Never ask the user for a file path. Existing creative material
is a separate host-owned intake after approved Audio Analysis and before the
Brief; do not ask for or reason about it here.

## Inputs

- A real audio file in `audio/` — mandatory.
- Optional `lyrics/lyrics.txt`.
- The current project state and gate state.

## Steps

### 1. Verify the host handoff

Read the project state and inspect:

- `audio/`
- `lyrics/`

If `audio/` contains no supported track, stop with:

> No track is attached. Complete the Track card before Project Init.

Do not present another track dialog. A missing track means the host-owned
startup intake is still incomplete.

### 2. Establish the song identity

Use the attached track filename as the initial song title. If that filename
is only a technical export name or the title is genuinely ambiguous, ask
one short free-text question for the actual title. Do not ask for a project
slug: the open NexGenVideo project already owns its location and identity.

The final title is written later into the brief and shot list. Do not rename
the project or audio file merely to match it.

### 3. Complete Project Init

State:

- the attached track,
- whether lyrics are present.

Then call `approve_gate(project_dir, "project_init")`. Approval is the
user's decision. If declined, remain in Project Init and address the stated
issue.

## Mandatory rules

- Do not run audio analysis in this phase.
- Do not ask for cut mode or budget; both belong in later guided decisions.
- Do not call `init_project`.
- Do not create or move project folders manually.
- Do not present file-intake dialogs for pack hard steps.
- Do not proceed without a real track.
- Do not ask for or develop a story before Audio Analysis is approved.

## Resume behavior

On every re-entry, derive the state again from `audio/` and `lyrics/`. Files
are the durable truth; chat history is not. If Project Init is already
approved, leave it unchanged and continue with Audio Analysis.
