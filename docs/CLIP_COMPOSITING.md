# Per-clip compositing

The host owns the version-one set of 16 blend modes in `ClipBlendMode`. Both inspector
selections and `set_clip_properties` use `EditorViewModel.setClipBlendMode`. The command
validates every target before mutation, rejects audio, does not expand linked partners,
and records one undo group. Existing opacity animation is preserved.

`Clip.compositing` is an optional host-only `ClipCompositingV1` carrier containing
`version` and the raw `blendMode` string. Missing settings mean Normal. Unknown strings
or versions render as Normal and retain their carrier when saved or undone. The inspector
labels this fallback explicitly; selecting a supported mode replaces it. Normal needs no
carrier. Agent input is stricter than project decoding: its schema and decoder accept only
the supported enum, and `get_timeline` reports both the effective mode and stored carrier.

## Pack ABI

`Clip`, `Timeline`, `LayerPlan`, and the new carrier belong to the `NexGenVideo` executable
target and are internal types. Packs link only `NexGenEngine`, as declared in `Package.swift`.
No engine type, public value layout, registry property, protocol, compatibility floor,
pack version, or pinned project binding changes. The carrier stays in the existing timeline
JSON inside the project package and Recovery workflow; no storage-contract deviation is needed.

## Rendering contract

Every visible layer follows source → crop → effects/matte → transform → blend → opacity/fade.
Layer order follows timeline tracks, bottom to top. Text on the same track composites after
that track's media. Core Image works in the existing unmanaged compositor color space.
The blend result is faded toward the existing backdrop; clip opacity never changes the
input color of a nonlinear blend. Pixels outside a placed/cropped layer preserve the backdrop.

Text rasterizes lazily into a bounded cache of immutable images, retaining typography,
fill, border, and shadow. Text then receives the same transform, crop, effects, blend,
opacity keyframes and fades as other visual clips. Text is not added as a second display
overlay or export animation tool. Preview, frame capture, agent inspection, final renders,
and encoded exports all consume the shared `CompositionBuilder`/`FrameRenderer` path.
Interchange XML remains the existing source-edit interchange format, not a rendered delivery.

## Verification

`ClipBlendReferenceTests` asserts independent numeric color references for every supported
mode, fractional alpha/opacity, preserved backdrop extents, and chroma-key mattes.
`ClipBlendPipelineTests` exercises actual image/video sources, alpha media, text glyphs,
text crop/keyframes/fades/order, normal fallback, and preview/final/encoded-export pixels.
Model and agent suites cover old-project defaults, unknown-value round trips, undo/redo,
split/duplicate/copy, atomic validation, linked audio, and the closed tool schema.
Builds and tests run only in GitHub Actions.
