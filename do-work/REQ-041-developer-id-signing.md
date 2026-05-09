# REQ-041: Developer ID signing configuration

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** supporting

## Task

Configure Developer ID Application signing for the Release configuration of the app target. Add a build phase or post-build script that runs `codesign --deep --options runtime --entitlements <entitlements> --sign "Developer ID Application: Tom Kaczocha (<TEAM_ID>)"` on the built `.app`. Verify with `codesign --verify --deep --strict --verbose=2 <built.app>`.

## Context

Spec Section 2 commits to notarized direct-download distribution. Notarization (REQ-042) requires the `.app` to be Developer ID signed with hardened runtime first.

## Acceptance Criteria

- [ ] Release-config build produces a signed `.app`
- [ ] `codesign --verify --deep --strict` returns exit 0 for the built app
- [ ] Hardened runtime is enabled (`--options runtime`)
- [ ] `codesign -d --entitlements - <built.app>` shows the same entitlement keys as `Resources/SystemAudioToMP3.entitlements` (REQ-004)
- [ ] Build setting `DEVELOPMENT_TEAM` resolves to a 10-character team ID; signed binary's team-id matches

## Verification Steps

1. **build** `xcodebuild -configuration Release archive`
   - Expected: archive succeeds, `.app` is signed
2. **runtime** `codesign -dvv <built.app>` shows Developer ID Application signature with team ID
   - Expected: signature valid

## Integration

**Reachability:** Code signing is invoked by `xcodebuild` during Release builds. Required for distribution.

**Data dependencies:** Reads Developer ID certificate from the Keychain.

**Service dependencies:** Foundation for REQ-042 (notarization). Depends on REQ-004 (entitlements file).
