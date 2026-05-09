# System Audio to MP3

A signed, notarized macOS app that records system audio (and optionally microphone) to MP3 with no virtual audio devices and no driver installs. Requires macOS 14.4+ (Sonoma).

## What It Does

- Records per-process system audio via Core Audio Tap (`AudioHardwareCreateProcessTap`) — no BlackHole, no Soundflower.
- Optionally mixes in microphone input.
- Encodes to MP3 using bundled libmp3lame on a background queue after Stop.
- Ships as a Developer ID-signed, notarized DMG.

## Build

```sh
make build
```

Requires Xcode 15.3+ and the `xcodegen` CLI (`brew install xcodegen`). The Makefile runs `xcodegen generate` then `xcodebuild`.

## Run Tests (CI / Unit + Integration)

```sh
make test
```

Runs the Xcode test suite. Unit and integration tests run headlessly. Manual tests require physical hardware — see [docs/manual-tests.md](docs/manual-tests.md).

## Documentation

- **Design spec**: [docs/superpowers/specs/2026-05-09-system-audio-to-mp3-design.md](docs/superpowers/specs/2026-05-09-system-audio-to-mp3-design.md)
- **Manual test plan**: [docs/manual-tests.md](docs/manual-tests.md)
