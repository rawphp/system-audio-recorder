---
ur: UR-008
received: 2026-05-10
status: intake
---

# UR-008: User Request

## Request

Toast not shown on stop - fix it

(Surfaced during UR-006 documentation work. While attempting to capture a screenshot of the post-Stop SaveToast for the user guide, the user observed that the toast does NOT appear when a recording is stopped. REQ-027 originally implemented the post-stop toast; something has regressed or is conditionally suppressing it. Tracked as a separate UR — fix is out of scope for UR-006 docs.)

(Likely related: `testSilenceDetectorResetsOnPause` in `Tests/AudioEngineTests/RecordingSessionTests.swift:836` fails with `invalidTransition(from: SystemAudioRecorder.SessionState.stopped, to: SystemAudioRecorder.SessionState.paused)`. Both symptoms point at the stop transition — the recording session may be entering an unexpected state on stop, which would explain both the missing toast and the invalid pause-after-stop transition. When capturing this UR, investigate them as one bug, not two.)
