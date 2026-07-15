# Pattern fit contract

Status: **normative, implementation-ready**

Contract version: `pattern-fit/1.0`

Scorer version: `pattern-fit-scorer/1.0`

Policy: `contracts/pattern-fit-policy.v1.json`

This contract lets the musicvideo pack rank all Patterns against a user's project without
mistaking one observed reference video's genre or BPM for universal suitability. A score is
an explainable compatibility index, never a probability of creative success.

The generated JSON Schemas are authoritative. This document defines the deterministic
semantics that cannot be expressed in JSON Schema alone.
`contracts/pattern-fit-golden-vectors.v1.json` is the normative cross-language test set for
boundaries, missing inputs, aggregation, confidence, conflict modes and qualification.

## Contract surfaces

1. `PatternFitProfile` is embedded as `fit_profile` in each Pattern YAML. It describes the
   Pattern's sweet spots, compatible uses, deliberate stretches, avoidances, hard production
   requirements and adaptations. The block may be authored before measurement is complete.
2. `ProjectFitProfile` is assembled at runtime from audio analysis, the persisted Brief,
   explicit user statements and bounded agent inference. Every input carries source and
   confidence.
3. `PatternFitPolicy` freezes weights, category values, evidence confidence, thresholds and
   match-mode behavior. Implementations load the committed policy; weights are not hidden in
   Swift or an agent prompt.
4. `PatternRecommendationSet` is the agent-facing result: score, confidence, coverage,
   per-axis explanation, conflicts, triggered adaptations and three recommendation slots.

`fit_profile` is required for every recommendable Pattern. The unshipped `triggers` scorer is
not part of this contract and must be removed when the app adopts it. There is no fallback,
adapter or second score semantics.

## Why measured signature and fit stay separate

Measurement describes visible behavior in selected works: ASL, cut density, beat proximity,
motion, shot function, performance, transitions, screen look and similar axes. It does not by
itself prove suitable mood, audience, lyrical theme, budget or production intent.

- Measurement may ground descriptive fit ranges such as pacing, motion, abstraction or
  performance share, with `basis: measured`, stats-artifact hash and exact field path. The
  cited artifact's field gate must permit `eligible_as: measured`; inferred or abstained
  measurement fields cannot be relabeled.
- Suitability statements normally use documented sources or an explicit editorial inference.
- A single video's raw BPM is evidence about that work, not a hard Pattern requirement.
- Every fit axis references one or more evidence IDs; unknown references fail validation.

The test Pattern can therefore be populated later without blocking the app implementation.

## Runtime project profile

Existing values map without reinterpretation:

| Existing source | Project-fit field |
|---|---|
| `Brief.visualMedium` | `visual.visual_medium` |
| `Brief.conceptType` | `creative.concept_type` |
| `Brief.figures` | `creative.figures` |
| `Brief.lyricsIntegration` | `creative.lyrics_integration` |
| `Brief.tone` plus confirmed treatment intent | weighted `creative.affects` |
| production plan checked against `Brief.budgetEur` | `production.budget_tier` and complexity inputs |
| `Analysis.perceivedBpm` | `audio.perceived_bpm` |
| audio energy/onset/section analysis | the corresponding `audio` inputs; onset density is events/second |

An agent must not fill unknown fields merely to increase coverage. Agent-inferred values are
capped at confidence `0.7` by schema. Explicit user exclusions and hard gates may only rely on
user-/Brief-confirmed data; agent inference can affect a soft score but cannot veto a Pattern.

`budget_tier` is feasibility relative to the actual production plan, not a universal Euro
lookup table. Provider prices, live-shoot costs and available in-kind resources differ. If no
costed plan exists, leave the axis missing; do not convert `budgetEur` with invented thresholds.

Brief tone mapping is lossless only for identical vocabulary:

- `melancholic`, `ironic`, `euphoric`, `dark`, `surreal`, and `poetic` map directly;
- `energetic` maps to `high_energy`;
- `quiet` and `other` do not imply a specific affect and remain missing until treatment or
  user context disambiguates them.

Normalized semantic axes use fixed anchors: `0` means absent/minimal, `0.5` moderate, and `1`
dominant/maximal for the project. Specifically, energy runs from sparse/fragile to relentless,
narrative clarity from non-narrative to explicit linear story, abstraction from literal to
fully non-literal, and section contrast from uniform to strongly differentiated sections.
Intermediate values interpolate this scale. A DSP value may populate such an axis only through
a separately versioned mapping; raw RMS or another uncalibrated feature is not a unit score.

If the high-impact known input weight is below the policy minimum, return a provisional result
and at most three questions, ordered by missing global weight. The agent asks only questions
whose answers can materially change the ranking.

## Deterministic scoring

### 1. Hard gates

A Pattern is `excluded` with no numeric `fit_score` when any of these is confirmed:

- its ID occurs in `excluded_pattern_ids`;
- `hard_constraints.required_visual_mediums` is non-empty and excludes the project's medium;
- a required production capability is absent;
- a project constraint intersects `incompatible_project_constraints`.

`experimental` mode does not override hard production facts or explicit user exclusions.
Hard constraints are reserved for documented/measured impossibilities or mandatory resources,
not ordinary creative preference; inferred evidence is rejected for this block. Missing
capability data means unknown, not absent, and cannot trigger exclusion.

### 2. Axis resolution

Categorical input resolves in this order: `ideal`, `compatible`, `stretch`, `avoid`, then
`unlisted`. The policy values are `1.0`, `0.75`, `0.4`, `0.0`, and `0.5`. Empty overlap is not
silently treated as ideal. Multiple weighted affects use the weighted mean of their individual
category scores.

Continuous input scores `1.0` inside `ideal`, `0.75` elsewhere inside `compatible`, `0.4`
elsewhere inside `usable`, and `0.0` outside `usable`. The ranges are contract-model-validated as
`ideal` within `compatible` within `usable`.

Missing project input produces `unscored`, not `0.5`.

### 3. Weights and coverage

For axis `a` in dimension `d`:

```text
global_weight(a) = dimension_weight(d) * axis_weight(a | d)
input_coverage = sum(global_weight(a) for scored axes)
raw_fit = sum(global_weight(a) * axis_score(a)) / input_coverage
```

The six dimension weights are:

| Dimension | Weight |
|---|---:|
| Affect and energy | 20% |
| Concept and story | 20% |
| Subject and performance | 15% |
| Medium and aesthetic | 15% |
| Rhythm and edit grammar | 15% |
| Production feasibility | 15% |

Perceived BPM is only 20% of the 15% rhythm dimension: exactly **3% of total fit**. Beat
salience, `onset_density_hz` (detected onsets per second), rhythmic regularity and section
contrast carry the rest.

### 4. Evidence-aware confidence

For each scored axis:

```text
axis_evidence_confidence = minimum policy confidence of referenced evidence
axis_quality = project_input.confidence * axis_evidence_confidence
mean_quality = sum(global_weight * axis_quality) / sum(scored global_weight)
confidence = input_coverage * mean_quality
```

The frozen evidence factors are measured `0.95`, documented `0.85`, inferred `0.60`.
Using the minimum prevents a strong measurement reference from concealing a weaker editorial
premise.

### 5. Conflicts, adaptations and final score

Every `avoid` or outside-`usable` resolution is a conflict. Starting from
`100 * raw_fit`, subtract the match mode's `avoid_penalty_points` per distinct conflict and
clamp to `[0, 100]`. If any conflict remains, apply the mode's cap:

- conservative: cap `49`, penalty `8`;
- balanced: cap `69`, penalty `5`;
- experimental: no conflict cap, penalty `2`.

Every matching adaptation rule is returned as `triggered`; its
`maximum_recommended_fit` is another cap. An adaptation describes a real pipeline lever and
does not erase the conflict. If the user accepts a material project change, update the project
profile and score again.

### 6. Qualification and bands

Results below `0.60` input coverage or `0.45` confidence are `provisional`, retain their
diagnostic score, receive no rank and cannot occupy a recommendation slot. Qualified results
use these bands:

- `exceptional`: 90–100
- `strong`: 80–89.999
- `good`: 65–79.999
- `stretch`: 50–64.999
- `weak`: below 50

The user-facing label must say `Compatibility Index`, not `% success`, `% quality` or
`probability`. The UI rounds the index to a whole number; JSON retains the deterministic
floating-point result for auditing and tie-breaking.

## Ranking and user presentation

Qualified, non-excluded results sort by descending fit score, descending confidence and then
Pattern ID for deterministic ties. The default agent response returns five results and these
slots when available:

- `best_overall`: the top qualified result;
- `production_efficient`: the highest result with production score at least `0.75` and no
  production conflict;
- `creative_stretch`: the highest result with score at least `50`, a different style family
  from `best_overall`, and at least one `stretch` resolution or triggered adaptation.

Each shown recommendation includes strengths, conflicts, adaptations and confidence/coverage.
The agent must not recommend an excluded or provisional Pattern as a winner. A deliberate user
selection may override a weak score, but the decision and warnings remain visible.

## Cutover and content gate

This contract is a hard cutover, not a migration:

1. Replace and remove `PatternTriggers` and its integer scorer.
2. Make `fit_profile` a required field of every Pattern that participates in recommendations.
3. Rank the patterns that carry a valid `fit_profile`. An unauthored pattern is **not** a defect
   and **not** a reason to withhold the ranking — it is simply not a candidate.
   **(Owner decision 2026-07-16, superseding the original all-or-nothing gate.)** A pattern is
   OPTIONAL: without one, a music video's structure comes from the analysis, the user's intent
   and the agent-moderated process. Authoring a profile is expensive and deliberate, so a
   partially authored library is the normal state — and the useful question, "does this pattern
   fit, yes or no", is answerable with one profile just as well as with a hundred. An empty ranking
   ("none of the scored patterns fit") is a legitimate answer, not an error.
   A profile that is PRESENT but invalid stays loud: it is a pack defect, reported as
   `invalid_profiles`, and is excluded from the ranking.
4. Report `library_coverage` (scored / unscored / total) with every ranking, so a partial field is
   never presented as the whole library. **The library has no fixed size** — it grows as profiles
   get authored. Never assert a pattern count in code, tests or docs; load and rank what is there.
5. Do not expose fallback candidates, adapters or alternate score semantics.
6. App code and Pattern content develop independently; the feature ships with however many
   profiles exist.

## App-agent implementation order

1. Add Codable mirrors for all four generated schemas and fixture round-trip tests.
2. Replace `PatternTriggers` with required `fit_profile` in Pattern YAML decoding.
3. Implement the pure deterministic scorer against the committed policy and golden vectors.
4. Replace `PatternProviding.suggest` with the full `ProjectFitProfile` request and
   `PatternRecommendationSet` response; do not retain an adapter.
5. Update `suggest_patterns` tool schema and UI to show index, band, confidence, coverage,
   strengths, conflicts and adaptations.
6. Assemble the project profile from Brief + audio analysis; ask only missing high-impact
   questions.
7. Add slot selection and fail-closed whole-library validation.
8. Populate `fit_profile` blocks as patterns get authored, in parallel with steps 1–7. Contract fixtures may be
   used while app and content branches are separate; complete Pattern content is a mandatory
   integration and enablement gate.
