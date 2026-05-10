# REQ-052: Real-tap validation in RecordingSession.start

**UR:** UR-005
**Status:** backlog
**Created:** 2026-05-10
**Layer:** audio_engine

## Task

Add a real-tap validation step in `RecordingSession.start(config:)` (`AudioEngine/Recording/RecordingSession.swift:227`) that — when the session config requires the process tap — attempts to create a tap against the actual chosen process list (or empty list for "Everything") and throws a typed error if creation fails. This is the audio-engine half of the "Both layers" fail-fast gate (UR-005 clarification); REQ-051 is the AppStore-side cheap gate.

The empty-process-list probe in `PermissionManager.probeAudioTap()` only proves the entitlement is plausible — it does NOT prove that creating a tap with the real process list will succeed (the HAL may refuse for transient or per-process reasons). This validation closes that gap before audio routing or file writers are initialised.

Failure path: throw a typed error. Two existing enums are candidates: `SessionError` (`AudioEngine/Recording/RecordingSession.swift:103`) and `CaptureError` (`AudioEngine/Capture/ProcessTapCapture.swift:9`, which already has `case tapCreationFailed(OSStatus)`). Prefer reusing `CaptureError.tapCreationFailed` if the validation lives close to the tap primitive; add a new `SessionError` case if the validation lives at the session orchestration level. The thrown error must reach `AppStore.startRecording`'s catch block (`App/AppStore.swift:317-333`) so `errorSurface` routes it consistently with REQ-051's alert.

Cleanup contract: if the validation tap is created successfully and then immediately destroyed for the validation step, ensure no resources (tap IDs, audio object IDs) leak. Reuse `AudioHardwareDestroyProcessTap` per the existing probe pattern (`Permissions/PermissionManager.swift:175`).

## Context

UR-005 clarification: "Both layers — AppStore does the cheap gate (re-probe + reject early); RecordingSession does the deep check (real-tap creation) and throws if it fails. Belt-and-braces." This REQ owns the audio-engine deep check.

Connector: `ProcessTapCapture` already has tap-creation logic and per-PID error handling (REQ-044, REQ-045). The validation in this REQ should reuse the same primitive (`AudioHardwareCreateProcessTap`) and follow the same OSStatus interpretation conventions REQ-046 used for diagnostic logging.

Challenger: per-PID failures are already handled gracefully by REQ-045 (the session continues with surviving PIDs). REQ-052's validation should NOT duplicate that logic — its job is the *all-fail* case (no tap can be created at all), which today only surfaces partway through engine setup. Distinguish "everything succeeded" from "everything failed" before any output file is opened.

## Acceptance Criteria

- [ ] When `RecordingSession.start(config:)` is invoked with a config that requires the tap, a real-tap validation step runs before opening any output file or starting any audio unit.
- [ ] If the validation tap creation fails for the entire chosen process set (no surviving PIDs), `start` throws a typed error (`CaptureError.tapCreationFailed(OSStatus)` or a new equivalent case on `SessionError`).
- [ ] If the validation succeeds, the validation tap is destroyed before the real engine setup begins (no resource leak).
- [ ] Mic-only sessions skip the validation entirely.
- [ ] The thrown error is caught by `AppStore.startRecording`'s existing error path and surfaced via `errorSurface` (consistent with REQ-051's alert copy where appropriate).
- [ ] No regression: existing `RecordingSessionIntegrationTests` and `ProcessTapCapture` tests still pass.

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** Run `swift test --filter RecordingSession` and `swift test --filter ProcessTapCapture`. Add a test that injects a stub tap factory configured to fail tap creation, and asserts `RecordingSession.start` throws `tapCreationFailed` (or the chosen typed error) without opening the output file.
   - Expected: green; the new test fails if the validation step is removed.
2. **build** Project builds clean.
   - Expected: zero warnings, zero errors.
3. **runtime** Manual: revoke the Screen Recording entitlement, launch the app (REQ-051's gate may catch this first — temporarily disable that gate for this verification), click Start with "Everything" preset.
   - Expected: an error is thrown from `RecordingSession.start` and surfaced via `errorSurface`. No `.wav` or `.mp3` artefacts are created on disk for the failed session.

## Integration

**Reachability:** `RecordingSession.start(config:)` (`AudioEngine/Recording/RecordingSession.swift:227`) — invoked from `AppStore.startRecording` (`App/AppStore.swift:285`) after REQ-051's gate passes. The validation runs as the first step inside `start`, before any file or audio-unit setup.

**Data dependencies:** Reads `SessionConfig` (already passed in). Writes a transient `AudioObjectID` for the validation tap (immediately destroyed). No persistent state changes on the failure path.

**Service dependencies:** Calls `AudioHardwareCreateProcessTap` and `AudioHardwareDestroyProcessTap` (Core Audio HAL APIs already used by `Permissions/PermissionManager.swift:170-175` and `AudioEngine/Capture/ProcessTapCapture.swift`). Throws into `AppStore.startRecording`'s existing catch path (`App/AppStore.swift:317-333`). Reuses `CaptureError.tapCreationFailed(OSStatus)` (`AudioEngine/Capture/ProcessTapCapture.swift:10`) where possible; otherwise extends `SessionError` (`AudioEngine/Recording/RecordingSession.swift:103`).
