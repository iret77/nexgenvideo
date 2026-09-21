# Per-clip compositing

The host owns the version-one set of 16 blend modes in `ClipBlendMode`. Both inspector
selections and `set_clip_properties` use `EditorViewModel.setClipBlendMode`. The command
validates every target before mutation, rejects every nonvisual target, does not expand
linked partners, and joins the caller's undo group or records its own. Existing opacity
animation is preserved.

`Clip.compositing` is an optional host-only `ClipCompositingV1` carrier containing
an opaque JSON value. Version one recognizes `version` and `blendMode`; all fields and
nested values survive save and undo until explicit editing. Missing settings mean Normal.
Unknown modes or versions render as Normal. The inspector
labels this fallback explicitly; selecting a supported mode replaces it. Normal needs no
carrier. Agent input is stricter than project decoding: its schema and decoder accept only
the supported enum. `get_timeline` omits default Normal and nonvisual blend settings;
unsupported visual settings report `blendMode: normal` and `blendModeUnsupported: true`
without duplicating the opaque carrier. `blendModeContract` lists supported modes.

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

Text prepares immutable raster sources once per composition, retaining typography,
fill, border, and shadow. Instructions eagerly retain at most 64 MB of small rasters per
build, with a 1 MB per-image cap. Eager materialization does not also populate the tile
cache. Larger text boxes and canvases remain demand-tiled:
Core Image requests only source regions needed by the visible canvas, including animated
transforms and effect margins. Provider bitmaps are at most 512 × 512 RGBA pixels and
use a shared 64 MB tile cache without per-frame JSON encoding. Their virtual extent is
not a bitmap allocation and is never clipped to the clip's initial placement.
CATextLayer draws glyphs directly into clipped contexts without allocating a full-size
backing store. Source alpha supplies the shadow before the shared compositing stages.
Rasterization disables Core Animation actions and preserves top-left glyph/shadow coordinates.
Text then receives the same transform, crop, effects, blend,
opacity keyframes and fades as other visual clips. Text is not added as a second display
overlay or export animation tool. Preview, frame capture, agent inspection, final renders,
and encoded exports all consume the shared `CompositionBuilder`/`FrameRenderer` path.
Interchange XML remains the existing source-edit interchange format, not a rendered delivery.

## Verification

`ClipBlendReferenceTests` asserts independent numeric color references for every supported
mode, fractional alpha/opacity, preserved backdrop extents, and chroma-key mattes.
`ClipBlendPipelineTests` exercises actual image/video sources, alpha media, text glyphs,
text crop/keyframes/fades/order, normal fallback, and preview/final/encoded-export pixels.
`TextRasterizerTests` compares styled glyphs against small Core Animation reference
images and verifies oversized/animated sources and large canvases stay demand-tiled.
Model and agent suites cover old-project defaults, unknown-value round trips, undo/redo,
split/duplicate/copy, atomic validation, linked audio, and the closed tool schema.
Builds and tests run only in GitHub Actions.
