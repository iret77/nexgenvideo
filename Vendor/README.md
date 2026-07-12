# Vendored binaries

## whisper.xcframework

whisper.cpp on-device speech recognition, used by the app's `AudioTranscribing`
implementation for the music-video forced-alignment pipeline.

- **Upstream:** https://github.com/ggml-org/whisper.cpp
- **Release:** `v1.9.1` — official `whisper-v1.9.1-xcframework.zip`
- **Slimmed here to:** the `macos-arm64_x86_64` slice only (the app is macOS/arm64
  only); iOS/tvOS/visionOS slices and dSYMs were dropped and `Info.plist` rewritten
  to match. Module name: `whisper` (`import whisper`). `install_name` is
  `@rpath/whisper.framework/Versions/Current/whisper`, resolved via the app's
  `@executable_path/../Frameworks` rpath once embedded by `scripts/bundle.sh`.

### Updating
Download the upstream `whisper-vX.Y.Z-xcframework.zip`, keep only the
`macos-arm64_x86_64` slice (drop `dSYMs`), rewrite `Info.plist` to list just that
library, and replace this directory. Bump the pinned version above.
