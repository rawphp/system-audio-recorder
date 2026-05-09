# REQ-025: RecordControlsView — start/pause/stop button morphing

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/RecordControlsView.swift`. Single component that morphs based on `AppStore.currentSession?.state`:
- **idle**: large "● Start Recording" button
- **recording**: side-by-side "⏸ Pause" + "■ Stop" buttons + elapsed time HH:MM:SS below
- **paused**: side-by-side "▶ Resume" + "■ Stop" + elapsed time

Buttons call `AppStore.startRecording`, `pauseRecording`, `resumeRecording`, `stopRecording`.

## Context

Spec Section 4.1 (idle layout) and Section 4.3 (recording layout). Pause/resume per Section 5.5.

## Acceptance Criteria

- [x] Idle state shows one big record button; pressing it starts a session with `AppSettings.lastSourcePreset`
- [x] Recording state shows pause + stop, plus elapsed time updating every second
- [x] Paused state shows resume + stop; elapsed time stops updating
- [x] State transitions animate (~150 ms) for visual continuity
- [x] Starting a recording without permissions surfaces the permission prompt via `RecordingSession`'s entry path

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
   - Result: `make build` → **BUILD SUCCEEDED**
2. **ui** Launch app, click Start, wait 3 s, click Pause, wait 2 s, click Resume, click Stop; take snapshots after each transition
   - Expected: snapshots match spec Sections 4.1, 4.3, and the paused variant; elapsed time freezes during pause and resumes counting
   - Result: **skipped — manual** (no automated UI snapshot harness in this project)

## Integration

**Reachability:** Embedded in `ContentView` (REQ-023). Mirror controls also live in the menu bar status item (REQ-031).

**Data dependencies:** Binds to `AppStore.currentSession?.state` and `AppStore.currentSession?.elapsedTime`.

**Service dependencies:** Calls `AppStore` action methods (REQ-022).

## Outputs

- `App/Views/RecordControlsView.swift` — `RecordControlsState` enum (`idle | recording(elapsed:) | paused(elapsed:)`, `Equatable`, `Sendable`); `RecordControlsViewModel` (`@Observable @MainActor` class) with injected action closures (`startAction`, `pauseAction`, `resumeAction`, `stopAction`), injected `sessionStateProvider` and `clock: () -> Date` for deterministic testing; `update(sessionState:)` maps `SessionState` → `RecordControlsState` with elapsed-time accounting (segment start + accumulated paused time); `tick()` advances elapsed time while recording; `formatElapsed(_:) -> String` static HH:MM:SS formatter. `RecordControlsView` (`public struct`) wires `appStore` via `@Environment(\.appStore)`, builds `RecordControlsViewModel` lazily in `.task`, reacts to `appStore.sessionState` changes via `.onChange`, renders idle/recording/paused layouts, drives 1 Hz `Timer.publish` ticks, and applies `.animation(.easeInOut(duration: 0.15), value: vm.controlsState)`.
- `App/Views/ContentView.swift` — Replaced inline `RecordControlsView` stub with wiring to the real `RecordControlsView()` from `App/Views/RecordControlsView.swift`.
- `Tests/AudioEngineTests/RecordControlsViewTests.swift` — 14 unit tests in `RecordControlsViewModelTests` using `FakeControlsAppStore` test double and injected clock closure: `testInitialControlsStateIsIdle`, `testRecordingStateProducesRecordingControlsState`, `testElapsedTimeAdvancesOnTick`, `testPausedStateFreezesClock`, `testResumeAccumulatesElapsedTime`, `testStopResetsToIdle`, `testStartCallsStartAction`, `testPauseCallsPauseAction`, `testResumeCallsResumeAction`, `testStopCallsStopAction`, `testControlsStateEquality`, `testElapsedTimeFormatting`, `testStoppedStateBecomesIdle`, `testFailedStateBecomesIdle`. All 14 pass. Full suite: all 18 test suites pass.
