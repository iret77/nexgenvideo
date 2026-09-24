# NexGenVideo — research and desktop-workbench decisions

Research date: 2026-09-17. Native source reviewed at `8bd8fbde5cdb9a2a46b26c2441aa5035c885d1e0`. Read-only inspection of native sources and upstream patches; no native build, app launch, merge or implementation. The proposed visible contract and clickdummy are in `../desktop-production-workbench.html`.

## What the actual interfaces show

**Final Cut Pro 12.3.** Apple's release notes identify version 12.3, released June 30, 2026. Inspected both the main-window illustration in the current 12.3 guide and the contemporary Transcript Search screenshot on the product page. Library/browser, media viewer, optional inspector and timeline are spatially persistent. The current Transcript Search example puts AI-assisted retrieval into a familiar asset-selection/filter task; it does not replace the editor with a conversation. The useful observation is the continuity of selection, work surface and commands, rather than a particular shade of gray.

Sources: [release notes](https://support.apple.com/en-us/102825), [window arrangement guide](https://support.apple.com/en-ae/guide/final-cut-pro/ver2a27194eb/mac), [current product page](https://www.apple.com/final-cut-pro/), [Transcript Search image](https://www.apple.com/v/final-cut-pro/w/images/overview/video_editing/transcript__f3q7j6y3aree_large.jpg).

**DaVinci Resolve 21.** Inspected the official Edit-page screenshot: bins and media at left, source/program viewers in the middle, dense but aligned parameter groups at right, a substantial timeline below, task-specific pages at the bottom. Boundaries divide continuous surfaces; headings and controls do not compete with footage. The Cut/Edit distinction demonstrates specialization within one project. NGV benefits from that principle; copying Resolve's complete page count, dual viewers and NLE timeline into preproduction would waste space again.

Sources: [Resolve 21 overview and pages](https://www.blackmagicdesign.com/products/davinciresolve), [official Edit screenshot](https://images.blackmagicdesign.com/images/products/davinciresolve/overview/onesolution/carousel/edit.jpg?_v=1776043037).

**Newcomer: LTX Desktop, with LTX Studio as context.** The official Desktop page currently advertises beta v1.2.7 and a connected generation/editor workflow. The actual repository screenshot was inspected, not just the stylized marketing hero: asset browser at left, source/timeline viewers, conventional tracks, clear Gen Space versus Video Editor. The documented ability to keep multiple takes within a clip and revise only a selected portion is particularly relevant. The repository showed approximately 2,000 stars and 426 forks during research. This establishes visible community interest; it is not a measured growth rate or proof of widespread professional adoption. It is a useful emerging comparator, not a mature product we should copy wholesale.

Sources: [LTX Desktop](https://ltx.io/ltx-desktop), [official repository](https://github.com/Lightricks/LTX-Desktop), [actual editor screenshot](https://github.com/Lightricks/LTX-Desktop/blob/main/images/video-editor.png), [LTX Studio's connected project, Elements and Retake workflow](https://ltx.io/blog/ltx-studio-tutorial).

**Consequence for NGV:** Desktop value comes from sustained work with project objects, simultaneous context, direct selection, resizable panels, keyboard operations, reversible edits and versions. A dark page with buttons remains a web form if each phase replaces the work environment. The new dummy therefore retains its browser/main/inspector containers and places phase-specific work inside them. AI is a scoped command or review result; pipeline state remains visible and deterministic.

## What can be reused now

- `Editor/EditorView.swift`: native split-view infrastructure, persistent panel dimensions and existing Produce/Edit/Finish composition. The proposed German label “Produktion” maps to the existing Produce workspace; preproduction and take generation are activities inside it.
- `Inspector/InspectorView.swift`: actual selected-object routing, entity/shot/asset identity and existing contextual actions. Refactor the controls and move production documents into the work surface; do not introduce another global object-selection store.
- `UI/AppTheme.swift`, `UI/PackAccent.swift`: existing styling and trusted pack palette. The mock uses derived contrasting fills for pack identity and primary actions, with neutral borders and focus. Native implementation must use AppTheme tokens.
- `Inspector/Cockpit/PackSurface/AnalysisPanelView.swift` and `PackSurfacePrimitives.swift`: measured values, proportional song sections, beat/downbeat visualization and section/segment/phrase hierarchy. The example retains these; there is no invented energy curve masquerading as native measurement.
- `StoryCausalityPlanV1`, `StoryboardCausalityV1`, `SpatialProductionPlanV1` / state ladder: existing world chronology, cause/effect links, input/output states and reference bindings. Sanity and frame-audit acceptance provide further checks. The integrated review is a targeted connection and extension of these capabilities.
- Existing canonical writers, exact-byte lineage, readiness gates, one-phase job execution and batch authorization remain the execution boundary. GUI controls must never own competing production truth.

See the fuller [source compatibility audit](code-compatibility-2026-09-17.md). Inspecting a schema is not evidence that semantic image/continuity checking is complete, and this source review is not native runtime verification.

## Upstream: concrete transferable patches

The actual diffs were read, including the two additional inspector commits below. NGV issues #506–#509 were checked live and remain open.

| NGV scope | Upstream | Transfer | Boundary |
|---|---|---|---|
| [#506](https://github.com/iret77/nexgenvideo/issues/506) | [89ce887e / #548](https://github.com/<upstream repository>/commit/89ce887e90b4432f3953265ba2b0cc7b710cece5) | Continuous chrome, panel divider drawing, aligned toolbars | Preserve native NGV workspaces, focus, pack identity; do not take unrelated timeline/view-model changes |
| [#507](https://github.com/iret77/nexgenvideo/issues/507) | [cfe9c18f / #327](https://github.com/<upstream repository>/commit/cfe9c18fce6083cedf5d0ee6f8f910b5fe5560f7), [3026f72e / #567](https://github.com/<upstream repository>/commit/3026f72ed2924c2e6f876ab34ed6854b744407f9) | Collapsible groups, consistent label axis, reusable value controls | NGV typography/control sizes; neutral focus instead of upstream accent borders; preserve keyboard focus |
| [#508](https://github.com/iret77/nexgenvideo/issues/508) | [6aafb867 / #491](https://github.com/<upstream repository>/commit/6aafb867c9df597dedae6535da7ad28f45283387), [49841f35 / #570](https://github.com/<upstream repository>/commit/49841f35b3eafa65c7eadc7b168bcc74db632906) | Asset identity, executable actions and model/cost provenance | #491 still uses AccountService; #570 stores Palmier costCredits. Reuse presentation, use NGV provider/cost truth and preserve pack ABI |

The live upstream history also includes `eba39db7` (“Retire public source development”). Consequently these are pinned, inspectable historical patches, not a promise of an ongoing public upstream UI roadmap. No patch was applied to Swift sources.

## Where bounded new work is genuinely needed

1. **Structured interaction surface:** expose current runner, intake, review and recovery capabilities with scope-specific controls before retiring free chat. A visual shell alone is insufficient.
2. **Script and planning lifecycle:** the current locked harness has no independent script phase. Its canonical Shot List requires real reference bindings. A lightweight scene artifact and a distinct draft planning state before final executable inputs require an explicit contract decision. The clickdummy makes the desired UX testable; it does not silently change the runtime order.
3. **References workspace:** identities and shot anchors can share a browser, but native Bible and Frames retain their distinct ownership, provenance and gates.
4. **Integrated Pre-Render Review [#533](https://github.com/iret77/nexgenvideo/issues/533):** connect existing treatment chronology, storyboard bindings, shot states, reference versions and audits. Add comprehensible findings and explicit correction/rewind. Typed semantic coverage and ambiguous chronology require focused design; there is no basis to claim a finished universal continuity checker.
5. **FilmFlow snapshot adoption:** explicit acceptance, stable shot IDs, local copies of media and imported lineage. Earlier work is covered by the import, not fabricated or automatically marked as generated. The simulation creates a generic project; active pack prerequisites cannot be bypassed in native implementation.

## What the clickdummy exercises

Stable panels and neutral separators; adjustable browser/inspector widths; focus mode; contextual inspector groups; same-shot storyboard/plan/animatic timing; selection, multi-selection, arrow keys and Undo; camera/blocking axis checks; distinct sketch/render comparison; story-world continuity example and explicit corrective revision; approved input/cost gates; cancellation/resume and deliberate take selection; separate edit ordering/trims; source clips without generation charges; old takes isolated after a plan revision; generic and music-pack entry; FilmFlow snapshots at three completion levels; simulated Finish/export.

The figures and render results are fixtures. No video/audio is synthesized or played, no true image audit occurs, and no file is exported. Animatic playback is a silent sequence of actual included sketch images driven by shared durations.

Browser verification uses a local file URL and a headless browser, not the NGV app or a dev server. Results are recorded in [desktop-workbench-checks.json](desktop-workbench-checks.json) and [desktop-workbench-layouts.json](desktop-workbench-layouts.json). Native builds/tests remain exclusively in GitHub Actions.

## Follow-up: direct panel controls and compact chrome

The current [FCP window arrangement guide](https://support.apple.com/en-ca/guide/final-cut-pro/ver2a27194eb/mac) explicitly documents direct Browser and Inspector toolbar buttons. Its illustrated buttons use small panel glyphs. Resolve's official Edit screenshot places direct panel commands in the chrome; LTX's actual editor uses compact asset controls, but is not evidence for exactly the same two-button convention.

Applied to NGV: two neutral mirrored panel icons, one independent visibility state per side, accessible while closed. No View dropdown or coupled focus mode. Project-title menu, undo, workspace switch and pack badge fit in the same titlebar; the redundant global toolbar row is removed. At desktop widths this restores about 40 px to the working surface. A narrow embedded preview wraps the titlebar rather than hiding essential actions; native NGV remains a desktop design.
