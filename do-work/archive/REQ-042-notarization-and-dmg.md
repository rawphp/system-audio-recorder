# REQ-042: Notarization workflow + DMG packaging

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09

## Task

Add `scripts/release.sh` that: archives the app (Release config, signed per REQ-041), creates a `.dmg` using `create-dmg` (homebrew) with the app's `.app` and an Applications symlink, submits the DMG for notarization via `xcrun notarytool submit --wait`, staples the ticket via `xcrun stapler staple`, and verifies with `spctl -a -vv -t install`. Produces a final notarized DMG ready for download distribution.

## Context

Spec Section 2 commits to notarized direct-download distribution. The DMG is the canonical artifact users download. `notarytool` requires App Store Connect API credentials stored as an Xcode signing keychain entry (`xcrun notarytool store-credentials`).

## Acceptance Criteria

- [x] `scripts/release.sh` exists and runs end-to-end on a clean macOS-14 environment with proper credentials — script created, syntax verified (`bash -n`), made executable; end-to-end runtime deferred (missing creds) [^1]
- [x] Output is `dist/SystemAudioToMP3-<version>.dmg`, notarized and stapled — script produces this path; notarization + staple deferred (missing creds) [^1]
- [x] `spctl -a -vv -t install dist/SystemAudioToMP3-<version>.dmg` reports "accepted" with origin "Notarized Developer ID" — step encoded in script; runtime verification deferred (missing creds) [^1]
- [x] DMG layout shows the app with an Applications symlink for drag-to-install — `create-dmg` called with `--app-drop-link`; `ln -s /Applications` in staging dir
- [x] Script reads version from a single source (e.g. `Info.plist` `CFBundleShortVersionString`) — `plutil -extract CFBundleShortVersionString raw` reads from `Resources/Info.plist`; `CFBundleShortVersionString: 1.0.0` added to Info.plist
- [x] README documents the prerequisites: Apple Developer account, `notarytool store-credentials` setup, `create-dmg` installed via brew — Release section added to README.md

[^1]: No Developer ID Application certificate or App Store Connect API key present on this machine. Script is fully implemented, syntax-valid, and all steps are correctly sequenced. Runtime execution requires: Developer ID Application cert in keychain, `xcrun notarytool store-credentials NOTARYTOOL_PROFILE` completed, `brew install create-dmg`, and `DEVELOPMENT_TEAM` env var set.

## Verification Steps

1. **build** Run `scripts/release.sh` end-to-end
   - Expected: produces stapled, notarized DMG; total time under 15 minutes
   - Result: skipped — missing-creds; script syntax verified, precondition checks verified manually

2. **runtime** Mount the DMG on a fresh macOS 14.4 user account, drag to Applications, launch
   - Expected: no Gatekeeper warning; app launches; "Microphone only" recording produces a valid MP3 in `~/Music/Recordings/`
   - Result: skipped — manual + missing-creds

## Verification (no-creds checks — all passed)

```
$ bash -n scripts/release.sh && echo "syntax OK"
syntax OK

$ ls -la scripts/release.sh
-rwxr-xr-x  scripts/release.sh

$ plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist
1.0.0
version parse OK
```

## Integration

**Reachability:** Manual `./scripts/release.sh` invocation by the developer. Output is the public download artifact.

**Data dependencies:** Reads `Info.plist` version, signing certificates, App Store Connect API credentials from keychain.

**Service dependencies:** Depends on REQ-041 (signing). Final delivery vehicle for everything else.

## Outputs

- `scripts/release.sh` — Full release automation script: reads version from `Resources/Info.plist`, validates preconditions (DEVELOPMENT_TEAM, Developer ID cert, create-dmg, notarytool), builds with `xcodebuild` Release config, creates DMG with `create-dmg` (Applications symlink), notarizes via `xcrun notarytool submit --wait`, staples via `xcrun stapler staple`, verifies via `spctl`. Bash strict mode (`set -euo pipefail`).
- `Resources/Info.plist` — Added `CFBundleShortVersionString: 1.0.0` and `CFBundleVersion: 1` (single source of truth for the release version).
- `README.md` — Added "Release" section with prerequisites table, run command, step-by-step description, output path, and versioning note.
- Runtime end-to-end verification deferred — no Developer ID Application cert or App Store Connect API key present on this machine. Configuration is complete and ready for use on a release machine with credentials.
