# 3.4 runtime migration status

Issue #547 remains open. This change implements complete source retrieval and the corrected
four-roll assessment; it does not complete the nine-part production behavior migration.

The engine bundles a separate, hashed 3.4 archive through `ProductionKnowledgeLoaderV1.loadArchive34`.
`get_production_knowledge(sourceVersion: "3.4")` reads sections, Unicode units, stable blueprint IDs,
runbooks W1–W10, tables, templates, individual medium rows and the complete format specifications.
The archive conserves 297 source sections, 682 blocks, 42 blueprints, 10 runbooks, 59 tables and 21
templates. It additionally exposes 30 supplied medium rows and four NGV format specifications.
No upstream commit or unavailable external master-prompt library is invented.

`read_plan` reads one technique. B/C retrieve the exact shared 12h lint units without A's form;
C requires one medium row and includes the seven-layer form and its exceptions. The filled Sumi-e
example is included only for that medium. Reads return source identity and host-computed SHA256/byte
receipts. Those prove returned content, not comprehension, actual generation quality or backend
cold-test success. The source's reported measurements remain attributed source claims.

The [runtime ledger](ai-film-production-3.4-runtime-ledger.json) records actual retrieval consumers
separately from intended behavioral consumers. Dated vendor/backend evidence and future-pack designs
are explicitly non-executable. All baseline libraries and public V1 stored layouts remain unchanged.
The new archive has its own schema/version; no independently released host or pack version is bumped.
Pack/engine version allocation belongs to the combined batch if later pack code calls new symbols.

The existing take policy now counts three or four same-axis failures in a reviewed four-roll batch
as a failed iteration even with one accepted outlier. One/two failures or split axes do not fail the
iteration. Overfull revisions fail explicitly instead of silently claiming a four-roll measurement.
Custom roll limits remain explicit policy. No assessment authorizes or submits generation.

## Remaining acceptance

| Issue point | Delivered here | Remaining work and actual dependency |
|---|---|---|
| 1. A/B/C state | Complete menu/forms selectively retrievable | Persisted choice, canonical writer/gate/lineage and compiler shape remain unimplemented. Their integration was stopped by automatic approval review, not by an inherent prohibition on new artifacts. |
| 2. Economy | Complete doctrine preserved | Sparse compiler projection conflicts with locked `PRODUCTION_PROFILES.md`'s compulsory approved camera/blocking/match/rescue directives and exact prompt checks. A versioned opt-in contract must preserve legacy projection and needs an explicit decision before removing those obligations. |
| 3. Lint/slate | Full seven/eight-check source and exceptions readable | Actual compiled-byte slate and attributed semantic observations remain unimplemented; no semantic PASS is invented. This is unfinished implementation, not a demonstrated locked-spec blocker. |
| 4. Iteration/draft | Three-of-four threshold and counterexample fixtures | Non-growing protected-line repair, planned-duration fallback, separately authorized derived draft rescue remain unimplemented. Rescue must preserve the locked exact-source/provenance gate; no #546 change is approved by this work. |
| 5. References/audio | Complete positive/partial reference, dialogue and ownership source | Typed reference/speech compiler semantics remain unimplemented. Locked original-song and exact-source ownership must remain; no additional permission is inferred or required merely to implement compatible behavior. |
| 6. Blueprints/planning | All 42 recipes and W10, with full `[edit]` text, readable | Style advisor/QA still use the baseline. Typed animatic in an existing phase, observed cuts vs planned timing, boundary and coverage consumers remain unimplemented. No new phase or #559 contract change is authorized. A compatible existing-phase artifact is not inherently blocked. |
| 7. Evidence | Complete dated platform/backend source with non-executable disposition | Current route evidence and enabled-provider catalog remain authoritative and unchanged. No provider probe or generation was run. |
| 8. Context/evaluation | Shared tool consumer, selective technique reads and byte receipts | Phase-driven 3.4 activation, start/resume/transition traces for both real backends and independently evaluated cold fixtures remain unverified/unimplemented. A common tool implementation alone does not prove those traces. |
| 9. Format packs | Four complete revised specifications retrievable | Existing pack consumers and future format implementations remain unchanged; source specifications are not executable behavior. |

Actions fixtures were prepared for loader/resource coverage, Unicode ranges, technique isolation,
legacy resource preservation, the actual shared tool read and four-roll counterexamples. They were
not executed. Static diff inspection is not runtime acceptance, independent review or release approval.
