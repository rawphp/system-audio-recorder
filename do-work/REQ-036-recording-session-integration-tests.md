# REQ-036: Integration tests for RecordingSession lifecycle flows

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** none

## Task

Write `Tests/IntegrationTests/RecordingSessionTests.swift` covering full lifecycle flows using `MockAudioSource` (REQ-035):
- start → stop produces one valid mixed MP3
- start → pause → resume → stop produces one continuous MP3 with paused gap removed
- start with separate-output mode produces N+1 MP3 files
- start with auto-stop duration ends at the configured duration
- start with auto-stop silence ends after silence threshold
- start with no permissions throws expected error path
- starting a second session before first stops throws `SessionError.alreadyRecording`

## Context

Spec Section 7 lists integration tests as the second of three test layers. These tests run in CI on every push (REQ-005).

## Acceptance Criteria

- [ ] Each scenario above is a separate test method with descriptive name
- [ ] All tests use `MockAudioSource` — no real audio devices opened
- [ ] All tests complete in under 30 seconds total
- [ ] Tests deterministically assert against produced MP3 files (duration, file count, content via FFT spot-check)
- [ ] Tests run cleanly on the macos-14 GitHub Actions runner (REQ-005)

## Verification Steps

1. **test** `xcodebuild test -only-testing:IntegrationTests/RecordingSessionTests`
   - Expected: all tests pass
2. **test** Re-run the same suite 5 times in a row
   - Expected: all 5 runs green (deterministic, no flake)

## Integration

This REQ is `**Layer:** none` (test code), so the Integration block is omitted.
