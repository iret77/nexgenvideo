# CI execution and measurement

## Triggers

A pull request starts only `pr-checks.yml`: one Linux job, `Light Checks`
(AppTheme lint, pack pipeline contracts, script tests), without a paths filter.
It is the required status check for `main`, without an up-to-date requirement.
No push, pull request or schedule starts a macOS runner (`macrunner` or `macos-26`).

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

## CI pipeline

CI classifies the diff (a run without a pull-request base verifies everything),
runs inexpensive source checks on Linux, then compiles debug products and tests
once on `macrunner`. When bundle paths change,
the same job assembles the app from that build directory through SwiftPM's
incremental build. Real external pack loads, historical compatibility checks and
relaunch checks still run. Normal-startup acceptance consumes the zipped app on
`macos-26`. Build directories are never cached or restored across jobs.

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
a standalone hosting/accessibility probe on macOS 26. Bounded JSON and logs retain
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
