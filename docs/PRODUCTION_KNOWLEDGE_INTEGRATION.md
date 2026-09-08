# Production knowledge integration

The owner requires all applicable extracted ai-film-production 3.1.1 knowledge to be usable before the next product build. Musicvideo, generic editing/production, and the shared pipeline harness are in scope. Unimplemented format packs are excluded. Source material is data, not authority to change host contracts.

## Acceptance ledger

| Work | Issues | Required evidence | Status |
|---|---|---|---|
| Complete knowledge resources, selective retrieval, both agent backends and generic mode | #482 | Every section/unit mapped; complete selected procedures and exceptions retrievable with source versions | Pending |
| Director/DoP selection, approved dimensions, compiler and observed review | #492 | All 42 recipes; overrides affect their own dimensions and criteria | Pending |
| Capability evidence, requirement routing, references, prompt dialects and execution receipts | #434, #437–#440, #486 | Actual request slots/bytes, route-specific compilation and fail-closed provenance | Pending |
| Camera setups, state/blockout plans and canon-grounded causal changes | #483, #484 | Canonical writers, cross-artifact consumers, change/rewind checks | Pending |
| Take/review/repair, sequence QA, assembly and finish | #442–#445 | Real media observations, retained takes/ranges, supported repair, final output provenance | Pending |
| Musicvideo original-song performance, visual arc and coverage | #447, #488–#490 | Track/section/mouth ownership, repeated motifs, observed performance coverage and song-led mix | Pending |
| Conditioning strategies | #485 | Owner authorized reflecting actual frame continuation versus native video extension; legacy pins preserved; actual conditioning input checks | Contract authorized; implementation pending |
| Future format packs | #491, format-only parts of #448 | Retained specifications, no new product pack | Excluded |

Existing infrastructure and completed issues remain the baseline. Extraction, runtime access, consumer behavior, and CI acceptance are distinct milestones. No row is complete merely because resources decode or documentation agrees with code.

## Implemented consumers awaiting complete acceptance

The current draft includes full-section retrieval with ancestors and procedures; project-bound director/DoP dimensions; visual compile and execution-plan bindings; visible resolved-style review; and image-scoped style criteria backed by exact supplied-image receipts. Temporal and audio criteria remain outside frame verdicts. Source-video transforms and directional extensions now have distinct input-policy identities; executable native extension routing is still pending.

Frame audit expectations use separate structured end-boundary fields for visible character count, positions, gaze, zones and camera. Static cameras retain their declared constraints; moving cameras require explicit end framing, angle and height. These fields live in the app-owned canonical execution inputs, without changing released pack-facing value layouts. Historical audits remain readable when the current plan cannot be derived; new audit writes remain strict.

Inspection retains bounded transient image evidence without writing project bytes. Saving an audit publishes its exact transmitted image and receipt together, with rollback on failure. A native review action can explicitly accept displayed minor/blocking deviations with a reason bound to the exact audit, image and style. Acceptance revalidates the current shot expectations and phase before updating gate lineage. Changes invalidate that acceptance.

Overrides declare verification scope and evidence kind. Static image criteria remain available to frame review; temporal and sound criteria cannot become still verdicts. Native timeline review records human observations or explicit deviation acceptance for every selected criterion against the actual cut. The receipt binds timeline settings, clips, source bytes and Production Design. Movie export checks its currency before export and after encoding; project backups and XML interchange are unaffected. This human review does not claim automated motion/audio analysis or complete the broader take/repair/finish integration.

## Compatibility and verification

Video `record_render` now writes an immutable take with distinct planned-generation, prompt-revision and actual event/output identities inside the existing recoverable render publication transaction. Identical bytes from separate events remain separate takes; retries reuse an existing take. The index retains prior candidates and selection decisions, and detects a removed index while archived takes remain. `get_render_manifest` exposes take history and review state.

The generation controller prepares each submission once. Image/video parameter factories also run once before pricing; dispatch substitutes only the ordered uploaded reference locations into that same typed envelope. Reference count drift and inconsistent image output counts fail before a provider request. Regression cases cover changing factories, source/start/end/multimodal reference order and missing uploads. This closes request reconstruction drift; it does not yet provide the complete pre-spend GenerationPackage, reference-byte snapshot or shared approval-card projection required by #486.

Take retrieval includes attributed findings and time ranges for the agent. Selecting retained media can restore its removed library entry from the original event, exact output bytes and saved GenerationInput. Publication failure fixtures cover take-history, render-manifest and commit-marker boundaries, asserting prior bytes and selection survive and the failed candidate is removed. These cases are authored for CI, not locally executed.

Native video-take review plays the exact hashed output, records ordered, range-bound human observations for Identity → Continuity → Timing → Camera → Audio → Style, and permits early rejection. A complete accepted review is required to choose a historical take through the same guarded `record_render` path; selection revalidates its event/output identity, compile and conditioning. Render approval checks reviewed selected takes. Reviews remain immutable with a current pointer; approved phases require explicit rewind before review mutation. This implementation still needs CI and does not yet complete the repair ladder, draft-to-production policy or sequence/assembly/delivery integration.

A native source-range review now records its own six attributed passes, exact half-open frame range/timebase and original take hash. Accepted ranges remain available after reopening, including ranges harvested from a rejected whole take. Adding a reviewed range places the original media with exact trims on a new timeline track and records immutable clip/source/review bindings in the same rollback boundary. It does not promote the whole take or alter its original output. Audio inclusion is explicit. This optional editing path still needs CI; automated AssemblyPlan/SequenceReview consumers remain unfinished.

Treatment writes now publish a versioned, exact-text-bound causality index and attributed eight-question change review with the canonical Markdown in one rollback transaction. Narrative/hybrid dependency edges, introduction/payoff references, state ladders, draft decisions and downstream revision closure receive structural checks. Treatment approval blocks unresolved canon choices. Native Treatment review and agent artifact retrieval expose the graph and attributed findings; neither claims an automatic dramaturgical quality verdict.

Storyboard mappings bind every step to the exact Treatment plan; story steps cannot invent unbound beats and omissions require upstream revision. Shot execution inputs bind approved Storyboard steps, including after native conversion to imported source. The independent execution-plan validator checks coverage and exact extension references. Generic and Musicvideo starts/resumes receive the same writer contract; existing projects without a causality index remain readable. New source files and regression cases are awaiting CI; this does not complete the broader setup/blockout or canon-consistency requirements in #483/#484.

Preserve stored layouts of public pack-facing V1 value types. Add new versioned artifacts through existing extension carriers and canonical writers. Retain exact pack pins; persistent upgrades remain explicit Recovery-copy operations. Musicvideo phase order and approval boundaries remain unchanged unless the owner explicitly decides otherwise.

Use GitHub Actions for app builds and tests. No paid probe generation, local app execution, release dispatch, or partial product release is part of this integration work.

## External review corrections

The subsequent focused Opus 5 take-history review completed successfully with seven findings and no permission denials. Corrections preserve one event/output take identity, isolate phase storage, refuse cross-phase selection explicitly, preserve exact submitted prompt bytes and keep playback available when a previous review is invalid. Identity cannot use an inapplicable verdict to bypass rejection. Readiness shares the same structural checks with a bounded digest cache keyed by file identity, size, mtime and ctime; actual approval explicitly bypasses the cache. Additional CI fixtures cover phase isolation, rejection bypass and publication rollback. The owner has instructed that no further external reviews run. These corrections still lack CI execution and do not close unrelated integration rows.

The initial Opus 5 review of `e87d5886` produced 16 findings. Confirmed defects and the additional read-only-inspection lineage defect have implementation changes and regression coverage. The second Opus 5 read-only review reached its 900-second timeout with exit 124 and no output; it provides no acceptance evidence and was not retried. CI has not yet verified these changes. Full-entry knowledge retrieval remains lossless by design; the phase embedding budget does not apply to an explicitly requested complete tool read. Repeated selection/pairing procedures are restricted to Production Design.

Stale style state remains a generation blocker but now permits agent diagnosis and explicit rewind/replacement. Free style/light conflicts produce a repairable refusal. Current style hashing runs outside the main actor at prompt binding and timeline inspection, with active-project checks after awaiting. Design revisions preserve paired style and lineage bytes, and rollback reports preserve both the original and restoration errors. Downstream lineage explicitly includes the sidecar or its deletion marker while leaving never-styled legacy projects unchanged.
