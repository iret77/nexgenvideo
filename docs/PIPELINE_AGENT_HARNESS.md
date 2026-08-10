# Pipeline agent harness

Status: locked release contract.

This document defines the executable contract for every musicvideo pipeline phase. The agent explains
and proposes; deterministic host code owns ordering, persistence, invalidation, and approval eligibility.
Packaged phase prose is guidance inside this state machine, never the state machine itself.

## Canonical phase order

`project_init → analysis → brief → production_design → treatment → storyboard → bible → shotlist → sanity → frames → render`

`project_init` follows the separate observable intake contract in
`docs/MUSICVIDEO_START_CONTRACT.md`. Every later phase follows the same four-part contract:

1. a schema-validated writer or deterministic runner;
2. a structural gate requirement for the canonical artifact;
3. a cumulative input/output lineage fingerprint;
4. the packaged instructions for that exact phase.

## Phase artifacts

| Phase | Canonical writer | Canonical artifact |
|---|---|---|
| Project Init | host Track/Lyrics intake | `audio/`, optional `lyrics/` |
| Audio Analysis | `run_phase`, `write_analysis_interpretation` | measured and interpreted `analysis/` |
| Brief | `record_affect`, then `write_brief` | `analysis/affect.json`, `brief.yaml`, synchronized `project.yaml` |
| Production Design | `write_production_design` | `production_design/production_design.yaml` and referenced files |
| Treatment | `write_treatment` | versioned treatment plus `treatment/current.md` |
| Storyboard | `write_storyboard` | versioned storyboard plus `storyboard/current.yaml` |
| Bible | `write_bible` | `bible/bible.yaml`, generated-asset proof, and referenced files |
| Shot List | `PipelineShotlistWriter` via `write_shotlist` or native source-mode edit | latest versioned shot list with source-mode-owned production plans |
| Sanity | `run_sanity` | `sanity/report.json` |
| Frames | `run_phase`, `record_render`, `save_frame_audit` | role-aware Frames manifest, exact images, exact audits |
| Render | `run_phase`, `record_render` | final render manifest, render-proof sidecar, exact videos |

Only these canonical artifact writers may capture fresh phase lineage. Agent and native Shot List
edits converge on `PipelineShotlistWriter`; neither entry surface may persist or validate a Shot List
independently. Adjacent actions such as preview
assembly, media inspection, generation, copying, or cropping may support a phase but cannot legitimize
an artifact written outside its validated writer. File staging is restricted to image-asset paths in
Production Design and Bible; it cannot read from or overwrite canonical pipeline artifacts. Scene3D
extraction accepts only pipeline-local panoramas and writes only beneath the matching Bible location.

The Intent Ledger is evolving creative memory, not a planning artifact. Bible and Frames may update it;
those updates apply to subsequent compiled prompts and do not retroactively invalidate already reviewed
media. Exact generated-media proofs retain the provider prompt that was actually used.

The harness also exposes an explicit capability set per phase for both phase-bound writers/runners and
current-phase support tools. Planning phases cannot invoke rendering tools; Production Design and Bible
may generate stills; Frames may generate/crop stills; Render may generate final media. A tool outside
the current phase's capability set is rejected before it can spend money or mutate the project.

## Runtime invariants

- Before any phase tool executes, that phase must be the single current phase, its host-owned intake
  must be complete or explicitly declined, all earlier gates must be approved, and the immediate
  predecessor's structural requirement plus lineage must still be current. Editing an approved phase
  requires an explicit rewind.
- A project has at most one host-executed phase job. Concurrent calls and MCP reconnect retries for
  its current phase join that job instead of starting duplicate work; a different phase is refused
  until it settles. Runner-emitted stage boundaries are the only source of user-visible progress.
- While a phase job is running, approval, revision-state changes, and rewind fail before mutation.
  Approval becomes available only after the completed canonical artifact passes the same structural
  gate used by agent approval.
- Pipeline approval controls derive their enabled state from that shared approval check. They stay
  visibly disabled while it is blocked, and the mutation re-runs the check to close click-time races.
- A successful canonical write rewinds its own gate and every downstream gate, then records lineage
  from the current cumulative inputs and exact artifact bytes.
- Native artifact edits use the same canonical data root and phase-access guard as agent tools. They
  cannot change an approved or future phase implicitly; the pipeline must first be rewound until that
  artifact's phase is current.
- An upstream-input mutation rewinds the affected phase and downstream phases without recording new
  artifact lineage.
- Gate approval through the agent and through the Pipeline panel uses the same fail-closed requirement.
- Missing, unreadable, mismatched, manually changed, or stale lineage blocks approval.
- Project files are accepted only as regular files inside the project; symlink and traversal escapes
  never count as artifacts.
- Track discovery has one engine-owned implementation shared by intake, analysis, writers, and gates;
  an audio symlink escaping the project is not a track.
- Production Design, Bible, and Shot List image references must resolve to actual image files before
  their typed writer persists them, and the approval gate repeats the check independently.
- Every media path referenced by the Shot List is part of its exact-byte lineage. Replacing an
  AI-enhancement source or explicit reference at the same path invalidates Shot List and every
  downstream phase.
- Every newly agent-written generated or AI-enhanced Shot List shot carries a schema-validated
  `production_plan`; imported shots omit it. Active core production profiles determine which
  conditional fields and sanity checks apply. Legacy shot lists remain readable without invented
  values and are explicitly warned until revised. The approval gate enforces plan ownership for the
  canonical agent writer while preserving that explicit legacy tolerance. Prompt
  compilation projects the approved action, camera move, continuity locks, and match-action cue;
  render iteration returns that exact plan and its rescue cut.
- Analysis binds to the exact track hash. Frames bind each required role to its exact image hash,
  compiled provider prompt, generation model, and current vision audit. Render binds each
  non-imported final shot to its exact video hash, compiled provider prompt, generation model, and the
  exact current conditioning inputs required by the Shot List: source video, start/end frames, or the
  deterministic reference-image plan.
- Imported and AI-enhanced shots never enter Frames. Every AI-enhanced shot declares one project-local
  `source_path` in the Shot List; `next_render_shot` resolves that source for the agent, and Render
  approval rejects any missing, changed, or substituted source.
- A chained generated shot uses its predecessor's extracted last frame as its sole start condition.
  It declares `keyframe_strategy=none`, `seedance_input_mode=keyframe`, no explicit reference images,
  and never creates a separate Frames start image. Render currency binds the exact predecessor frame.
- Every Bible sheet and Scene3D panorama must be staged from a ready generated media asset. The Bible
  gate binds its exact bytes to the host-recorded compiled prompt and generation model; user uploads
  remain valid only as `reference_images`.
- `source_mode=imported` is deliberately outside provider rendering. Therefore empty Frames/Render
  manifests are valid only when the current shot list requires no provider-generated assets.
- Timeline assembly is optional editing work after renders exist. It neither completes nor re-seals the
  Render artifact and cannot change the Render gate.

## Release evidence

The release suite must fail if:

- the phase order or phase coverage changes;
- a phase lacks a gate, lineage provider, packaged instruction document, or executable writer path;
- a non-writer can capture lineage;
- a changed upstream input permits later phase work;
- an artifact or generated media file changes after its recorded proof;
- a future or approved phase can be mutated without becoming the current phase through rewind;
- a phase-bound runner or writer is accepted outside that phase's explicit capability set;
- an MCP reconnect duplicates or loses a running host phase, or a running phase can be approved;
- the Pipeline UI enables approval while the shared approval check is blocked;
- a Render passes with missing, stale, substituted, or unplanned conditioning input;
- host intake appears in an unsupported phase or violates the locked startup sequence;
- an imported-only project cannot create and approve valid empty Frames/Render artifacts.
- a new agent-written generated or AI-enhanced shot omits its production plan, a narrative/hybrid
  planned shot omits its narrative beat, or a generated long take reaches Sanity without a declared
  risk and rescue cut.

macOS execution evidence comes only from the GitHub Actions release workflow. Local Swift builds and
tests are prohibited.
