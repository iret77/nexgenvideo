# Phase K0 — Project Init

> **Orchestrator instruction (main-session context).** Never spawn this
> phase as a sub-agent. Converse with the user **in the user's language**;
> everything written into provider-facing fields is **English**.

## Goal

Establish the production context from the material the host already
collected, confirm the song identity, and request approval for Project Init.

The NexGenVideo host owns pipeline creation and startup intake. By the time
you work on this phase, the project is already scaffolded and the intake is
complete. Do not call `init_project`, do not create folders, and do not ask
for any declared startup file again.

## Canonical startup intake

`hardsteps.json` is the single source of truth. The host presents these
steps in this exact order before starting your turn:

1. Track — required
2. Lyrics — optional
3. Story script — optional
4. Prepared characters — optional, repeatable
5. Prepared locations — optional, repeatable
6. Style references — optional

The host writes the results deterministically:

- track → `audio/`
- lyrics → `lyrics/lyrics.txt`
- story script → `import/script.md`
- characters → `import/characters/<slug>/`
- locations → `import/locations/<slug>/`
- style references → loose image files in `import/`

Never use `show_dialog` or prose to collect, combine, replace, or duplicate
these inputs. Never ask the user for a file path. The user has either
provided each optional item or explicitly skipped it.

## Inputs

- A real audio file in `audio/` — mandatory.
- Optional `lyrics/lyrics.txt`.
- Optional brownfield material under `import/`.
- The current project state and gate state.

## Steps

### 1. Verify the host handoff

Read the project state and inspect:

- `audio/`
- `lyrics/`
- `import/`

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

### 3. Establish greenfield or brownfield

Derive the project shape from the durable files:

- `import/script.md` → brownfield story. Its characters, locations, and
  beats are source material for treatment, bible, and shots.
- `import/characters/<slug>/` or `import/locations/<slug>/` → prepared
  identity anchors. Preserve their names and visual identity.
- loose images in `import/` → style sources for Production Design.
- none of the above → greenfield. Develop the concept from the song.

Do not re-ask whether this material exists. Confirm your reading with the
user in one concise summary.

### 4. Complete Project Init

State:

- the attached track,
- whether lyrics are present,
- greenfield or brownfield,
- which prepared identities or style sources are present.

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

## Resume behavior

On every re-entry, derive the state again from `audio/`, `lyrics/`, and
`import/`. Files are the durable truth; chat history is not. If Project Init
is already approved, leave it unchanged and continue with the next
unapproved phase.
