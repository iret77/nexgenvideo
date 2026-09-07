# Director and DoP blueprints: NGV application contract

Status: implementation specification. Tracking: #492. The complete 31 director recipes and 11 DoP signatures are materialized in `blueprints.json`; the selection index, mood table, constraint filter, aliases, documented partnerships, experimental cross-pairings and clashes are preserved in `chapters/director-recipes.json` and the readable handbook. These are production recipes, not a list of director names or five generic camera moods.

## Selection and synthesis

1. Resolve the brief through the source selection index: genre shortlist, explicitly named listed recipe, disclosed alias/nearest match, mood shortlist, minimal clarification, or synthesis. Show at most two candidates, with their actual “Feels like” character and the applicable constraint tradeoff. Never silently substitute an unavailable recipe.
2. Run the source constraint filter for budget/time, action complexity, dialogue, face performance, continuity and stylization. A user can choose a costly aesthetic after the tradeoff is explained; that does not authorize its render spend.
3. Select one director structure and at most one DoP signature, with one dominant. For two named directors select one base and explicit dimension overrides from the other. An alias with several named influences is also scoped dimension synthesis, not several complete packages. Villeneuve's embedded Deakins grammar already counts as one package.
4. House-signature directors have no default extra DoP: Kubrick, Tarantino, Fincher, Scorsese, Ridley Scott, Edgar Wright, Wachowskis/Pope and Gilligan. Apply the source harmony and clash tables before offering other pairs. Preserve “none” as a real selection.
5. Record the selected recipe version, dominant package, optional signature, every dimension override, reason and retained/overridden Verify clauses in the approved style artifact. Style choice is project state; conversation history alone is insufficient.
6. A source gap remains a gap. Bong Joon-ho, Michael Mann, the named apartment-paranoia lineage and Herzog are candidates for future original recipes, not silently fabricated entries. Pixar is a pointer to the complete stylized-3D method, not a 32nd director paragraph.

## Executable dimension ownership

| Source dimension | NGV consumer and effect |
|---|---|
| Feels like / character | Selection rationale and intended emotional effect; not an adjective-only prompt substitute |
| Composition | Storyboard framing, depth planes, spatial relationships, symmetry, foreground/background roles |
| Camera | Setup, shot size/FOV, height, movement and stability, bounded by actual geography and route capability |
| Editing | Coverage and NLE assembly: cut relation, reveal ordering, montage, pacing, transition and hold intent |
| Light / Color / Light/Color / Grade | Production Design and Bible look, motivated source, continuity side, palette, act/sequence progression and finishing intent |
| Timing | Beat duration, performance pauses, cut/hold criteria and sequence rhythm; not an unverified provider duration limit |
| Sound / Sound cue | Audio design/assembly intent; score does not become an instruction to generate music in the video model |
| Best for / Pairs with | Selection applicability; neither is a hard restriction on user choice |
| Verify | Explicit, scope-qualified acceptance observations, carried with the selected dimensions |

`dimensions` retains source labels, including combined `Light/Color`; do not invent a missing dimension. `completeRecipeMarkdown` is authoritative for nuance such as variants and AI notes that sit between named labels. Parsing the fields is not permission to drop that text. Compile the resolved recipe into the relevant model blocks/fields; never prefix a whole director essay or a director name in place of concrete craft instructions.

## Binding Verify clauses to actual observations

Each selected clause becomes a versioned criterion with `recipe_id`, exact `source_clause`, `dimension`, `applies_when`, `scope`, `evidence_kind`, target artifact/shot/sequence IDs, expected observable condition, result (`pass`, `fail`, `not_applicable`, `not_observed`), evidence reference and reviewer attribution. This is a logical schema proposal, not an ABI change to an existing public struct. Preserve source words alongside the NGV binding.

Scope is semantic, not inferred from the sentence containing a question mark:

- Composition, subject placement, silhouette, palette and visible source can be judged on a still **when that still shows the required evidence**.
- Camera steadiness, a motivated move, a held reaction, a deadpan pause or motion trails need a clip/range. A still cannot pass them.
- Reaction-before-reveal, Hitchcock's POV construction, alternating scale, escalation, a late-arc accent, act-owned color or a motif's recurrence need the relevant sequence/project context. Do not demand every constituent image in one frame or every shot.
- Sound cues need actual audio and the correct stem/mix. “No generated score” is a route/audio-ownership check, not proof that the final musicvideo must be silent.
- A clause overridden in the approved synthesis is replaced by the explicit override criterion and retains its provenance; it is not both mandatory and forbidden. Undeviated base clauses survive synthesis.

Examples: Anderson's centered composition can be checked on a frame; the deadpan hold needs the beat's clip. Spielberg's reaction-before-reveal is a cut-order relation. Storaro's act hue is evaluated against that act's declared palette, and moving light is required where planned, not in every shot. Ozu's assembly geography does not authorize a generated take to break its fixed dialogue axis. A Wenders/Müller palette variant is a project choice, not simultaneous color and B&W.

Recipe checks are review criteria, not imaginary machine observations. Structural checks can prove IDs, bindings and scope, but cannot prove lighting or emotion. The reviewer must actually see/hear the evidence or record attributed director answers. Missing evidence remains `not_observed`. Source-mandated aesthetic checks are retained; technical hard rejects are evaluated before emotional ranking, then the winning production take's local fault takes the repair route. Do not implement “Verify = automatically reroll everything.”

## Acceptance scenarios

- Selecting each of the 42 entries resolves its complete source text, fields, Verify text and valid provenance locally, without reading the external skill.
- Anderson + a scoped Storaro color deviation changes the approved palette/compile output and the relevant review criteria; camera geometry remains Anderson unless explicitly changed.
- “Greengrass + Kurosawa” produces one base plus dimension overrides, never two whole packages. “Jarmusch” resolves its scoped alias without creating three packages.
- A Fincher request offers no automatic DoP overlay. A requested clash shows the real tradeoff and records the user's choice without secretly changing it.
- Switching the look invalidates affected downstream artifacts under explicit rewind; it does not silently rewrite an approved project's pinned knowledge version.
- A frame-only review cannot pass a timing or sequence criterion. An unseen take cannot be accepted through fabricated aesthetic findings.
- Musicvideo uses the same visual blueprints while retaining original-song ownership and its approved section/energy arc.
