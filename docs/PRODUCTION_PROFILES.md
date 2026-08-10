# Production profiles

Production profiles are reusable filmmaking doctrine owned by `NexGenEngine`. Format packs activate
and compose them; they do not copy their prompts, schemas, or checks.

## Boundary

- A **profile** applies across formats and owns phase guidance plus deterministic sanity checks.
- A **pack** owns category-specific knowledge, phase order, intake, analysis, patterns, and policy.
- Model capability claims remain in the provider/model catalog. A profile contains only stable
  production constraints, never claims tied to one vendor or model version.

`EngineRegistry.registerProductionProfile` is the composition boundary. Activations use generic
project metadata so the engine does not learn pack-specific concepts.

## Standard profiles

### `generative_film`

Always active for the musicvideo pack and reusable by any pack that generates moving images.

- Build named style, character, location, prop, geometry, and reverse-view anchors before shots.
- Plan one primary action, one camera movement, and at most two visible characters per generated shot.
- Anchor generated character blocking through a non-empty `set_anchor` naming an object or set zone;
  keep its spatial relationship in `relation_to_set`. Screen direction alone is not an anchor.
- Treat 4–12 seconds as the normal generated-shot range; longer shots declare `long_take` risk.
- Rate renderability `green`, `yellow`, or `red`; every yellow/red shot declares risks and a rescue cut.
- Persist continuity locks and match-action cues instead of relying on prompt prose.

### `narrative_storytelling`

Active when project metadata declares `concept_type` as `narrative` or `hybrid`.

- Every planned generated or AI-enhanced shot declares a narrative beat: establish, action, reaction,
  detail, transition, performance, or atmosphere. Imported footage remains planless production truth.
- Planned narrative sequences of three or more shots make context and consequence visible around an
  action beat rather than explaining them in prose. Performance/atmosphere-only sequences are exempt.
- Ellipsis is preferred when a continuous action is materially harder to render than its story beat.

## Shot-list contract

`shotlist/v4` adds `production_plan` to every newly agent-written generated or AI-enhanced shot;
imported shots omit it because their existing footage is the production truth:

- `primary_action`
- `camera_movement` and optional `camera_movement_detail`
- optional `narrative_beat`, required by the narrative profile's sanity gate
- `renderability`, `risks`, and optional `rescue_cut`
- optional `match_action_cue`
- `continuity_locks`

Older shot lists migrate losslessly with no invented plan. They remain readable and receive only a
non-blocking missing-plan warning until revised. New writes require the structure through the tool
schema; once a plan exists, active profiles enforce all of its conditional fields.

`compile_prompt(shotId:)` projects the approved primary action as a deterministic single-action
directive, plus camera movement, blocking anchors, continuity locks, and the match-action cue, into
video prompts. Still-image prompts receive blocking anchors and continuity locks only, so a motion
instruction cannot leak into a frame anchor. `next_render_shot` returns the same plan, including the
rescue cut, so rendering cannot silently substitute an improvised execution strategy.

## Pack composition

| Pack | Core profiles | Pack-owned doctrine |
|---|---|---|
| `musicvideo` | `generative_film`; conditional `narrative_storytelling` | Audio analysis, lyrics, beat/section modes, music pacing, music-video patterns |
| `fiction` / `shortmovie` | `generative_film`, `narrative_storytelling` | Screenplay structure, dialogue coverage, scene/act policy |
| `trailer` | `generative_film`, `narrative_storytelling` | Trailer escalation, reveals, compression, campaign variants |
| `explainer` | `generative_film`; optional `narrative_storytelling` | Pedagogy, voice-over, comprehension pacing, information hierarchy |
| `vacation` | Optional profiles selected by project intent | Source-footage coverage, chronology, place/travel structure |

Future cross-format doctrine becomes another core profile only when at least two packs need the same
behavior. Category-only rules stay in their pack.
