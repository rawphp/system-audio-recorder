# Ideate — UR-011

**Reviewed:** 2026-05-11

## Explorer — Assumptions & Perspectives

- **The user is reporting symptom, not cause.** "Click twice to fire" likely means the first click DOES initiate the stop, but the UI gives no immediate feedback — so the user clicks again. The visible state change that arrives after the second click is really the first click's stop completing. Triggered by: `App/AppStore.swift:399-427` where `sessionState = .idle` is set AFTER `await session.stop()` returns (which drains emitters, normalizers, the writer task — can take seconds).

- **`startRecording` and `stopRecording` use opposite ordering.** `startRecording` (line 339-341) flips `sessionState = .recording` BEFORE awaiting `session.start()`, exactly as the class docstring (line 178-180) prescribes: *"`sessionState` is updated before the underlying `RecordingSession` work completes so SwiftUI bindings flip immediately on user action."* `stopRecording` violates this rule — UI doesn't flip until after the long await. The asymmetry is the bug.

- **There is no `.stopping` transient state.** `SessionState` has `.idle, .recording, .paused, .stopped, .failed`. The view model collapses `.idle, .stopped, .failed` to the idle controls. So flipping to `.stopped` immediately is a one-line fix that hides the controls instantly — no new state needed.

## Challenger — Risks & Edge Cases

- **Double-tap during the stop await must remain safe.** If we flip state synchronously to `.stopped`, a second tap's `stopRecording()` guard (`sessionState == .recording || .paused || .failed`) fails and returns. Good — but verify the guard still handles re-entrancy correctly. The `currentSession` is still non-nil during the await; only the *state check* protects us. Triggered by: line 399-404.

- **Failure during `session.stop()` leaves state as `.stopped`.** If the writer throws or URLs return empty, current code never reaches the line that sets `.idle`. Optimistically setting `.stopped` early means a failed stop also lands at `.stopped`, then the user can start a new recording (guard accepts `.stopped`). Acceptable but worth checking the failure path doesn't strand `currentSession` non-nil.

- **The same pattern affects `pauseRecording`/`resumeRecording`.** Both await `session.pause()/.resume()` BEFORE flipping `sessionState` (lines 385-389, 392-396). User likely hasn't noticed because pause/resume on this codebase are fast (no writer drain), but the same UI-lag bug exists in principle. Scope decision needed: fix only Stop, or fix all three for consistency.

- **The `_dispatch` of the Task inside the Button might also amplify perception.** SwiftUI Button → `Task { await vm.stop() }` → `await store.stopRecording()` → `await session.stop()` — three async hops before any state change. Even with the fix, the wall-clock delay from tap to UI flip should be < 100 ms; verify on real hardware.

## Connector — Links & Reuse

- **The docstring at `App/AppStore.swift:178-180` is the authoritative pattern.** The fix is literally "follow the rule the class already documents." No new abstraction needed — just reorder two lines in `stopRecording`.

- **`RecordControlsViewModel.update(sessionState:)` already handles the transition cleanly.** When `sessionState` flips to `.stopped`, the view collapses to the `.idle` controls layout, animated by `.animation(.easeInOut(duration: 0.15), value: vm.controlsState)` — the existing 150 ms animation will mask the brief async tail.

- **Existing test surface to extend:** `Tests/AudioEngineTests/AppStoreTests.swift` and `Tests/AudioEngineTests/RecordControlsViewTests.swift` already exercise the state machine. A regression test should assert `appStore.sessionState != .recording` synchronously after `stopRecording` enters (or via a paused/awaiting checkpoint), proving the state flips before the work completes.

## Summary

The bug is a UI-feedback lag: `AppStore.stopRecording` awaits the entire session teardown before updating `sessionState`, so the Stop button appears unresponsive until the stop finishes. The fix is a one-line reorder — flip `sessionState` to `.stopped` (and null `currentSession`) BEFORE `await session.stop()`, mirroring how `startRecording` already works (per its own class docstring). Scope question for capture: also apply the same fix to `pauseRecording`/`resumeRecording` for consistency, or keep the change tight to Stop?
