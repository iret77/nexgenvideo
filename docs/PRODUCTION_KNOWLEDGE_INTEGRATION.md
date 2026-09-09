# Production knowledge integration

NexGenVideo 1.5.7 adapts ai-film-production 3.1.1 into the generic runtime, the Musicvideo pack and the shared pipeline harness. Future format packs remain specifications under #491 and are not shipped.

## Runtime coverage

The authoring corpus preserves 20 source documents as 254 complete sections and 631 addressable units. The materializer produces 20 complete chapter libraries plus the 42-entry Director/DoP blueprint library. Every section has a source hash, runtime entry, activation, consumer, verification rules and issue ownership in `runtime-ledger.json`; packaging prose is explicitly provenance-only.

`get_production_knowledge` provides paginated search, complete entry reads with provenance and deterministic style recommendation in generic and format projects. The same `AgentInstructions.serverInstructions` reaches Anthropic API mode, the embedded Claude CLI and MCP initialization. It requires the complete applicable procedure and governing exceptions at production start, resume and phase transition.

Musicvideo registers phase-specific selections for Project Init, Analysis, Brief, Production Design, Treatment, Storyboard, Bible, Shot List, Sanity, Frames and Render. The harness injects only complete entries that fit its bounded context and identifies every omitted selected entry for an exact follow-up read. It never truncates an entry or assembles the whole corpus. Pack phase instructions, canon, approval and exact-byte lineage remain authoritative.

## Executable consumers

| Area | Runtime consumer and proof |
|---|---|
| Director/DoP | `ProductionStyleAdvisorV1` resolves genre, name, aliases, mood, constraints, harmony and clashes across 31 director recipes and 11 DoP signatures. `ProductionStyleStoreV1`, prompt binding, frame review and timeline review preserve per-dimension overrides and scoped evidence. |
| Story and canon | `StoryCausalityPlanV1`, Treatment and Storyboard writers bind proposals, causal changes, beat coverage and downstream rewind to canonical artifacts. |
| Spatial production | `SpatialProductionPlanV1` binds location/setup IDs, state changes, take/cut timing and exact blockout bytes through Shot List, Render and approval. |
| Assets and references | `ConfirmedIdentityAssetStoreV1`, `ReferencePlannerV2` and frame reference usage receipts bind approved project-local assets, semantic jobs, offering limits and actual ordered inputs. |
| Prompt dialects | `VideoPromptIRV1`, `VideoPromptDialectCompilerV1`, `PromptDialectRegistry` and `PromptCompiler` translate typed reference roles, operation mode, camera and audio intent into the selected route's syntax. |
| Generation | `GenerationPackageV1`, the central provider boundary and host-owned execution authority bind exact compiled requests, retained input bytes, route evidence, single-use spend, provider receipts and output bytes. |
| Review and repair | Immutable takes, six-pass attributed review, range salvage, iteration decisions, scoped repair gates, frame-audit acceptance and exact timeline style evidence prevent unobserved acceptance. |
| Musicvideo | `MusicvideoProductionExtensionsV1` binds original-song ranges, audible voices, visible mouth owners, section-aware visual arcs, performance/dance/concert coverage and final master-song assembly. |
| Delivery | `ShotDeliveryModeV1`, `TimelineAssemblyProofV1` and `MusicAssemblyProofV1` distinguish provider video, animated stills and imports and prove exact placed bytes, timings, motion and audio. |

## Audit #481 closure map

| Finding | Resolution |
|---|---|
| F01 recognition trait | Removed from the active writer contract and intake. Confirmed canonical identity views and versioned identity variants are the source of truth; the legacy field remains readable for ABI compatibility without an automatic-effect claim. |
| F02 frame reference loss | Required semantic identity, location and light jobs survive scoring. Insufficient offering capacity fails before generation. Frames generation, provenance and approval use the same host-recorded plan. |
| F03 ledger scope | The host compiler selects film/look plus only the current shot and its referenced characters, location and props. Audio excludes visual directives. |
| F04 reference syntax | Typed plan roles compile into the exact route dialect and slot order, including multiple views, start/end inputs and reference mode. |
| F05 pattern camera vocabulary | Pattern camera vocabulary remains selection knowledge. Stills receive no movement; video receives only its approved structured camera movement. |
| F06 rhythm source | Sanity accepts the gate-approved macOS 26 beat-transformer evidence and retains the future Music Understanding path without demanding it. |
| F07 frame verdict | Blocking and user-decision verdicts block normal approval until an exact-image, exact-expectation acceptance exists. Start/end expectations, observations and references are role-specific. |
| F08 project spend | Estimate, cockpit and hard stop read one append-only generation spend journal, including sheets, frames, retakes, failures and active reservations. Planning budget and hard stop are separate fields. |
| F09 still delivery | Animated still is an explicit execution/delivery mode with image output proof and timeline motion. It skips video routing and pricing and remains required in assembly. |
| F10 cut handles | The Brief states net/gross seconds and cost. The iterator prices and orders the gross duration, the prompt requests micro-motion, and assembly trims to the net interval. |
| F11 import-only canon | Explicitly confirmed existing project images may satisfy canonical views with adoption provenance. Import-only projects do not require content generation. |
| F12 deferred Brief writes | Every Brief-owned choice is settled before Brief approval. Later changes show affected approvals and require explicit rewind; no later phase promises an in-place Brief update. |

## Durable generation batches

One numbered immutable manifest carries each exact compiled request, input role/hash, route, output count, destination and monetary ceiling. Approval creates host-owned execution authority before dispatch. The central spend boundary consumes each item once; concurrent calls and reconnects join the same item job. Queued items can be canceled, submitted items continue to truthful completion, and partial failures do not erase unrelated work.

Authority persists under Application Support by host, project and batch. It restores exact requests, spend events, provider receipts and completed bytes after relaunch, an older project save or a discarded Recovery copy. Save As and another Mac expose history without executable authority. Missing or unverifiable provider evidence blocks another submission.

## Compatibility and acceptance

All new cross-pack data uses new versioned sidecar types. Existing public pack-facing V1 stored layouts remain unchanged, `EngineRegistry` additions are append-only, pack versions install side by side and existing projects retain their exact pin until an explicit transactional Recovery-copy upgrade.

The release commit must pass the full GitHub Actions build and test suite, the real external `.ngvpack` load test, corpus/materialization integrity, signing/notarization and release preflight. No source-authored statement or documentation match substitutes for those checks.
