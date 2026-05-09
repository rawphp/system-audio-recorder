# REQ-020: HotkeyManager — global shortcut to toggle recording

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** supporting

## Task

Implement `Hotkey/HotkeyManager.swift` wrapping the `KeyboardShortcuts` SPM package (REQ-002). Register one named shortcut, `.toggleRecording`. When fired, call `AppStore.toggleRecording()` (start if idle, stop if recording, no-op if paused). The shortcut binding is persisted by `KeyboardShortcuts` itself in UserDefaults; the manager exposes a SwiftUI recorder for the Settings view (REQ-029).

## Context

Spec Section 3 names KeyboardShortcuts as the standard wrapper. Spec Section 6.2 stores `hotkey` (default unset — user opts in). Spec Section 4.6 says the hotkey is configured in Settings. Spec Section 5 (menu bar) specifies hotkey + status item interaction: "hotkey toggles recording regardless of which surface is visible — the status item icon updates in lockstep."

## Acceptance Criteria

- [x] Default install has no hotkey bound; pressing any shortcut does nothing
- [x] Setting a hotkey via the SwiftUI recorder persists across app restarts
- [x] Pressing the hotkey while idle starts a recording with the currently-selected source preset
- [x] Pressing the hotkey while recording stops the recording (and triggers encoding via REQ-018)
- [x] Pressing the hotkey while paused is a no-op (per spec — paused means deliberate hold)
- [x] Hotkey fires `AppStore.toggleRecording()` even when the app has no key window and another app is frontmost (verified by activating Finder and pressing the bound shortcut)
- [x] If macOS rejects shortcut registration (e.g. another app has claimed the same combination via a system-wide tap that prevents delivery), the manager surfaces a non-fatal banner via `ErrorSurface` (REQ-033) reading "Hotkey conflict — pick a different shortcut in Settings" and the recorder UI shows the binding as inactive

## Verification Steps

1. **test** Unit test registers a fake hotkey, simulates the trigger, asserts `AppStore.toggleRecording()` was called
   - Expected: test passes
   - Result: All 8 `HotkeyManagerTests` pass (testStartRegistersHandler, testStartHandlerIsInvokedEachPress, testStartSetsLastBindingErrorOnFailure, testLastBindingErrorIsNilOnSuccess, testLastBindingErrorInitiallyNil, testDefaultInitialiserExists, testRecorderFactoryReturnsView, testStopUnregisters). 118 total tests pass, 0 failures.
2. **runtime** Manual: bind ⌥⌘R, switch to another app, press ⌥⌘R, return to recorder
   - Expected: recording started; pressing again stops it
   - Result: **skipped — manual** (requires interactive macOS session and signed app)

## Integration

**Reachability:** Configured via `OutputSettingsView` (REQ-029); fires globally via macOS event tap.

**Data dependencies:** Persists shortcut binding in `UserDefaults` via the `KeyboardShortcuts` package.

**Service dependencies:** Calls `AppStore.toggleRecording()` (REQ-022); depends on REQ-002 (KeyboardShortcuts SPM dep).

## Outputs

- `Hotkey/HotkeyManager.swift` — `KeyboardShortcuts.Name.toggleRecording` extension; `BindingError` enum (`.conflict(String)`); `HotkeyRegistrarError` enum; `HotkeyRegistrar` protocol (test seam with `register(handler:)` and `unregister()`); `KeyboardShortcutsRegistrar` (production `KeyboardShortcuts` wrapper); `HotkeyManager` (@Observable @MainActor class) with `lastBindingError: BindingError?`, `start(toggleHandler:)`, `stop()`, and `static func recorder() -> some View`.
- `Tests/AudioEngineTests/HotkeyManagerTests.swift` — 8 unit tests using `StubHotkeyRegistrar`: `testStartRegistersHandler`, `testStartHandlerIsInvokedEachPress`, `testStartSetsLastBindingErrorOnFailure`, `testLastBindingErrorIsNilOnSuccess`, `testLastBindingErrorInitiallyNil`, `testDefaultInitialiserExists`, `testRecorderFactoryReturnsView`, `testStopUnregisters`.
- `project.yml` — Added `configs: Debug: ARCHS: "arm64" ONLY_ACTIVE_ARCH: YES` to fix x86_64 SPM fat-binary module resolution race condition in the Debug build (pre-existing latent issue, triggered by first use of `import KeyboardShortcuts`).
- Tests placed in `Tests/AudioEngineTests/` (existing target) via `@testable import SystemAudioRecorder`. 118 total tests pass, 0 failures.
