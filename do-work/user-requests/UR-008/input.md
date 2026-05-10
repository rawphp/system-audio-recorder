---
ur: UR-008
received: 2026-05-10
status: captured
classification: bug-fix
layers_in_scope: []
layer_decisions: {}
reqs:
  - { id: REQ-058, layer: none, integration_confidence: n/a }
acknowledged_partials: []
---

<!-- capture-summary-start -->
## Capture summary (2026-05-10)

| Item | Value |
|---|---|
| Classification | bug-fix |
| Layers in scope | (none — bug-fix) |
| Layer decisions | (none — bug-fix) |
| REQs generated | 1 |

| REQ | Layer | Integration confidence |
|---|---|---|
| REQ-058 | none | n/a |
<!-- capture-summary-end -->

# UR-008: User Request

## Request

Toast not shown on stop - fix it

(Surfaced during UR-006 documentation work. While attempting to capture a screenshot of the post-Stop SaveToast for the user guide, the user observed that the toast does NOT appear when a recording is stopped. REQ-027 originally implemented the post-stop toast; something has regressed or is conditionally suppressing it. Tracked as a separate UR — fix is out of scope for UR-006 docs.)

(Likely related: `testSilenceDetectorResetsOnPause` in `Tests/AudioEngineTests/RecordingSessionTests.swift:836` fails with `invalidTransition(from: SystemAudioRecorder.SessionState.stopped, to: SystemAudioRecorder.SessionState.paused)`. Both symptoms point at the stop transition — the recording session may be entering an unexpected state on stop, which would explain both the missing toast and the invalid pause-after-stop transition. When capturing this UR, investigate them as one bug, not two.)

## Investigation note (2026-05-10)

After inspection, the toast bug and the failing silence-detector test are NOT the same bug:

- **Toast bug — root cause identified.** `App/Views/SaveToast.swift:328-333` — `observeQueue()` calls `withObservationTracking` on `vm.toastState` (the toast's own state property). It should track the encoding queue's `running`, `completed`, and `failed` arrays. Worse: when the tracker does fire, the loop just yields — it never calls `handleQueueChange()`. The observer is wired to the wrong property AND has no action on change. Result: queue mutations never reach the view model, toast never transitions out of `.hidden`.
- **Silence-detector test failure — separate concern.** Race between the test's hardcoded silence-push timing and the grace-period restart logic. Out of scope for this UR; track separately if it persists.

UR-008 scope: fix the toast observer wiring only.
