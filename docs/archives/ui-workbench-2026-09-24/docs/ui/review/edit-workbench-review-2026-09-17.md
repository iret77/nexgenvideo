# Edit workspace — code comparison and UI/UX self-review

Reviewed before presentation. Scope: restore the existing editor's structure and core editing interactions in the clickdummy. No Swift changes, app build, native test or launch.

## Native foundation

| Source | Native behavior retained as the foundation |
| --- | --- |
| `Sources/NexGenVideo/Editor/EditorView.swift:348` | Default Edit layout: Media, Preview and Inspector above a separate full-width timeline; adjustable splits. The previous mock incorrectly confined its miniature timeline to the center column. |
| `Sources/NexGenVideo/Toolbar/ToolbarView.swift` | Pointer, razor, split at playhead, start/end trims, text insertion and timeline zoom. Undo/redo remain available. The mock keeps Undo in the shared titlebar and command shortcuts. |
| `Sources/NexGenVideo/Timeline/TimelineContainerView.swift` | Independently scrolling timeline and fixed track-header column. The mock restores this spatial relationship. |
| `Sources/NexGenVideo/Timeline/TimelineHeaderView.swift` | Track labels, video visibility, audio mute and sync-lock. Visibility/mute are simulated; sync-lock is visibly disabled with its limitation in the tooltip. |
| `Sources/NexGenVideo/Preview/PreviewContainerView.swift` | Timeline/source tabs, separate source transport, frame stepping, playback and timecodes. The mock preserves independent source and sequence cursors. |
| `Sources/NexGenVideo/Inspector/InspectorView.swift:727` | Selection-based Video / Adjust / Audio / AI Edit tabs; transform and playback parameters. The mock shows these without imposing a production-step form on editing. |
| `Sources/NexGenVideo/Editor/ViewModel/EditorViewModel+Ripple.swift:26` | Ordinary trims resize the clip in place; adjacent clips and other tracks do not ripple. This distinction is implemented in the mock: trims can leave a visible gap. |
| `Sources/NexGenVideo/Editor/ViewModel/EditorViewModel+ClipMutations.swift:562` | Split/trim at playhead apply to selected clips. Mock action readiness follows the selected clip and playhead, not an arbitrary clip under the cursor. |

## Review findings fixed

- Replaced the center-only miniature timeline with a full-width, height-adjustable timeline below all three upper panels. Video filmstrips, a text lane and illustrative audio waveform share the same ruler and playhead.
- Removed the large production-approval strip from Edit. The mock's workflow completion action stays compact in the footer; it is not a proposal for a new native editing gate.
- Fixed viewer aspect distortion: the picture fits both available dimensions at 16:9, including after timeline resizing.
- Restored compact inspector label/value rows; controls do not consume one whole row for the label and another for the input.
- Fixed selection rerenders dropping keyboard focus. Physical clip selection followed by Ctrl+K now reaches the selected clip.
- Fixed frame updates recreating the transport buttons, which made keyboard pause timing-dependent. Playback updates picture/timecode in place and retains the same focused button.
- Fixed split/trim readiness becoming stale after scrubbing. The toolbar updates from one shared selection/playhead predicate.
- Source playback leaves timeline position and approved take selection unchanged. Editing modifies timeline clip instances; planned Shot IDs, durations, sketches and production data remain intact.

## Evidence

The browser interaction suite covers split, trims, gaps, Undo, source isolation, transforms, track states, playback, text and reordering, alongside prior production workflows. Physical mouse/keyboard checks cover clip selection, Ctrl+K, Undo, edge dragging, timeline divider dragging and Space to pause. `edit-workbench-checks.json` records these and five width/aspect/full-width checks. The main reports remain `desktop-workbench-checks.json` and `desktop-workbench-layouts.json`.

Visually inspected the actual supplied preview and the rendered final editor at 1024 and 736 px, plus measured 1440/500/320 px layouts. Reviewed spatial hierarchy, timeline dominance, image proportions, icon states, inspector density and continuity with the existing NGV layout. This is a self-review, not a claim of an independent agent review.

## Prototype boundaries — not removal instructions

The mock uses reference-derived stills as video placeholders and an explicitly illustrative waveform. It does not decode video, play audio, execute providers, or export media. Clip dragging demonstrates insertion/reordering in the example montage, not NGV's complete free-placement/overwrite/ripple matrix. The demo supports one selected clip and a small text example; it is not a replacement timeline engine.

Native multi-selection, additional tracks, linking/sync-lock, snapping, clipboard and range operations, keyframes, crop, full color/effect tools, captions, media folders/search, frame capture and provider-bound AI Edit actions remain product capabilities. Their incomplete simulation here never authorizes removal. Native AI Edit already offers Upscale, Edit, Rerun and AI Audio; the mock's AI Edit tab only exposes the source/take relationship and explains its unconnected status. Native implementation must reuse those existing modules.
