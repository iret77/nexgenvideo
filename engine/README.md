# NexGenVideo Generic Production Engine (`nexgen_engine`)

The format-neutral production core — the reusable substance extracted from the
`musicvideo` pipeline: project layout, schema versioning, the asset-graph Bible,
the consistency/reference engine, the render dispatch + cost guard, the sanity /
linter framework, and the MCP spine. Per [CONCEPT.md](../docs/CONCEPT.md) §2/§4,
the consistency machinery is **core**, not a plugin — format-packs (musicvideo,
…) sit on top and register only their domain-specific behavior.

This is a **monorepo**: the engine lives here next to the Swift host; activated
format-packs live under [`../packs/`](../packs). The embedded `claude -p` runtime
loads the engine + the active pack via `--plugin-dir`.

## Status

Migration from `musicvideo` is staged and ongoing — see
[docs/ENGINE_MIGRATION.md](../docs/ENGINE_MIGRATION.md) for the full module map,
tier sequence, and the music→generic decoupling seams.

**Landed (Tier 1A leaf):** `core/{paths, schema_versions, aspect, models}`,
`treatment/schema`. Pure, zero music-coupling modules, verified by Engine CI.

## Develop

```bash
pip install -e ./engine
pytest engine/tests -q
```

Python 3.11+. The engine is independent of the Swift package; the macOS Swift CI
does not build it (a fast Ubuntu **Engine CI** workflow does).
