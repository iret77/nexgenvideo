# Seedance 2.5 integration decision

Status: approved contract change for Issue #306 on 2026-08-14.

The owner explicitly approved the locked-contract changes for Issue #306 on 2026-08-14. The approved
change replaces the Seedance 15-second code assumption with versioned capability data and keeps
executable provider parameters in the host model catalog.

## Authority split

- `catalog/models.json` is authoritative per model ID for remotely refreshed executable model
  capabilities, pricing, and provider offers.
- `FalModelRegistry` is the offline fallback and owns fal request dialects that cannot be expressed by
  the generic catalog.
- `MusicvideoPack/model-capabilities.json` is the pack-versioned, fail-closed projection used only by
  deterministic pipeline sanity checks. Its aliases cover fal endpoint IDs and Higgsfield
  `seedance_2_5`; it does not advertise or dispatch a model.

## Approved observable behavior

- Video duration supports discrete values, inclusive ranges, and automatic selection.
- Seedance 2.5 accepts `auto` or 4–30 seconds and advertises only 480p/720p.
- fal text-to-video, image-to-video, and reference-to-video endpoints are available. Image-to-video
  accepts a required start frame and optional end frame. Reference mode accepts up to 30 images, 10
  videos, and 10 audio inputs, capped at 50 total.
- A 30-second Seedance 2.5 shot is valid in musicvideo Sanity; limits are read from capability data.

Build, release, and live generation remain separately authorized actions and are not approved here.
