# REQ-033: Error surfacing infrastructure (modal / banner / toast)

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Errors/ErrorSurface.swift`, the routing layer that maps typed errors from the audio engine (`CaptureError`, `EncodingError`, `SessionError`) to one of three UI surfaces per spec Section 6.3:
- **Fatal** → `NSAlert` modal with "Try Again" + "Open System Settings"
- **Non-fatal** → inline warning banner in the recording window (dismissible)
- **Background** → toast (reuses the post-stop toast component, REQ-027)

Provide `ErrorSurface.report(_ error: Error, severity: ErrorSeverity)` from any thread.

## Context

Spec Section 6.3 enumerates the severity-to-surface mapping. The error layer must not depend on view internals; views observe `AppStore.currentBanner` / `AppStore.currentAlert` instead.

## Acceptance Criteria

- [x] `ErrorSurface.report` can be called from any thread; it dispatches to the main actor
- [x] Fatal severity surfaces an `NSAlert` with the documented buttons; "Open System Settings" deep-links to the relevant pane (mic / screen recording / privacy)
- [x] Non-fatal banner appears at the top of the window content area; dismissible with an X button
- [x] Background toast reuses the REQ-027 component
- [x] Multiple non-fatal errors stack vertically up to 3, then collapse with "+N more"

## Verification Steps

1. **test** Unit test reports a fake fatal error; asserts `AppStore.currentAlert` is set with the documented button labels
   - Expected: test passes
   - Result: `testFatalErrorFromBackgroundSetsAlert` and all 10 ErrorSurfaceTests pass. Full suite: 319 tests, 1 pre-existing skip, 0 failures. **PASS**
2. **ui** Inject a non-fatal error during a session; take snapshot; assert banner is visible with the message
   - Expected: banner visible; X closes it
   - Result: **skipped — manual**

## Integration

**Reachability:** Visible across the entire app — `ContentView` (REQ-023) renders banners and alerts.

**Data dependencies:** Writes to `AppStore.currentAlert`, `AppStore.banners`, `AppStore.toasts` (REQ-022).

**Service dependencies:** Receives errors from REQ-007, REQ-008, REQ-013, REQ-017, REQ-018, REQ-019.

## Outputs

- `App/Errors/ErrorSurface.swift` — `ErrorSeverity` enum (`fatal`, `nonFatal`, `background`); `SystemSettingsPane` enum (`.microphone` → `Privacy_Microphone`, `.screenRecording` → `Privacy_ScreenCapture`) with computed `url: URL`; `AppAlert` struct (`Identifiable`, `Equatable`, `Sendable`) with `title`, `message`, `primaryButton`, `secondaryButton?`, `secondaryAction?: SystemSettingsPane`; `AppBanner` struct (`Identifiable`, `Equatable`, `Sendable`) with `message`, `dismissible`; `ErrorSurface` `@Observable @MainActor final class` with `currentAlert: AppAlert?`, `banners: [AppBanner]` (capped at 3), `collapsedCount: Int`, `report(_ error: Error, severity: ErrorSeverity) async` (dispatches to main actor via `MainActor.run`), `dismiss(banner:)`, `dismissAlert()`. Error mapping: `CaptureError.permissionRevoked` → fatal + `.microphone` settings link; `EncodingError.invalidInput` → background toast; `EncodingError.lameInitFailed` → fatal alert; `SessionError.noSourcesConfigured` → non-fatal banner; `SettingsError.outputFolderUnavailable` → non-fatal banner; unknown → background toast with `localizedDescription`.
- `App/AppStore.swift` — Added `errorSurface: ErrorSurface` property (composed at init, default fresh instance); designated init updated to accept optional `errorSurface` parameter.
- `App/Views/ContentView.swift` — Added `BannerStackView` + `BannerRow` structs; wired `.overlay(alignment: .top)` for banners and `.alert` modifier for fatal alerts from `store.errorSurface`.
- `Tests/AudioEngineTests/ErrorSurfaceTests.swift` — 10 unit tests: `testFatalErrorFromBackgroundSetsAlert`, `testDismissAlertClearsCurrentAlert`, `testNonFatalBannerAppearsForSessionErrorNoSources`, `testBackgroundEncodingInvalidInputProducesToast`, `testBannerStackCapsAtThreeWithCollapsedCount`, `testDismissBannerRemovesCorrectEntry`, `testLameInitFailedProducesFatalAlert`, `testSettingsErrorOutputFolderUnavailableProducesBanner`, `testUnknownErrorProducesBackgroundToastWithLocalizedDescription`, `testAppStoreHasErrorSurface`. All 10 pass. Full suite: 319 tests, 1 pre-existing skip, 0 failures.
