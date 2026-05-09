# REQ-005: GitHub Actions CI pipeline running unit + integration tests on macos-14 runner

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** supporting

## Task

Add `.github/workflows/ci.yml` that runs on push and pull request, on a `macos-14` GitHub Actions runner. The workflow checks out the repo, runs `xcodebuild build` (test once REQ-036 lands), and fails the build on any failure.

## Context

Spec Section 7 commits to GitHub Actions CI on macos-14 running unit + integration tests on every push. Layer 3 (manual hardware tests) is gated by a release checklist, not CI.

## Acceptance Criteria

- [x] `.github/workflows/ci.yml` exists and triggers on `push` and `pull_request`
- [x] Workflow uses `runs-on: macos-14`
- [x] Workflow runs `xcodebuild build -project SystemAudioToMP3.xcodeproj -scheme SystemAudioToMP3 -destination 'platform=macOS'` (test command documented in comment; switches to `xcodebuild test` once REQ-036 lands)
- [x] Workflow caches `~/Library/Developer/Xcode/DerivedData` to speed up incremental runs
- [ ] A red-test commit (deliberately failing test pushed to a throwaway branch, then reverted) makes the workflow fail — **DEFERRED — requires GitHub remote + REQ-036**

## Verification Steps

1. **build** Push the workflow file to a branch and observe the GitHub Actions run
   - Expected: workflow runs to completion, all current tests pass, status check is green
   - **DEFERRED — requires GitHub remote**
2. **test** Push a deliberately failing test on a throwaway branch
   - Expected: workflow status is red; revert the commit before merging
   - **DEFERRED — requires GitHub remote + REQ-036**

## Integration

**Reachability:** Triggered by GitHub on every push/PR. Visible in the GitHub PR UI as a status check.

**Data dependencies:** Reads test results from `xcodebuild` output.

**Service dependencies:** Depends on REQ-001 (Xcode project), REQ-003 (LAME vendored — needed for tests that touch encoder).
