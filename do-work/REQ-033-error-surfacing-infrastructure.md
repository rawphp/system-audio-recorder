# REQ-033: Error surfacing infrastructure (modal / banner / toast)

**UR:** UR-001
**Status:** backlog
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

- [ ] `ErrorSurface.report` can be called from any thread; it dispatches to the main actor
- [ ] Fatal severity surfaces an `NSAlert` with the documented buttons; "Open System Settings" deep-links to the relevant pane (mic / screen recording / privacy)
- [ ] Non-fatal banner appears at the top of the window content area; dismissible with an X button
- [ ] Background toast reuses the REQ-027 component
- [ ] Multiple non-fatal errors stack vertically up to 3, then collapse with "+N more"

## Verification Steps

1. **test** Unit test reports a fake fatal error; asserts `AppStore.currentAlert` is set with the documented button labels
   - Expected: test passes
2. **ui** Inject a non-fatal error during a session; take snapshot; assert banner is visible with the message
   - Expected: banner visible; X closes it

## Integration

**Reachability:** Visible across the entire app — `ContentView` (REQ-023) renders banners and alerts.

**Data dependencies:** Writes to `AppStore.currentAlert`, `AppStore.banners`, `AppStore.toasts` (REQ-022).

**Service dependencies:** Receives errors from REQ-007, REQ-008, REQ-013, REQ-017, REQ-018, REQ-019.
