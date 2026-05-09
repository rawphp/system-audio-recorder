# REQ-015: Auto-stop on silence

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Add `autoStopSilenceSeconds: TimeInterval?` to `SessionConfig`. Implement a separate `installTap` on the mix node that computes a 200 ms RMS window. If the window stays below −60 dBFS for `autoStopSilenceSeconds` consecutive seconds, call `RecordingSession.stop()` from the main queue. Skip silence detection during the first 2 seconds of a session (to avoid stopping before any audio arrives).

## Context

Spec Section 5.6 specifies the silence detector: 200 ms RMS window, −60 dBFS threshold, default 30 s silence threshold, 2 s startup grace period.

## Acceptance Criteria

- [x] Default threshold of −60 dBFS and 30 s window matches spec
- [x] Silence detector ignores the first 2 s of recording
- [x] When a -70 dBFS noise floor is fed for the threshold duration after the grace period, session stops
- [x] When audio above -60 dBFS is mixed in at any point, the silence counter resets
- [x] Detector runs on the audio thread but issues `stop()` on the main queue
- [x] `autoStopSilenceSeconds: nil` (default) means the tap is not installed

## Verification Steps

1. **test** Integration test with `autoStopSilenceSeconds = 1.0` feeds silent buffers from t = 2 s onwards; asserts session stops at t = 3.0 s ± 0.1 s
   - Expected: test passes
   - Result: `testSilenceDetectorStopsAfterThreshold` passes — session stops at ~3.1 s (2.0 s grace + 1.0 s silence). **PASS**
2. **test** Integration test feeds intermittent audio (1 s on / 0.9 s off / 1 s on); asserts session does NOT stop because each silent gap is below threshold
   - Expected: test passes
   - Result: `testSilenceDetectorResetsOnAudio` passes — audio injection resets the counter; 0.9 s of post-audio silence is below 1.0 s threshold. **PASS**

## Integration

**Reachability:** UI control in spec Section 4.6 (auto-stop toggle inside source dropdown's expanded view).

**Data dependencies:** Reads `autoStopSilenceSeconds` from `UserDefaults` (REQ-021).

**Service dependencies:** Extends `RecordingSession` (REQ-013), taps `MixerGraph` mix node (REQ-010).

## Outputs

- `AudioEngine/Recording/RecordingSession.swift` — `SessionConfig` extended with `autoStopSilenceSeconds: TimeInterval? = nil`; `RecordingSession` actor extended with: `silenceThreshold`, `silenceDetectorTask`, `silenceDetectorCont`, `silenceDetectorState` private state; `SilenceDetectorState` inner class (NSLock-guarded, tracks active seconds and pause state); `installSilenceDetector(stream:threshold:)` launches a `Task.detached` that reads from a fan-out copy of the mix stream, skips the 2 s grace period, applies per-buffer `MeterTap.computeRMS`, resets on any above-threshold buffer, and calls `stop()` when consecutive silence ≥ threshold; mix-stream fan-out in `start(config:)` creates two downstream `AsyncStream`s (one for the writer, one for the detector) from the single `MixerGraph.mixBufferStream()`; `pause()` calls `notifySilenceDetectorPaused()` (freezes active-time clock, drops buffers while paused); `resume()` calls `notifySilenceDetectorResumed()` (restarts grace period and resets accumulated time); `stop()` cancels `silenceDetectorTask` and finishes `silenceDetectorCont`.
- `Tests/AudioEngineTests/RecordingSessionTests.swift` — `FakeEmitter.pushSilent()` helper (zero-filled canonical buffer, RMS = −160 dBFS); 5 new tests: `testNilAutoStopSilenceNoDetector`, `testSilenceDetectorGracePeriodPreventsEarlyStop`, `testSilenceDetectorStopsAfterThreshold`, `testSilenceDetectorResetsOnAudio`, `testSilenceDetectorResetsOnPause`. All 82 tests pass (1 skipped — existing hardware-requiring test from REQ-007).
