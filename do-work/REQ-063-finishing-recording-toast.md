# REQ-063: Show "Finishing recording…" transient toast during stop-tail

**UR:** UR-011
**Status:** backlog
**Created:** 2026-05-11
**Layer:** ui

## Task

Once REQ-062 flips `sessionState` to `.stopped` synchronously, the record controls collapse to the idle layout instantly — but `await session.stop()` (writer drain + WAV finalize) is still running in the background. Add a transient "Finishing recording…" toast that appears at the click instant and disappears when `session.stop()` returns. Reuse the existing `SaveToast` infrastructure (`App/Views/SaveToast.swift`) by adding a new state to `ToastState` so the toast container in `ContentView` (lines 166-220) already renders it.

## Context

**Depends on:** REQ-062 (this REQ requires `AppStore.isFinishingRecording` to be exposed and to flip synchronously around `await session.stop()`, which is added as part of REQ-062's restructured stop/pause/resume path).

UR-011 clarification: the user opted for a "transient toast" over no feedback or a disabled Start button. Reasoning: instant control collapse with no feedback would leave the user uncertain whether the file is actually being saved; the toast spans the small but real window between Stop click and writer finalize, then hands off to the existing `.encoding → .saved` toast progression already wired to `EncodingQueue`. Connector observation from ideate: `SaveToast` already implements the toast lifecycle pattern with `ToastState` and `SaveToastViewModel`; adding a new case is materially smaller than building a parallel toast.

Implementation outline (the implementer may adapt):

- Add `ToastState.finishingRecording` to `App/Views/SaveToast.swift:30-50`.
- `AppStore.stopRecording()` exposes a signal (e.g. an `@Observable` boolean `isFinishingRecording` set to `true` immediately before `await session.stop()` and `false` immediately after). `SaveToastViewModel` observes this signal (in addition to the encoding queue) and shows `.finishingRecording` while it is `true`. When it flips back to `false` the toast either hides or hands off to the next state driven by the encoding queue (`.encoding`).
- `SaveToast` body renders the new state as a spinner + "Finishing recording…" text, using the same visual idiom as the existing `.encoding` state.

## Acceptance Criteria

- [ ] `ToastState` gains a `finishingRecording` case; the existing `==` implementation handles it.
- [ ] `AppStore` exposes an observable signal (e.g. `isFinishingRecording: Bool`) that flips `true` synchronously when `stopRecording()` begins and `false` after `await session.stop()` returns, regardless of whether the stop succeeded or threw.
- [ ] `SaveToastViewModel` toast appears with "Finishing recording…" text and a progress spinner while the signal is `true`. The toast appears within ~50 ms of the Stop click (i.e. before any encoding job exists in the queue).
- [ ] When the signal flips back to `false`, the toast either hides immediately (if no encoding job is running) or transitions to the existing `.encoding` state (if at least one job is in `running`). This avoids a flicker between states.
- [ ] No auto-dismiss timer fires while in `.finishingRecording` — the state is purely signal-driven.
- [ ] If `session.stop()` produces no files (failure path), the `.finishingRecording` toast disappears and the existing `.failed` toast path (when the encoding queue emits a failure) or no toast (when no job is enqueued) takes over. The user is never left with a stuck "Finishing…" toast.
- [ ] Snapshot/UI test in `Tests/AudioEngineTests/SaveToastViewModelTests.swift` (or the existing equivalent) covers the new state transitions.

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** `xcodebuild test -scheme SystemAudioRecorder -only-testing:SystemAudioRecorderTests/SaveToastViewModelTests`
   - Expected: all existing tests pass plus the new transitions (`hidden → finishingRecording → hidden` and `hidden → finishingRecording → encoding → saved`).
2. **build** `xcodebuild -scheme SystemAudioRecorder -configuration Debug build`
   - Expected: zero errors, zero warnings.
3. **ui** Launch the app, start a recording, let it run for ~5 seconds, click Stop once.
   - Expected: the "Finishing recording…" toast appears immediately at the bottom of the window (within ~150 ms), persists briefly while writer/finalize completes, then hands off to the existing "Encoding…" → "Saved to …" toast progression.
4. **ui** Take a screenshot of the running app immediately after Stop is clicked.
   - Expected: the screenshot shows the idle Start Recording button AND the "Finishing recording…" toast simultaneously. (Confirms REQ-062's synchronous control collapse + REQ-063's toast both fire on a single click.)
5. **runtime** Repeat the start-stop cycle 5 times in quick succession.
   - Expected: no flicker, no stuck toast, no double "Finishing…" toasts. Each cycle transitions cleanly.

## Integration

**Reachability:** Triggered automatically by `AppStore.stopRecording()` (`App/AppStore.swift:399`) via a new `isFinishingRecording` observable property. Rendered by `SaveToast` in `App/Views/ContentView.swift:166-220`, which is already overlaid at the bottom of the main window and observes `SaveToastViewModel`. No new nav entry, route, or user-driven entry point — the toast is a side-effect of the existing Stop action.

**Data dependencies:** Reads the new `AppStore.isFinishingRecording: Bool` (added by this REQ). Continues to read `EncodingQueue.pending/running/completed/failed` via the existing `EncodingQueueObservable` protocol in `App/Views/SaveToast.swift:8-26` for the handoff to the `.encoding` state. The existing `SaveToastViewModel.activeJobID` (`App/Views/SaveToast.swift:85`) gating logic is unchanged.

**Service dependencies:** Extends `ToastState` (`App/Views/SaveToast.swift:30-50`) with a new case. Extends `SaveToastViewModel` (`App/Views/SaveToast.swift:68+`) with an observation hook for the new signal — either via the existing `handleQueueChange()` entry point reused or a parallel `handleFinishingChange()` method invoked from `ContentView`'s observation block (lines 213-220). No new module or service; pure extension of the existing toast subsystem.

## Assets

(none)
