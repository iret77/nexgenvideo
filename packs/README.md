# Format Packs

Thin, format-specific packages on top of the [`engine/`](../engine). A pack
contributes only its domain knowledge — schemas, checks, prompt patterns,
phase workflows — and registers them with the engine's extension points
(duration policy, sanity-check registry, prompt linters, providers).

The consistency machinery (Bible, pipeline, sanity framework, render dispatch)
is **engine core**, not duplicated per pack — see
[docs/ENGINE_MIGRATION.md](../docs/ENGINE_MIGRATION.md) for the boundary.

Planned: `packs/musicvideo/` — the music-specific remainder of the current
`musicvideo` repo (audio DSP, beat/tempo/genre patterns, cover art, lyrics
anchoring, tempo/pacing sanity checks).
