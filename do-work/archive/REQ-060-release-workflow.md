# REQ-060: GitHub Actions release workflow on tag push

**UR:** UR-009
**Status:** done
**Created:** 2026-05-10
**Layer:** none

## Task

Add a GitHub Actions workflow at `.github/workflows/release.yml` that triggers on a version tag push (`v*`), builds + signs + notarises a DMG via `scripts/release.sh`, and uploads the resulting DMG as a GitHub Release asset. The workflow consumes signing/notarisation material from encrypted repository secrets — no certs, keys, or App Store Connect credentials are committed to the repo.

This REQ does not change `scripts/release.sh` itself. The workflow shells out to the existing script.

## Context

`scripts/release.sh` already builds, signs, notarises, staples, and verifies the DMG locally — it depends on a Developer ID Application certificate in the keychain, an `xcrun notarytool store-credentials NOTARYTOOL_PROFILE` keychain entry, and `DEVELOPMENT_TEAM` in the environment. The workflow's job is to recreate this environment in a fresh GitHub-hosted runner using secrets, then run the script.

The standard Apple-on-CI pattern uses [`apple-actions/import-codesign-certs`](https://github.com/apple-actions/import-codesign-certs) to import a base64-encoded `.p12` into a temporary keychain, then `xcrun notarytool store-credentials` (or `--apple-id` / `--team-id` / `--password` flags directly) for notarisation auth.

Required repository secrets (documented in the workflow file's top comment so they're discoverable):

| Secret | Source |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | `base64 < cert.p12` of the exported Developer ID Application cert |
| `DEVELOPER_ID_CERT_PASSWORD` | The export password set when generating the .p12 |
| `KEYCHAIN_PASSWORD` | Any random string — used to lock the temporary CI keychain |
| `APPLE_ID` | The Apple ID email used for notarisation |
| `APPLE_TEAM_ID` | 10-character team ID (also used as `DEVELOPMENT_TEAM`) |
| `APPLE_APP_SPECIFIC_PASSWORD` | An app-specific password for notarisation |

The workflow should also `actions/setup-xcode` (or pin to a known-working macOS-14 runner that has Xcode 15.3+ pre-installed), `brew install xcodegen create-dmg`, and surface `scripts/release.sh`'s output verbatim on failure.

## Acceptance Criteria

- [x] `.github/workflows/release.yml` exists and is committed
- [x] Workflow triggers on `push` to tags matching `v*` (e.g. `v1.0.0`)
- [x] Workflow runs on `macos-14` (or newer) runner
- [x] Workflow installs `xcodegen` and `create-dmg` via Homebrew
- [x] Workflow imports the Developer ID certificate from `DEVELOPER_ID_CERT_P12_BASE64` and `DEVELOPER_ID_CERT_PASSWORD` into a temporary keychain (using `apple-actions/import-codesign-certs@v3` or equivalent)
- [x] Workflow stores notarisation credentials via `xcrun notarytool store-credentials NOTARYTOOL_PROFILE` using `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`
- [x] Workflow exports `DEVELOPMENT_TEAM=$APPLE_TEAM_ID` before invoking `scripts/release.sh`
- [x] Workflow runs `scripts/release.sh` and fails the job on non-zero exit
- [x] Workflow uploads `dist/SystemAudioRecorder-*.dmg` as an asset on a GitHub Release named after the tag (using `softprops/action-gh-release@v2` or equivalent)
- [x] Top of the YAML includes a comment block listing all required repository secrets
- [x] No certificates, passwords, profiles, or Apple IDs appear in the YAML — every sensitive value is read from `secrets.*`

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **build** `yamllint .github/workflows/release.yml` (or `actionlint`)
   - Expected: zero errors. If neither tool is installed, at minimum `python -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"` parses without error.
2. **runtime** `grep -E 'secrets\.(DEVELOPER_ID_CERT_P12_BASE64|DEVELOPER_ID_CERT_PASSWORD|KEYCHAIN_PASSWORD|APPLE_ID|APPLE_TEAM_ID|APPLE_APP_SPECIFIC_PASSWORD)' .github/workflows/release.yml | wc -l`
   - Expected: `>= 6` (every required secret is referenced)
3. **runtime** `grep -E '(BEGIN CERTIFICATE|BEGIN ENCRYPTED PRIVATE KEY|-----BEGIN|password.*:.*[A-Za-z0-9])' .github/workflows/release.yml`
   - Expected: no output (no leaked credentials in YAML)
4. **runtime** `grep -E "on:.*push.*tags.*'v\\*'|tags:" .github/workflows/release.yml`
   - Expected: at least one match (tag trigger configured)
5. **runtime** `grep 'scripts/release.sh' .github/workflows/release.yml`
   - Expected: at least one match (workflow invokes the existing release script)

> Note: full end-to-end CI verification (running the workflow on GitHub against a real tag) is out of scope for this REQ. The user runs that manually after the workflow + secrets are in place. Acceptance here is "workflow file is correct and parseable"; the first real `git tag v0.1.0 && git push --tags` will exercise it.

## Outputs

- .github/workflows/release.yml — release workflow triggered on v* tag push
