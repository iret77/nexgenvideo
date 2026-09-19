# Migration contract: complete ai-film-production 3.4 knowledge

Tracking: [runtime migration #547](https://github.com/iret77/nexgenvideo/issues/547).

Status: full knowledge extraction and NGV adaptation specification. The earlier 3.1.1 integration is implemented on the baseline `8bd8fbde`; #433, #482 and #492 and the Musicvideo child issues are closed. This revision does not relabel that completed work as missing. It defines the additional 3.4 migration; this documentation PR changes no runtime behavior, model selection, paid execution, ABI or project pin.

## Source identity and full coverage

The source is the user-supplied `ai-film-production.skill`, version **3.4**, SHA256 `4827d6da3df7654434bceac3e143ec7172f18833a7a45c693fcf55c68a2cd012`. No GitHub commit for these bytes is claimed. All 20 Markdown files are conserved exactly in 297 sections/682 blocks. `agent-models.md` is new; the old repository README was not included in the attachment and is not invented for 3.4. Source license is retained. `source-delta.json` accounts for every old/new file and hash.

The complete 31 director recipes and 11 DoP signatures retain their identities, with newly separated headings and explicit `[edit]` clauses. Ten runbooks, 59 tables and 21 fenced templates/examples are independently addressable. All other rules, procedures, exceptions, provenance and contextual explanations remain present, not just the changes listed below. Every section has a consumer contract and a disposition in `coverage.md`.

Use the existing registered knowledge loader, phase harness and typed production consumers. Current `film-production-*.v3.json` libraries and `VideoPromptIRV1` establish the baseline; a folder/resource suffix `v3` is not proof of source version 3.4. Add honestly versioned resources and ABI-safe extension artifacts. Existing pinned projects remain pinned; no silent rewrite on open. Current locked NGV contracts prevail where the generic source workflow needs adaptation.

## 1. Technique is explicit project state

Offer all three techniques together at the applicable creative intake: **A Caption Spine**, **B block structure**, **C Master Style Block + story**. Recommend one with a reason. When the choice is not obvious, offer the same-beat/same-reference draft-batch comparison; an offer is not permission to spend. Persist one technique, its source version, decision/ASSUMED status and approval lineage per project. Never switch per prompt or concatenate two shapes. The W3 one-off ASSUMED-A case is a scoped exception, not a universal default.

Musicvideo keeps Track → optional Lyrics → Init → approved Analysis → optional existing material → story. Resolve technique in an appropriate existing creative phase after analysis; do not add a pre-analysis questionnaire. A later technique change is a recorded decision with affected artifact invalidation and explicit rewind where required.

A carries eight elements with sparse positive reference jobs, optional camera (except Veo), complete beats and an ending. B retains named blocks but omits blocks with no necessary/deliberate content, including previously mandatory padding. C carries one seven-layer description of a physical medium, its own short prose-beat story and exactly one terminal MUST NOT APPEAR list; never a second STYLE line or B skeleton. H3's official fields remain the outer container in every technique.

## 2. Compiler economy and responsibility

Default model-owned axes are composition inside a shot size, in-take cutting/timing, motion/body mechanics, material rendering, light behavior/falloff, transitions and simple-contact physics. The agent always owns scene contents, canon, action order, each beat's end state, reference jobs and required continuity. This does not relax source identity, host approval or deterministic lineage gates.

A control on a model-owned axis needs one of: explicit canon, a deliberate look requirement, or a failed batch on that axis in this take. Record which reason applies in the Render Slate. Do not emit all populated IR fields, camera/FOV/Kelvin/numeric rates, location maps or reference exclusions as mandatory boilerplate. The selected blueprint makes controls available; it does not force them into every prompt.

Scale/distance use one relation to a named object, not metres, body-length units or canvas fractions. Numeric look controls require an actual look reason and visible result; a still's native lens/f-stop/ISO/Kelvin vocabulary and canvas/grid counts retain their documented exceptions. Preserve successful lines verbatim through failure repair; replacement must not drop a previously working requirement.

## 3. Verifiable lint and Render Slate

Each video delivery records seven measures from the **actual compiled prompt bytes**: word count, prohibition-sentence count, numerals outside timing, absolute measures, double mentions, contradictions and beat completeness. The word count is not a universal video ceiling. Source-specific H3 vendor targets and actual platform character caps remain separately scoped facts. Do not fake semantic findings with a string counter or mark unobserved semantics as passed.

Counting respects technique and exceptions: A has one closing prohibition sentence; C one terminal list; B counts within the governing block. Partial video/audio-reference scoping clauses are not prohibition sentences. Fixed terms (3D, tags, shot labels, vendor-verbatim strings), timecodes and declared duration are excluded from the numeric count. A justified numeric look control has a Crew choices record. Contractual ENDING STATE repeats are not accidental double mentions.

`Crew choices` has two parts: **left to the model** and **decided by the crew**, including reasoned exceptions. Keep all these measurements and explanations outside prompt prose. Failed checks are repaired before delivery. Source examples' reported lint numbers are source assertions until independently recounted; preserving an example is not validation of its claims.

Stills use all eight 24i checks: scoped measured word budget; one statement per axis; first-mentioned subject; exact small count or collective noun; ordinary/default state before exceptions; bounded Avoid with protected world rules retained; one-sentence literal-tag roles; relational measures. Three or more failures trigger a short clean rewrite plus stronger channel. The source's GPT Image budget was measured on the stated older generation and inherited to its named newer version; retain that provenance, not a fabricated new measurement.

## 4. Failure and production policies

One iteration is one prompt revision evaluated across four rolls. Three or four failures on the same axis fail the iteration; one or two odd rolls are roll variance. A first steer/exclusion after one failed run, restatement of an existing exclusion after two. Some older runbook wording still says “four”; the current always-rule 15 and detailed QA threshold govern that shorthand.

Repair follows REMOVE → CHANGE → ADD one line, with total word count constant or lower and successful lines protected. After three failed iterations: shorter clean rewrite and stronger control channel. Only two clean failed iterations on at least two channels support a model-limit conclusion. Paid iteration budgets remain explicit authorizations, never an automatically exhausted allowance.

Drafts use planned take length at a supported draft tier; 10 seconds is only the fallback when no duration is planned. Production normally regenerates the locked prompt at full target duration/resolution. Preserve W3's explicit exception: when that regeneration loses scale/structure, offer a scoped edit/upscale of the draft as a **new derived take**, with lineage and acceptance, never raw draft pixels in final delivery. A video extension is still not draft promotion.

Continuation remains explicit frame continuation OR verified native video extension under the current locked NGV contract. The source's clean-last-frame trim is a newly derived immutable source with exact timestamp/frame bytes, not mutation of the original or silent substitution of the approved predecessor. Preserve the original export and every derivation receipt.

## 5. References, speech and style

References carry exactly one positive job. A whole image is not accompanied by prophylactic exclusion lists. A partial image gets a non-transfer clause after observed over-copying; partial video/audio references state what is and is not taken from the first run. Keep source handle syntax route-specific and prove binding; registered NGV asset IDs are not automatically executable API tokens.

Dialogue uses one notation; the spoken line appears once and only in its speech field, with the exact count/speaker/voice ownership locks the selected dialect requires. Do not also write it in ACTION. Musicvideo retains the original master track, exact source segments, mouth ownership and separate audio classes. C places the no-music requirement inside its one terminal list. The source's synthetic sung-line exception is not permission to replace the owner's song.

Retain the complete medium-emulation table and motion signatures, medium-motion diagnostic ladder, seven-layer Master Style Block and its filled example. One chosen medium per prompt. Its still counterpart condenses relevant layers within the still budget and omits video motion grammar. The source's public upstream 33-prompt library is cited evidence; the supplied skill contains its own table/distillation, not all 33 external full prompts. Do not claim those unavailable documents were imported.

## 6. Blueprints, storyboard and animatic

All 42 source recipes are updated in full. Source `[edit]` markers are postfix to their preceding criterion: cut order, VO, score, cross-cutting or transition requirements belong to NLE/assembly and **never trigger a generation reroll**. Other criteria still require appropriate viewed-frame/clip evidence. Retain undeviated base checks and replace only explicitly approved dimension overrides.

Read only the selected recipe plus selection/combination rules as needed. Deakins lineage chosen as a structure permits no extra signature; the incompatible Gilligan/Fraser suggestion was removed. The single grouped intake message also contains any style clarifications. Compile the resolved look via A/B/C, not a universal block compiler or director-name shortcut.

W10 now has nine stages: idea → bible/beat lint → storyboard/setup and take/cut plan → **animatic** → sheets → blockout → location anchors → draft takes → production takes. The animatic proves planned rhythm and duration before expensive generation. Integrate it as a typed planning artifact owned by the appropriate existing pack phase; this is not permission to change the locked Musicvideo phase order.

Model timestamps budget events, not actual detected cuts. Plan intent, observed media cuts and NLE placement remain distinct. Preserve additional previs, comparison-scale-sheet, seamless-loop, new-angle-on-existing-footage, performance-capture/re-skin and clean-boundary workflows with exact source roles. This knowledge applies to generated and ai_enhanced routes; imported/live-action paths must not acquire mandatory generation steps.

## 7. Platforms, evidence and backend evaluation

Retain the new dated Higgsfield API evidence (key-pair auth, separate billing, asynchronous request receipts, upload envelope, endpoint/mode correspondence, route-specific output limits and unknown tag binding), distinct from web/MCP/Bridge/plugin surfaces. The source's claimed model names, resolutions, prices and endpoint behavior are **not independently verified in this PR**, never sufficient to enable a provider or publish a capability as executable. No paid probes.

Veo's camera-first positioning is vendor-backed in the source; Kling camera-first and Grok style-first are recommendations, not immutable vendor constraints. Seedance 2.0 uses numbered shots rather than the 2.5 timestamp behavior; inherit old-version knowledge only where the source records no scoped contrary evidence. Preserve source confidence and vendor/first-party/practitioner hierarchy.

Exact film text goes to compositing by default; retain the specifically scoped master-plate, H3 and designed-motion-typography exceptions. Typography-as-product is a different route, with every word/number checked in the result. New model/API, voice, reframe and restoration claims remain evidence, not automatic routing defaults.

`agent-models.md` adds three named, dated model/harness rows and a reusable cold-test protocol. Keep small sample counts and not-measured cells; they are not success rates or current rankings. Adapt tasks to NGV's local retrieval and verify actual tool traces/lint independently. Never infer authorization for delegation, model switching, approvals, PROPOSAL picks or paid testing from the document.

## 8. Pack and retrieval integration

The updated `formats/` specs retain complete baseline requirements and add 3.4 deltas for Musicvideo, fiction/series, documentary, commercial/social, explainer and animation. Trailer/vacation design additions remain identified as NGV derivations. No closed baseline issue is reopened merely because the source evolved.

Selective context is itself acceptance: no full large chapter files; no second technique chapter. B/C may load only the shared 12h lint paragraph and universally applicable semantic checks, not A's form. Source registry is retrieved when evidence/confidence is disputed. `retrieval-plans.json` provides exact local unit locators for this exception. Both backends must obey the same scope on start/resume/transition; reported reading lists alone are not evidence of actual reads.

## Acceptance for the follow-up implementation

- Every source section/subunit has a runtime resource, concrete future-pack spec, evidence record or explicit non-runtime disposition. Complete preservation here is already checked; consumer migration is separate work.
- A/B/C selection persists, survives resume, changes compiler output, and cannot drift between prompts. H3 keeps its schema; Seedance version-specific timing and Veo placement remain correct.
- Deliberate controls survive; boilerplate controls disappear. Repair never grows the failed prompt or drops a working line. A false lint row cannot pass by merely matching an output schema.
- Partial image/video/audio references exercise their distinct scoping rules. Protected still-world exclusions survive shortening; default-before-exception and relational scale produce the intended plan.
- `[edit]` failures affect assembly only. Animatic, generation events, actual cut times and edit placements stay distinct. Draft rescue creates a separately accepted derived take, preserving raw exports.
- Musicvideo keeps original-song ownership and its startup order; generic imported workflows remain usable without generation.
- Independent cold fixtures prove actual retrieval, semantic lint and canon compliance in both agent backends. Provider evidence stays non-executable until actually verified. App verification runs only in GitHub Actions.
