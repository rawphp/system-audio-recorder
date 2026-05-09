# REQ-025: RecordControlsView — start/pause/stop button morphing

**UR:** UR-001
**Status:** backlog
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

- [ ] Idle state shows one big record button; pressing it starts a session with `AppSettings.lastSourcePreset`
- [ ] Recording state shows pause + stop, plus elapsed time updating every second
- [ ] Paused state shows resume + stop; elapsed time stops updating
- [ ] State transitions animate (~150 ms) for visual continuity
- [ ] Starting a recording without permissions surfaces the permission prompt via `RecordingSession`'s entry path

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
2. **ui** Launch app, click Start, wait 3 s, click Pause, wait 2 s, click Resume, click Stop; take snapshots after each transition
   - Expected: snapshots match spec Sections 4.1, 4.3, and the paused variant; elapsed time freezes during pause and resumes counting

## Integration

**Reachability:** Embedded in `ContentView` (REQ-023). Mirror controls also live in the menu bar status item (REQ-031).

**Data dependencies:** Binds to `AppStore.currentSession?.state` and `AppStore.currentSession?.elapsedTime`.

**Service dependencies:** Calls `AppStore` action methods (REQ-022).
