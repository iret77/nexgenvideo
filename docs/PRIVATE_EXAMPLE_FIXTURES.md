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
  "schema": "nexgenvideo.example-fixture-expectations/v1",
  "datasets": {
    "dataset_id": {
      "audio": {
        "path": "dataset_id/track.mp3",
        "duration_s": 199.26,
        "duration_tolerance_s": 0.5,
        "bpm": 150.0,
        "bpm_tolerance": 2.0,
        "expect_boundary_reduction": true
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
  ghcr.io/iret77/nexgenvideo-examples:fixtures-v1
```

The command prints the immutable `ghcr.io/...@sha256:...` reference. Its digest is stored as the
repository variable `NGV_EXAMPLE_FIXTURE_DIGEST`, so workflow dispatchers never copy or retype it.
The publisher stages only in a process-owned temporary directory and removes that directory on exit.
Before the first dispatch, both input and report packages must be provisioned out of band as private,
unlinked GHCR packages. This deliberate bootstrap prerequisite lets the source gate fail closed before
any macOS runner receives private data.

## Analysis run

`.github/workflows/private-example-analysis.yml` is manual-only. Before allocating a macOS runner it
requires the centrally configured exact fixture digest, validates the dataset id, verifies that both
private packages are unlinked, confirms that its dedicated package secret exists, and rejects the
current index or reachable repository history if any blob matches private fixture content. The Linux gate removes its
temporary media and registry credentials before the macOS job can start.

The macOS job then:

1. pulls and verifies the private fixture by digest;
2. bundles the real app and external `.ngvpack`;
3. runs the headless app self-test with AVFoundation and the pack's real analysis phase;
4. applies the pack's independent pre-interpretation gate;
5. checks the private duration/BPM expectations and raw-to-canonical boundary reduction; and
6. pushes `analysis.json` plus `provenance.json` to the private report package.

The provenance record links the result to the immutable fixture reference, tree and file digests,
loaded pack version and bundle-tree digest, commit, workflow run, measured summary, actual optional
audio-ML registration state, and gate outcome. It contains no runner-local source path.
No media, lyrics, analysis, or provenance file is uploaded as a public Actions artifact. The macOS
job removes its fixture, report, and registry-auth directories after publication or failure.
