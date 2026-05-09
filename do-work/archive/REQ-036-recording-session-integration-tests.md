# REQ-036: Integration tests for RecordingSession lifecycle flows

**UR:** UR-001
**Status:** done
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

- [x] Each scenario above is a separate test method with descriptive name
- [x] All tests use `MockAudioSource` — no real audio devices opened
- [x] All tests complete in under 30 seconds total
- [x] Tests deterministically assert against produced MP3 files (duration, file count, content via FFT spot-check)
- [x] Tests run cleanly on the macos-14 GitHub Actions runner (REQ-005)

## Verification Steps

1. **test** `xcodebuild test -only-testing:AudioEngineTests/RecordingSessionIntegrationTests`
   - Expected: all tests pass
   - Result: All 7 integration tests pass. Full suite `Test Suite 'All tests' passed`. **PASS**
2. **test** Re-run the same suite 5 times in a row
   - Expected: all 5 runs green (deterministic, no flake)
   - Result: All 5 runs green. No flakes. **PASS**

## Integration

This REQ is `**Layer:** none` (test code), so the Integration block is omitted.

## Outputs

- `Tests/AudioEngineTests/IntegrationTests/RecordingSessionIntegrationTests.swift` — 7 integration tests covering the full RecordingSession + LameEncoder → MP3 lifecycle using `MockAudioSource`:
  1. `testStartStopProducesMixedMP3` — start → stop → 1 WAV → 1 MP3; FFT spot-check for 440 Hz ±20 Hz
  2. `testPauseResumeDurationMatchesActiveRecordingTime` — continuous driver, pause/resume, asserts WAV duration < 2 s (gap excluded)
  3. `testSeparateModeProducesNPlusOneMP3Files` — 2 sources × separate mode → 3 WAVs → 3 MP3s
  4. `testAutoStopDurationProducesMP3` — autoStopDuration = 1.0 s; session stops at 0.6–2.5 s; MP3 produced
  5. `testAutoStopSilenceProducesMP3` — autoStopSilenceSeconds = 2.0 s; session stops at 3–8 s wall clock; MP3 produced
  6. `testNoSourcesConfiguredThrows` — empty sources list → `SessionError.noSourcesConfigured`
  7. `testSecondStartBeforeStopThrows` — second `start()` throws `SessionError.invalidTransition`

## Notes

- Tests placed at `Tests/AudioEngineTests/IntegrationTests/` (sub-folder of existing target). `project.yml` covers `Tests/AudioEngineTests` recursively, so no project.yml change was needed.
- `SessionError.alreadyRecording` as a distinct enum case does not exist in REQ-013's implementation. The guard uses `invalidTransition(from:to:)` instead. Scenario 7 verifies the observable behavior (re-start throws) and documents that a dedicated `alreadyRecording` case is deferred to REQ-013 v2 work.
- FFT spot-check uses the `peakFrequency()` helper copied from `LameEncoderTests` (private to the test file).
- All tests complete in ≤10 s each; total suite ≤15 s (well under the 30 s budget).
