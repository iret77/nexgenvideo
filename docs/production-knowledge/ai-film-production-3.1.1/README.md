# NexGenVideo production knowledge — ai-film-production 3.1.1

This is the complete locally usable knowledge extraction, not a summary and not an installed skill. It preserves every source Markdown document at commit `0333751214c7af17977dd33f0ba88ba9c352421e` and adds NGV consumer contracts, explicit adaptations and format specifications. Runtime integration remains tracked in #482 and the linked consumer issues; this dossier itself does not change app behavior.

| Material | Count | Read or consume |
|---|---:|---|
| Complete source documents / sections | 20 / 254 | [Handbook](handbook/skill.md), `chapters/*.json`, [index](index.json) |
| Addressable blocks within sections | 631 | [Units](units.json), with containing section and exceptions |
| Director recipes / DoP signatures | 31 / 11 | [Complete structured blueprints](blueprints.json), [selection and pairing handbook](handbook/director-recipes.md), [NGV binding](blueprint-bindings.md) |
| Complete runbooks W1–W10 | 10 | [Procedures](procedures.json) |
| Complete decision/reference tables | 50 | [Tables](tables.json) |
| Intact fenced templates and examples | 17 | [Templates](templates.json), always with their parent selector/context |
| NGV application contracts | 20 | [Contracts](application-contracts.json) |
| Explicit NGV precedence/adaptations | 17 | [Precedence](precedence.json) |

## Use in implementation work

Read [integration.spec.md](integration.spec.md) for the full migration contract and [coverage.md](coverage.md) for every section's consumer and owner issue. Select an application contract and use `index.json` to locate the relevant complete sections. `locators.json` resolves original file/chapter notation entirely within this bundle. Direct local links exist for all full chapter texts below.

For a style choice, read the complete selection/pairing chapter, select the actual blueprint from `blueprints.json`, then apply `blueprint-bindings.md`. For a production task, select W1–W10 from `procedures.json` and follow its local chapter dependencies. For a model prompt, load the named model's complete dialect and exceptions; a fenced template by itself is insufficient. Examples retain invented fixture names; they are never project canon.

This authoring format is not the existing `ProductionKnowledgeV1` runtime format. It is the complete input to that migration. No network or external skill installation is needed to use the knowledge. Source links serve provenance, not content delivery. Provider/UI assertions remain their dated source evidence until independently verified for an actual route.

## Complete handbook

- [Production discipline, preflight and Render Slate](handbook/skill.md)
- [Director recipes, DoP signatures and selection](handbook/director-recipes.md)
- [Film craft](handbook/film-craft.md) · [All genre baselines](handbook/genre-baselines.md) · [Story structures and causal lints](handbook/story-structures.md)
- [Pipeline, assets, geometry and coverage](handbook/production-pipeline.md) · [Canon, registry, IDs and full bible template](handbook/production-bible.md)
- [Video blocks and protocols](handbook/video-prompting.md) · [Image control ladders](handbook/image-model-logic.md)
- [Style vocabularies and reference integration](handbook/style-control.md) · [Complete stylized-3D method and case lessons](handbook/pixar-look.md)
- [Renderability and rescues](handbook/renderability.md) · [W1–W10](handbook/workflows.md) · [Post, audio, review and rights](handbook/post-audio-legal.md)
- [Model dialects and historical evidence](handbook/platforms-models.md) · [Platform/UI/API/MCP routes and receipts](handbook/platform-ui-workflows.md)
- [Worked delivery](handbook/worked-example.md) · [Glossary](handbook/glossary.md) · [Source/evidence registry](handbook/sources.md) · [Original release/packaging context](handbook/readme.md)

## Pack specifications

Musicvideo: [Performance sync and mouth ownership](formats/musicvideo-performance-sync.spec.md) (#488), [Visual concept arc](formats/musicvideo-visual-arc.spec.md) (#489), [Performance/dance/concert coverage](formats/musicvideo-coverage.spec.md) (#490).

[Future-pack specification](formats/future-packs.spec.md) (#491) covers fiction, series, documentary/interview/biography, commercial, vertical/social/microdrama, explainer, animation, trailer and vacation. It distinguishes source knowledge from proposed NGV design. The full underlying procedures are retained here rather than compressed into that spec.

## Verification and license

`python3 validate_corpus.py` checks the offline bundle, original source-content hashes, exact reconstruction, IDs, local references, derived recipe/runbook/table/template integrity, unit ranges and manifest. To also compare against a separately obtained checkout of the pinned skill, run `python3 validate_corpus.py --source /absolute/path/to/skill-checkout`. This validates knowledge data only; it does not build, test or launch NexGenVideo.

See [inventory.json](inventory.json) for source hashes and explicit dispositions and [bundle-manifest.json](bundle-manifest.json) for distribution hashes. Only the decorative `assets/hero.jpg` is excluded. Original MIT copyright and permission notice are preserved in [LICENSE.source.txt](LICENSE.source.txt). All unmodified source prose remains attributable to `iret77/ai-film-production`; NGV application contracts and specifications are separately marked adaptations.
