# REQ-005: GitHub Actions CI pipeline running unit + integration tests on macos-14 runner

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** supporting

## Task

Add `.github/workflows/ci.yml` that runs on push and pull request, on a `macos-14` GitHub Actions runner. The workflow checks out the repo, runs `xcodebuild test` against the AudioEngineTests and IntegrationTests test plans, and fails the build on any test failure.

## Context

Spec Section 7 commits to GitHub Actions CI on macos-14 running unit + integration tests on every push. Layer 3 (manual hardware tests) is gated by a release checklist, not CI.

## Acceptance Criteria

- [ ] `.github/workflows/ci.yml` exists and triggers on `push` and `pull_request`
- [ ] Workflow uses `runs-on: macos-14`
- [ ] Workflow runs `xcodebuild test -project SystemAudioToMP3.xcodeproj -scheme SystemAudioToMP3 -destination 'platform=macOS'`
- [ ] Workflow caches `~/Library/Developer/Xcode/DerivedData` to speed up incremental runs
- [ ] A red-test commit (deliberately failing test pushed to a throwaway branch, then reverted) makes the workflow fail

## Verification Steps

1. **build** Push the workflow file to a branch and observe the GitHub Actions run
   - Expected: workflow runs to completion, all current tests pass, status check is green
2. **test** Push a deliberately failing test on a throwaway branch
   - Expected: workflow status is red; revert the commit before merging

## Integration

**Reachability:** Triggered by GitHub on every push/PR. Visible in the GitHub PR UI as a status check.

**Data dependencies:** Reads test results from `xcodebuild` output.

**Service dependencies:** Depends on REQ-001 (Xcode project), REQ-003 (LAME vendored — needed for tests that touch encoder).
