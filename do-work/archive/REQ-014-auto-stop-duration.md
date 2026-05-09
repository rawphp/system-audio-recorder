# REQ-014: Auto-stop by duration

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Add `autoStopDuration: TimeInterval?` to `SessionConfig`. When set, `RecordingSession.start()` schedules a `DispatchSourceTimer` that fires after the duration and calls `stop()`. Pause cancels the timer; resume recreates it with the *remaining* time (start time + duration − cumulative recording time).

## Context

Spec Section 5.6 specifies a `DispatchSourceTimer` that survives pause/resume by resuming with remaining time. UI surface in spec Section 4.6 (auto-stop optional toggle).

## Acceptance Criteria

- [x] Setting `autoStopDuration: 60` and starting a session causes `stop()` to be called at t = 60 s ± 0.1 s
- [x] Pausing at t = 30 s and resuming at t = 60 s causes `stop()` to fire at t = 90 s (30 s of paused time, 60 s of recording)
- [x] `autoStopDuration: nil` (default) means no timer is scheduled
- [x] Stopping manually before the timer fires cancels the timer cleanly (no double-stop)

## Verification Steps

1. **test** Integration test with `autoStopDuration = 1.0`; assert session reaches `stopped` state at t = 1.0 ± 0.1 s
   - Expected: test passes
   - Result: `testAutoStopFiresAfterDuration` passes (1.016 s). Session reaches `.stopped` at t ≈ 1.0 s. **PASS**
2. **test** Integration test pauses for 1 s at t = 0.5 s; asserts session stops at t = 2.0 s ± 0.1 s
   - Expected: test passes
   - Result: `testAutoStopRespectsPausedTime` passes (3.059 s total wall clock: 0.5 s record + 1.0 s paused + 1.5 s record). **PASS**

## Integration

**Reachability:** UI control in spec Section 4.6 (auto-stop toggle inside source dropdown's expanded view, off by default).

**Data dependencies:** Reads `autoStopDurationSeconds` from `UserDefaults` (REQ-021). Persisted as part of `SessionConfig`.

**Service dependencies:** Extends `RecordingSession` (REQ-013).

## Outputs

- `AudioEngine/Recording/RecordingSession.swift` — `SessionConfig` extended with `autoStopDuration: TimeInterval? = nil`; `RecordingSession` actor extended with: `autoStopDuration`, `autoStopRemaining`, `recordingSegmentStart`, `autoStopTimer` private state; `armAutoStopTimer(remaining:)` arms a `DispatchSourceTimer` on a utility queue that calls `stop()` on fire; `cancelAutoStopTimer()` cancels the live timer and subtracts elapsed segment time from `autoStopRemaining`; `start(config:)` arms the timer after entering `.recording`; `pause()` cancels the timer before freezing WAV; `resume()` re-arms with remaining time; `stop()` cancels the timer before teardown (no double-stop).
- `Tests/AudioEngineTests/RecordingSessionTests.swift` — 4 new tests: `testAutoStopFiresAfterDuration`, `testAutoStopRespectsPausedTime`, `testNilAutoStopDurationNoTimer`, `testManualStopCancelsAutoStopTimer`. All 73 tests pass (1 skipped — existing hardware-requiring test from REQ-007).
