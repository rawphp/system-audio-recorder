# REQ-042: Notarization workflow + DMG packaging

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** supporting

## Task

Add `scripts/release.sh` that: archives the app (Release config, signed per REQ-041), creates a `.dmg` using `create-dmg` (homebrew) with the app's `.app` and an Applications symlink, submits the DMG for notarization via `xcrun notarytool submit --wait`, staples the ticket via `xcrun stapler staple`, and verifies with `spctl -a -vv -t install`. Produces a final notarized DMG ready for download distribution.

## Context

Spec Section 2 commits to notarized direct-download distribution. The DMG is the canonical artifact users download. `notarytool` requires App Store Connect API credentials stored as an Xcode signing keychain entry (`xcrun notarytool store-credentials`).

## Acceptance Criteria

- [ ] `scripts/release.sh` exists and runs end-to-end on a clean macOS-14 environment with proper credentials
- [ ] Output is `dist/SystemAudioToMP3-<version>.dmg`, notarized and stapled
- [ ] `spctl -a -vv -t install dist/SystemAudioToMP3-<version>.dmg` reports "accepted" with origin "Notarized Developer ID"
- [ ] DMG layout shows the app with an Applications symlink for drag-to-install
- [ ] Script reads version from a single source (e.g. `Info.plist` `CFBundleShortVersionString`)
- [ ] README documents the prerequisites: Apple Developer account, `notarytool store-credentials` setup, `create-dmg` installed via brew

## Verification Steps

1. **build** Run `scripts/release.sh` end-to-end
   - Expected: produces stapled, notarized DMG; total time under 15 minutes
2. **runtime** Mount the DMG on a fresh macOS 14.4 user account, drag to Applications, launch
   - Expected: no Gatekeeper warning; app launches; "Microphone only" recording produces a valid MP3 in `~/Music/Recordings/`

## Integration

**Reachability:** Manual `./scripts/release.sh` invocation by the developer. Output is the public download artifact.

**Data dependencies:** Reads `Info.plist` version, signing certificates, App Store Connect API credentials from keychain.

**Service dependencies:** Depends on REQ-041 (signing). Final delivery vehicle for everything else.
