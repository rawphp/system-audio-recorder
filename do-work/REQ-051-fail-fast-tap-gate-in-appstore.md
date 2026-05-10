# REQ-051: Fail-fast tap availability gate in AppStore.startRecording

**UR:** UR-005
**Status:** backlog
**Created:** 2026-05-10
**Layer:** ui

## Task

Add a cheap pre-flight check at the top of `AppStore.startRecording(preset:)` (`App/AppStore.swift:285`) that:

1. Inspects the chosen preset — if it needs the audio tap (anything other than mic-only), call `permissionManager.refreshAudioTapStatus()` (added by REQ-048) so the gate uses fresh state.
2. If `permissionManager.audioTapStatus != .available` after the refresh, abort the start *before* building `SessionConfig` and surface the failure through the existing `errorSurface` path (`App/AppStore.swift:317-333`) with a custom alert that explains the tap is unavailable and offers an "Open Settings" action (deep-linking to `PermissionDeepLink.screenRecordingSettingsURL`).
3. Leave the session in `.idle` (or `.failed` per existing `ErrorSurface` semantics) — no half-started recording.

The mic-only preset must skip the gate entirely (it doesn't need the tap).

## Context

UR-005 clarification: the user opted for "Both layers" fail-fast — AppStore does the cheap orchestration gate, RecordingSession does the deep audio-engine check (REQ-052). This REQ owns the orchestration half.

Connector: AppStore already routes session-start errors through `ErrorSurface` (`App/AppStore.swift:317-333` and REQ-033 infrastructure), and a custom-alert path already exists (`reportCustomAlert(AppAlert(...))` at line 325). The new gate reuses both.

Challenger: even with REQ-047 / REQ-048 / REQ-049 wired, status can still be stale when Start is clicked (entitlement revoked while menu was already closed). This gate is the last guard — without it, a valid-looking dropdown selection can still produce a confusing failure mode mid-engine-startup.

## Acceptance Criteria

- [ ] When the user invokes Start with a preset that needs the audio tap and `audioTapStatus != .available` after a fresh re-probe, the recording does NOT start.
- [ ] On the failure path, an alert appears (via `errorSurface`) explaining the tap is unavailable, with an "Open Settings" action that opens `PermissionDeepLink.screenRecordingSettingsURL`.
- [ ] When the preset is mic-only, the gate is skipped (no tap probe, no rejection).
- [ ] When `audioTapStatus == .available`, behaviour is unchanged from today: session starts normally.
- [ ] No regression: existing `AppStore` / `ContentView` / `RecordControlsView` tests still pass.

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** Run `swift test --filter AppStore` (and the surrounding integration tests). Add a test using a stub `PermissionManager` (always returns `.deniedByPolicy`) that asserts `startRecording(preset: .everything)` does NOT call `recordingSession.start` and DOES surface an `AppAlert`.
   - Expected: green; the new test fails if the gate is removed.
2. **build** Project builds clean.
   - Expected: zero warnings, zero errors.
3. **ui** Launch the app on a Mac with the Screen Recording entitlement revoked (or simulate via the override seam). Try to Start a recording with the "Everything" preset.
   - Expected: an alert appears with "Tap unavailable" copy and an "Open Settings" button that opens the Screen Recording pane. No partial recording is created on disk.

## Integration

**Reachability:** `AppStore.startRecording(preset:)` (`App/AppStore.swift:285`) — invoked from `toggleRecording()` (line 265), which is bound to the Start button in `RecordControlsView`. The gate runs at the very top of the function, before `sessionConfigBuilder` is invoked.

**Data dependencies:** Reads `permissionManager.audioTapStatus` (`Permissions/PermissionManager.swift:77`). Reads `PermissionDeepLink.screenRecordingSettingsURL` (`App/Errors/PermissionDeepLink.swift:27`). Writes nothing new.

**Service dependencies:** Calls `PermissionManager.refreshAudioTapStatus()` (added by REQ-048 — hard dependency, REQ-048 must merge first). Calls `errorSurface.reportCustomAlert(_:)` via the existing `AppAlert` pattern (`App/AppStore.swift:325`).
