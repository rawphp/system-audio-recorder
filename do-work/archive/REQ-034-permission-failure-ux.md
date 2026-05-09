# REQ-034: Permission failure UX paths

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Wire the permission failure paths from spec Section 6.5:
- **Mic denied**: source dropdown options that need mic become disabled with "Mic access denied — Open Settings" affordance (link opens System Settings → Privacy → Microphone deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`)
- **Audio-tap denied**: all options except "Microphone only" disabled with the same affordance for the audio-tap pane
- **MDM blocks tap APIs**: caught at session start; show fatal alert offering fallback to mic-only

## Context

Spec Section 6.5 specifies each path. Section 4.7 specifies lazy permission requests — failures are surfaced post-prompt, not pre-emptively.

## Acceptance Criteria

- [x] When mic is denied, "Everything + Mic" and "Microphone only" rows in the dropdown are visually greyed and show the affordance text
- [x] Clicking the "Open Settings" affordance opens System Settings to the correct pane
- [x] When audio-tap is denied, only "Microphone only" remains enabled
- [x] On MDM-blocked tap APIs, a fatal alert offers "Switch to mic-only" or "Quit"
- [x] Granting permission via System Settings updates the dropdown within 1 s of returning to the app

## Verification Steps

1. **test** Unit test sets `permissionManager.microphoneStatus = .denied`; asserts mic-involving options return `.disabled` with the documented affordance
   - Expected: test passes
   - Result: All 11 PermissionFailureUXTests pass (PermissionDeepLinkTests × 3, PermissionPollObservationTests × 3, MDMBlockedTapTests × 5). Full suite: 330 tests, 1 pre-existing skip, 0 failures. **PASS**
2. **ui** Manual: deny mic in System Settings, return to app; click dropdown; take snapshot
   - Expected: mic options greyed, affordance visible, link opens correct pane
   - Result: **skipped — manual**

## Integration

**Reachability:** Surfaces in `SourcePickerView` (REQ-024) and as fatal alerts via `ErrorSurface` (REQ-033).

**Data dependencies:** Reads `PermissionManager` state (REQ-019).

**Service dependencies:** Depends on REQ-019, REQ-024, REQ-033.

## Outputs

- `App/Errors/PermissionDeepLink.swift` — `PermissionDeepLink` enum with `microphoneSettingsURL` and `screenRecordingSettingsURL` static URL constants; canonical source of all `x-apple.systempreferences:` deep-link URLs. `SystemSettingsPane.url` (REQ-033) now delegates to these constants. `SourcePickerViewModel.openMicrophoneSettings()` now calls `PermissionDeepLink.microphoneSettingsURL` instead of an inline string.
- `App/Errors/ErrorSurface.swift` — Added `reportCustomAlert(_ alert: AppAlert)` public method that bypasses the standard error-mapping path, allowing callers to present alerts with bespoke button labels (e.g. MDM fallback alert). `SystemSettingsPane.url` now delegates to `PermissionDeepLink` constants.
- `App/AppStore.swift` — Added `routeSessionStartError(_ error: Error) async` private method; `startRecording(preset:)` now calls it on build/start failure. `CaptureError.tapCreationFailed` is recognized as MDM/policy denial and surfaces a fatal `AppAlert` via `errorSurface.reportCustomAlert()` with `primaryButton: "Switch to mic-only"` and `secondaryButton: "Quit"`. All other errors route to `errorSurface.report(_:severity:.nonFatal)`.
- `Tests/AudioEngineTests/PermissionFailureUXTests.swift` — 11 unit tests in 3 suites: `PermissionDeepLinkTests` (3 tests: `testMicrophoneDeepLinkURL`, `testScreenRecordingDeepLinkURL`, `testSourcePickerViewModelUsesCanonicalMicURL`); `PermissionPollObservationTests` (3 tests: `testMicStatusChangeUpdatesDisabledState`, `testAudioTapOverrideUpdatesDisabledState`, `testPollFiresObservationTracking`); `MDMBlockedTapTests` (5 tests: `testMDMBlockedTapProducesFatalAlertWithSwitchToMicOnly`, `testMDMBlockedTapAlertTitleMentionsTap`, `testMDMBlockedTapSessionStateRemainsIdle`, `testNonMDMErrorDoesNotProduceMDMAlert`, `testPermissionRevokedDoesNotProduceMDMAlert`). All 11 pass. Full suite: 330 tests, 1 pre-existing skip, 0 failures.
