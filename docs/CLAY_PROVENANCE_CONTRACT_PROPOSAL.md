# Clay provenance contract proposal

Status: **decision proposal only**. This document does not change a locked contract, authorize
product implementation, or approve the runtime work in #541. The contract becomes normative only
after an explicit owner decision and separate edits to the affected locked specs.

Issue: #546. Runtime and scene producers: #541–#545. Possible future consumers: #533 and #559 /
PR #577; neither is approved or incorporated here.

## TL;DR

Adopt four optional Core artifact families, expressed by five new schema IDs, and no new phase:

1. Production Design owns an opaque `spatial-scene-index/v1` plus immutable
   `spatial-scene-manifest/v1` revisions. These artifacts do not use Bible IDs.
2. Bible owns `bible-spatial-bindings/v1`, which maps current Bible locations/entities to a current
   approved scene revision and inventories early Clay proofs with a typed purpose.
3. Both early and final Clay outputs use `spatial-derivation-proof/v1`. An early proof owns its
   inspection camera and binds `scene_rest`; a final proof binds current Shot List camera and state
   plans.
4. Shot List owns `shot-clay-bindings/v1` through the existing `PipelineShotlistWriter` transaction.
   `write_shotlist` with a spatial payload is the sole final-Clay producer and runs its local worker
   inside that existing project/phase execution identity and lease; it adds no supporting capability.

Every Bible and Shot spatial binding must match the exact current approved Production Design index
entry, revision, and manifest hash. Selecting an older revision is forbidden; changing the current
revision requires a rewind to Production Design.

`BlockoutProofV1`, `CameraSetupPlanV1`, `Scene3D`, `AssetProvenanceV1`,
`BibleViewProvenanceRequirementV1`, and every other existing public pack-facing value type keep
their stored layout. Clay outputs never occupy `location.sheets` or `scene3d.panorama`; their sole
Bible carrier is the new typed binding/proof inventory. The local spatial worker receives neither
provider/LLM credentials nor canonical-write or Render-runner authority.

## Decision requested

Approve or reject this contract as one decision:

- **Ownership:** Production Design owns portable scene revisions and optional read-only review
  cameras; Bible owns mappings to Bible identity, early inspection cameras, and early Clay views;
  Shot List owns final shot cameras, state, time, and shot-bound Clay.
- **Representation:** add the five schemas above without changing existing public stored layouts or
  reinterpreting `BlockoutProofV1`.
- **Capabilities:** add only the listed local spatial capabilities to existing phases. Packless
  generic projects use a narrow Core default table and Core current-phase guards. Pack projects use
  only the mapping and intake steps declared by their resolved manifest.
- **Compatibility:** ship Musicvideo support in a new exact pack version while retaining
  `musicvideo/2.0.0` if the artifacts remain optional. Every pack-version switch still uses the
  existing transactional Recovery-copy upgrade. Old pinned packs remain installed and keep their
  exact behavior.

Approval would not approve implementation, build, merge, release, #533, or #559 / PR #577.

## Verified current constraints

This proposal is constrained by current main-tree code rather than open proposal branches:

- `ProductionDesign` has no location/entity identity fields. Bible owns location and entity IDs.
- `BibleViewProvenanceRequirementsV1.make` currently treats every `location.sheets` path and
  `scene3d.panorama` as appearance/identity evidence. Clay cannot use either carrier truthfully.
- `StateLadderV1` binds a Shot List hash and therefore cannot describe a pre-Shot-List Bible view.
- `PipelineSpatialProductionWriter` writes the current Shot List-bound plans plus optional
  `BlockoutProofV1`; that proof does not bind a `.blend`, complete resources, runtime, renderer,
  evaluated frame, or Clay settings.
- `PipelineShotlistWriter` already owns the atomic Shot List and execution-plan transaction.
- `ReferencePlanV2` already binds exact asset bytes, semantic job, input slot/mode, duration, route
  capability hashes, budgets, and dropped optional demands. No second provider planner is needed.
- Packless `PipelinePhaseAccess.requireCurrentPhaseAndIntake` and `guardCurrentPhaseWork` currently
  return before enforcing current phase/capabilities. Hard Steps and capability lists are otherwise
  pack-manifest data.
- `ProjectCreativeContextV1.extensions` and `PackArtifactExtensionReferenceV1` can carry versioned
  sidecars without changing a public value layout.
- Imported and AI-enhanced shots never enter Frames. AI-enhanced shots own exactly one project-local
  `source_path` and accept no reference inputs. Frame continuation and native extension keep their
  locked input semantics.

## Ownership and lifecycle

### Core roles

| Core role | Generic default phase | Musicvideo phase | Canonical owner |
|---|---|---|---|
| `spatial_scene_design` | `production_design` | `production_design` | `write_production_design` |
| `spatial_bible_derivation` | `bible` | `bible` | `write_bible` and independent Bible gate |
| `spatial_shot_execution` | `shotlist` | `shotlist` | `PipelineShotlistWriter` |

A pack may map a role only to an existing phase and must preserve the acyclic order scene design <
Bible derivation < shot execution. Omission disables that optional role for that exact pack version;
it never falls back to the generic table. The generic table applies only when no pack is resolved.

### Production Design owns opaque scene truth

Production Design may create zero or more scenes. It assigns an opaque `scene_key` and scene-local
`object_id`/`role` values; it does not predict or reserve Bible location/entity IDs. A spatial worker
edits only a job-local candidate. `write_production_design` validates an expected base revision and
atomically commits an immutable revision plus the updated index with `production_design.yaml`.

The index is the only mutable revision pointer. Once Production Design is approved, later phases
consume the indexed revision read-only. Geometry, resources, object catalog, coordinate/time
contract, rest frame, or index revision changes require an explicit rewind to Production Design.

A manifest may contain optional `review_cameras`. They are immutable review aids owned by the scene
revision, never Shot List setups. Bible may copy one as an initial value, but every early derivation
embeds and hashes its own `camera.owner = bible_inspection` snapshot. Creating a new Bible
perspective never mutates Production Design geometry, its manifest, or its review cameras.

### Bible owns identity mapping, purpose, and early inspection

Bible may bind one Bible location to one current approved scene revision and Bible entities to
scene-local object IDs. `bible-spatial-bindings/v1` is the typed carrier for those mappings and for
the inventory of early Clay outputs. It binds exact current Bible bytes, exact current scene-index
bytes, revision/manifest bytes, proof bytes, output bytes, `purpose`, and `semantic_role`.

The worker writes only staging. The host seals an opaque Recovery candidate.
`write_bible` validates the candidate and atomically publishes Bible, the binding inventory, outputs,
proofs, and cumulative exact-byte lineage. Failure restores every previous
byte. The supporting tool never captures lineage or writes `pipeline/`.

The independent Bible gate reloads all committed bytes rather than trusting writer state. It checks
that the Bible IDs exist, mapped object IDs exist in the named manifest, the scene entry is still the
current approved index entry, every proof and output hash matches, and every inventory purpose/role
matches the proof. A stale, missing, ambiguous, or many-scene mapping fails closed.

Clay bytes are forbidden in existing `location.sheets` and `scene3d.panorama`, even if the same path
also appears in the new inventory. `write_bible` and the independent gate reject identical paths or
identical hashes classified as generated appearance, confirmed identity, location panorama, or
Clay. This preserves the existing Generated/Identity/Panorama behavior unchanged and prevents the
reference planner from treating geometry evidence as a look anchor.

### Shot List owns final camera, state, time, and binding

Only the existing Shot List transaction may decide final setup ID, shot ID, camera path, start/end
state, interval, sampling, and cut ownership. `CameraSetupPlanV1`, `ShotGenerationCutPlanV1`, and
`StateLadderV1` remain the sources. A final proof uses `camera.owner = shotlist` and
`state.kind = state_ladder`.

The transaction must bind the exact current approved scene-index hash and its exact revision and
manifest hash. It cannot choose a historical revision. `write_shotlist` with a spatial payload is
the producer: inside its one existing project/phase execution identity and mutation lease, it binds
the current draft's exact project-local scene-index, `CameraSetupPlanV1`, `StateLadderV1`, Shot List,
and cut bytes into the immutable worker request and starts the local worker internally. Immediately
before commit, the writer revalidates that the same bytes are the transaction's actual final bytes,
then atomically writes the Shot List, spatial proof/output, `shot-clay-bindings/v1`, extension
references, and cumulative lineage. Parallel calls and identical retry/reconnect requests join that
host job; a different payload fails closed. Cancellation or crash discards staging and preserves the
previous canonical bytes. Gate-state mutation and approval remain unavailable until the complete
transaction passes the independent structural gate. A cache preview is never an input or proof
source, and a Bible proof cannot be relabeled as a final-shot proof.

## Canonical paths

All paths are relative to the `pipeline/` data root. IDs are validated path segments, not filenames.

```text
production_design/spatial/index.v1.json
production_design/spatial/scenes/<scene-key>/revisions/<revision-id>/
  manifest.v1.json
  scene.blend
  resources/<resource-id>/<original-filename>

bible/spatial-bindings.v1.json
bible/spatial/<location-id>/<derivation-id>/
  output.<png|exr>
  proof.v1.json

execution/spatial-derivations/<shot-id>/<derivation-id>/
  output.<png|mov>
  proof.v1.json
execution/extensions/shot-clay-bindings.v1.json
```

Transient candidates, thumbnails, unsealed frames, partial clips, and previews remain in Recovery
staging, Caches, or `NSTemporaryDirectory()`. Every canonical entry is a regular project-local file.
Symlinks, aliases escaping the package, traversal, sockets, devices, missing dependencies, and
undeclared external resources fail closed.

## Versioned data contracts

The examples are normative about field presence, variants, and relationships. Example IDs, hashes,
and the explicitly named example renderer contract are illustrative.

### 1. Spatial scene index and manifest

Schema IDs: `spatial-scene-index/v1` and `spatial-scene-manifest/v1`.

```json
{
  "schema": "spatial-scene-index/v1",
  "project_id": "example-project",
  "scenes": {
    "pd-scene-a7f3": {
      "revision_id": "scene-rev-0007",
      "manifest_path": "production_design/spatial/scenes/pd-scene-a7f3/revisions/scene-rev-0007/manifest.v1.json",
      "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
}
```

```json
{
  "schema": "spatial-scene-manifest/v1",
  "project_id": "example-project",
  "scene_key": "pd-scene-a7f3",
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
  "rest_state": {
    "contract": "scene-file-evaluated-frame/v1",
    "evaluated_frame": 0
  },
  "scene": {
    "path": "production_design/spatial/scenes/pd-scene-a7f3/revisions/scene-rev-0007/scene.blend",
    "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "resources": [
    {
      "id": "resource-door-mesh",
      "path": "production_design/spatial/scenes/pd-scene-a7f3/revisions/scene-rev-0007/resources/resource-door-mesh/door.glb",
      "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "media_type": "model/gltf-binary"
    }
  ],
  "objects": [
    {
      "object_id": "object-door-frame",
      "role": "portal.frame",
      "resource_ids": ["resource-door-mesh"]
    },
    {
      "object_id": "object-door-leaf",
      "role": "portal.movable-leaf",
      "resource_ids": ["resource-door-mesh"]
    }
  ],
  "review_cameras": [
    {
      "camera_id": "review-entrance",
      "snapshot": {
        "projection": "perspective",
        "world_transform_row_major": [1, 0, 0, 2.5, 0, 1, 0, -4, 0, 0, 1, 1.6, 0, 0, 0, 1],
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

The manifest contains the complete resource closure. `objects` are scene-local and never carry
Bible IDs. `resource_set_sha256` used below hashes canonical sorted JSON tuples
`[id, path, sha256, media_type]`. Snapshot hashes cover canonical sorted-key JSON.

### 2. Bible spatial bindings and proof inventory

Schema ID: `bible-spatial-bindings/v1`. This full example is the normative early-Bible mapping and
provenance boundary.

```json
{
  "schema": "bible-spatial-bindings/v1",
  "project_id": "example-project",
  "bible_path": "bible/bible.yaml",
  "bible_sha256": "1010101010101010101010101010101010101010101010101010101010101010",
  "scene_index_path": "production_design/spatial/index.v1.json",
  "scene_index_sha256": "2020202020202020202020202020202020202020202020202020202020202020",
  "scene_bindings": [
    {
      "bible_location_id": "loc-stage",
      "scene_key": "pd-scene-a7f3",
      "revision_id": "scene-rev-0007",
      "manifest_path": "production_design/spatial/scenes/pd-scene-a7f3/revisions/scene-rev-0007/manifest.v1.json",
      "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "entity_object_bindings": [
        {
          "bible_entity_kind": "prop",
          "bible_entity_id": "prop-door",
          "object_ids": ["object-door-frame", "object-door-leaf"]
        }
      ]
    }
  ],
  "derivations": [
    {
      "bible_location_id": "loc-stage",
      "derivation_id": "clay-bible-loc-stage-v1",
      "purpose": "bible_clay_still",
      "semantic_role": "composition_geometry",
      "proof_path": "bible/spatial/loc-stage/clay-bible-loc-stage-v1/proof.v1.json",
      "proof_sha256": "3030303030303030303030303030303030303030303030303030303030303030",
      "output_path": "bible/spatial/loc-stage/clay-bible-loc-stage-v1/output.png",
      "output_sha256": "4040404040404040404040404040404040404040404040404040404040404040"
    }
  ]
}
```

The sidecar owns both the Bible-to-PD binding and the typed derivation inventory. The writer and
independent gate require every `scene_bindings` entry to equal the current approved index pointer and
every object ID to exist in that manifest. Each derivation must resolve through its location's scene
binding, and its purpose, role, proof, and output must match exact bytes. One Bible location cannot
silently bind two scenes; one scene may support multiple locations only through explicit distinct
bindings whose entity-object mappings remain unambiguous.

### 3. Spatial derivation proof

Schema ID: `spatial-derivation-proof/v1`.

The complete early-Bible proof corresponding to the inventory above is:

```json
{
  "schema": "spatial-derivation-proof/v1",
  "project_id": "example-project",
  "derivation_id": "clay-bible-loc-stage-v1",
  "bible_location_id": "loc-stage",
  "purpose": "bible_clay_still",
  "semantic_role": "composition_geometry",
  "scene": {
    "scene_index_path": "production_design/spatial/index.v1.json",
    "scene_index_sha256": "2020202020202020202020202020202020202020202020202020202020202020",
    "scene_key": "pd-scene-a7f3",
    "revision_id": "scene-rev-0007",
    "manifest_path": "production_design/spatial/scenes/pd-scene-a7f3/revisions/scene-rev-0007/manifest.v1.json",
    "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "scene_path": "production_design/spatial/scenes/pd-scene-a7f3/revisions/scene-rev-0007/scene.blend",
    "scene_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "resource_set_sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  },
  "camera": {
    "owner": "bible_inspection",
    "camera_id": "bible-inspect-northwest-v1",
    "source_review_camera": {
      "camera_id": "review-entrance",
      "camera_snapshot_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    },
    "snapshot": {
      "projection": "perspective",
      "world_transform_row_major": [1, 0, 0, 3, 0, 1, 0, -3.5, 0, 0, 1, 1.8, 0, 0, 0, 1],
      "sensor_fit": "horizontal",
      "sensor_width_mm": 36,
      "focal_length_mm": 40,
      "clip_start_meters": 0.1,
      "clip_end_meters": 1000,
      "path": [],
      "path_interpolation": "linear"
    },
    "camera_snapshot_sha256": "5050505050505050505050505050505050505050505050505050505050505050"
  },
  "state": {
    "kind": "scene_rest",
    "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "scene_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "evaluated_frame": 0
  },
  "time": {
    "kind": "evaluated_frame",
    "fps_numerator": 24,
    "fps_denominator": 1,
    "evaluated_frame": 0,
    "interpolation_contract": "scene-evaluated/v1"
  },
  "runtime": {
    "runtime_distribution_sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "python_version": "3.13.15",
    "bpy_version": "5.2.2",
    "worker_protocol": "ngv-spatial-worker/v1"
  },
  "renderer": {
    "renderer_contract_id": "example.clay-renderer/v1",
    "renderer_implementation_sha256": "6060606060606060606060606060606060606060606060606060606060606060",
    "settings_schema": "example.clay-render-settings/v1",
    "settings": {
      "quality_tier": "preview",
      "resolution_percentage": 100
    },
    "settings_sha256": "7070707070707070707070707070707070707070707070707070707070707070",
    "material_override": {
      "contract": "neutral-clay/v1",
      "base_color_linear_rgba": [0.55, 0.55, 0.55, 1],
      "roughness": 0.8,
      "metallic": 0
    },
    "material_override_sha256": "8080808080808080808080808080808080808080808080808080808080808080",
    "color_management": {
      "contract": "renderer-defined-color-management/v1",
      "values": {}
    },
    "color_management_sha256": "9090909090909090909090909090909090909090909090909090909090909090"
  },
  "outputs": [
    {
      "role": "clay_color",
      "path": "bible/spatial/loc-stage/clay-bible-loc-stage-v1/output.png",
      "sha256": "4040404040404040404040404040404040404040404040404040404040404040",
      "media_type": "image/png",
      "width": 1920,
      "height": 1080,
      "frame_count": 1
    }
  ],
  "host_validation": {
    "validator_contract": "spatial-derivation-validator/v1",
    "validated_at": "2026-09-24T10:05:00Z",
    "source_job_id": "spatial-job-0183"
  }
}
```

The renderer contract fields are deliberately abstract: #546 requires a registered implementation
hash and complete settings schema, not a guessed Blender engine/device combination. In particular,
the document does not claim that EEVEE exposes or used a CPU device. Integration replaces the
example renderer IDs/settings only with values established by the approved #545 implementation.
The runtime example reflects the current #541 pins, Python 3.13.15 and bpy 5.2.2; it does not approve
#541 or claim runtime evidence.

#### Discriminated variants

| Discriminator | Required | Forbidden |
|---|---|---|
| `purpose = bible_clay_still` | `semantic_role = composition_geometry`; `camera.owner = bible_inspection`; `state.kind = scene_rest`; `time.kind = evaluated_frame`; one image output | Shot/setup IDs, Shot List plan hashes, `state_ladder_*`, interval fields, video output |
| `purpose = bible_clay_panorama` | Same Bible camera/state/time variant; one equirectangular image output declared by the output contract | Same forbidden Shot List and interval fields |
| `purpose = shot_clay_still` | `semantic_role = composition_geometry`; `camera.owner = shotlist`; `state.kind = state_ladder`; current camera/shot/state hashes; one evaluated frame and image | Bible location carrier and `scene_rest` |
| `purpose = shot_clay_video` | `semantic_role = composition_geometry_motion`; Shot List camera/state; inclusive interval and exact rational sample sequence; video output | Bible location carrier and `scene_rest` |

For `camera.owner = bible_inspection`, `snapshot` and `camera_snapshot_sha256` are always required.
`source_review_camera` is permitted only when its referenced ID/hash exists in the bound manifest;
it records copied starting values and grants no ownership. Shot/setup fields and camera-plan hashes
are forbidden.

For `camera.owner = shotlist`, `shot_id`, `setup_id`, `camera_setup_plan_path/hash`, complete snapshot
and snapshot hash, and the named deterministic projection adapter are required. Bible
`source_review_camera` is forbidden.

For `state.kind = scene_rest`, `manifest_sha256`, exact `.blend` `scene_sha256`, and
`evaluated_frame` are required and must equal the manifest rest-state declaration. State Ladder
path/hash and entity-state IDs are forbidden. For `state.kind = state_ladder`, State Ladder
path/hash and exact ordered entity-state IDs are required and must resolve against the current Shot
List; `manifest_sha256`, `scene_sha256`, and the rest-frame field inside `state` are forbidden. The
proof's `scene` object still binds the current manifest and `.blend` in both variants.

No state field is optional. A proof whose discriminator-specific required/forbidden set is violated
fails before publication. A final camera snapshot is a deterministic projection of its named
current `CameraSetupPlanV1` entry, never an independently editable copy.

Depth, normal, and object-mask outputs require a separate versioned pass-settings contract declaring
units, range, coordinate space, normalization, and object-ID mapping. Their presence never implies
provider support.

### 4. Shot Clay bindings

Schema ID: `shot-clay-bindings/v1`. Path:
`execution/extensions/shot-clay-bindings.v1.json`.

```json
{
  "schema": "shot-clay-bindings/v1",
  "project_id": "example-project",
  "shotlist_path": "shotlist/v12.yaml",
  "shotlist_sha256": "8181818181818181818181818181818181818181818181818181818181818181",
  "bible_spatial_bindings_path": "bible/spatial-bindings.v1.json",
  "bible_spatial_bindings_sha256": "8282828282828282828282828282828282828282828282828282828282828282",
  "scene_index_path": "production_design/spatial/index.v1.json",
  "scene_index_sha256": "2020202020202020202020202020202020202020202020202020202020202020",
  "camera_setup_plan_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
  "shot_generation_cut_plan_sha256": "9999999999999999999999999999999999999999999999999999999999999999",
  "state_ladder_sha256": "3333333333333333333333333333333333333333333333333333333333333333",
  "bindings": [
    {
      "shot_id": "s014",
      "setup_id": "K03",
      "location_id": "loc-stage",
      "scene_key": "pd-scene-a7f3",
      "scene_revision_id": "scene-rev-0007",
      "scene_manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "derivation_proof_path": "execution/spatial-derivations/s014/clay-shot-s014-v1/proof.v1.json",
      "derivation_proof_sha256": "abababababababababababababababababababababababababababababababab",
      "output_role": "clay_color",
      "semantic_job_id": "core.composition-geometry-motion",
      "required": true
    }
  ]
}
```

Each binding resolves to one output in a `camera.owner = shotlist` proof. Sidecar, proof, plans, and
Shot List must name identical shot/setup/state identities. Its location must resolve through the
exact bound Bible spatial sidecar to the same `scene_key`, revision, and manifest hash, which must in
turn equal the entry in the exact bound current approved index bytes. Historical or merely existing
revisions are invalid. The sidecar is a new `PackArtifactExtensionReferenceV1`; no field is appended
to an existing public struct.

## Determinism and replay

A valid proof binds:

- the exact current scene index entry, manifest, `.blend`, and complete resource closure;
- the discriminator-valid camera snapshot/plan and state variant;
- the exact evaluated frame or time/sample sequence;
- exact runtime distribution, Python/bpy versions, registered renderer implementation, complete
  settings, Clay material, and color management;
- exact output bytes and host-validation receipt.

This is a complete origin/replay contract, not a claim that different hardware, drivers, renderers,
or codecs produce bit-identical output. Replay uses the recorded execution closure. A different
closure creates a new derivation ID/proof. Acceptance compares independently calculated geometry and
decoded media within declared tolerances; hashes always bind the exact bytes used downstream.

## Host sealing boundary

The worker receives only a read-only materialization of exact scene/resources, a job-local writable
staging directory, and a schema-validated envelope containing the expected project, scene-index or
base state, revision, camera, state, time, renderer contract, and output limits. It receives no
project package path, canonical pipeline write access, network, Keychain, provider/LLM credential,
prompt secret, gate state, or lineage authority.

The host applies these common bounds to every result:

1. job identity and immutable request bytes match the active host job;
2. all inputs and outputs are regular files under their allowed roots and independently hashed;
3. camera, state variant, evaluated frame/time, renderer contract/settings, dimensions, frame count,
   and codec match the request and decoded result where those fields apply;
4. no undeclared output or partial success exists; and
5. the canonical writer remains current and holds the project/phase mutation lease.

It then applies the rule for the candidate kind:

- A Production Design scene candidate is accepted only in the active, unapproved Production Design
  phase job. Its expected current base revision, or explicit expected absence for the first scene,
  must equal the current index state; its new manifest must declare the complete resource closure,
  and a clean untrusted, auto-execution-disabled scan must verify exactly that closure. The host
  performs the base compare-and-swap again immediately before the canonical index/revision write. A
  missing first index is therefore valid only when absence was expected; a stale concurrent base
  fails closed.
- A Bible or Shot List derivation candidate is accepted only when its bound scene-index bytes remain
  the approved current Production Design index, the named entry still equals its revision and
  manifest hash, and a clean auto-execution-disabled scan reports exactly that approved manifest's
  complete resource closure.

Only then may the writer copy bytes to canonical paths and encode the proof. A worker result is never
itself a proof. Cancellation, crash, reconnect, conflicting retry, stale index/revision, or failed
validation leaves only disposable staging.

## Phase capabilities

These tool names describe the contract; they do not authorize implementation.

| Capability | Kind | Production Design | Bible | Shot List | Paid provider | Canonical write |
|---|---|---:|---:|---:|---:|---:|
| `stage_spatial_scene` | supporting | Yes | No | No | No | Staging only |
| `inspect_spatial_scene` | supporting/read | Yes | Yes | Yes | No | No |
| `render_spatial_preview` | supporting/read | Yes | Yes | Yes | No | Cache only |
| `derive_clay_reference` | supporting | No | Yes | No | No | Sealed Recovery candidate only |
| `write_production_design` spatial payload | existing writer | Yes | — | — | Existing still rules only | Atomic |
| `write_bible` spatial payload | existing writer | — | Yes | — | Existing still rules only | Atomic |
| `write_shotlist` spatial payload | existing writer/internal local render | — | — | Yes | No | Atomic |

No spatial tool calls `generate_image`, `generate_video`, `run_provider_tool`,
`prepare_generation_batch`, or the Render runner.

### Packless generic projects

Core adds a `DefaultSpatialCapabilityTable` containing only the rows above, keyed by the three Core
roles and `coreGatePhases`. It does not grant, revoke, or reinterpret any other generic tool. It adds
no phase, card, intake step, required 3D artifact, or global default for existing tools.

For a packless project, the listed spatial entry points must not take the current early-return paths.
They resolve the role through `coreGatePhases`, load gates, prove the mapped phase is exactly current,
prove all prior phases approved/appraisable, enforce the table's phase-bound/supporting distinction,
and acquire the same project/phase job lease as pack writers. There is no generic intake manifest,
so there is no generic Track, Lyrics, Analysis, or other Hard Step to enforce.

### Pack projects

An exact pack version explicitly registers role-to-existing-phase mappings and adds only the desired
spatial tools to that phase's capability lists. Current-phase enforcement uses the resolved pack
order/capabilities. Intake enforcement considers only Hard Steps actually declared for that resolved
phase in that resolved pack manifest. Musicvideo therefore keeps its existing Track/Lyrics/Analysis
contract; none of those steps leak into generic projects.

If registration needs `EngineRegistry` storage, the new stored property is appended after the
current last property `frameReferencePlanProvider`. On the reviewed base, `EngineContract.current`
is 9 and `minimumCompatible` is 2; integration takes the next free value and retains 2 only after an
actual old-pack load test. No public value type receives a stored property.

## Bible provenance and planner boundary

The Bible gate has three evidence classes:

| Class | Carrier | Roles it may satisfy |
|---|---|---|
| `model_generation` | existing prompt/model/source/output proof | Existing declared generated roles |
| `confirmed_identity` | existing exact-byte host confirmation | Matching character/location identity |
| `spatial_derivation` | `bible-spatial-bindings/v1` plus current proof/output | `composition_geometry` only |

The gate rejects any path or identical bytes in multiple classes, arbitrary import, stale scene
binding, final proof presented as Bible proof, or Clay assigned appearance/identity/look purpose.
`PipelineAssetProof`, generated paths, confirmed identity, and panoramas remain unchanged.

The approved Shot List creates normal `AssetGraphV1` nodes for sealed Clay outputs. Existing
`AssetProvenanceV1` carries `kind_id = core.spatial-derivation` and an opaque source identity formed
from the bound `scene_key` plus revision; model/prompt fields remain absent. The appropriate Bible or
Shot binding sidecar supplies proof path/hash and is validated with the graph.

New semantic jobs are `core.composition-geometry` for Clay stills and
`core.composition-geometry-motion` for Clay video. The planner discovers them only through the typed
binding inventories, never by scanning `location.sheets` or `scene3d.panorama`. Identity and look
demands remain independently required.

`ReferencePlanV2` remains the only provider-reference planner. A selected Clay demand names a real
route slot/mode and becomes required. Unsupported combinations fail before spend rather than
downgrading modality, dropping Clay, or switching model/provider/strategy.

### Conditioning compatibility

| Existing source/strategy | Clay still | Clay video | Rule |
|---|---:|---:|---|
| Imported | No provider input | No provider input | Imported media remains production truth |
| AI-enhanced | No | No | Exact `source_path`-only contract remains |
| `reference_anchor` | Genuine image slot only | Genuine video slot only | Exact role combination must be executable |
| `two_state_interpolation` | Only if frames+references coexist | Only if route declares combination | Never replaces start/end states |
| explicit `first_frame` | Additional reference only | Independently supported only | Never replaces first-frame input |
| `frame_continuation` | No | No | Predecessor last frame remains sole start condition |
| `native_extension` | Only if in approved permitted-original set | Same | Never replaces predecessor video/mode |

A Clay video is never an AI-enhanced `source_path`, never changes `source_mode`, and never creates a
new conditioning strategy. Provider assembly preserves exact ordered bindings and roles.

## Mutation, rewind, and invalidation

| Changed input | Owner | Required rewind | Invalidated evidence |
|---|---|---|---|
| Scene geometry, object catalog/roles, resources, coordinate/time/rest contract, PD review camera, or current index revision | Production Design | `production_design` | Index/manifest consumers, Bible mappings/proofs/views, Shot spatial/Clay bindings, downstream plans/proofs |
| Bible location/entity mapping, Bible inspection snapshot, purpose/role, Clay output, or Clay settings | Bible | `bible` | Matching Bible inventory/proof/output and actual downstream dependents |
| Identity/look reference | Existing owning phase | That phase | Existing dependent plans/proofs; scene may remain current |
| Final setup, camera path, shot interval, State Ladder identity, or shot Clay role | Shot List | `shotlist` | Shot proof/binding and dependent execution/reference/compile/review/Frames/Render evidence |
| Selected provider/model/capability snapshot | Shot List planning contract | `shotlist` | Route/Reference Plan, compile/review/Render authorization |
| Canonical bytes at same path | No direct mutation | Rewind owning phase and republish | Hash failure invalidates all actual dependents |
| Worker staging or Cache preview | None | None | No canonical evidence existed |

There is no Shot List “scene revision selection.” Bible and Shot List bind only the exact current
approved PD index entry. A different revision is a Production Design change, requires a PD rewind,
and invalidates all downstream bindings to the old index/revision. Dependency edges determine actual
fan-out, but an unchanged filename or ID never preserves evidence after bytes change.

Approval, pending/needs-revision mutation, and rewind remain unavailable while the relevant host job
runs. Retry and reconnect join the same project/phase job.

## Pack, schema, and old-project compatibility

- Add new Core types only; add no stored property to an existing public value type.
- Carry execution additions through new `PackArtifactExtensionReferenceV1` entries.
- Append any `EngineRegistry` storage at the end of the class.
- Publish a Musicvideo pack version newer than reviewed 0.5.8 with explicit role mappings and
  capabilities. Choose the exact version at integration to avoid parallel-release collision.
- Retain `musicvideo/2.0.0` only while all new artifacts remain optional. Switching an existing
  project to the new pack version is explicit and transactional through a Recovery copy even when
  the project schema is unchanged; no spatial artifact is fabricated by that upgrade.
- Keep old exact pack versions installed/loadable. Their pinned projects see no new spatial tools or
  inferred geometry and keep existing Panorama, Generated, Identity, Blockout, imported,
  AI-enhanced, and conditioning behavior.

A new project schema and explicit Recovery-copy migration decision are required if implementation
makes any spatial artifact/mapping mandatory for open, save, approval, or execution. That is outside
this proposal. Presence of a file never opts a project into the contract; exact pack version/schema
binding and live host engine contract do.

## Smallest proposed locked-spec delta after approval

The six locked specs are unchanged on this branch.

### `docs/PIPELINE_AGENT_HARNESS.md` — required targeted delta

1. Add the four optional artifact families/five schemas to the three existing owner rows.
2. Add the canonical-writer, independent-gate, transaction, lineage, and current-index invariants.
3. Add the camera/state discriminators and required/forbidden fields; keep `BlockoutProofV1` intact.
4. Replace the Bible “two classes” invariant with the three-class table and forbid Clay paths/bytes
   in `location.sheets` and `scene3d.panorama`.
5. Add only the four new supporting spatial tools and three existing-writer spatial payloads.
   `write_shotlist` is the sole producer for final Clay and runs its worker internally in the
   existing host job/lease; add no Shot List supporting capability. For packless calls, require
   `coreGatePhases` current-phase guards without intake; for pack calls, enforce only resolved
   manifest Hard Steps/capabilities.
6. Add conditioning and release evidence for stale index/revision, invalid state/camera union,
   purpose collision, worker canonical write, phase bypass, and provider bytes differing from the
   approved Reference Plan.

### `docs/PLUGIN_STANDARD.md` — required targeted delta

Add the additive spatial role-registration boundary, three role meanings, existing-phase-only rule,
exact-pack capability declaration, and the no-fallback distinction between packed and generic
projects. Record the engine-contract bump and compatibility evidence. Add no `Pack` protocol
requirement and no public stored property.

### `docs/PRODUCTION_PROFILES.md` — required targeted delta

Under `generative_film`, allow optional sealed geometry anchors only through the new typed inventory.
State that Clay controls composition/geometry only, never identity/look, and Clay video eligibility is
a verified route-capability decision rather than profile doctrine.

### No text delta

- `docs/PROJECT_STORAGE.md`: existing package, Recovery, and pack-upgrade rules already apply.
- `docs/MUSICVIDEO_START_CONTRACT.md`: Track → optional Lyrics → Project Init → approved Analysis →
  optional existing material → story development remains unchanged; spatial work begins later.
- `docs/PATTERN_FIT_CONTRACT.md`: Clay is production machinery, not Pattern suitability evidence.

No new required phase, 3D obligation, intake card, or blanket generic-tool policy is proposed.

## Unapproved neighboring work

#559 / PR #577 is not adopted: this contract uses the current approved Shot List identity and phase
graph and reserves none of #559's proposed IDs. If #559 is later approved, its own contract must
transactionally preserve or rewrite exact Clay bindings; #546 needs no additional owner option now.

#533 is not adopted: spatial proofs expose read-only structural evidence but grant no final creative
review approval. If #533 is later approved, its own contract decides which current bindings a review
receipt covers; #546 needs no additional owner option now.

## End-to-end acceptance for later implementation

All executable evidence runs in GitHub Actions. No local build, test, app start, worker run, provider
probe, or CI dispatch is part of this proposal branch.

### Contract and storage

- Generic and Musicvideo fixtures use the same schemas but resolve capabilities through their
  distinct Core-default or exact-pack paths.
- A project with no 3D completes normally with no new phase/card/upload.
- Packless spatial tools fail outside the exact current `coreGatePhases` owner while generic projects
  receive no Musicvideo Track/Lyrics/Analysis intake obligations.
- Save, Save As, Recovery restore, machine move, Recovery-copy pack upgrade, and exact old-pack open
  preserve portable bytes and pin behavior.
- Escaped, symlinked, missing, changed, or incompletely declared scene/proof bytes fail before
  approval or provider spend.
- The actual old pinned pack is loaded against the new host; static symbol inspection is insufficient.

### Writer and referential integrity

- Production Design proves it never writes Bible IDs; Bible mapping proves every Bible ID and
  scene-local object ID independently.
- A first Production Design scene candidate succeeds with an explicitly absent base index; a stale
  or concurrently replaced base revision fails the final compare-and-swap before canonical write.
- Writer failure restores Bible plus inventory/proofs/outputs and Shot List plus bindings/proofs/
  outputs. Supporting tools cannot capture lineage or mutate canonical artifacts.
- Concurrent writes, retry, reconnect, cancellation, crash, and stale-index candidates prove one
  project/phase execution identity and no last-writer-wins loss.
- Concurrent or reconnected identical spatial `write_shotlist` calls join one host job; a different
  payload fails closed. The worker request and commit revalidate identical project-local index,
  camera plan, State Ladder, Shot List, and cut bytes; cancellation/crash preserves prior canonical
  bytes, previews cannot supply proof, and approval waits for transaction plus structural gate.
- A PD revision change requires a PD rewind; neither Bible nor Shot List can bind a historical or
  invalidated revision.

### Camera, state, and replay

- A Bible-created perspective changes only its own embedded/hash-bound camera snapshot. Optional PD
  review-camera source values remain immutable.
- Early proofs accept only `scene_rest` bound to exact manifest, `.blend`, and evaluated frame and
  reject every State Ladder field. Final proofs require `state_ladder` and reject rest-state fields.
- Still/video proofs bind exact camera, state, frame/time sequence, runtime, registered renderer
  contract/settings, and output bytes. Independent projection checks cover asymmetric geometry,
  occlusion, and parallax.
- Changed resource, camera, state, setting, or output bytes invalidate every recorded dependent.

### Provenance and provider boundary

- A full Bible fixture maps real Bible location/entity IDs to opaque scene/object IDs and accepts
  Clay only through `bible-spatial-bindings/v1` as `composition_geometry`.
- The same Clay path or bytes in `location.sheets`, `scene3d.panorama`, Generated, or Identity fail.
- Existing Generated, Identity, and Panorama fixtures retain unchanged behavior.
- Identity/look demands remain when Clay is selected; insufficient route capacity fails before spend.
- Provider adapter fixtures compare exact bytes/order/roles/slots/modes against `ReferencePlanV2` and
  prove every conditioning-matrix prohibition.
- The worker cannot reach provider/LLM credentials or the paid Render runner.

## Implementation boundary after approval

Implementation should extend the current canonical writers, lineage, execution composer,
production-input writer, `ReferencePlannerV2`, phase resolver, and independent gates. It must not
create a parallel scene engine, provider planner, prompt path, gate store, phase runner, or public
struct layout change.

#541 supplies no trusted runtime fact until reviewed code and Actions evidence prove the shipped
worker/resource boundary and real bpy output. #542 owns portable scene production; #543 agent spatial
tools; #544 native UI; #545 renderer/export. This proposal defines only their contract seams.
