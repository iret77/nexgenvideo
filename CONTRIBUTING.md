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
or run `scripts/dev.sh` locally. NexGenVideo targets macOS 26 on Apple Silicon,
and its authoritative verification runs only in GitHub Actions on `macos-26`.

## Verification

Pull requests run `.github/workflows/ci.yml`, which performs `swift build` and
`swift test`. Changes to the engine, pack, package graph, scripts, or plugin
metadata also run `.github/workflows/bundle.yml` to assemble and load-test the app
and `.ngvpack` bundle. Documentation-only pull requests do not consume a macOS
runner.

Releases, signing, notarization, and DMG assembly also run only in GitHub Actions.
Maintainers batch release work and dispatch it only with the owner's explicit
approval.

By contributing, you agree your contributions are licensed under [GPLv3](LICENSE).
