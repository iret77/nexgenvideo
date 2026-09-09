# Format-pack authoring

A format pack owns the workflow decisions that are unique to its format. The host owns media safety, project pinning, production knowledge, provider capabilities, generation requests, and canonical production artifacts. A pack must not copy provider or model enums into its own schema.

Before implementation, answer these ownership questions:

1. Which intake belongs to this format, and which inputs are optional?
2. Which phases are format-specific extensions, and which use a host-owned canonical writer?
3. Which exact files does each phase own?
4. Which upstream bytes make a phase stale?
5. Which production profiles and knowledge libraries apply to each phase?
6. Which source modes enter Frames and Render?
7. Does a schema change require a declared project migration?

Declare the complete ordered graph in `pipeline-contract.json`. Every phase needs packaged runtime instructions, one schema-validated writer, one structural approval gate, and exact cumulative lineage. Use `host.generic_json_extension` only with an `extensions/*.json` artifact and a closed JSON schema. Keep the schema small and format-specific; use core artifacts for canon, asset graphs, execution plans, requirements, routing, PromptIR, frames, and render render records.

Pack versions install side by side. `ngv.json` pins pack ID, pack version, and project schema. Never edit an existing project under a different pack version without an explicit transactional upgrade. A first version has no invented migration.

Acceptance requires both greenfield and imported-source fixtures, unknown-schema rejection, save/reopen, rewind after upstream byte changes, and actual external `.ngvpack` loading by the app binary. Provider tests stop at a request envelope and spend no credits. Imported-only fixtures produce no provider frame or render requests.

`fixture-fiction` is the repository's unpublished architecture fixture. It demonstrates a graph without Track, Lyrics, Audio Analysis, music-video modes, or model-specific enums. It is assembled and ad-hoc signed only in CI and is never added to the public catalog or release assets. Planned product packs remain documented in [the future-pack matrix](production-knowledge/ai-film-production-3.1.1/formats/future-packs.spec.md) and require their own product decisions.
