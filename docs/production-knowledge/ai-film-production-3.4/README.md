# NexGenVideo production knowledge — ai-film-production 3.4

Tracking: [runtime migration #547](https://github.com/iret77/nexgenvideo/issues/547).

Complete extraction of the supplied **3.4** skill archive, plus updated NGV application contracts and format specifications. This follows the merged extraction PR #493. The prior 3.1.1 runtime integration is implemented; **the 3.4 behavior changes described here still require runtime migration**. The old snapshot remains unchanged.

Source: `ai-film-production.skill`, SHA256 `4827d6da3df7654434bceac3e143ec7172f18833a7a45c693fcf55c68a2cd012`. No upstream GitHub commit or independent live provider verification is asserted for this attachment.

| Complete material | Count | Local resource |
|---|---:|---|
| Source Markdown documents / sections | 20 / 297 | `chapters/*.json`, [index](index.json), full handbook below |
| Addressable blocks | 682 | [Units](units.json) |
| Director recipes / DoP signatures | 31 / 11 | [Blueprints](blueprints.json), [NGV binding](blueprint-bindings.md) |
| Runbooks W1–W10 | 10 | [Procedures](procedures.json); W10 now has nine stages |
| Decision/reference tables | 59 | [Tables](tables.json) |
| Fenced templates and examples | 21 | [Templates](templates.json), with complete parent rules |

## What changes for NGV

Read the **[complete 3.4 migration contract](migration-3.4.spec.md)**, [precedence/adaptations](precedence.json), [application contracts](application-contracts.json) and [exhaustive coverage](coverage.md). They distinguish existing completed consumers from new requirements.

The substantive changes include a persisted A/B/C prompt-technique decision, model/agent responsibility and prompt economy, seven verifiable video-lint measures, eight still-lint checks, non-growing repair, revised batch-failure threshold, planned-length drafts and a scoped draft-rescue exception. W10 adds animatic; recipes explicitly mark assembly-only `[edit]` criteria; medium emulation adds motion signatures and a seven-layer Master Style Block. Reference/audio scoping, dialogue notation, source boundaries, platform/API evidence and agent cold tests also change.

All source text is retained, including conditions, examples, evidence labels and exceptions. The technique-specific [retrieval plans](retrieval-plans.json) use local section/unit IDs: B/C can load the shared lint paragraph without loading A's entire technique. The corpus is not a skill to install and not a monolithic system prompt. Source instructions are knowledge data to adapt, not authorization to execute tools, delegate, spend or override NGV contracts.

`source-delta.json` accounts for every baseline/new source file. `references/agent-models.md` is added; source README.md was absent from the supplied package and remains only in the historical snapshot. The 33 external P51 master prompts are cited source material; the attachment contains their table/distillation and supplied examples, not all external full prompts. Nothing absent from the attachment is claimed as imported.

## Full local handbook

- [17 production rules, economy, technique menu, lint and Render Slate](handbook/skill.md)
- [Complete director/DoP recipes, selection and pairing](handbook/director-recipes.md)
- [Film craft](handbook/film-craft.md) · [13 genre baselines](handbook/genre-baselines.md) · [Story containers and causal lints](handbook/story-structures.md)
- [Assets, geometry, performance capture, coverage](handbook/production-pipeline.md) · [Canon, registry, IDs and bible template](handbook/production-bible.md)
- [A/B video techniques, model containers and protocols](handbook/video-prompting.md) · [Image control ladders and still lint](handbook/image-model-logic.md)
- [Style systems, technique C, medium motion and references](handbook/style-control.md) · [Stylized 3D and complete case lessons](handbook/pixar-look.md)
- [Renderability and rescues](handbook/renderability.md) · [W1–W10](handbook/workflows.md) · [Post, audio, review and rights](handbook/post-audio-legal.md)
- [Model dialects and dated evidence](handbook/platforms-models.md) · [Platform/UI/API/MCP evidence and receipts](handbook/platform-ui-workflows.md)
- [Worked deliveries](handbook/worked-example.md) · [Glossary](handbook/glossary.md) · [Source registry](handbook/sources.md) · [Dated agent-model measurements and cold-test protocol](handbook/agent-models.md)

## Format specifications

The complete baseline pack designs are carried forward with explicit 3.4 deltas: [Musicvideo performance/audio](formats/musicvideo-performance-sync.spec.md), [visual arc](formats/musicvideo-visual-arc.spec.md), [coverage](formats/musicvideo-coverage.spec.md), and [future packs](formats/future-packs.spec.md). Source-backed content and additional NGV design remain distinct. Musicvideo's locked startup, original song, source modes and phase ownership stay intact.

## Verification and provenance

Run `python3 validate_corpus.py` for offline data integrity; add `--archive /path/to/ai-film-production.skill` to compare exact bytes against the supplied zip and its hash. This checks knowledge data only, not the app. The chapter JSON reconstructs every original source byte; handbook Markdown only normalizes whitespace. The validator checks the complete source set, hashes, section ranges, derived collections, stable recipe identities, `[edit]` binding and technique-scoped retrieval.

[Inventory](inventory.json) identifies source files and the archive; [bundle manifest](bundle-manifest.json) hashes the distribution. The original MIT license and attribution are in [LICENSE.source.txt](LICENSE.source.txt). The new JSON is an authoring/interchange format; it does not change the current runtime manifest or make a provider executable.
