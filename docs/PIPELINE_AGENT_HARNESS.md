# Pipeline agent harness

Status: locked release contract.

This document distinguishes the legacy `musicvideo.pipeline.v1` workflow from production V2.
Legacy project bindings retain their existing order and artifacts. Music Video V2 resolves the exact
`(musicvideo, 0.6.0, musicvideo/3.0.0, pipeline-contract/v1, musicvideo.pipeline.v2, 12)` tuple;
native Core production uses the explicit `core.production.v2` / `2.0.0` project declaration without
a pack. These are source contracts, not completed runtime or release acceptance.

The agent explains and proposes; deterministic host code owns ordering, persistence, invalidation,
and approval eligibility. Packaged phase prose is guidance inside this state machine, never the
state machine itself. Common current-phase, exact-byte lineage, consent and source-ownership
invariants apply to both versions. Existing projects change contracts only through explicit
Recovery-copy migration.

## Canonical phase order

Legacy `musicvideo.pipeline.v1`:

`project_init → analysis → brief → production_design → treatment → storyboard → bible → shotlist → sanity → frames → render`

Music Video `musicvideo.pipeline.v2`:

`project_init → analysis → brief → production_design → treatment → script → storyboard → shot_planning → bible → shotlist → sanity → frames → render_review → render`

Core V2 retains `project_init` and the same later production phases, but omits Music Video
`analysis` and Track/Lyrics intake. Workflow identity, rather than file presence or pack ID alone,
selects the order. The visual workbench needs real Script and Shot Planning artifacts; its
pre-render review needs Frames that already exist. V2 models those stages explicitly while keeping
the legacy sequence unchanged.

Music Video `project_init` follows the separate observable intake contract in
`docs/MUSICVIDEO_START_CONTRACT.md`. Every later phase follows the same four-part contract:

1. a schema-validated writer or deterministic runner;
2. a structural gate requirement for the canonical artifact;
3. a cumulative input/output lineage fingerprint;
4. the packaged instructions for that exact phase.

## Legacy phase artifacts

| Phase | Canonical writer | Canonical artifact |
|---|---|---|
| Project Init | host Track/Lyrics intake | `audio/`, optional `lyrics/` |
| Audio Analysis | `run_phase`, `write_analysis_interpretation` | measured and interpreted `analysis/` |
| Brief | `record_affect`, then `write_brief` | `analysis/affect.json`, `brief.yaml`, synchronized `project.yaml` |
| Production Design | `write_production_design` | `production_design/production_design.yaml` and referenced files |
| Treatment | `write_treatment` | versioned treatment plus `treatment/current.md` |
| Storyboard | `write_storyboard` | versioned storyboard plus `storyboard/current.yaml` |
| Bible | `write_bible` | `bible/bible.yaml`, generated-asset proof, and referenced files |
| Shot List | `PipelineShotlistWriter` via `write_shotlist` or native source-mode edit | latest versioned shot list, canonical execution plan, and source-mode-owned production plans |
| Sanity | `run_sanity` | `sanity/report.json` |
| Frames | `run_phase`, `record_render`, `save_frame_audit` | role-aware Frames manifest, exact images, exact audits |
| Render | `run_phase`, `record_render`, `assemble_timeline` | final render manifest, render-proof sidecar, exact provider videos or accepted animated stills, and exact timeline assembly proof |

## V2 planning artifacts

Paths are relative to the pipeline data root; `N` identifies the immutable revision. Unchanged
phases retain their canonical artifacts. V2 adds or replaces these planning writers:

| Phase | Canonical writer | Canonical artifact |
|---|---|---|
| Script | `PipelineScriptWriter` / `write_script` | `script/vN.v1.json`, `script/current.v1.json` |
| Visual Storyboard | `PipelineStoryboardBundleWriter` / `write_storyboard_bundle`, `assign_storyboard_sketch` | `storyboard/vN.v2.yaml` and `current.v2.yaml`; versioned/current causality, timing and identity JSON alongside it |
| Shot Planning | `PipelineShotPlanningWriter` / `write_shot_planning_draft` | `shot-planning/vN.v1.json`, `shot-planning/current.v1.json` |
| Shot List promotion | `PipelineProductionPlanWriter` | `shotlist/vN.v5.yaml`, `shot-planning/promotion-vN.v1.json`, `shot-planning/promotion-current.v1.json` |
| Render Review | `PipelineRenderReviewWriter` / `write_render_review` | `render-review/vN.v1.json`, `render-review/current.v1.json`, exact bound receipts under `render-review/receipts/` |

Storyboard timing owns V2 editorial duration. Shot Planning and promotion bind that timing,
stable shot identities, sources and execution choices; they cannot silently change the approved edit.

Only these canonical artifact writers may capture fresh phase lineage. Legacy agent and native Shot List
edits converge on `PipelineShotlistWriter`; neither entry surface may persist or validate a Shot List
independently. Adjacent actions such as preview
assembly, media inspection, generation, copying, or cropping may support a phase but cannot legitimize
an artifact written outside its validated writer. File staging is restricted to image-asset paths in
Production Design and Bible; it cannot read from or overwrite canonical pipeline artifacts. V2
native sketch import separately validates real images and binds host-owned `storyboard/sketches/`
bytes through its canonical sketch writer; it does not widen generic file staging. Scene3D
extraction accepts only pipeline-local panoramas and writes only beneath the matching Bible location.

The Intent Ledger is evolving creative memory, not a planning artifact. Bible and Frames may update it;
those updates apply to subsequent compiled prompts and do not retroactively invalidate already reviewed
media. Exact generated-media proofs retain the provider prompt that was actually used.

The harness also exposes an explicit capability set per phase for both phase-bound writers/runners and
current-phase support tools. In V1, planning phases cannot invoke rendering tools; Production Design and Bible
may generate stills; Frames may generate/crop stills; Render may generate final media. A tool outside
the current phase's capability set is rejected before it can spend money or mutate the project.

V2 Storyboard adds only `compile_storyboard_sketch`, `compile_prompt`, `generate_image`,
`prepare_generation_batch` and `import_media` as supporting capabilities for actual sketches.
Final shot generation remains outside Storyboard. The canonical sketch assignment owns its lineage;
compilation, generation or import alone does not approve a visual Storyboard.

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
- A required spatial blockout binds stable location-local camera setups, metric layouts, entity
  shapes, State Ladder IDs, camera paths, internal shot ranges, cut kinds, and shot-owned timed
  reference roles. Native graybox export and imported QuickTime blockouts pass through the same
  canonical Shot List writer. The blockout proof binds those exact canonical bytes, the ordered
  setup/shape/state identities, and the exported clip hash; a changed plan, assignment, or clip
  blocks approval before generation.
- Analysis binds to the exact track hash. Frames bind each required role to its exact image hash,
  compiled provider prompt, generation model, and current vision audit. Render binds each
  non-imported final shot to its exact executable delivery, compiled provider prompt, generation
  model, and the exact current conditioning inputs required by the Shot List. A provider-video
  delivery binds its video hash and source video, start/end frames, or deterministic reference-image
  plan. An animated-still delivery binds the exact accepted Frames image, adds no Render generation
  cost, and binds its deterministic timeline motion and placement.
- Model-dependent Sanity checks resolve the selected provider/model ID through the active pack's
  versioned capability catalog. Missing, unreadable, schema-mismatched, or unknown capability data
  fails closed; provider aliases for the same concrete model share one capability definition.
- Imported and AI-enhanced shots never enter Frames. Every AI-enhanced shot declares one project-local
  `source_path` in the Shot List; `next_render_shot` resolves that source for the agent, and Render
  approval rejects any missing, changed, or substituted source.
- Conditioning is an explicit, versioned plan decision. Existing pinned plans retain their exact
  behavior; adopting a new strategy requires an explicitly approved plan and, where necessary, the
  transactional Recovery-copy pack upgrade. No route silently substitutes one strategy for another.
- A chained generated shot uses either `frame_continuation` or an explicitly chosen `native_extension`.
  Frame continuation retains the predecessor's extracted last frame as its sole start condition:
  `keyframe_strategy=none`, `seedance_input_mode=keyframe`, no explicit reference images, and no
  separate Frames start image. Its proof binds the exact predecessor video and extracted frame.
  Native extension instead binds the exact approved predecessor video, direction, boundary state,
  permitted original references, and a verified executable extension mode. An extracted frame cannot
  stand in for its video input; the legacy first-frame mechanism is not added implicitly.
- `reference_anchor`, `two_state_interpolation`, and explicitly selected `first_frame` are distinct
  conditioning strategies, not substitutes for chaining. A reference anchor occupies a genuine
  reference slot; interpolation uses the same shot's approved start/end states in their actual input
  slots. Frames owns the required still approvals. V1 introduces no extra phase for these strategies;
  V2 Render Review subsequently checks current render inputs without replacing Frames approval. Missing capability,
  changed input bytes, substituted slots, or unapproved states block before spend and at Render
  approval. Imported and AI-enhanced source ownership remains unchanged.
- Every Bible sheet and Scene3D panorama in V1 binds exact current bytes to one of two host-recorded
  provenance classes: a completed generation with compiled prompt/model, or an identity image the
  user explicitly confirmed in the host-owned prepared-character/location intake. A confirmed image
  may be adopted as the demanded canonical view without generation; an arbitrary library import may
  not. Only a demanded view lacking either proof is generated. V2 keeps these requirements for
  identity/appearance sheets and panoramas. Its spatially derived geometry has separate typed
  exact-byte provenance; neutral Clay is never identity or appearance evidence.
- A real outfit or persistent identity-state change is a distinct Bible entity plus the versioned
  `bible/identity-variants.v1.json` inheritance artifact. Its changed attributes are exhaustive;
  every undeclared attribute remains byte-identical to the base entity, inherited paths must be
  actual base Canon images, and the derived entity owns distinct proven sheets. Storyboard and Shot
  List select the derived entity id, so the normal reference planner consumes its Canon directly.
- `source_mode=imported` is deliberately outside provider rendering. Therefore empty Frames/Render
  manifests are valid only when the current shot list requires no provider-generated assets.
- Timeline assembly completes the Render artifact and covers provider outputs plus every imported
  Shot List source. `assemble_timeline` writes the exact clip, source,
  placement, duration, and motion proof; the Render gate rejects missing, stale, substituted, or
  incomplete assembly. Provider videos retain their source motion. Animated stills receive the
  deterministic host-owned motion declared by their execution plan.
- End-frame audits bind explicit visible character count, positions, gaze, zones and distinct camera
  fields in the canonical execution inputs. Moving cameras require end framing, angle and height;
  static cameras retain their declared constraints unless explicit end values override them. Start
  geometry remains owned by the Shot List. Historical audits stay readable without granting current
  approval when execution inputs are stale.
- Read-only image inspection never changes phase artifacts. Bounded transient observations become
  durable exact-byte evidence only when their canonical audit is saved. Minor/blocking findings
  require repair or native user acceptance of the exact audit, image and style with a reason. This
  acceptance is available only in the current Frames phase, preserves original findings, and expires
  when its bound evidence changes. Agent routing must respect a still-current explicit acceptance.
- Style criteria declare the media evidence they require. Stills cannot attest timing, cut relations,
  motion or audio. An approved production style requires native human review of the actual timeline
  before movie export, with observations or explicit deviations for each criterion. The receipt
  binds the cut and exact source/style bytes and is rechecked before and after encoding. It does not
  re-seal the Render phase, and does not gate project backup or XML interchange.

## Release evidence

The release suite must fail if:

- the phase order or coverage differs from the exact supported workflow bound to the project;
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

macOS execution evidence comes from the GitHub Actions build, native acceptance and release
workflows. Local Swift builds and tests are prohibited. Source validation and contract review alone
do not establish runtime or visual acceptance.
