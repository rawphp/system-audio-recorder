# REQ-052: Real-tap validation in RecordingSession.start

**UR:** UR-005
**Status:** done
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

- [x] When `RecordingSession.start(config:)` is invoked with a config that requires the tap, a real-tap validation step runs before opening any output file or starting any audio unit.
- [x] If the validation tap creation fails for the entire chosen process set (no surviving PIDs), `start` throws a typed error (`CaptureError.tapCreationFailed(OSStatus)` or a new equivalent case on `SessionError`).
- [x] If the validation succeeds, the validation tap is destroyed before the real engine setup begins (no resource leak).
- [x] Mic-only sessions skip the validation entirely.
- [x] The thrown error is caught by `AppStore.startRecording`'s existing error path and surfaced via `errorSurface` (consistent with REQ-051's alert copy where appropriate).
- [x] No regression: existing `RecordingSessionIntegrationTests` and `ProcessTapCapture` tests still pass.

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** `make test`. Add a test that injects a stub tap factory configured to fail tap creation and asserts `RecordingSession.start` throws `tapCreationFailed` (or the chosen typed error) without opening the output file.
   - Result: PASS — 3 new tests added: `testTapValidationFailureThrowsAndDoesNotCreateOutputFile`, `testTapValidationSuccessDestroysTapBeforeEngineSetup`, `testMicOnlySessionSkipsTapValidation`. All pass. Pre-existing flaky expected-failure (`testSilenceDetectorResetsOnPause`) confirmed present before changes. 392 tests total, 0 unexpected failures.
2. **build** `make build` — clean compile.
   - Result: PASS — test suite compiled and ran without build errors.
3. **runtime (manual — deferred to user)** Revoke the Screen Recording entitlement, launch the app (REQ-051's gate may catch this first — temporarily disable that gate for this verification), click Start with "Everything" preset. The worker cannot drive macOS settings UI; this step is documentation for manual verification post-merge.
   - Expected: an error is thrown from `RecordingSession.start` and surfaced via `errorSurface`. No `.wav` or `.mp3` artefacts are created on disk for the failed session.
   - Result: deferred (manual) — cannot automate native macOS UI.

## Integration

**Reachability:** `RecordingSession.start(config:)` (`AudioEngine/Recording/RecordingSession.swift`) — invoked from `AppStore.startRecording` (`App/AppStore.swift:285`) after REQ-051's gate passes. The validation runs as the first step inside `start`, before any file or audio-unit setup.

**Data dependencies:** Reads `SessionConfig.tapValidationPIDs` (new field, set by caller). Writes a transient `AudioObjectID` for the validation tap (immediately destroyed). No persistent state changes on the failure path.

**Service dependencies:** Calls `AudioHardwareCreateProcessTap` and `AudioHardwareDestroyProcessTap` (Core Audio HAL APIs already used by `Permissions/PermissionManager.swift:170-175` and `AudioEngine/Capture/ProcessTapCapture.swift`). Throws into `AppStore.startRecording`'s existing catch path (`App/AppStore.swift:317-333`). Reuses `CaptureError.tapCreationFailed(OSStatus)` (`AudioEngine/Capture/ProcessTapCapture.swift:10`).

**Error choice**: Used `CaptureError.tapCreationFailed(OSStatus)` rather than a new `SessionError` case. Rationale: (1) the existing `AppStore.routeSessionStartError` already has a dedicated match arm for `CaptureError.tapCreationFailed` that offers the "Switch to mic-only" alert; (2) the validation is semantically close to the tap primitive; (3) reuse avoids protocol proliferation.

## Outputs

- `AudioEngine/Recording/RecordingSession.swift` — added `CoreAudio` import; added `tapValidationPIDs: [pid_t]?` to `SessionConfig`; added `TapValidator` typealias; added `tapValidator` stored property and injectable `init(tapValidator:)` parameter on `RecordingSession`; added `defaultTapValidator` static closure (real Core Audio probe that creates and immediately destroys a validation tap); added REQ-052 validation block at the top of `start(config:)` before `MixerGraph`/`WAVWriter` creation.
- `Tests/AudioEngineTests/RecordingSessionTests.swift` — added 3 new tests: `testTapValidationFailureThrowsAndDoesNotCreateOutputFile`, `testTapValidationSuccessDestroysTapBeforeEngineSetup`, `testMicOnlySessionSkipsTapValidation`.
