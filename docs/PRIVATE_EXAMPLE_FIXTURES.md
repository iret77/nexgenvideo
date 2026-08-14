# Private example fixtures

Real MP3, lyrics, and image examples are test inputs, not repository assets. They remain in the
owner-managed `examples` directory and are published directly from there into the private, unlinked
OCI package `ghcr.io/iret77/nexgenvideo-examples`. Analysis output goes only to the separate private,
unlinked package `ghcr.io/iret77/nexgenvideo-analysis-reports`.

## Data contract

`scripts/example_fixture_bundle.py` creates two OCI layers outside the repository:

- `examples.tar.gz` contains every regular file below each dataset directory.
- `fixtures.manifest.json` records every relative path, media kind, byte size, SHA-256 digest, the
  complete tree digest, and independent audio expectations.

The builder rejects root-level files, duplicate paths, multiple tracks per dataset, multiple lyrics
files per dataset, symlinks, and special files. Extraction rejects path traversal and verifies the
complete tree before the app receives a path. The archive is deterministic.
Before publication, the publisher also hashes size-matched tracked repository files and refuses to
push if any private fixture content has been staged under any name. The CI source gate repeats that
check and scans every reachable blob in the repository's full history.

Independent expectations are supplied from a private JSON file when the bundle is published:

```json
{
  "schema": "nexgenvideo.example-fixture-expectations/v3",
  "datasets": {
    "dataset_id": {
      "audio": {
        "path": "dataset_id/track.mp3",
        "duration_s": 180.0,
        "duration_tolerance_s": 0.5,
        "bpm": 120.0,
        "bpm_tolerance": 2.0,
        "expect_boundary_reduction": true,
        "section_boundaries_s": [24.0, 64.0, 104.0],
        "section_labels": [null, "verse1", "chorus", "verse2"],
        "section_boundary_tolerance_s": 4.0
      }
    }
  }
}
```

The expectations file is private fixture metadata and must not be committed.

## Publication

Input publication is explicit and local to the host that can read the owner-managed directory. A
classic GitHub Packages token with `read:packages` and `write:packages` is read from a file; it is
never passed as an argument or stored by ORAS. `ORAS_BIN` may point at a checksum-verified temporary
ORAS binary.

```bash
NGV_GHCR_TOKEN_FILE=/secure/token-file \
NGV_FIXTURE_EXPECTATIONS_FILE=/private/fixture-expectations.json \
scripts/publish_example_fixtures.sh \
  /owner-managed/examples \
  ghcr.io/iret77/nexgenvideo-examples:fixtures-v3
```

The command prints the immutable `ghcr.io/...@sha256:...` reference. Its digest is stored as the
repository variable `NGV_EXAMPLE_FIXTURE_DIGEST`, so workflow dispatchers never copy or retype it.
The publisher stages only in a process-owned temporary directory and removes that directory on exit.
Before the first dispatch, both input and report packages must be provisioned out of band as private,
unlinked GHCR packages. This deliberate bootstrap prerequisite lets the source gate fail closed before
any macOS runner receives private data.

## Analysis run

`.github/workflows/private-example-analysis.yml` is manual-only. Before allocating a macOS runner it
uses a Linux source gate that requires the centrally configured exact fixture digest, validates the
dataset id, verifies that both
private packages are unlinked, confirms that its dedicated package secret exists, and rejects the
current index or reachable repository history if any blob matches private fixture content. It removes
its temporary media and registry credentials before the macOS job can start.

The `xcode-27` build job first bundles the app and external pack without access to private fixture
data, wraps both in a one-day runtime-harness artifact that preserves executable modes and framework
symlinks, and transfers that artifact to the pinned GitHub-hosted macOS 26 runner. The runtime job then:

1. verifies the booted macOS version before downloading any artifact or private data;
2. restores the prebuilt app and external `.ngvpack` with their runtime layout intact;
3. pulls and verifies the private fixture by digest;
4. configures the exact production audio runtime and runs the headless app self-test through the
   external pack's real analysis phase;
5. applies the pack's independent pre-interpretation gate;
6. checks duration, BPM, boundary reduction, and every ordered section boundary and label against
   private, independently produced expectations; and
7. always pushes `provenance.json`, plus `analysis.json` and the runner-owned measurement proof
   whenever available, to the private report package.

Successful provenance links the result to the immutable fixture reference, tree and file digests,
loaded pack version and bundle-tree digest, commit, workflow run, measured summary, actual optional
audio-ML registration state, alignment timing evidence and method, boundary-evidence kinds, and gate outcome.
The gate also verifies the runner-owned measurement proof that binds the exact track, lyrics,
alignment source, attention-DTW method, anchor counts, and canonical alignment bytes before accepting
known-text timing. The source used for that measurement remains part of the phase's exact-byte lineage.
Failure provenance records the exact private error and
every identity known at that stage; a partial canonical artifact is retained beside it when available.
Neither record contains a runner-local source path on a successful acceptance path.
The app writes a redacted success summary and a redacted failure message. Full comparisons remain in
the private report package. Workflow logs never print private expectations, fixture paths, source
names, lyrics, labels, hashes, or media content.
No media, lyrics, analysis, or provenance file is uploaded as a public Actions artifact. The macOS
job removes its fixture, report, and registry-auth directories after publication or failure.

The acceptance run requires macOS 26 exactly and verifies `sw_vers` before downloading private data.
This proves the shipping neural beat, stem, transcription, harmony, and evidence-resolution path.
The dormant Music Understanding adapter is compiled with the macOS 27 SDK but is intentionally not
activated by this production-floor test.
