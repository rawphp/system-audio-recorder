# System Audio Recorder

System Audio Recorder is macOS app that records system audio (and optionally microphone) to MP3 — no virtual audio devices, no driver installs. Requires macOS 14.4+ (Sonoma).

## Download

Grab the latest signed, notarized DMG from the [Releases page](https://github.com/rawphp/system-audio-recorder/releases/latest).

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

## Release

Produces a notarized, stapled DMG for direct-download distribution.

### Prerequisites

| Requirement | How to satisfy |
|---|---|
| Apple Developer account with **Developer ID Application** certificate | Install via Xcode → Settings → Accounts |
| App Store Connect API key stored in keychain | `xcrun notarytool store-credentials NOTARYTOOL_PROFILE` (run once) |
| `create-dmg` | `brew install create-dmg` |
| `DEVELOPMENT_TEAM` env var | Your 10-character Apple team ID |

### Run

```sh
DEVELOPMENT_TEAM=XXXXXXXXXX scripts/release.sh
```

The script will:
1. Build the app in Release configuration (Developer ID-signed, hardened runtime).
2. Create a DMG (`dist/SystemAudioRecorder-<version>.dmg`) with an Applications symlink for drag-to-install.
3. Submit the DMG to Apple for notarization and wait for approval.
4. Staple the notarization ticket to the DMG.
5. Verify with `spctl -a -vv -t install`.

### Output

```
dist/SystemAudioRecorder-<version>.dmg   # notarized, stapled, Gatekeeper-accepted
```

The version is read from `Resources/Info.plist` (`CFBundleShortVersionString`). Bump that key before releasing a new version.

### Signing reference

See [docs/release-signing.md](docs/release-signing.md) for certificate installation, CI setup, and troubleshooting.

## Documentation

- **Design spec**: [docs/superpowers/specs/2026-05-09-system-audio-to-mp3-design.md](docs/superpowers/specs/2026-05-09-system-audio-to-mp3-design.md)
- **Manual test plan**: [docs/manual-tests.md](docs/manual-tests.md)
- **Signing guide**: [docs/release-signing.md](docs/release-signing.md)
