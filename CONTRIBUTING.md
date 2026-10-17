# Contributing

## How to contribute

The best way to contribute is to open a Github issue. Bug reports, feature requests, ideas are welcome.

With AI coding, human reviews are the bottleneck. We don't have the bandwidth to review large unsolicited PRs.

## Getting started

### Prerequisites
- A GitHub account
- A branch or fork of `iret77/nexgenvideo`

### Work on a change
```bash
git clone https://github.com/iret77/nexgenvideo
cd nexgenvideo
```

Keep changes focused and open a pull request. Do not build, test, launch the app,
or run `scripts/dev.sh` locally. NexGenVideo targets the latest macOS on Apple
Silicon, and its authoritative verification runs only in GitHub Actions. Builds,
unit tests, and bundles use the self-hosted `macrunner`; runtime acceptance uses
GitHub's `macos-26` runner, which boots the current product minimum.

## Verification

Pull requests run the Linux source checks in `.github/workflows/pr-checks.yml`.
The manually dispatched `.github/workflows/ci-batch.yml` runs compilation, unit
tests, app and external-pack loading, native UI acceptance, and real Music Video
audio-analysis acceptance. See [CI execution and measurement](docs/CI_EFFICIENCY.md)
for the selected checks and their evidence. Pull requests do not start macOS jobs.

Releases, signing, notarization, and DMG assembly also run only in GitHub Actions.
Maintainers batch release work and dispatch it only with the owner's explicit
approval.

By contributing, you agree your contributions are licensed under [GPLv3](LICENSE).
