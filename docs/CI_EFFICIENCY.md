# CI execution and measurement

## Triggers

A pull request starts two Linux workflows without path filters: `pr-checks.yml`
provides `Light Checks` (AppTheme lint, pack pipeline contracts, script tests),
and `ci-lint.yml` checks workflow policy and YAML syntax. `Light Checks` is the
required status check for `main`, without an up-to-date requirement. `ci-lint`
is not yet required; issue #674 tracks its activation after successful CI.
No push, pull request or schedule starts a macOS runner. All macOS jobs use `macrunner`.

Heavy verification starts manually through `ci-batch.yml` or a focused acceptance
workflow. When approval is required, it covers the build incident rather than
each run. The batch calls `ci.yml` and, selectable per run, the hang replays,
signing preflight, native workspace acceptance and private Music Video analysis
acceptance, covering every merge since the previous batch. After a scoped fix,
the incident resumes only the affected failed checks. The PR records the earlier
successful run and commit, the new run and commit, and why the retained checks'
code and inputs remain applicable. Release readiness combines those documented
results for the release's `main` commit; an unresolved failure cannot count as
passing evidence. `ci.yml`'s first job carries the same name,
`Light Checks`, so a dispatched run (for example the release metadata flow) also
satisfies the required check.

### Existing-artifact followups

For a fresh Core build immediately after a PR merge, `verified_pr_run_id` reuses
that PR's three successful Linux checks: AppTheme, pack contracts and the complete
tooling suite. The producer must be the owned `pr-checks.yml` run at attempt 1,
with every check and proof-upload step successful. Its artifact records the actual
checkout commit and tree, separately from the PR head. Core verifies the artifact
digest, original job output, merged PR identity and equality with its entire current
Git tree before omitting those checks. A changed tree, failed or skipped check,
expired artifact, fork or missing proof fails before Mac work starts.

The composition retains original metadata, archive and job output. Distributable
bpy qualification, UI rendering, compilation, native tests and runtime checks keep
their existing requirements. No input selects reuse by itself: the verification
step must emit success. This mode cannot be combined with historical failed-Core
continuations; their restricted input contracts remain unchanged. Without this input,
the normal source checks still execute. Proof recording and upload run after the
PR checks; their failures also fail Light Checks. The proof does not replace a
check or claim native product verification.

Use the registered `CI Batch` entrypoint on the exact producer commit with
`mode=followup`, its `runtime_run_id`, and exactly one `followup_workflow`:
`externalgui`, `settings`, or `smartsearch`. This calls the reusable workflow from
that commit even before its standalone dispatch is registered on the default branch.
Followups skip Core compilation, workspace acceptance, signing, replays and private
analysis regardless of the initial-mode checkbox defaults. Linux validation rejects
missing or incompatible selectors and requires one unexpired, source-matching
`workspace-ui-app` from the named producer before allocating any Mac job. Existing
consumer archive, source and app checks remain in force.

For `externalgui`, `interface_scale` selects `all`, `1`, `1.25`, or `1.5`. For
`settings`, `settings_scope` selects all cases, the Settings or Recovery family,
or one existing case such as `settings125` or `packrecovery100`. The separate
`packresume172` family selects `packresume172100`, `packresume172125`, and
`packresume172150`: the known released 1.7.2 preview pack, not an inferred user-project
pin. Existing Settings and `packrecovery` cases retain their original 0.5.8 baseline;
the additional family binds the unchanged 0.5.16 ZIP from `preview-39124049687`.
Both use the same exact app artifact. The preparer's unqualified default still
selects the newest compatible baseline; these RC matrix cases explicitly pin their
baseline versions and verify original archive hashes. Smart Search keeps
its existing cold-download and warm-layout sequence. Unrelated selectors must stay
at `all`. Initial mode remains the default and keeps the existing checkbox behavior;
it rejects supplied followup selectors or a producer run ID. Workspace cases retain
their separate registered `Workspace UI Acceptance` entrypoint and artifact-reuse
inputs. Followup success proves only the selected surface and cases.

### Managed bpy qualification before app builds

`CI Batch` with `mode=qualification` runs only the existing bpy source-closure
workflow with `distribution: false`. Its first run assembles and independently
validates the source candidate on Linux and records the pinned binary on macrunner with its actual OS;
it does not compile the app or run the normal batch jobs. App followup selectors
must remain unset/default. A later qualification can name that producer through
`qualification_binary_run_id`: only sources run, and the original passing binary
measurement is reused after the existing repository, workflow/job, attempt, time,
artifact-digest and runtime-input checks. The registered batch calls the reusable
workflow without requiring its standalone dispatch to be registered on main.

`qualification_source_run_id` separately selects retained source bytes from one
exact completed qualification, including a failed source job with a verified
partial inventory. Every reused file is checked again against its current original
pin. Download failures are collected while other declared sources are attempted;
the job remains failed and uploads its verified subset. A successful job uploads
the assembled tar without a second full cache copy. Changes to the source workflow
still change the binary fingerprint: leave `qualification_binary_run_id` empty
once to obtain a fresh measurement after such a change.
Partial source artifacts expire after seven days; successful evidence remains for
30 days. Cancellation or job timeout does not guarantee an upload: only an actual
uploaded, provenance-checked partial artifact can be reused.

Use the actual candidate artifacts to complete binary/source correspondence,
source-archive pins and notice text/coverage. A source-only qualification then
produces the complete archive and manifest; pin their exact hashes and archive
size before setting the lock to `ready`. Normal CI retains `--distribution` and
the distributable-source checks before any app build. Candidate success alone
does not authorize distribution or supply missing evidence.

Initial CI, standalone workspace builds and releases consume the exact qualified
Corresponding Source pair through `bpy-qualified-source.yml` and
`prepare-bpy-source`. Before publication it comes from the pinned successful
Actions producer; after publication it comes from the fixed original
`publicSourceAsset.releaseTag`. Both paths retain the current public hashes and
independent distribution validation. The complete producer identity is pinned in
the lock and in the small same-source `bpy-source-receipt.json` handoff.
Release publication attaches the exact source pair beside the binaries; Actions
app/test/diagnostic artifacts carry only the receipt. An expired unpublished source
artifact requires an explicit qualification rebuild and reviewed replacement pins; consumers never
rebuild, repin or fall back after a hash mismatch. Candidate/partial source reuse
in qualification remains separate and cannot satisfy the distribution gate.

`external-gui-acceptance.yml` reuses the same-source `workspace-ui-app` artifact
and builds only its external XCTest driver. Separate macrunner jobs exercise the
normal installed app at 100/125/150%; a failed size can be selected independently.
Each job checks the archive and app tree against the build producer's source-bound
receipt, which is retained with the journey evidence. Independent workflow runs
have separate concurrency groups so a new batch cannot displace a queued release journey.
The journey covers generic import/edit/save/reopen/export without internal app
acceptance flags. Screenshots, accessibility trees, input records, project snapshots
and independently decoded output accompany the result. All native acceptance uses
the macrunner desktop and records its actual macOS version; the deployment target remains macOS 26.

The release workflow uploads the exact notarized DMG for a separate external
journey at 100%. Publication and publication recovery require that journey's
success for the same source and DMG hash. A failed GUI job resumes against the
existing DMG without repeating compilation, signing or notarization.

## CI pipeline

CI classifies the diff (a run without a pull-request base verifies everything),
runs inexpensive source checks on Linux, then compiles debug products and tests
once on `macrunner`. When bundle paths change,
the same job assembles the app from that build directory through SwiftPM's
incremental build. Real external pack loads, historical compatibility checks and
relaunch checks still run. Normal-startup acceptance consumes the zipped app on
`macrunner`. Build directories are never cached or restored across jobs.

SwiftPM dependency caches use a stable directory inside `RUNNER_TEMP`;
the key includes the platform, toolchain and package manifests. Run IDs are absent
from the cache path because [GitHub's cache version also hashes that path](https://github.com/actions/cache/blob/v4/README.md#cache-version).
The cache contains no compiled products. Core saves resolved dependencies after a
successful build, before testing; an exact cache hit needs no new save.
Debug and release use `run_macos_tests.py`: XCTest runs once through SwiftPM with
Swift Testing disabled, Engine Swift Testing runs once through its test product,
then App Swift Testing runs once in `NexGenVideoAppKitTestHost`. That host enters
`NSApplication.run` synchronously and invokes the public Swift Testing ABI after
loading the exact built App test bundle. The same configuration, scratch path and
compiler flags locate and exercise the built products. No phase retries a failure.
Each phase retains original console output and exit status. Engine and App JSON
records bind discovered opaque test IDs to actual starts, ends and run completion;
executed functions must belong to the intended source module. App execution also
requires the owned host receipt, successful ABI result, active AppKit main loop
and healthy original event stream. Full-suite output still requires two genuine
XCTest and two genuine Swift Testing completions. Neither exit zero nor an ABI
result alone supplies missing test completion.
Only the App child receives the selected toolchain, macOS platform and staged
bundle loader paths; its recorded paths and native load result remain evidence.

Agent UI specification rendering runs in a separate Linux job for changes to its
inputs or CI wiring. A documentation-only UI specification edit now produces
render evidence without allocating a macOS runner. Runtime Markdown in source
and pack directories is treated as code. `Merge Gate` requires all selected jobs,
including UI evidence and normal-startup acceptance, and rejects missing plans,
failed jobs and unexpected skips. The manual Bundle workflow calls the same CI.

Native workspace acceptance includes a Musicvideo sequence review and delivery
at 960×640 with 100%, 125% and 150% interface text. It uses the real assembled
timeline, review controls, Export sheet and save panel. Its synthetic film and
delivery receipt are retained with the screenshots; independent decoding checks
the full song duration, waveform identity and selected moving shot images. The
first shot passes through prompt compilation, the visible batch approval card,
the real batch runner and Fal HTTP client, output import and the native take-review
sheet against a simulator that rejects unexpected requests. The next shot uses
imported footage. The report binds native actions, persisted approvals, generated
source, references, spend receipt and trimmed cut handles to the assembled film.
Intake and phase approvals use the document's controls throughout the same run;
missing current artifacts must disable approval before their exact bytes are restored.
Agent responses and creative choices remain supplied fixture inputs.

The same Workspace UI Acceptance workflow also runs the generation batch pointer
and keyboard review with that built app. This review runs even after a workspace
check fails. Both checks' logs and screenshots, along with the workspace JSON,
are retained in `workspace-ui-evidence`. Its standalone dispatch repeats these two native surfaces
without rerunning the unit, HDR, pack, startup or chat suites whose earlier
successful evidence remains applicable to the scoped fix.

An optional `unit_test_filter` on the standalone or reusable workspace workflow
adds the affected unit suite, such as `MusicvideoChecksTests`. The existing
`macrunner` build directory is extended with test targets, their runtime inputs
are staged, and the same macOS driver forwards the unchanged native filter to
XCTest, Engine Swift Testing and the AppKit host. Native discovery and JSON events
prove a backend's empty selection; it is recorded as empty, never as a passed
suite. A filter with no actual test execution in any backend fails. HDR QC selects
the App Swift Testing backend explicitly and retains its exact filter. The full
release and Core suites keep the fixed two-plus-two completion requirement. Tests run
after the app artifact is uploaded. An empty filter skips this step. The build job
exports `app_ready` only after a successful upload with an artifact ID. Native
acceptance downloads that exact artifact from the same run even if the later unit
step fails; the unit failure still fails the workflow. A failed or missing upload
cannot start native acceptance.

The optional `acceptance_scope=filmreview` repeats only the mixed Musicvideo film
case at 100%, 125% and 150%, plus the separate generation pointer/keyboard review.
The default `all` retains every workspace case. Film-only results require the same
native actions, 45 screenshots, delivered movie and bound receipt; the JSON names
the selected and unexecuted cases and never marks full workspace acceptance for
that partial scope. Earlier passing cases remain identified by run and commit in
the PR's verification record.

The missing-reference acceptance follows the visible revision action through the
agent-facing diagnostic, a supplied repaired proposal, its rendered thumbnail and
native approval. This focused card check stops before provider execution; the
mixed-film scenario separately exercises the actual batch runner. Bible readiness
and Storyboard checks inspect the displayed reason, opened diagnostics and selected
shot details rather than treating a selected model identifier as UI evidence.

The private analysis acceptance reuses the workspace app and external pack from
the same batch instead of compiling them again. Without workspace acceptance it
builds its own harness. Real source media and analysis remain in the private
fixture/report packages; no private media enters the public UI artifacts. The
real analysis run and the synthetic delivery scenario provide different evidence:
neither represents a live paid generation-provider run or a subjective film-quality
assessment. Runtime results are established only by the corresponding Actions run.

The synthetic chat stress run also reuses the workspace app when that acceptance
is selected. Chat stress and private analysis proceed even if the workspace UI
checks fail, so independent failures are observed in the same batch. If its build
failed and produced no runtime artifact, their download fails without another build.
A standalone chat run builds its own app. The recorded
chat replay still builds separate optimized candidate and historical transcript
variants. Both restore the captured window dimensions, states and timing. When
the recording includes transcript dimensions, those remain mandatory; older
recordings without them use the workflow's explicitly declared 480×560 comparison
viewport. Evidence distinguishes recorded geometry from comparison geometry and
requires the actual transcript to match it, including measured scroll movement.
The comparison does not reconstruct the unknown original viewport or prove that
the historical hang was reproduced. Completion and main-thread responsiveness
remain required for the candidate.
An incident retry can deselect `recorded_hang_replay` while retaining chat stress
when the optimized replay already passed and the correction does not affect its
code or inputs. The earlier run and the unchanged replay scope belong in the PR's
verification record.

The manual Native Acceptance Probes workflow diagnoses audio duration and native
Storyboard text without compiling the app. It compiles the actual
decoder with the engine PCM contract on `macrunner`, then measures it alongside
a standalone hosting/accessibility probe on macrunner. Bounded JSON and logs retain
conversion status, WAV payloads, EOF reads, real final audio and observed text.
Pixel recognition retains its raw results and visible forbidden-token controls
at all three supported text scales. These probes
do not replace the full workspace or private-file acceptance.

## Release metadata

The publication script dispatches CI with `metadata_version` on the version's
metadata branch. CI downloads that release's existing publication transaction
from the plugin channel. It verifies ancestry and reconstructs the only allowed
changes from the transaction: the two Info.plist version strings and one appcast
entry. Other plist keys, earlier appcast entries, signatures, URLs and file modes
cannot use the shortcut. Changed source since the release requires full CI;
malformed or mismatched release metadata fails on Linux. A manual CI dispatch
without metadata input always selects full verification.

## Release compilation

Release tests still use their separate scratch directory with `-enable-testing`.
Tests import app, engine and pack internals using `@testable`; the distributed app
and pack compile without that flag. Sharing their build directory or shipping
testable products would change the production configuration. This optimization
therefore retains both release compilations and all signed-artifact checks.

## Monitoring

Collect merges before one approved batch run. Monitor an exact run and commit with
`scripts/ci_watch.py`; it polls once per minute, remains quiet while unchanged,
reports API failures and timeouts explicitly, and prints one JSON result plus
bounded excerpts for failed jobs. It does not dispatch or retry workflows.

From an interactive project shell with the repo auth helpers:

```sh
python3 scripts/ci_watch.py RUN_ID --sha COMMIT_SHA --gh-command gho "$(getpat)"
```

Inside Actions the default authenticated `gh` command is used. The report sums
job timestamps as raw runner seconds, reports workflow elapsed time separately,
and includes step durations and runner labels. Queue time is excluded from runner
seconds. These are operational timings, not rounded billing minutes or costs.

Compare equivalent successful changes and configurations; also count failed and
cancelled attempts when assessing a batch. Baseline observations before these
changes:

| Run | Measured steps |
| --- | --- |
| [CI 34416977181](https://github.com/iret77/nexgenvideo/actions/runs/34416977181) | Compile 453 s; UI rendering 79 s |
| [Bundle 34416977199](https://github.com/iret77/nexgenvideo/actions/runs/34416977199) | Build and bundle 274 s |
| [Release preview 34175620480](https://github.com/iret77/nexgenvideo/actions/runs/34175620480) | Test compilation 1,003 s; production build and signing 410 s |

The bundle baseline includes assembly and signing; it is not all removable
compilation time. Wall-clock savings also depend on the former parallelism and
runner queues. Measure the resulting runs before claiming a percentage.

## Standards adoption, 2026-10-25

Issue #674 tracks the incomplete standards adoption. The standalone `ci-lint`
workflow runs strict policy and YAML syntax checks on Linux for every PR and
manual diagnostic dispatch. `script/ci-lint` is the unchanged 1.10.0 copy from
`iret77/engineering-standards` commit
`f69060bdfef550f9efa293a43368217034a60575` (SHA256
`d98eb34e03b83284df7482b153f035942f4d7e858d9e7e60bfb196087594ebc3`).
Manual replay, signing and native diagnostic workflows preserve the active run.
A newer dispatch waits; GitHub retains only the latest pending run per group.
Previously implicit artifact retention now requests 90 days, subject to the
repository retention limit. The bpy orphan
check polls for worker exit within its existing two-second grace period.

Before this standards patch, PR run `40226274208` on source
`6995fd36512b955af14a547464e3280adf6d4f33` completed Light Checks in 220 seconds on `ubuntu-24.04`:
AppTheme, pack contracts and 1,261 Python tests (three skips; 207.200 seconds for
the Python suite). This is a timing comparison point, not verification of this
standards patch. The patch requires its own PR run including `ci-lint`. Older 20–24 second PR
runs have a different source/test inventory. Successful qualification-only and
full Core batches, and the different diagnostic modes, are not interchangeable
samples for a runtime estimate. No full-suite per-test coverage measurement or
completed test-value audit is claimed here.

Actions used by jobs that read signing, private-fixture or provider credentials
are pinned to full commits, including the dependency-cache composite they call.
The pins resolve the same existing major-version tags; no action major upgrade
or additional credential use is introduced.
