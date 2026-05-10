# REQ-048: Re-probe audio tap on app foreground

**UR:** UR-005
**Status:** done
**Created:** 2026-05-10
**Layer:** supporting

## Task

Add an event-driven re-probe of audio tap status to `PermissionManager` so that granting the Screen Recording entitlement in System Settings while the app is running takes effect without a relaunch.

Two changes:

1. **Public API:** add a `refreshAudioTapStatus()` method (sync wrapper that schedules `requestAudioTap()` on the main actor) that other components can call. This is the seam REQ-049 will consume from the UI.
2. **Foreground observer:** subscribe to `NSApplication.didBecomeActiveNotification` (or `NotificationCenter.default` equivalent on `@MainActor`) and call `refreshAudioTapStatus()` whenever the notification fires.

The 1 Hz mic poll (`startPolling` at `Permissions/PermissionManager.swift:194`) is **not** the right pattern here — `AudioHardwareCreateProcessTap` is heavyweight per the user's clarification, so re-probe must be event-driven (foreground + menu-open in REQ-049), not on a timer.

## Context

UR-005 clarification: "Event-driven — probe on app foreground, on menu open, and on tap-related setting change. No timer." The "setting change" path is implicitly covered by foreground+menu-open: the user must return focus to our app or open the picker for the granted permission to matter. This REQ owns the foreground half and the public re-probe seam; REQ-049 owns the menu-open half (UI side).

Connector: mirrors the structure of `startPolling()` (1 Hz mic timer) but uses an `NSApplication.didBecomeActiveNotification` observer instead of a timer, per the cost-vs-freshness clarification.

## Acceptance Criteria

- [x] `PermissionManager` exposes a public method (e.g. `refreshAudioTapStatus()`) that re-runs the audio-tap probe and updates `audioTapStatus`.
- [x] When the app receives `NSApplication.didBecomeActiveNotification`, `audioTapStatus` is re-probed within one main-actor hop.
- [x] Granting the Screen Recording entitlement in System Settings while the app is in the background, then switching back to the app, results in `audioTapStatus == .available` without an app relaunch.
- [x] The observer is removed in `deinit` (no leak, no notifications fired against a deallocated manager).
- [x] No regression: existing `PermissionManagerTests` still pass.

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** `make test`. Add a test that posts a fake `NSApplication.didBecomeActiveNotification` and asserts the probe was re-invoked (count or stub-tap-factory-call increment).
   - Result: PASS — 2 new tests added: `testRefreshAudioTapStatusInvokesProber`, `testForegroundNotificationTriggersReprobe`. Both pass. (Pre-existing `testSilenceDetectorResetsOnAudio` flaky failure confirmed present before this REQ's changes.)
2. **build** `make build` — clean compile.
   - Result: PASS — BUILD SUCCEEDED, zero errors.
3. **runtime (manual — deferred to user)** Launch the app, then `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"` and toggle the entitlement. Return to the app. The worker cannot drive macOS settings UI; this step is documentation for manual verification post-merge.
   - Result: deferred (manual) — cannot automate native macOS UI.

## Integration

**Reachability:** Two callers. (a) `NSApplication.didBecomeActiveNotification` observer registered inside `PermissionManager.init` (`Permissions/PermissionManager.swift:92`), unregistered in `deinit` (line 99). (b) New public method `refreshAudioTapStatus()` exposed from `PermissionManager` for REQ-049's UI trigger to call.

**Data dependencies:** Writes `PermissionManager.audioTapStatus` (`Permissions/PermissionManager.swift:77`). Reads no external state; the probe (`probeAudioTap()` line 166) is self-contained.

**Service dependencies:** `NotificationCenter.default` for the foreground observer; `AudioHardwareCreateProcessTap` (Core Audio) via the existing `probeAudioTap()` helper. No new module dependencies.

## Outputs

- `Permissions/PermissionManager.swift` — added `import AppKit`; added `_ObserverBox` nonisolated wrapper class; added `observerBox: _ObserverBox` stored property; added `startForegroundObserver()` private method (registers `NSApplication.didBecomeActiveNotification` observer); added public `refreshAudioTapStatus()` method (event-driven re-probe seam for REQ-049); `deinit` now calls `observerBox.remove()`.
- `Tests/AudioEngineTests/PermissionManagerTests.swift` — added 2 new tests: `testRefreshAudioTapStatusInvokesProber`, `testForegroundNotificationTriggersReprobe`.
