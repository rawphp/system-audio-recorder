# REQ-015: Auto-stop on silence

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Add `autoStopSilenceSeconds: TimeInterval?` to `SessionConfig`. Implement a separate `installTap` on the mix node that computes a 200 ms RMS window. If the window stays below −60 dBFS for `autoStopSilenceSeconds` consecutive seconds, call `RecordingSession.stop()` from the main queue. Skip silence detection during the first 2 seconds of a session (to avoid stopping before any audio arrives).

## Context

Spec Section 5.6 specifies the silence detector: 200 ms RMS window, −60 dBFS threshold, default 30 s silence threshold, 2 s startup grace period.

## Acceptance Criteria

- [ ] Default threshold of −60 dBFS and 30 s window matches spec
- [ ] Silence detector ignores the first 2 s of recording
- [ ] When a -70 dBFS noise floor is fed for the threshold duration after the grace period, session stops
- [ ] When audio above -60 dBFS is mixed in at any point, the silence counter resets
- [ ] Detector runs on the audio thread but issues `stop()` on the main queue
- [ ] `autoStopSilenceSeconds: nil` (default) means the tap is not installed

## Verification Steps

1. **test** Integration test with `autoStopSilenceSeconds = 1.0` feeds silent buffers from t = 2 s onwards; asserts session stops at t = 3.0 s ± 0.1 s
   - Expected: test passes
2. **test** Integration test feeds intermittent audio (1 s on / 0.9 s off / 1 s on); asserts session does NOT stop because each silent gap is below threshold
   - Expected: test passes

## Integration

**Reachability:** UI control in spec Section 4.6 (auto-stop toggle inside source dropdown's expanded view).

**Data dependencies:** Reads `autoStopSilenceSeconds` from `UserDefaults` (REQ-021).

**Service dependencies:** Extends `RecordingSession` (REQ-013), taps `MixerGraph` mix node (REQ-010).
