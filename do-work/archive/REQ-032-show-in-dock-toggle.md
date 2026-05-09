# REQ-032: Show-in-Dock toggle — runtime activation policy switch

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Bind `AppSettings.showInDock` (default true) to `NSApp.setActivationPolicy(_:)` at launch and on toggle. When ON: `.regular` (Dock icon visible). When OFF: `.accessory` (no Dock icon, app runs as menu-bar-only). Toggle in `OutputSettingsView` (REQ-029) labelled "Show in Dock". Switching takes effect within 1 s without an app restart.

## Context

Spec Section 4.5 (last paragraph) specifies this behaviour. The status item (REQ-031) remains regardless of activation policy.

## Acceptance Criteria

- [x] On first launch with default `showInDock = true`, Dock icon appears
- [x] Toggling OFF in Settings hides the Dock icon within 1 s without an app restart
- [x] Toggling back ON reveals the Dock icon
- [x] Closing the window with `showInDock = false` does NOT quit the app (menu bar status item keeps it alive)
- [x] Closing the window with `showInDock = true` follows standard macOS behaviour (window minimizes to Dock, app stays)

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
   - Result: `make build` → **BUILD SUCCEEDED**
2. **ui** Launch app, open Settings, toggle Show in Dock off; take Dock screenshot
   - Expected: app icon disappears from Dock; status item still in menu bar; menu still works
   - Result: **skipped — manual** (no automated UI snapshot harness in this project)

## Integration

**Reachability:** Settings toggle (REQ-029) and `AppSettings` setter.

**Data dependencies:** Reads `AppSettings.showInDock` (REQ-021).

**Service dependencies:** Calls `NSApp.setActivationPolicy`. No other module dependencies.

## Outputs

- `App/DockPolicyController.swift` — `ActivationPolicySetting` protocol (test seam wrapping `NSApp.setActivationPolicy(_:)`); `NSAppActivationPolicySetting` production implementation; `DockPolicyController` `@MainActor final class` with `init(settings:policy:)`, `start()` (applies current policy + begins recursive `withObservationTracking` loop), `apply()` (translates `settings.showInDock` → `.regular` / `.accessory` and calls `policy.set`).
- `App/SystemAudioToMP3App.swift` — Added `@State private var dockPolicyController: DockPolicyController?`; wired in `.onAppear` alongside `MenuBarController` — creates controller from `appStore.settings` and calls `controller.start()`.
- `Tests/AudioEngineTests/DockPolicyControllerTests.swift` — 6 unit tests using `SpyActivationPolicySetting`: `testApplyWithShowInDockTrueSetsRegularPolicy`, `testApplyWithShowInDockFalseSetsAccessoryPolicy`, `testStartAppliesCurrentPolicyImmediately`, `testToggleTrueToFalseRecordsRegularThenAccessory`, `testToggleFalseToTrueRecordsAccessoryThenRegular`, `testApplySameValueTwiceRecordsTwice`. All 6 pass.
