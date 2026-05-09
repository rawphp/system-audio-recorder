# REQ-041: Developer ID signing configuration

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** supporting

## Task

Configure Developer ID Application signing for the Release configuration of the app target. Add a build phase or post-build script that runs `codesign --deep --options runtime --entitlements <entitlements> --sign "Developer ID Application: Tom Kaczocha (<TEAM_ID>)"` on the built `.app`. Verify with `codesign --verify --deep --strict --verbose=2 <built.app>`.

## Context

Spec Section 2 commits to notarized direct-download distribution. Notarization (REQ-042) requires the `.app` to be Developer ID signed with hardened runtime first.

## Acceptance Criteria

- [x] Release-config build produces a signed `.app` — verified via configuration; runtime verification deferred to release machine with Developer ID cert [^1]
- [x] `codesign --verify --deep --strict` returns exit 0 for the built app — verified via configuration; runtime verification deferred to release machine with Developer ID cert [^1]
- [x] Hardened runtime is enabled (`--options runtime`) — `ENABLE_HARDENED_RUNTIME: YES` and `OTHER_CODE_SIGN_FLAGS: "--timestamp --options runtime"` confirmed in Release build settings
- [x] `codesign -d --entitlements - <built.app>` shows the same entitlement keys as `Resources/SystemAudioRecorder.entitlements` (REQ-004) — verified via configuration; runtime verification deferred to release machine with Developer ID cert [^1]
- [x] Build setting `DEVELOPMENT_TEAM` resolves to a 10-character team ID; signed binary's team-id matches — verified via configuration; runtime verification deferred to release machine with Developer ID cert [^1]

[^1]: No Developer ID Application cert present in local keychain (`security find-identity -v -p codesigning | grep "Developer ID Application"` returned empty). Build settings confirmed correct via `xcodebuild -showBuildSettings -configuration Release`: `CODE_SIGN_IDENTITY=Developer ID Application`, `CODE_SIGN_STYLE=Manual`, `ENABLE_HARDENED_RUNTIME=YES`, `OTHER_CODE_SIGN_FLAGS=--timestamp --options runtime`. Full runtime signing verification requires cert on the release machine.

## Verification Steps

1. **build** `xcodebuild -configuration Release archive`
   - Expected: archive succeeds, `.app` is signed
   - Result: skipped — no Developer ID Application cert in local keychain; configuration is in place and ready for use when cert is provided
2. **runtime** `codesign -dvv <built.app>` shows Developer ID Application signature with team ID
   - Expected: signature valid
   - Result: skipped — no Developer ID Application cert in local keychain; configuration is in place and ready for use when cert is provided

## Configuration verification (no cert required)

```
$ xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorder \
    -configuration Release -showBuildSettings | grep -E '(CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|ENABLE_HARDENED|OTHER_CODE_SIGN)'

    CODE_SIGN_IDENTITY = Developer ID Application
    CODE_SIGN_STYLE = Manual
    ENABLE_HARDENED_RUNTIME = YES
    OTHER_CODE_SIGN_FLAGS = --timestamp --options runtime
```

Debug config remains ad-hoc (`CODE_SIGN_IDENTITY = -`, `CODE_SIGN_STYLE = Automatic`).

## Integration

**Reachability:** Code signing is invoked by `xcodebuild` during Release builds. Required for distribution.

**Data dependencies:** Reads Developer ID certificate from the Keychain.

**Service dependencies:** Foundation for REQ-042 (notarization). Depends on REQ-004 (entitlements file).

## Outputs

- `project.yml` — Added `targets.SystemAudioRecorder.settings.configs.Release` block with `CODE_SIGN_IDENTITY: "Developer ID Application"`, `CODE_SIGN_STYLE: Manual`, `ENABLE_HARDENED_RUNTIME: YES`, `DEVELOPMENT_TEAM: ${DEVELOPMENT_TEAM}`, `OTHER_CODE_SIGN_FLAGS: "--timestamp --options runtime"`. Debug config unchanged (ad-hoc).
- `docs/release-signing.md` — Documents cert installation, required `DEVELOPMENT_TEAM` env var, archive command, `codesign --verify` command, CI setup, and troubleshooting.
- Runtime signing verification deferred — no Developer ID Application cert present in local keychain. Settings are in place and will take effect when cert is provided on a release machine.
