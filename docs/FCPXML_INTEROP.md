# FCPXML interoperability

NexGenVideo exports a deliberately bounded, version-pinned FCPXML feature set for handoff to Final
Cut Pro and DaVinci Resolve. Every document is validated against Apple's complete DTD for its
declared version. This does not claim that NexGenVideo emits every construct those DTDs permit.

## Versions and targets

The default is FCPXML 1.10 for the broadest supported interchange profile. Versions 1.10 through
1.14 use the same deliberately bounded feature set; the selected version is written on the root and
validated against the matching `apple/fcpxml-dtd/<version>` profile. The Apple DTD resources are
integrity-checked before use, so a missing or modified schema fails the export closed.
Select the target independently as Final Cut Pro or DaVinci Resolve. Resolve-specific transform and
crop units are emitted when Resolve is selected.

| Feature | 1.10 | 1.11 | 1.12 | 1.13 | 1.14 | Rule |
| --- | --- | --- | --- | --- | --- | --- |
| Video | Export | Export | Export | Export | Export | Placement, source range, retime, opacity, crop, and transform |
| Audio | Export + warning | Export + warning | Export + warning | Export + warning | Export + warning | Placement and static gain export; fades, automation, roles, and channel layout warn |
| Captions | Export + warning | Export + warning | Export + warning | Export + warning | Export + warning | Editable Basic Titles; caption-role semantics warn |
| Transform keyframes | Export + warning | Export + warning | Export + warning | Export + warning | Export + warning | Position, scale, rotation, and opacity export; non-linear easing warns |
| Source timecode | Export | Export | Export | Export | Export | Exact rational origin and explicit DF/NDF |
| NexGenVideo effects | Warning only | Warning only | Warning only | Warning only | Warning only | No stable cross-editor effect identity |
| Color metadata | Warning only | Warning only | Warning only | Warning only | Warning only | Target editor discovers source color metadata |
| Lottie | Warning only | Warning only | Warning only | Warning only | Warning only | Render to video before interchange |

Offline media and document clips are omitted with per-clip warnings. Text backgrounds, text
shadows, rectangular text borders, partial title transforms, animated crop, and animated gain also
produce explicit warnings. A NexGenVideo caption-box border is not exported as a glyph stroke.
No unsupported timeline feature is silently represented as if it survived the handoff.

## Timing and source timecode

All FCPXML times and container durations are reduced rational seconds. NTSC source rates use exact `1001/24000`,
`1001/30000`, or `1001/60000` frame durations, never rounded decimal rates. Source in/out includes
the exact source origin and trim; retimes keep an exact rational time map. Apple defines
[`start` as the beginning of an element's local timeline](https://developer.apple.com/documentation/professional-video-applications/timing-attributes),
so keyframes include that local start for direct and compound media while title keyframes remain
zero-based. Drop-frame changes the
timecode numbering convention, not elapsed time. Other fractional rates remain exact (for example,
29.5 fps is `2/59s`); their FCP format name stays undefined and the export reports a
`nonstandard_source_rate` warning instead of coercing them to a nearby NTSC rate.

Source timecode priority is:

1. A regular container timecode track exposed by AVFoundation.
2. Sony `rtmd` in ISO BMFF/MOV metadata, including the Sony 29.97/59.94 clear-flag drop-frame
   convention.
3. Broadcast Wave `bext.TimeReference`, including RIFF and RF64.

Malformed, out-of-range, or arithmetically unrepresentable metadata is rejected instead of being
coerced. If no source timecode is usable, the asset starts at `0s` and uses NDF.

## Relinking

Project-owned media is copied beside the FCPXML into `<export name> Media/`. Each sidecar filename
keeps a readable original name and adds stable identity and content suffixes. XML `name` attributes
keep the unsuffixed original filename; only the sidecar path carries the suffix. The XML uses that durable file URL,
not a content-addressed title or a transient directory. Manifest aliases and project-local symlink aliases that
resolve to the same physical source share one asset resource and one physical sidecar copy. External
media keeps its resolved file URL. Asset IDs are derived from stable interchange identity, so export
order does not change them. External files with duplicate basenames produce an explicit manual-relink
warning while retaining their distinct full URLs. Re-export reuses a sidecar only when size and SHA-256 both match. A
same-size stale or corrupt sidecar is replaced atomically. A failed export removes only sidecars it
created during that attempt and removes its new sidecar directory only if empty; it does not delete
pre-existing or obsolete media implicitly.

## Failure, QC, and provenance

Encoding, validation, cancellation, media staging, and destination write failures propagate as
export failures. Invalid XML control characters name the affected clip or field and the required
remedy. Media hashing reports byte progress and checks cancellation between chunks. The exporter
writes to an adjacent temporary file, reads it back, requires exact byte equality, validates those
persisted bytes, and verifies their byte count before atomically replacing the destination. A failed
post-write validation therefore leaves an existing export untouched.

A successful report records the selected version and target, validation profile and structural
counts, ordered warnings, media bindings and source-timecode origins, output byte count, and SHA-256
of the exact persisted bytes. Each media binding also records its exact byte count, SHA-256, and
whether it is a staged project copy; the report aggregates staged count and media bytes. Those values
are immutable evidence for the exported file. Structural
roundtrip tests use an independent XPath/JSON oracle in addition to the exporter validator; native
build and test evidence comes only from GitHub Actions.
