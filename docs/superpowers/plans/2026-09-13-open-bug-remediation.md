# Open Bug Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct all ten open bug issues in one compatibility-safe release batch.

**Architecture:** Shared boundary types reject invalid input and project typed host truth into Agent and SwiftUI surfaces. Media/window fixes stay in internal app code; pipeline provenance is additive and phase-owned so public pack-boundary layouts remain unchanged.

**Tech Stack:** Swift 6.2, Swift Testing, SwiftUI, AppKit, AVFoundation, Foundation XML/XMEML, NexGenEngine, MusicvideoPlugin.

**Spec:** `docs/superpowers/specs/2026-09-13-open-bug-remediation.md`

## Global Constraints

- Support only macOS 26 and arm64.
- Never build, test, or launch locally; GitHub Actions on `xcode-27` is the only build/test surface.
- Never dispatch Actions, push, merge, or release without separate authorization; release dispatch requires the exact in-the-moment phrase “build now”.
- All visible UI values use `AppTheme`; no hardcoded spacing, font size/weight, radius, border width, opacity, icon size, shadow, color, or animation duration.
- New stored properties go only at the end of `EngineRegistry`; existing public pack-boundary value types receive no stored properties.
- Preserve exact pack pinning and side-by-side versions. Project-schema change uses a declared transactional Recovery-copy migration.
- Keep comments minimal and explain only non-obvious reasons.
- Tests assert independent observable behavior, not source text or mocks.
- Because local test execution is forbidden, every red/green run step is recorded as deferred to GitHub Actions rather than claimed as executed.

---

### Task 1: Exact numeric Agent and MCP boundary (#510)

**Files:**
- Modify: `Sources/NexGenVideo/Agent/Tools/ToolExecutor.swift`
- Modify: `Sources/NexGenVideo/Agent/Tools/ToolExecutor+Clips.swift`
- Modify: `Sources/NexGenVideo/Agent/Tools/ToolExecutor+Words.swift`
- Modify: `Sources/NexGenVideo/Agent/Tools/ToolExecutor+GenerationBatch.swift`
- Modify: `Sources/NexGenVideo/Agent/Tools/ToolExecutor+Generate.swift`
- Modify: `Sources/NexGenVideo/Agent/Tools/ToolExecutor+PipelineArtifacts.swift`
- Modify: `Sources/NexGenVideo/Agent/Dialogs/AgentDialog.swift`
- Modify: `Sources/NexGenVideo/Agent/Pipeline/NativeBlockoutExporter.swift`
- Modify: `Sources/NexGenVideo/Agent/Pipeline/PipelineArtifactWriteContract.swift`
- Modify: `Sources/NexGenVideo/Generation/Providers/MCPGenerationArguments.swift`
- Modify: `Sources/NexGenVideo/Agent/Tools/ToolDefinitions.swift`
- Test: `Tests/NexGenVideoTests/Agent/ToolExecutorTests.swift`
- Test: `Tests/NexGenVideoTests/Generation/MCPGenerationArgumentsTests.swift`
- Test: `Tests/NexGenVideoTests/Agent/MCPHTTPServerTests.swift`
- Test: `Tests/NexGenVideoTests/Agent/NativeBlockoutExporterTests.swift`
- Test: `Tests/NexGenVideoTests/Agent/PipelineAgentContractTests.swift`

**Interfaces:**
- Produces: `ToolIntegerDecoder.exact(_:tool:path:) throws -> Int` and path-aware required/optional argument access used by all manual numeric sinks.
- Consumes: existing JSON-schema validation and `ToolResult` error projection.

- [ ] **Step 1: Author boundary regression tests before production edits**

Add table-driven tests that send `Double.nan`, both infinities, `1.5`, `"12"`, `1e19`, and `-1e19` through the real `get_timeline.startFrame` dispatch and require an error containing `get_timeline.startFrame`. Add real mutation tests proving huge clip, track, keyframe, ripple, speed-derived duration, word range, nested batch duration, and pipeline blockout inputs leave prior state unchanged.

- [ ] **Step 2: Record the red gate as deferred**

Do not run Swift locally. In the task report, name each test and the current trapping/lossy production branch it is expected to catch.

- [ ] **Step 3: Implement exact conversion at the common boundary**

Add one throwing decoder that accepts Swift integer values and finite JSON numbers only when `Int(exactly:)` succeeds and the numeric value is integral. Validate integer schema fields with it before minimum/maximum checks. Model the integer-or-array word schema with `anyOf`, preserve full nested field paths, and replace all manual `Int(Double)`, `NSNumber.intValue`, and silent default conversions identified in the task files.

- [ ] **Step 4: Bound derived work before mutation**

Validate subtraction, multiplication, frame-loop counts, speed-derived duration, and word spans before undo groups, iterations, package creation, or writers. Intersect valid word ranges without iterating attacker-sized ranges. Reject unsafe values instead of clamping them.

- [ ] **Step 5: Harden provider-side numeric constraints**

Make `MCPGenerationArguments` reject numeric strings, fractions, non-finite numbers, and overflowing `minItems`/`maxItems` with the same exact-conversion semantics.

- [ ] **Step 6: Review and commit**

Inspect the diff for every remaining unsafe numeric conversion under Agent and provider argument paths with `rg`, record tests as not executed by policy, verify the branch, and commit `fix: validate agent numeric arguments exactly`.

### Task 2: Durable XML export truth (#511)

**Files:**
- Modify: `Sources/NexGenVideo/Export/XMLExporter.swift`
- Modify: `Sources/NexGenVideo/Export/ExportService.swift`
- Modify: `Sources/NexGenVideo/Agent/Tools/ToolExecutor+Export.swift`
- Test: `Tests/NexGenVideoTests/Export/XMLExporterTests.swift`
- Test: `Tests/NexGenVideoTests/Export/ExportServiceRoundTripTests.swift`
- Test: `Tests/NexGenVideoTests/Agent/ToolExecutorTests.swift`

**Interfaces:**
- Produces: throwing `XMLExporter.export(..., to:) throws` with atomic destination replacement and a typed internal write error.
- Consumes: existing export progress/error state and agent export destination policy.

- [ ] **Step 1: Author failure and retry tests**

Test a nonexistent parent, a failed overwrite preserving old bytes, service progress remaining below completion with safe retry copy, agent `isError` containing `export_project` plus the filename, and a successful readable `<xmeml>` output.

- [ ] **Step 2: Record the red gate as deferred**

Do not execute locally; document that current `try?` makes the failure tests observe false success.

- [ ] **Step 3: Implement atomic throwing export**

Encode with `Data(xml.utf8)` and write atomically. Remove agent-side pre-deletion. Preserve `overwrite=false`; for overwrite success use atomic replacement. Surface safe user copy `Couldn’t write <filename>. Choose another location and try again.` and keep underlying errors in logs.

- [ ] **Step 4: Propagate truthful state**

Only set service progress to completion and agent status to `exported` after the write returns. Make direct helpers throwing so tests cannot hide failures.

- [ ] **Step 5: Review and commit**

Verify all XML exporter call sites handle `throws`, record tests as not executed by policy, verify the branch, and commit `fix: propagate XML export failures`.

### Task 3: Muted composition and transcription locale (#512, #514)

**Files:**
- Modify: `Sources/NexGenVideo/Preview/CompositionBuilder.swift`
- Modify: `Sources/NexGenVideo/Transcription/Transcription.swift`
- Test: `Tests/NexGenVideoTests/Export/CompositionBuilderTests.swift`
- Test: `Tests/NexGenVideoTests/Export/ExportServiceRoundTripTests.swift`
- Test: `Tests/NexGenVideoTests/Captions/TranscriptionLocaleTests.swift`

**Interfaces:**
- Produces: muted-track exclusion before URL resolution; `Transcription.baseLocale(for:) -> Locale?` used only by supported-locale matching.
- Consumes: existing composition builder shared by preview/export and actual `SpeechTranscriber.supportedLocales` values.

- [ ] **Step 1: Author muted-source tests**

Use a resolver that fails the test if called for an all-muted track. Assert no audio mappings, composition tracks, mixer inputs, offline entries, or exported audio stream. Add a mixed audible/muted case and preserve the existing clip-volume-zero behavior.

- [ ] **Step 2: Author locale tests**

Require `de-DE-u-rg-zazzzz` to match `de_DE`, plain `en-US` to remain exact, `sr-Latn-RS-u-ca-gregory` to prefer Latin Serbian over Cyrillic, language-only fallback to work, and invalid or `und` tags to return nil.

- [ ] **Step 3: Record the red gates as deferred**

Do not execute locally; identify unconditional audio resolution and extension-sensitive locale matching as the expected failures.

- [ ] **Step 4: Implement both minimal fixes**

Skip a muted track before `loadSource` while retaining visual-refresh muting for already-built items. Canonicalize transcription candidates to BCP-47, remove the canonical `-u-` suffix, reject missing/undetermined language, preserve script and region, and rank exact script+region, script, region, then same language. Return the supported locale object.

- [ ] **Step 5: Review and commit**

Confirm XMEML still serializes muted track structure and agent language code is untouched. Record tests as not executed by policy, verify the branch, and commit `fix: align mute and transcription semantics`.

### Task 4: Editor presentation lifecycle (#513)

**Files:**
- Modify: `Sources/NexGenVideo/App/AppState.swift`
- Modify: `Sources/NexGenVideo/Project/VideoProject.swift`
- Modify: `Sources/NexGenVideo/Editor/EditorWindowController.swift`
- Test: create `Tests/NexGenVideoTests/Project/ProjectWindowPresentationTests.swift`

**Interfaces:**
- Produces: `AppState.projectWindowDidBecomeKey(_:)`, `AppState.hideHomeIfEditorIsVisible()`, and a narrow `EditorWindowController` key-window callback.
- Consumes: existing pack/open validation, document registration, and project window-controller construction.

- [ ] **Step 1: Author serialized MainActor lifecycle tests**

Cover new/open success ordering, cancel, validation failure, rapid successive opens, key-window switches between two projects, closing/reopening Home, and notification-driven open. Assert Home hides only after the intended editor becomes key and `activeProject` follows the key document.

- [ ] **Step 2: Record the red gate as deferred**

Do not run locally; document the current early `showEditor` call during window-controller construction.

- [ ] **Step 3: Implement the narrow AppKit boundary**

Make `EditorWindowController` the `NSWindowDelegate` or forward through a dedicated delegate without creating a second state owner. Report `windowDidBecomeKey` to `AppState`; remove Home hiding from controller construction. Order new/open as validate, register, create/show, key event, then hide Home.

- [ ] **Step 4: Review and commit**

Audit every Home-hide call and every editor presentation route. Confirm no global long-lived `NSWindow` storage is added. Record tests as not executed by policy, verify the branch, and commit `fix: hide Home after editor activation`.

### Task 5: Decoded-frame waveform pipeline (#516)

**Files:**
- Create: `Sources/NexGenVideo/Timeline/WaveformExtractor.swift`
- Modify: `Sources/NexGenVideo/Timeline/MediaVisualCache.swift`
- Modify: `Sources/NexGenVideo/Timeline/ClipRenderer.swift`
- Modify: `Package.swift`
- Modify: `Package.resolved`
- Create: `Tests/NexGenVideoTests/Audio/WaveformExtractorTests.swift`

**Interfaces:**
- Produces: internal `WaveformEnvelopeV2` containing normalized samples, source start time, decoded duration, and sample period; `WaveformExtractor.extract(from:maxSamples:) async throws -> WaveformEnvelopeV2`.
- Consumes: AVAssetReader sample buffers and source-time mapping used by timeline trims.

- [ ] **Step 1: Author decoded-time tests**

Create small real PCM fixtures covering incorrect/indefinite/zero container duration, silence and loud tone normalization, partial final buffers, non-zero PTS, timestamp gaps, source trims, empty media, and a long-duration cap. Expected bins and time alignment are literal fixtures independent of extractor helpers.

- [ ] **Step 2: Record the red gate as deferred**

Do not execute locally; document the current metadata-duration multiplication and conversion trap/truncation paths.

- [ ] **Step 3: Implement bounded timestamp-aware extraction**

Decode mono Float32, aggregate approximately 200 bins per decoded second, carry partial windows across buffers, account for PTS gaps/overlaps, use a -50 dB silence floor, and compact adaptively so no envelope exceeds 240,000 samples. Never derive allocation or integer conversion from invalid container duration.

- [ ] **Step 4: Version and atomically persist the cache**

Store and load `WaveformEnvelopeV2`, bump the waveform cache namespace to `waveform2`, write atomically, keep decoding on the detached utility path under the existing semaphore, and publish only on MainActor. Map clip source-time trims through envelope timing metadata.

- [ ] **Step 5: Remove the superseded dependency**

Remove DSWaveformImage from package declarations and resolution only after all source imports are gone.

- [ ] **Step 6: Review and commit**

Audit allocation bounds, cancellation, cache determinism, and main-thread crossings. Record tests as not executed by policy, verify the branch, and commit `fix: derive waveforms from decoded audio`.

### Task 6: Typed generation pricing and recovery (#529)

**Files:**
- Modify: `Sources/NexGenVideo/Generation/GenerationBudgetGuard.swift`
- Modify: `Sources/NexGenVideo/Generation/GenerationPackageInputs.swift`
- Modify: `Sources/NexGenVideo/Generation/GenerationPackageV1.swift` only through compatible initialization/computed behavior; do not add stored fields to a public pack-boundary type
- Modify: `Sources/NexGenVideo/Generation/GenerationBatch.swift`
- Modify: `Sources/NexGenVideo/Generation/GenerationBatchCoordinator.swift`
- Modify: `Sources/NexGenVideo/Generation/GenerationBatchStore.swift`
- Modify: `Sources/NexGenVideo/Agent/Tools/ToolExecutor+GenerationBatch.swift`
- Modify: `Sources/NexGenVideo/Agent/AgentService.swift`
- Modify: `Sources/NexGenVideo/Generation/Providers/RunwayModelRegistry.swift`
- Test: `Tests/NexGenVideoTests/Generation/GenerationPackageTests.swift`
- Test: `Tests/NexGenVideoTests/Generation/GenerationBatchTests.swift`
- Test: `Tests/NexGenVideoTests/Generation/RunwayClientTests.swift`
- Test: `Tests/NexGenVideoTests/Agent/PipelineAgentContractTests.swift`
- Test: `Tests/NexGenVideoTests/Agent/ToolDefinitionContractTests.swift`

**Interfaces:**
- Produces: internal `GenerationPricingFailure` cases `unsupportedOption`, `providerPricingUnavailable`, and `exchangeRateUnavailable`; exact pricing input carries resolution/pixel and ordered reference-count facts; coordinator exposes retry-pricing and change-route transitions.
- Consumes: immutable generation package hashing, batch authorization journal, provider catalog, and hidden agent continuation.

- [ ] **Step 1: Author typed pricing tests**

Test Runway `gemini_image3_pro` at literal official credit values for 1K/2K and 4K, reference-sensitive options, unsupported current models, transport failure, and FX failure. Assert `prepareReviewPackage` preserves the typed reason instead of erasing it.

- [ ] **Step 2: Author recovery and authority tests**

Retry must quote the exact prior request, perform no generation/reservation/submission, produce a new immutable package/batch ID after a changed quote, and preserve ceilings. Change Route must decline the unexecutable pending manifest and resume a hidden structured agent turn that re-prepares selected items. Reconnects must not duplicate authority.

- [ ] **Step 3: Record the red gates as deferred**

Do not execute locally; name the current `try?` and incomplete Runway credit switch as expected failures.

- [ ] **Step 4: Implement typed quote readiness**

Replace optional-error erasure with typed readiness stored outside existing public pack-boundary layouts. Quote only when exact request inputs determine the official price. Keep unknown price a hard approval stop. Verify current Runway availability through its non-generating model-list endpoint when credentials exist; do not send a generation probe.

- [ ] **Step 5: Implement retry and route recovery**

Retry the quote and rebuild immutable package/batch hashes without generation. Change Route uses a schema-validated hidden host-authored continuation carrying item IDs and failure categories; it never renders as a user turn and never edits an approved manifest in place.

- [ ] **Step 6: Review and commit**

Audit money arithmetic, ceiling preservation, idempotency, and both Claude backends. Record tests as not executed by policy, verify the branch, and commit `fix: recover unpriced generation batches`.

### Task 7: Compact batch review UI (#530)

**Files:**
- Create: `docs/ui/generation-batches.html`
- Modify: `Sources/NexGenVideo/Agent/Panel/GenerationBatchCard.swift`
- Modify: `Sources/NexGenVideo/Agent/Panel/GenerationPackageReviewView.swift`
- Modify: `Sources/NexGenVideo/UI/AppTheme.swift` only if an absent reusable token is required
- Test: create or modify generation batch panel/UI policy tests under `Tests/NexGenVideoTests/Agent`

**Interfaces:**
- Produces: compact numbered row view with row-local expansion, preview strip, and pointer/keyboard Remove action; one body scroll and fixed in-flow summary/actions.
- Consumes: Task 6 pricing readiness/retry/route actions and existing generation-package display data.

- [ ] **Step 1: Author the normative HTML concept**

Put binding `#spec` text at the top and mock 1-item, 13-item, 50-item, unpriced, expanded-detail, and keyboard-focus states below it. Required controls remain visible without scrolling the action footer.

- [ ] **Step 2: Render and inspect the mock without building the app**

Use an available headless browser to capture the HTML. Inspect density, clipping, contrast, preview legibility, and all disabled states; revise the artifact before SwiftUI changes. This is not an app build.

- [ ] **Step 3: Author policy and handler tests**

Test 1/13/50 row ordering, stable numbering after removal, total recomputation, unpriced approval disablement, retry/route visibility, and the real remove handler transition from click/keyboard command to pending batch ID and owner session.

- [ ] **Step 4: Record the red gate as deferred**

Do not execute Swift tests locally; identify nested scrolling/full-card rendering as the expected structural failure.

- [ ] **Step 5: Implement the native surface**

Use one bounded scroll for compact rows. Hoist common provider/model metadata, retain per-item purpose/output/price, render thumbnails for image references, and expand technical details on demand. Keep total and actions as in-flow siblings outside the scroll. Use only `AppTheme` values and ensure disabled controls lose active contrast and hover response.

- [ ] **Step 6: Review and commit**

Compare SwiftUI structure against the HTML `#spec`, verify pointer/keyboard routing statically, record tests as not executed by policy, verify the branch, and commit `fix: compact generation batch review`.

### Task 8: Phase-owned provenance, recovery, and host-truth projection (#531, #532)

**Files:**
- Create: `Engine/Sources/NexGenEngine/Artifacts/DerivedIdentityAssetsV1.swift`
- Modify: `Engine/Sources/NexGenEngine/Artifacts/ConfirmedIdentityAssetsV1.swift`
- Modify: `Sources/NexGenVideo/Agent/Tools/ToolExecutor+Workflow.swift`
- Modify: `Sources/MusicvideoPlugin/PipelineLineage.swift`
- Modify: `Sources/MusicvideoPlugin/GateChecks.swift`
- Modify: `Engine/Sources/NexGenEngine/Pipeline/ProjectState.swift`
- Modify: `Sources/NexGenVideo/Agent/Pipeline/PipelineAgentHarness.swift`
- Modify: `Sources/NexGenVideo/Inspector/Cockpit/NativeCockpitReader.swift`
- Modify: `Sources/NexGenVideo/Inspector/Cockpit/PipelinePanelModel.swift`
- Modify: `Sources/NexGenVideo/Inspector/Cockpit/PipelinePanelView.swift`
- Modify: `Sources/NexGenVideo/Agent/Panel/AgentTranscriptProjection.swift`
- Modify: `Sources/NexGenVideo/Agent/Panel/GateApprovalCard.swift`
- Modify: `Sources/NexGenVideo/Agent/GateApproval.swift`
- Modify: `Sources/NexGenVideo/Agent/AgentService.swift`
- Modify: `Sources/NexGenVideo/Agent/Pipeline/PipelineRenderRecordWriter.swift`
- Modify: `Sources/NexGenVideo/Plugins/ProjectPackMigration.swift`
- Modify: `Sources/NexGenVideo/Project/ProjectWorkingCopy.swift`
- Modify: `Sources/MusicvideoPlugin/MusicvideoPack.swift`
- Modify: `plugins/musicvideo.json`
- Test: `Tests/NexGenVideoTests/Agent/WorkflowToolsTests.swift`
- Test: `Tests/NexGenVideoTests/Agent/HardStepIntakeTests.swift`
- Test: `Tests/NexGenEngineTests/GateGuardTests.swift`
- Test: `Tests/NexGenEngineTests/ProjectStateTests.swift`
- Test: `Tests/NexGenVideoTests/Agent/AgentTranscriptProjectionTests.swift`
- Test: `Tests/NexGenVideoTests/Agent/GateApprovalTests.swift`
- Test: `Tests/NexGenVideoTests/Agent/PipelineAgentContractTests.swift`
- Test: `Tests/NexGenVideoTests/Project/ProjectPackBindingTests.swift`
- Test: `Tests/NexGenVideoTests/Project/ProjectWorkingCopyTests.swift`

**Interfaces:**
- Produces: new additive `DerivedIdentityAssetV1`/store keyed by owning phase and destination, recording source import path/hash, destination path/hash, role, and timestamp-free deterministic metadata; new `PhaseApprovalValidity` values returned alongside the unchanged `ProjectStateBuilder.ProjectState` layout separate historical approval from current lineage; internal `HostOperationOutcome` distinguishes rejected, persisted-unvalidated, validated-awaiting-review, approved, and stale.
- Consumes: exact-byte cumulative lineage, canonical writer gates, existing pack migration hooks, hidden agent messages, and Task 6 generation readiness.

- [ ] **Step 1: Author provenance regression tests**

In a legal Bible/Production Design phase, copy a confirmed identity image and assert the import manifest bytes and upstream fingerprints remain byte-identical, the new phase sidecar contains exact source/destination hashes, and replacement/symlink escape fails. Separately assert Storyboard still rejects `copy_project_file`.

- [ ] **Step 2: Author approval-validity and recovery tests**

Create an affected legacy fixture whose import manifest contains derived aliases. Recovery-copy must verify equality, remove aliases from intake truth in the copy, create phase sidecars and a recovery receipt, preserve canonical artifact bytes, and offer one explicit reviewed rebind. Changed or missing bytes remain stale and cannot be rebound. Original projects and pinned old packs remain untouched.

- [ ] **Step 3: Author typed host-outcome tests**

Test writer rejection before persistence, persistence followed by structural-gate failure, valid artifact awaiting review, approval, later lineage staleness, and unpriced generation readiness. Assert transcript and pipeline cards use host state, do not project assistant claims as saved/ready, keep automatic follow-ups hidden, and expose raw paths/fingerprints only in diagnostic detail for both Claude backends.

- [ ] **Step 4: Record the red gates as deferred**

Do not execute locally; document import-manifest adoption, raw `gate.approved` projection, ignored tool-result blocks, and binary writer results as expected failures.

- [ ] **Step 5: Add phase-owned provenance without public layout changes**

Write derived aliases only to the owning phase sidecar after security and hash checks. Include sidecar bytes in downstream cumulative lineage. Stop calling `ConfirmedIdentityAssetStoreV1.adopt` for phase copies. Do not add stored fields to existing public structs or widen phase capabilities.

- [ ] **Step 6: Add transactional Recovery-copy migration**

Declare the new Music Video pack version and migration. On an explicit Recovery copy, verify old alias/source/destination equivalence, materialize sidecars and a deterministic receipt, compute old/new lineage, show a preview, and rebind only approvals whose canonical artifacts and proven inputs are unchanged. Preserve the original project and old pack version.

- [ ] **Step 7: Project typed host truth**

Introduce internal outcome/readiness types outside pack ABI. Canonical writers report persistence separately from structural validation. Add a separate `ProjectStateBuilder.approvalValidity(...) -> [String: PhaseApprovalValidity]` query without changing the stored layout of `PhaseStatus` or `ProjectState`; consume it in cockpit, pipeline UI, gate cards, transcript activity, and agent tool results. User copy is concise and localized; diagnostic detail is expandable and agent-facing errors name tools/artifacts.

- [ ] **Step 8: Bump pack metadata and commit**

Update Music Video pack source and `plugins/musicvideo.json` from 0.5.8 to 0.5.9, raise `projectSchema` from `musicvideo/2.0.0` to `musicvideo/2.1.0`, add `musicvideo/2.0.0` to `migratesFrom`, and raise `minAppVersion` from 1.5.8 to 1.5.9 in the same commit. Record tests as not executed by policy, verify the branch, and commit `fix: separate pipeline provenance from host truth`.

### Task 9: Batch integration, release metadata, and static verification

**Files:**
- Modify: `Sources/NexGenVideo/Resources/Changelog/changelog.json`
- Modify: any compile-only call sites revealed by static inspection
- Test: all changed test files from Tasks 1–8

**Interfaces:**
- Consumes: all prior task interfaces.
- Produces: one coherent 1.5.9 changelog entry and an implementation ready for authorized GitHub Actions verification.

- [ ] **Step 1: Add release metadata**

Add a dated 1.5.9 changelog entry summarizing truthful agent/gate state, generation-batch recovery, pipeline provenance recovery, export/audio reliability, editor presentation, locale handling, and decoded waveforms. Do not dispatch or publish a release.

- [ ] **Step 2: Run source-only consistency checks**

Use `rg`, JSON parsing tools, `git diff --check`, and repository-provided non-build spec/static scripts only when they do not compile, test, launch, or dispatch. Confirm AppTheme use, pack version lockstep, no new stored fields in existing pack-boundary public types, and no Storyboard capability widening.

- [ ] **Step 3: Prepare independent review evidence**

Generate a whole-branch diff package against the recorded origin/main base. Review every observable requirement independently and label runtime/build/test criteria unverified pending Actions.

- [ ] **Step 4: Review and commit**

Verify the branch immediately before commit and commit `docs: record open bug remediation` if metadata/static fixes are not already folded into the behavior commits. Do not push, dispatch, merge, or release.
