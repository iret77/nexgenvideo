# Clay provenance contract proposal

Status: **decision proposal only**. This document does not change a locked contract, authorize
product implementation, or approve the runtime work in #541. The proposed contract becomes
normative only after an explicit owner decision and separate edits to the affected locked specs.

Issue: #546. Runtime and scene producers: #541–#545. Review consumers: #533 and #559 / PR #577.

## TL;DR

Adopt three additive Core sidecars and no new phase:

1. Production Design owns optional, immutable `spatial-scene-manifest/v1` location revisions.
2. Bible owns early `spatial-derivation-proof/v1` Clay stills used for composition and geometry.
3. Shot List owns final camera/path/time decisions and publishes `shot-clay-bindings/v1` through
   the existing `PipelineShotlistWriter` transaction.

`BlockoutProofV1`, `CameraSetupPlanV1`, `Scene3D`, `AssetProvenanceV1`, and every other existing
public pack-facing value type keep their stored layout. A Clay output is a third, truthful Bible
provenance class, not fake model generation and not confirmed identity. A local spatial worker can
stage and preview in planning phases, but it never receives provider/LLM credentials, never writes
canonical project files, and never gains `generate_image`, `generate_video`, or the Render runner.
The host validates regular project-local files and seals proofs before a canonical writer can bind
them.

Clay stills carry composition/geometry only. Identity and look remain independent required roles.
A Clay video is eligible only when the selected executable provider route exposes the exact video
reference slot, mode, limits, and combination needed by the approved plan. There is no silent model,
slot, modality, strategy, or source-mode substitution.

## Decision requested

Approve or reject the following contract as one decision:

- **Ownership:** Production Design owns committed location scene revisions; Bible owns early Clay
  derivations; Shot List owns final shot cameras and shot-bound Clay derivations.
- **Representation:** add the three versioned Core artifacts below; do not revise public V1 stored
  layouts and do not reinterpret `BlockoutProofV1`.
- **Capabilities:** add local spatial capabilities to existing phases only. No new phase and no
  paid render capability in a planning phase.
- **Compatibility:** ship the Musicvideo mapping in a new pack version. Keep its current project
  schema when the artifacts remain optional and additive. Old pinned pack versions keep their exact
  old behavior. Any implementation that makes these artifacts mandatory instead requires a new
  project schema and an explicit Recovery-copy migration decision.

Approval of this proposal would not approve a build, merge, release, #533's final review phase, or
#559's proposed phase graph and Shot List schema.

## Verified current contract

The proposal is constrained by the current main-tree behavior, not by open proposal branches:

- `PipelineSpatialProductionWriter` atomically writes four Shot List-bound plans plus optional
  `BlockoutProofV1`. The proof binds exact plan bytes, ordered setup/shape/state IDs, a QuickTime
  clip, dimensions, rate, and duration.
- `BlockoutProofV1` does not bind a `.blend` scene, external resources, worker/runtime closure,
  render engine, color management, material override, evaluated frame, or renderer settings. Those
  facts cannot be inferred from it.
- `PipelineShotlistWriter` is the transaction owner for Shot List, execution inputs,
  conditioning strategy, spatial plan, pack plan, production inputs, and execution plan. A failure
  restores all snapshots.
- `ReferencePlanV2` already binds exact asset path/hash, modality, semantic job, input slot, mode,
  duration, route capability hashes, budgets, and all dropped optional demands. This is the correct
  downstream planner; a second Clay-specific provider planner is unnecessary.
- `ProjectCreativeContextV1.extensions` and `PackArtifactExtensionReferenceV1` already carry a
  versioned extension ID, schema, path, and exact hash without changing a public value layout.
- Bible views currently pass only with host-recorded prompt/model generation provenance or explicit
  host-recorded character/location identity confirmation. Neither class truthfully describes a
  local Clay render.
- Musicvideo allows paid still generation in Production Design and Bible, no supporting tools in
  Shot List, and paid video only in Render. Packless generic projects have the Core phase order but
  no pack manifest from which to inherit a spatial capability mapping.
- `Scene3D` describes a panorama and extracted POV geometry. It is not a persisted bpy scene
  manifest. Extending it with stored properties would change a public pack-facing value layout.
- Imported and AI-enhanced shots never enter Frames. AI-enhanced shots own exactly one project-local
  `source_path` and currently accept no reference inputs. Chained frame continuation and native
  extension have their own locked input semantics.

## Decision matrix

| Choice | Provenance is truthful | Preserves pack ABI | Covers early and final cameras | Reuses current planner | Decision |
|---|---:|---:|---:|---:|---|
| Record Clay in `PipelineAssetProof` as model output | No | Yes | No | Partly | Reject |
| Adopt Clay as confirmed location identity | No | Yes | No | Partly | Reject |
| Add fields to `Scene3D`, `CameraSetupV1`, `AssetProvenanceV1`, or `BlockoutProofV1` | Potentially | No | Potentially | Potentially | Reject |
| Call every bpy clip a `BlockoutProofV1` native blockout | No; scene/runtime/settings remain unbound | Yes | Final only | No | Reject |
| Add a mandatory 3D or Clay phase | Potentially | Potentially | Yes | Yes | Reject |
| Add versioned scene, derivation, and shot-binding sidecars | Yes | Yes | Yes | Yes | **Recommend** |

The recommended option is the only one that represents the source honestly, supports a scene before
Bible location anchors, keeps final camera authority in Shot List, and leaves projects without 3D
untouched.

## Ownership and lifecycle

### Core roles

The Core defines three semantic roles. A pack maps them to phases already present in its phase graph:

| Core role | Generic project | Musicvideo | Canonical owner |
|---|---|---|---|
| `spatial_scene_design` | `production_design` | `production_design` | `write_production_design` transaction |
| `spatial_bible_derivation` | `bible` | `bible` | `write_bible` and its gate |
| `spatial_shot_execution` | `shotlist` | `shotlist` | `PipelineShotlistWriter` |

A future pack may map a role to a different existing phase, but must declare one owner per role and
an acyclic order `scene design < Bible derivation < shot execution`. Omission means the optional
feature is unavailable for that pack; it never falls back to a guessed phase. No mapping may create a
phase or change the Musicvideo start order.

### Production Design owns the scene

Production Design may create zero or more location scenes. A spatial worker edits only a job-local
candidate. `write_production_design` receives an opaque host candidate ID, validates the candidate
against the expected base revision, and commits the immutable revision plus the updated index in the
same phase transaction as `production_design.yaml`.

Once Production Design is approved, Bible and Shot List consume the scene read-only. Correcting
geometry or a resource requires an explicit rewind to Production Design. This avoids two canonical
scene writers and ensures that location geometry exists before Bible derives location views from it.

Inspection cameras stored with a scene revision are explicitly `inspection` cameras. They exist to
review geometry and derive early location views. They are not Shot List setups and cannot acquire a
shot ID, generation interval, cut decision, or final camera authority.

### Bible owns early Clay derivations

Bible may request local Clay stills or an equirectangular Clay panorama from an approved Production
Design scene revision and an inspection camera. The worker writes staging; the host independently
checks the declared inputs and outputs, seals an opaque candidate in Recovery staging, and returns its
host candidate ID. `write_bible` publishes the output and `spatial-derivation-proof/v1` beneath the
matching Bible location in the same transaction as the Bible artifact. The supporting tool never
writes `pipeline/` or captures lineage.

The Bible writer accepts the new provenance class only for an explicitly declared
`composition_geometry` view purpose. Such a view can satisfy geometry/composition demand; it cannot
satisfy character identity, location appearance, lighting, palette, material, costume, or look.
Those roles still require their existing generated or confirmed-identity evidence. A Clay input used
to generate a styled location sheet is retained as a distinct bound input; the generated styled sheet
retains its normal model provenance.

### Shot List owns final cameras and shot-bound Clay

Only the existing Shot List transaction may decide or change final setup ID, shot ID, camera path,
start/end state, interval, sampling, and cut ownership. `CameraSetupPlanV1`,
`ShotGenerationCutPlanV1`, and `StateLadderV1` remain the planning sources. A new
`shot-clay-bindings/v1` sidecar binds their exact bytes to the exact scene revision and sealed Clay
output used by each shot.

Final shot previews can be rendered from an uncommitted host draft into Caches for review. They are
not lineage and cannot be selected by the reference planner. On the final `write_shotlist` call, the
host validates the expected draft and scene revision, renders or accepts the matching staged output,
seals it, writes the binding sidecar, and rolls back all of those writes if the Shot List transaction
fails. A proof from an inspection camera cannot be relabeled as a final-shot proof.

## Canonical paths

All paths are relative to the `pipeline/` data root. IDs are validated path segments, not user file
names.

```text
production_design/spatial/index.v1.json
production_design/spatial/locations/<location-id>/revisions/<revision-id>/
  manifest.v1.json
  scene.blend
  resources/<resource-id>/<original-filename>

bible/<location-id>/scene3d/clay/<derivation-id>/
  output.<png|exr>
  proof.v1.json

execution/spatial-derivations/<shot-id>/<derivation-id>/
  output.<png|mov>
  proof.v1.json
execution/extensions/shot-clay-bindings.v1.json
```

Transient candidates, interactive viewport meshes, thumbnails, unsealed frames, partial clips, and
preview renders remain in Application Support Recovery staging, Caches, or `NSTemporaryDirectory()`
as appropriate. They do not enter `pipeline/` until a host canonical writer commits them.

Every canonical entry is a regular file. Directory symlinks, file symlinks, aliases resolving outside
the project, traversal, sockets, devices, and missing resources are rejected. The host resolves every
file against the real project root, hashes the bytes itself, and compares the complete dependency set
reported by a clean auto-execution-disabled scene scan. Unlisted external dependencies fail closed.

## Versioned data contracts

The examples below are normative about field presence and meaning, but the example IDs and hashes are
illustrative.

### 1. Spatial scene index and manifest

Schema IDs:

- `spatial-scene-index/v1`
- `spatial-scene-manifest/v1`

The index is the only mutable pointer. Revisions are immutable after publication.

```json
{
  "schema": "spatial-scene-index/v1",
  "project_id": "example-project",
  "locations": {
    "loc-stage": {
      "revision_id": "scene-rev-0007",
      "manifest_path": "production_design/spatial/locations/loc-stage/revisions/scene-rev-0007/manifest.v1.json",
      "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
}
```

```json
{
  "schema": "spatial-scene-manifest/v1",
  "project_id": "example-project",
  "location_id": "loc-stage",
  "revision_id": "scene-rev-0007",
  "parent_revision_id": "scene-rev-0006",
  "created_at": "2026-09-24T10:00:00Z",
  "coordinate_contract": {
    "linear_unit": "meter",
    "meters_per_unit": 1,
    "handedness": "right",
    "up_axis": "+Z",
    "camera_local_forward_axis": "-Z",
    "camera_local_up_axis": "+Y",
    "angle_unit": "degree"
  },
  "time_base": {
    "fps_numerator": 24,
    "fps_denominator": 1,
    "frame_origin": 0
  },
  "scene": {
    "path": "production_design/spatial/locations/loc-stage/revisions/scene-rev-0007/scene.blend",
    "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "resources": [
    {
      "id": "resource-door-mesh",
      "path": "production_design/spatial/locations/loc-stage/revisions/scene-rev-0007/resources/resource-door-mesh/door.glb",
      "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "media_type": "model/gltf-binary"
    }
  ],
  "entity_bindings": [
    {
      "entity_id": "prop-door",
      "object_ids": ["object-door-frame", "object-door-leaf"]
    }
  ],
  "inspection_cameras": [
    {
      "camera_id": "inspect-entrance",
      "purpose": "inspection",
      "snapshot": {
        "projection": "perspective",
        "world_transform_row_major": [
          1, 0, 0, 2.5,
          0, 1, 0, -4,
          0, 0, 1, 1.6,
          0, 0, 0, 1
        ],
        "sensor_fit": "horizontal",
        "sensor_width_mm": 36,
        "focal_length_mm": 35,
        "clip_start_meters": 0.1,
        "clip_end_meters": 1000,
        "path": [],
        "path_interpolation": "linear"
      },
      "camera_snapshot_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    }
  ],
  "worker_source": {
    "candidate_job_id": "spatial-job-0182",
    "runtime_distribution_sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  }
}
```

The manifest contains a complete resource closure, not merely resources the worker happened to touch.
Packed resources are either retained inside the hashed scene bytes or unpacked into the declared
project-local resource closure; a dependency cannot remain at an original user path.
`resource_set_sha256` used below is the SHA-256 of canonical sorted JSON tuples
`[id, path, sha256, media_type]`. `camera_snapshot_sha256` is the SHA-256 of canonical sorted-key JSON
for `snapshot`, including every path keyframe and interpolation rule.

### 2. Spatial derivation proof

Schema ID: `spatial-derivation-proof/v1`.

The same schema covers a Bible still, panorama, and shot-bound still or clip. Conditional fields are
validated by `purpose` and `camera.owner`.

```json
{
  "schema": "spatial-derivation-proof/v1",
  "project_id": "example-project",
  "derivation_id": "clay-shot-s014-v1",
  "location_id": "loc-stage",
  "purpose": "clay_video",
  "semantic_role": "composition_geometry_motion",
  "scene": {
    "revision_id": "scene-rev-0007",
    "manifest_path": "production_design/spatial/locations/loc-stage/revisions/scene-rev-0007/manifest.v1.json",
    "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "scene_path": "production_design/spatial/locations/loc-stage/revisions/scene-rev-0007/scene.blend",
    "scene_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "resource_set_sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  },
  "camera": {
    "owner": "shotlist",
    "camera_id": "camera-k03",
    "setup_id": "K03",
    "shot_id": "s014",
    "camera_setup_plan_path": "execution/extensions/camera-setup-plan.v1.json",
    "camera_setup_plan_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
    "snapshot": {
      "projection": "perspective",
      "world_transform_row_major": [
        1, 0, 0, 2.5,
        0, 1, 0, -4,
        0, 0, 1, 1.6,
        0, 0, 0, 1
      ],
      "sensor_fit": "horizontal",
      "sensor_width_mm": 36,
      "focal_length_mm": 35,
      "horizontal_fov_degrees": 54.432,
      "clip_start_meters": 0.1,
      "clip_end_meters": 1000,
      "path": [
        {
          "frame": 0,
          "world_transform_row_major": [
            1, 0, 0, 2.5,
            0, 1, 0, -4,
            0, 0, 1, 1.6,
            0, 0, 0, 1
          ]
        },
        {
          "frame": 119,
          "world_transform_row_major": [
            1, 0, 0, 4,
            0, 1, 0, -2,
            0, 0, 1, 2.2,
            0, 0, 0, 1
          ]
        }
      ],
      "path_interpolation": "linear"
    },
    "camera_snapshot_sha256": "2222222222222222222222222222222222222222222222222222222222222222",
    "projection_adapter": "camera-setup-v1-to-spatial-snapshot/v1"
  },
  "state": {
    "state_ladder_path": "execution/extensions/state-ladder.v1.json",
    "state_ladder_sha256": "3333333333333333333333333333333333333333333333333333333333333333",
    "entity_state_ids": ["hero-v2", "door-open-v1"]
  },
  "time": {
    "fps_numerator": 24,
    "fps_denominator": 1,
    "start_frame": 0,
    "end_frame_inclusive": 119,
    "sampled_frames": 120,
    "interpolation_contract": "scene-evaluated/v1"
  },
  "runtime": {
    "runtime_distribution_sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "python_version": "3.13.7",
    "bpy_version": "5.2.2",
    "worker_protocol": "ngv-spatial-worker/v1"
  },
  "renderer": {
    "engine_id": "blender-eevee-next",
    "device_class": "cpu",
    "settings_schema": "ngv-clay-render-settings/v1",
    "settings": {
      "samples": 64,
      "resolution_percentage": 100,
      "motion_blur": false,
      "transparent_background": false
    },
    "settings_sha256": "4444444444444444444444444444444444444444444444444444444444444444",
    "material_override": {
      "contract": "neutral-clay/v1",
      "base_color_linear_rgba": [0.55, 0.55, 0.55, 1],
      "roughness": 0.8,
      "metallic": 0
    },
    "material_override_sha256": "5555555555555555555555555555555555555555555555555555555555555555",
    "color_management": {
      "display_device": "sRGB",
      "view_transform": "Standard",
      "look": "Medium High Contrast",
      "exposure": 0,
      "gamma": 1
    },
    "color_management_sha256": "6666666666666666666666666666666666666666666666666666666666666666"
  },
  "outputs": [
    {
      "role": "clay_color",
      "path": "execution/spatial-derivations/s014/clay-shot-s014-v1/output.mov",
      "sha256": "7777777777777777777777777777777777777777777777777777777777777777",
      "media_type": "video/quicktime",
      "width": 1920,
      "height": 1080,
      "frame_count": 120,
      "encoder": {
        "container": "quicktime",
        "codec": "hevc",
        "profile": "main",
        "pixel_format": "yuv420p",
        "timescale": 24000
      }
    }
  ],
  "host_validation": {
    "validator_contract": "spatial-derivation-validator/v1",
    "validated_at": "2026-09-24T10:05:00Z",
    "source_job_id": "spatial-job-0183"
  }
}
```

For `camera.owner = inspection`, `setup_id`, `shot_id`, and Shot List plan hashes are forbidden; the
proof instead binds the inspection camera snapshot in the scene manifest. For `purpose = clay_still`,
time identifies exactly one evaluated frame and the output is an image. For `purpose = clay_video`,
start/end are inclusive and `sampled_frames` must equal the declared rational-rate sample sequence.
The camera snapshot and renderer subobjects use canonical sorted-key JSON; their hashes bind the
embedded values. A final camera snapshot must be the deterministic projection of its named current
`CameraSetupPlanV1` entry, not an independently editable copy.

Depth, normal, and object-mask outputs may be recorded only with a separately versioned pass settings
contract declaring unit, value range, coordinate space, normalization, and object-ID mapping. Their
existence does not make a provider able to consume them.

### 3. Shot Clay bindings

Schema ID: `shot-clay-bindings/v1`.

Path: `execution/extensions/shot-clay-bindings.v1.json`.

```json
{
  "schema": "shot-clay-bindings/v1",
  "project_id": "example-project",
  "shotlist_path": "shotlist/v12.yaml",
  "shotlist_sha256": "8888888888888888888888888888888888888888888888888888888888888888",
  "camera_setup_plan_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
  "shot_generation_cut_plan_sha256": "9999999999999999999999999999999999999999999999999999999999999999",
  "state_ladder_sha256": "3333333333333333333333333333333333333333333333333333333333333333",
  "bindings": [
    {
      "shot_id": "s014",
      "location_id": "loc-stage",
      "scene_revision_id": "scene-rev-0007",
      "setup_id": "K03",
      "derivation_proof_path": "execution/spatial-derivations/s014/clay-shot-s014-v1/proof.v1.json",
      "derivation_proof_sha256": "abababababababababababababababababababababababababababababababab",
      "output_role": "clay_color",
      "semantic_job_id": "core.composition-geometry-motion",
      "required": true
    }
  ]
}
```

Each binding must resolve to one output inside its proof. The proof must name the same project,
location, scene revision, shot, setup, state plan, and current camera plan. The sidecar is emitted as
a new `PackArtifactExtensionReferenceV1`; no field is appended to an existing public struct.

## Determinism and replay

“Deterministic” here means a complete origin and replay contract:

- exact scene, complete resource closure, camera snapshot/plan, state, time/sample sequence;
- exact worker distribution, bpy/Python versions, renderer, Clay material, color management, and
  settings;
- exact output bytes and host validation receipt.

It does **not** claim that different hardware, GPU drivers, renderer builds, or codec implementations
produce bit-identical output. Replaying a proof must use the recorded execution closure. Acceptance
compares known geometric projections and decoded media within a declared tolerance, while the proof
hash always binds the exact bytes actually used by the provider request.

A replay on a different execution closure creates a new derivation ID and proof even if a visual
comparison passes.

## Host sealing boundary

The worker receives only:

- a read-only materialization of the exact scene and declared resources;
- a job-local writable staging directory;
- a schema-validated job envelope with expected project, location, revision, camera, state, time,
  renderer, and output limits.

It receives no project package path, canonical pipeline write access, network access, Keychain data,
provider key, Anthropic/OpenAI credential, prompt-engine secret, gate state, or lineage authority.

The host accepts a worker result only when all of the following pass:

1. the job ID and immutable request bytes match the active host job;
2. the expected base scene revision is still current;
3. a clean auto-execution-disabled scan reports exactly the manifest resource closure;
4. every input and output is a regular file within its allowed root and independently hashed;
5. scene, resource, camera, state, time, renderer, settings, dimensions, frame count, and codec match
   the request and decoded result;
6. no undeclared output or partial success is present;
7. the relevant canonical writer is still current and holds the project phase mutation lease.

Only then does the host atomically copy the result to its canonical path and encode the proof. A
worker result is never itself a proof. Cancellation, timeout, worker crash, reconnect, duplicate job
ID with different payload, stale base revision, or failed validation leaves only disposable staging.

## Phase capabilities

Suggested tool names are contract names, not an implementation authorization.

| Capability | Kind | Production Design | Bible | Shot List | Paid-provider access | Canonical write |
|---|---|---:|---:|---:|---:|---:|
| `stage_spatial_scene` | supporting | Yes | No | No | No | Staging only |
| `inspect_spatial_scene` | supporting/read | Yes | Yes | Yes | No | No |
| `render_spatial_preview` | supporting/read | Yes | Yes | Yes | No | Cache only |
| `derive_clay_reference` | supporting | No | Yes | No | No | Sealed Recovery candidate only |
| `write_production_design` | existing phase writer | Commits scene candidate | — | — | Existing still rules only | Yes |
| `write_bible` | existing phase writer | — | Binds Clay proof | — | Existing still rules only | Yes |
| `write_shotlist` | existing phase writer | — | — | Commits final camera/binding/output transaction | No | Yes |

No spatial tool calls `generate_image`, `generate_video`, `run_provider_tool`, or
`prepare_generation_batch`. It cannot invoke `run_phase` for Render. A local renderer is a dedicated
Core operator, not a broadened media-generation permission.

Musicvideo declares the tools in a new exact pack version's phase capability lists and registers the
three Core-role mappings. Generic projects use the same host operators and the default mapping in the
table above. The generic path must enforce current phase, prior approvals, intake completion, active
job identity, and rewind rules itself; the current packless early return is not permission to bypass
those checks.

If the registration requires a new `EngineRegistry` stored property, it is appended at the end of the
class, after the current last property `frameReferencePlanProvider`. On the reviewed base,
`EngineContract.current` is `9` and `minimumCompatible` is `2`: integration would consume `10` and
retain `2`. If parallel work has already consumed `10`, integration uses the next free integer rather
than duplicating it. This conclusion must be re-evaluated if implementation changes any existing
cross-boundary signature or stored layout.

## Bible provenance gate

The Bible gate classifies each demanded path into exactly one provenance class:

| Class | Required evidence | Roles it may satisfy |
|---|---|---|
| `model_generation` | existing compiled prompt, model, source media ID, exact output hash | Declared generated identity/look/composition roles |
| `confirmed_identity` | existing host confirmation for exact current bytes and identity | Matching character/location identity only |
| `spatial_derivation` | current sealed derivation proof and exact output hash | `composition_geometry` only |

The gate rejects a path present in multiple classes, an arbitrary import, a stale proof, an inspection
proof claimed as a final-shot proof, or a Clay view assigned identity/look purpose. A
`spatial_derivation` entry does not need or accept a fake provider prompt/model/source-media ID.

`PipelineAssetProof` stays model-generation-only. A new internal classification step combines the
existing proof, confirmed-identity manifest, and spatial proof inventory without adding a field to
`BibleViewProvenanceRequirementV1`.

## Reference planning and compile contract

The approved Shot List creates normal `AssetGraphV1` nodes for sealed Clay outputs. It uses the
existing `AssetProvenanceV1` carrier as follows, without changing its layout:

- `kind_id = core.spatial-derivation`;
- `source_asset_id = <scene revision id>`;
- model and prompt fields are absent;
- the separate `shot-clay-bindings/v1` extension provides the proof path/hash and is validated with
  the graph before publication.

New semantic jobs are:

- `core.composition-geometry` for a Clay still;
- `core.composition-geometry-motion` for a Clay video.

They are roles, not provider capability claims. The demand still names the real route input slot and
mode. `ReferencePlanV2` remains responsible for exact path/hash, modality, duration, slot, mode,
capacity, mutual exclusions, route capability hashes, and deterministic failure. A chosen Clay plan
marks its Clay demand required; unsupported combinations return `requiredInputsUnsupported` before
spend rather than dropping the Clay input or changing strategy.

The prompt compiler emits role text saying that Clay controls composition, spatial layout, occlusion,
blocking, camera movement, and timing only. Identity sheets and look/lighting references retain their
own roles. Provider request assembly must preserve the exact ordered `ReferencePlanV2.bindings`; an
adapter cannot flatten a video reference to a still or relabel a role.

### Conditioning compatibility

| Existing source/strategy | Clay still | Clay video | Rule |
|---|---:|---:|---|
| Imported | No provider input | No provider input | Imported media remains production truth |
| AI-enhanced | No | No | Current exact `source_path`-only contract remains |
| `reference_anchor` | Yes, in a genuine image-reference slot | Yes, only in a genuine video-reference slot | Exact role combination must be executable |
| `two_state_interpolation` | Additional reference only if frames+references can coexist | Only if the route explicitly supports that combination | Never replaces start/end states |
| explicit `first_frame` | Additional reference only | Only if independently supported | Never occupies or replaces first-frame input |
| `frame_continuation` | No | No | Predecessor last frame remains the sole start condition |
| `native_extension` | Only if explicitly present in its approved permitted-original-reference set | Same | Never replaces predecessor video or extension mode |

A Clay video is never an AI-enhanced `source_path`. It does not change `source_mode`, does not enter
Frames as an imported/AI-enhanced shot, and does not create a new conditioning strategy. Depth,
normal, or mask passes stay unavailable to the planner until a live executable provider adapter
declares their exact slots and combinations.

## Mutation, rewind, and invalidation

| Changed input | Required current owner | Explicit rewind when approved | Invalidated evidence |
|---|---|---|---|
| Scene geometry, object/entity binding, resource bytes, coordinate/time contract | Production Design | To `production_design` | Scene index/revision selection, all dependent Bible Clay proofs/views, Shot List spatial/Clay extensions, route/reference/compile/review/Frames/Render proofs |
| Inspection camera or Bible Clay output/settings | Bible | To `bible` | Matching Bible proof/view and all dependent Shot List/reference/compile/review/Frames/Render proofs |
| Identity or look reference | Existing owning phase, normally Bible | To that phase | Existing dependent plans/proofs; spatial scene may remain current |
| Final setup, camera path, shot interval, state IDs, scene revision selection, or shot Clay role | Shot List | To `shotlist` | Shot Clay proof/binding, execution/reference/compile/review/Sanity/Frames/Render proofs for every actual dependent |
| Selected provider/model offering or capability snapshot | Shot List planning contract | To `shotlist` | Route and Reference Plan, compiled package, review and Render authorization |
| Canonical output bytes at the same path | No direct mutation allowed | Rewind owning phase and republish | Proof fails immediately; downstream approval remains unusable |
| Worker staging or Cache preview | None | None | No canonical evidence; it was never approved truth |

Invalidation follows recorded dependency edges, not an assertion that every change affects every shot.
Nevertheless, no dependent proof remains valid merely because a filename or ID stayed the same.
Approval, pending/needs-revision mutation, and rewind remain unavailable while the relevant host job is
running. Retry and reconnect join the same project/phase job.

## Pack, schema, and old-project compatibility

### Recommended additive path

- Add new Core types; do not add stored properties to any existing public value type.
- Carry execution additions through new `PackArtifactExtensionReferenceV1` entries.
- Append any `EngineRegistry` storage at the end of the class.
- Bump `EngineContract.current` from the reviewed base value `9` to the next unallocated value for the
  new additive cross-pack registration surface; retain `minimumCompatible = 2` after an actual
  old-pack load test.
- Publish a Musicvideo pack version newer than the reviewed `0.5.8` that registers role→phase
  mappings and capabilities; choose the exact version at integration so parallel releases cannot
  collide.
- Keep the current `musicvideo/2.0.0` project schema because scene/Clay artifacts are optional and older
  projects decode without them. Moving a project to the new pack is an explicit same-schema
  version-only upgrade; no artifact migration runs.
- Keep old pack versions installed and loadable. An old pinned project sees no spatial tools and no
  invented geometry. Panorama references, schematic native blockouts, imported blockout clips,
  imported footage, AI-enhanced sources, and current conditioning plans retain their exact contracts.

### When a schema migration becomes mandatory

A new pack project schema and explicit transactional Recovery-copy migration are required if an
implementation makes a scene, Clay proof, role mapping, or new phase artifact mandatory for opening,
approval, save, or execution of an existing project. That is outside the recommended minimal delta
and requires another owner decision. A migration cannot fabricate geometry or provenance; it can only
preserve old artifacts, reset the earliest affected gate, and ask for new work.

No file's mere presence selects the new contract. The exact project pack version/schema binding and
live host engine contract do.

## Proposed locked-spec deltas

These are the smallest proposed edits after approval. The locked files are intentionally unchanged in
this branch.

### `docs/PIPELINE_AGENT_HARNESS.md` — required

1. In **Phase artifacts**, extend Production Design, Bible, and Shot List rows with the optional
   scene index/revisions, sealed spatial derivation proofs, and shot Clay binding sidecar.
2. After the staging paragraph, state that spatial workers write only job staging; only the current
   canonical phase writer may commit a scene, Bible derivation, or shot binding; Bible support may
   create only an opaque host-sealed Recovery candidate that `write_bible` validates and publishes.
3. In the capability paragraph, add local spatial stage/inspect/preview/derivation capabilities with
   explicit phase-role mapping and explicitly deny all provider/Render-runner authority.
4. Replace “one of two” in the Bible provenance invariant with the three-class table above, including
   `composition_geometry` limits.
5. Add a new spatial-derivation invariant after the existing blockout invariant. State explicitly
   that `BlockoutProofV1` remains the proof for its current schematic/imported clip contract and is
   not sufficient evidence for a bpy derivation.
6. Add the conditioning matrix constraints, including no Clay for imported, AI-enhanced, or frame
   continuation and no substitution of first/end/source/predecessor inputs.
7. Extend release evidence to fail for stale scene/resource/runtime/settings/output bytes, a worker
   canonical write, invalid role combination, generic/pack phase bypass, or provider request bytes
   differing from the approved Reference Plan.

### `docs/PLUGIN_STANDARD.md` — required

Add the additive `registerSpatialPhaseRole(role:phase:)` registration boundary, the three role
meanings, and the rule that each pack version maps them only to existing phases. Record the
`EngineContract.current` bump and unchanged compatibility floor, conditioned on old-pack load
evidence. Add no `Pack` protocol requirement.

### `docs/PRODUCTION_PROFILES.md` — required

Under `generative_film`, clarify that geometry anchors are optional and may use the sealed local
spatial-derivation class; Clay controls composition/geometry only and never replaces required
identity/look evidence. State that Clay video use is a route capability decision, not profile
doctrine.

### `docs/PROJECT_STORAGE.md` — no text delta

Existing rules already place portable truth inside `pipeline/`, transient staging in Recovery/Caches,
and pack upgrades in an atomic Recovery copy. The paths above comply. Do not add a storage exception.

### `docs/MUSICVIDEO_START_CONTRACT.md` — no text delta

The order remains Track → optional Lyrics → Project Init → approved Analysis → optional existing
material → story development. Spatial scene work starts only in the existing mapped Production Design
phase.

### `docs/PATTERN_FIT_CONTRACT.md` — no text delta

Clay is production machinery, not Pattern suitability evidence or a new Pattern capability score.

## Integration with open proposals

### #559 / PR #577 decision point

This contract does not adopt `shotlist/v5`, stable sparse shot IDs, new phases, or a new host contract
key from the unapproved #559 proposal. `shot-clay-bindings/v1` binds whichever Shot List contract the
project's explicitly approved host/pack contract selects. If #559 is later approved, its migration
must preserve or transactionally rewrite every Clay binding and paid-output association; this proposal
does not reserve or duplicate any of its schema IDs.

Owner decision needed at integration: either land #546 against the current Shot List identity contract,
or first approve #559 and adapt the binding validator to that approved identity contract. Do not merge
the two decisions by implication.

### #533 decision point

The proposed proofs expose read-only scene revision, camera/setup, state, time, output, and role data
for #533's eventual visual review. They do not create `render_review`, Story/Continuity semantics,
creative exceptions, or a new gate. Structural proof currency remains distinct from creative image
assessment.

Owner decision needed at integration: after #533's contract is approved, decide which exact current
Clay and look/identity bindings its review receipt covers. Until then, no Clay proof can masquerade as
final creative review approval.

## End-to-end acceptance

All executable evidence runs in GitHub Actions on the repository's configured runners. No local build,
test, app start, worker execution, or paid provider probe is part of this proposal.

### Contract and storage

- A generic project and a Musicvideo project use the same Core writers and schemas, with their
  independently resolved phase mappings.
- A project with no 3D artifacts completes normally. No new mandatory phase, card, gate, or upload is
  visible.
- Save, Save As, Recovery restore, move to another machine, and exact old-pack open preserve the
  specified scene/resource/proof behavior without original external paths.
- Scene and proof files that are symlinks, non-regular, escaped, missing, mutated, or backed by an
  incomplete resource closure fail before approval and provider spend.
- The actual old pinned pack is loaded against the new host binary; static symbol inspection alone is
  insufficient.

### Writer and job integrity

- Worker success, failure, timeout, cancellation, crash, duplicate retry, reconnect, and stale base
  revision demonstrate that only a fully validated host commit becomes project truth.
- Concurrent UI/agent scene changes conflict on expected revision; no last-writer-wins scene loss.
- A failed Production Design, Bible, or Shot List transaction restores every prior canonical byte and
  removes newly published outputs.
- A support tool cannot capture lineage, approve a gate, change gate state, or write a canonical scene,
  binding, or proof directly.

### Geometry and media evidence

- A known asymmetric scene binds all resources and produces opposing views with verified projected
  points, occlusion, and parallax.
- Still and clip proofs bind exact camera, state, frame/time sequence, runtime, renderer/settings, and
  output hashes. Start/middle/end decoded frames agree with separately evaluated camera times within
  declared tolerance.
- Replaying on the recorded execution closure produces geometrically equivalent evidence; a different
  closure creates a new proof rather than claiming byte identity.
- Changing one scene resource, camera keyframe, state, render setting, or output byte makes every
  actual dependent proof unusable.

### Provenance and roles

- Bible accepts a current Clay view only as `spatial_derivation` with
  `composition_geometry`; it rejects the same bytes as identity or look.
- Generated and confirmed-identity Bible paths retain their existing behavior. An arbitrary library
  import remains insufficient.
- Identity/look demands remain present when Clay is selected. Reference capacity failure blocks
  before spend instead of dropping a required role.

### Provider and strategy boundary

- Adapter tests compare the exact image/video bytes, ordering, roles, slots, modes, and time/duration
  sent to the provider with the approved `ReferencePlanV2`.
- A Clay video route is offered only from an enabled executable adapter that declares the exact video
  input and combination. Unknown or stale capability data fails closed.
- Unsupported combinations do not switch provider/model, turn video into a still, change strategy,
  or omit Clay silently.
- Imported, AI-enhanced, `first_frame`, `two_state_interpolation`, `frame_continuation`, and
  `native_extension` fixtures prove the compatibility matrix above. A Clay clip never becomes
  AI-enhanced `source_path`.
- Any real paid generation remains inside a separately approved production batch. The local spatial
  worker cannot reach provider or LLM credentials.

## Implementation boundary after approval

The implementation should extend the current `PipelineSpatialProductionWriter`,
`PipelineShotlistWriter`, execution composer, production-input writer, `ReferencePlannerV2`, compile
validation, phase capability resolver, and independent gates. It should not create a parallel scene
engine, provider planner, prompt path, gate store, or phase runner.

#541 supplies no trusted runtime fact until its code is reviewed and Actions proves the shipped worker,
resource boundary, signing, and real bpy output. #542 owns the full portable scene implementation;
#543 owns agent modeling/inspection tools; #544 owns native UI; #545 owns the renderer/exporter. This
proposal fixes their contract seams and does not pre-implement those features.
