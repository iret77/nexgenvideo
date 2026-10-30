# External installed-app GUI acceptance

Prepared, unexecuted RC qualification. This adds a normal application startup and
external input path to the existing native fixture acceptance. It establishes no
current runtime result and does not mark any of the 121 RC groups accepted.

The Xcode project builds only an independent XCTest UI bundle. NexGenVideo is
installed unchanged from the previously built app artifact or final DMG and
started through `XCUIApplication(url:)`. The test supplies ordinary English
interface preferences, uses no internal acceptance flags, and neither calls the
app's fixture drivers nor writes its model or settings. The separate UI runner
reads saved project files as an independent observation.

## Required observable journey

One integration test must execute every stage; zero tests, skips and missing
attachments fail qualification.

| Stage | Independent expectation |
|---|---|
| Home and Settings | Normal Home appears, the native app menu opens Settings, the chosen interface text size is visibly selected. |
| File → New | The native save panel creates an empty generic project without a pack declaration. |
| File → Import Media | The real picker imports a generated four-second source under its original filename without inserting a timeline clip. |
| Source → Insert | The normal source inspector has Clear Range disabled and inserts all 120 frames. Saved timeline settings become 320×180 at 30 fps. |
| Timeline Split / Undo | External canvas focus, Select All and 30 right-arrow events precede Split at Playhead. Timeline and source ranges must both be 0–30 and 30–120; native Undo must restore the exact prior timeline. |
| Close and reopen | A native traffic-light click closes the document. The app quits and relaunches, then File → Open loads the saved project. |
| File → Export | The real export control and save panel produce H.264. Reveal must become enabled. External ffprobe checks size, fps and four-second duration; decoded pixels at one second must match the imported source within the recorded tolerance. |

Control locators come from normal product source: native menu titles in
`App/MainMenu.swift`, `Interface text size` in `Settings/AppearancePane.swift`,
`Insert` / `Clear Range` in `Inspector/SourceRangeInspector.swift`, the native
`Track controls` accessibility group in `Timeline/TimelineHeaderView.swift`, and
`export.start` / export job action IDs in `Export/ExportView.swift`. The custom
timeline canvas receives a click beside the observed track-header frame; exact
saved frame ranges validate its effect. Native panel navigation uses the actual
focused Accessibility text editor, rather than assumed system field IDs.

The `reviewAcceptanceProbe` IDs are unavailable during normal app startup and
are deliberately unused. Missing or unreachable controls fail with screenshot
and Accessibility evidence; they are never replaced by in-process actions.

## CI interface

Build the independent UI test bundle once on `macrunner`, then run its unchanged
products on `macrunner`'s arm64 VM. NexGenVideo is never rebuilt by this
workflow. Python 3.12 and the image's existing Xcode are required; xcodegen is used only
by the build job. A commit-pinned setup-micromamba action provides the conda-forge GPL
ffmpeg variant (including libx264) and ffprobe under RUNNER_TEMP. Shell initialization,
generated shell wrappers and caches are disabled; no global package installation or
shell profile change is involved. Both executables must run before the app is downloaded.
No private macrunner GUI tool is used at runtime.
The caller first verifies its immutable runtime artifact or publication
transaction. App mode then binds the copied bundle with the tree digest:

The orchestrator, test source and Xcode project must match their committed bytes
at the expected source SHA; the check uses the script's repository location.

```bash
APP_TREE_SHA=$(python3 scripts/external-gui/acceptance.py tree-sha256 --app "$VERIFIED_APP")
python3 scripts/external-gui/acceptance.py run \
  --app "$VERIFIED_APP" --app-tree-sha256 "$APP_TREE_SHA" \
  --source-sha "$GITHUB_SHA" --scale 1 --evidence "$RUNNER_TEMP/external-gui" \
  --test-runtime "$VERIFIED_TEST_INPUT" --test-producer-sha256 "$TEST_PRODUCER_SHA256"
```

Final DMG qualification requires the SHA-256 from the exact publication
transaction, rather than a newly inferred expected value:

```bash
python3 scripts/external-gui/acceptance.py run \
  --dmg "$VERIFIED_DMG" --dmg-sha256 "$PUBLICATION_DMG_SHA" \
  --source-sha "$GITHUB_SHA" --scale 1 --evidence "$RUNNER_TEMP/external-gui" \
  --test-runtime "$VERIFIED_TEST_INPUT" --test-producer-sha256 "$TEST_PRODUCER_SHA256"
python3 scripts/external-gui/acceptance.py validate \
  --evidence "$RUNNER_TEMP/external-gui" --source-sha "$GITHUB_SHA" --scale 1 \
  --dmg-sha256 "$PUBLICATION_DMG_SHA"
```

`validate` is read-only and can run in the Linux publication gate. With
`--dmg-sha256` it rejects app-artifact evidence and every other DMG. A publication
caller must pass this argument and require the originating GUI job to succeed.
No intermediate release is needed.

The optional `test_bundle_run_id` selects the original `external-gui-tests` artifact
from a completed same-source workflow run, including a run whose later journey failed.
Its actual build job must have succeeded. Omitting it builds one bundle before the
scale matrix. Further scales and failed journey retries can reuse that producer without
rebuilding either the app or successful test products. CI-batch externalgui followups
and the release caller expose the same input; release DMG identity remains independent.

The Linux binding job requires the original GitHub repository, workflow, source,
run/attempt/job identity, successful build, unexpired artifact ID and API digest. It
downloads the exact ZIP bytes and accepts only `tests.tar.gz` and `tests-input.json`.
The receipt binds every test input, the full product tree and archive, requested arm64
and macOS-26.0 build settings, and build Xcode version. Runtime verifies the Linux job's
hash-bound original producer records and product bytes without repeating the API query. It safely
extracts regular files and internal symlinks, preserves modes, and resolves XCTest's
`__TESTROOT__`/`__TESTHOST__` paths without rewriting the built products. File and directory
modes are bound; symlinks bind their target, since their mode is platform-dependent. The complete
test-input archive and original producer records remain in the journey evidence.

Runtime records and checks macOS 26 or later, arm64, the self-hosted runner and its name,
the OS build, the console user,
the Aqua bootstrap session, existing developer authorization and a captured PNG from
screencapture. Its actual visual content still needs independent assessment. It never
changes TCC, the host, runner configuration or quarantine.
The actual XCTest launch and ordinary app interactions remain the permission gate;
unavailable authorization fails with original logs instead of creating a substitute pass.
The read-only validator independently requires these runtime and bundle records.
It also binds the app's source and mode, the requested interface scale, and the
visible export's movie hash. App-artifact validation requires the original
`workspace-ui-input.json` copied to the evidence directory as `runtime-input.json`;
its source and app-tree hash must match the installed-app identity.

Use a fresh job VM: the script refuses to overwrite an existing
`/Applications/NexGenVideo.app` or reuse a configuration. The evidence directory
must not exist before the call. XCTest terminates its app, with bounded cleanup
of the uniquely installed executable after a runner timeout. The installed
bundle and test files remain in the disposable VM. No host changes, services,
personal accounts or provider keys are involved.

Always upload the entire evidence directory, including on failure. It contains
input/app/test identity, observed stage/action records, screenshots and AX trees,
exact saved project snapshots, XCTest logs/summary/`.xcresult`, the exported
movie, ffprobe output, and decoded source/output frames. All immutable source
and resulting binary identities remain distinguishable.

## Scope and limits

This initial external journey covers generic editing and is additional to the
existing native fixture acceptance. All external journeys execute on macrunner and record the actual OS version.
Their deployment target remains macOS 26. `--scale` accepts `1`, `1.25` or `1.5`; one run establishes
only its chosen scale. The initial integration may intentionally select `1`.

It does not prove the full production workflow, live generation or provider
availability. The checked-in engine fixtures are not complete normally openable
`.ngv` projects, so this test does not invent production-screen evidence from
them. The actual external Accessibility reachability and first execution time
remain unverified until the independently reviewed CI batch runs.

[Apple TN2339](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)
documents separate build-for-testing and test-without-building, with the bundles at
the paths declared by the xctestrun. Runtime compatibility remains pending until the real
journey produces exactly one passing test and zero failures or skips. Both Xcode
versions are retained. [Apple's release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-11_4-release-notes)
describe skipping incompatible deployment targets, so exit zero alone never qualifies.
The job's recorded macrunner environment is the platform reference; image preparation
is not runtime evidence.
