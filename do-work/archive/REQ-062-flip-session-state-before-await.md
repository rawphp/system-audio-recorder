# REQ-062: Flip sessionState synchronously before async session transitions

**UR:** UR-011
**Status:** done
**Created:** 2026-05-11
**Layer:** supporting

## Task

In `App/AppStore.swift`, fix `stopRecording()`, `pauseRecording()`, and `resumeRecording()` so they update `sessionState` (and, for stop, null `currentSession`) **before** awaiting the underlying `RecordingSession` call. This matches the pattern `startRecording()` already follows and the class docstring already prescribes (lines 178-180): *"`sessionState` is updated before the underlying `RecordingSession` work completes so SwiftUI bindings flip immediately on user action."*

## Context

The user reports having to click the Stop button twice for it to fire. Root cause traced to `App/AppStore.swift:399-427`: `stopRecording()` awaits `session.stop()` (which drains emitters, normalizers, the writer task — can take seconds) **before** flipping `sessionState` to `.idle`. While the await is pending, the UI continues to show the Recording controls. The user clicks Stop again because nothing visibly happened; the second click feels like it fires, but is really the first click's stop finally completing.

`pauseRecording()` (lines 385-389) and `resumeRecording()` (lines 392-396) have the same await-before-flip ordering. The wall-clock impact is currently small (pause/resume on `RecordingSession` is fast), but fixing all three keeps the class consistent with its own documented pattern and prevents future regression.

The corresponding session-actor methods are already safe for early state flipping: `RecordingSession.stop()` is idempotent (line 591) and sets its internal `state = .stopped` synchronously on entry; pause/resume use proper transition guards.

## Acceptance Criteria

- [x] `AppStore.stopRecording()` sets `sessionState = .stopped` and `currentSession = nil` **before** `await session.stop()`; the existing `.idle` flip after the await is removed (`.stopped` collapses to idle controls via `RecordControlsViewModel.update`).
- [x] `AppStore.pauseRecording()` sets `sessionState = .paused` **before** `await session.pause()`.
- [x] `AppStore.resumeRecording()` sets `sessionState = .recording` **before** `await session.resume()`.
- [x] If the underlying `session.pause()` or `session.resume()` call throws, the state is rolled back to the prior `sessionState` and the error is surfaced via `errorSurface` (mirrors the existing `startRecording()` rollback pattern at lines 346-351).
- [x] A new test in `Tests/AudioEngineTests/AppStoreTests.swift` proves that immediately after a `stopRecording()` call begins (before it returns), `appStore.sessionState != .recording`. Use a stub `RecordingSession` whose `stop()` blocks on a continuation so the test can observe the synchronous state flip.
- [x] Equivalent synchronous-flip tests cover `pauseRecording()` and `resumeRecording()`.
- [x] Existing `AppStoreTests` continue to pass without modification (no behavioural regression in the start path, error-routing path, or encoding handoff path).

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** `xcodebuild test -scheme SystemAudioRecorder -only-testing:SystemAudioRecorderTests/AppStoreTests`
   - Expected: all existing AppStore tests pass; the three new synchronous-flip tests (stop, pause, resume) pass.
2. **test** `xcodebuild test -scheme SystemAudioRecorder -only-testing:SystemAudioRecorderTests/RecordControlsViewTests`
   - Expected: all RecordControlsView tests pass — confirms the view model still maps `.stopped → idle controls` correctly.
3. **build** `xcodebuild -scheme SystemAudioRecorder -configuration Debug build`
   - Expected: zero errors, zero warnings.
4. **runtime** Launch the app, start a recording (any source preset), let it run for ~5 seconds, click Stop **once**.
   - Expected: the Stop/Pause control surface collapses to the "Start Recording" idle button within ~150 ms of the click (the existing easeInOut animation). MP3 encoding continues in the background and the existing `SaveToast` shows the saved file path on completion.
5. **runtime** Start a recording, click Pause once, then Resume once, then Stop once. Each click should produce an immediate visible state change in the controls.
   - Expected: no double-clicks required for any transition.

## Assets

(none)

## Outputs

- App/AppStore.swift — fixed stopRecording/pauseRecording/resumeRecording to flip sessionState before await; added rollback on pause/resume failure
- Tests/AudioEngineTests/AppStoreTests.swift — added BlockingFakeEmitter, BlockingStubSessionConfigBuilder, makeBlockingAppStore helper, and 3 synchronous-flip tests
