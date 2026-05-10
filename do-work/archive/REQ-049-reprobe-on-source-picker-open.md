# REQ-049: Re-probe audio tap when source picker menu opens

**UR:** UR-005
**Status:** done
**Created:** 2026-05-10
**Layer:** ui

## Task

Wire `SourcePickerView` (or its view model) to call `PermissionManager.refreshAudioTapStatus()` (added in REQ-048) when the user opens the "Recording from:" dropdown — so the disabled-state of tap-needing items reflects current availability at the moment the user looks at it.

SwiftUI's `Menu` does not expose a native `onMenuOpen` callback, so the trigger must be implemented through the available hook (e.g. an `.onTapGesture` on the menu's label, a custom button that invokes `Menu` programmatically, or by subscribing to `Menu`'s `isPresented` binding via a wrapper). Choose the most compatible approach for the project's macOS deployment target — keeping the behaviour testable through the existing `overrideAudioTapAvailable` seam (`App/Views/SourcePickerView.swift:70`).

## Context

**Depends on:** REQ-048 (calls the `refreshAudioTapStatus()` method added on `PermissionManager`).

UR-005 clarification: "Event-driven — probe on app foreground, on menu open, and on tap-related setting change." This REQ owns the menu-open half. REQ-048 owns the foreground half and provides the `refreshAudioTapStatus()` seam this REQ consumes. Together they replace any need for a timer-based re-probe.

The picker is the moment of truth: if the user grants the entitlement after launch and then immediately opens the dropdown (without leaving the app first), only this trigger surfaces the new availability without forcing a relaunch.

## Acceptance Criteria

- [x] Opening the "Recording from:" dropdown invokes `PermissionManager.refreshAudioTapStatus()` (or equivalent re-probe seam) before the menu items render.
- [x] If the audio tap status changed since the last open, the disabled-state of "Everything", "Everything + Mic", and "Specific app…" updates accordingly when the menu appears.
- [x] The trigger fires on every menu open — not just the first — so subsequent settings changes are reflected too.
- [x] No regression: existing source-picker view-model tests (e.g. `RecordControlsViewTests`, source picker tests) still pass.

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** `make test`. Add a test that asserts `refreshAudioTapStatus()` is called when the picker view-model receives a menu-open event (use a stub `PermissionManager` whose call counter is asserted to be > 0 after the trigger fires).
   - Result: PASS — 2 new tests added: `testOnMenuOpenCallsRefreshAudioTapStatus`, `testOnMenuOpenCallsRefreshOnEveryInvocation`. Both pass. Overall 380 tests, 1 pre-existing skip, 0 failures.
2. **build** `make build` — clean compile.
   - Result: PASS — BUILD SUCCEEDED, zero errors, zero warnings.
3. **ui (manual — deferred to user)** Launch the app, toggle the Screen Recording entitlement off in System Settings, return to the app, open the dropdown — then toggle it back on, return again, and re-open. The worker cannot automate native macOS UI; this step is documentation for manual verification post-merge.
   - Result: deferred (manual) — cannot automate native macOS UI.

## Integration

**Reachability:** `SourcePickerView.body`'s `Menu(viewModel.currentSelectionLabel)` (`App/Views/SourcePickerView.swift:255`) is the user entry point. The menu-open hook attaches there (or to a wrapper button substituted for the menu label). The view model already holds `permissionManager` indirectly via `isDisabled` — REQ-049 either passes `permissionManager` into the view model or routes the call through the model itself.

**Data dependencies:** Reads `PermissionManager.audioTapStatus` (`Permissions/PermissionManager.swift:77`) after the re-probe completes. Consumes the existing `overrideAudioTapAvailable` test seam (`App/Views/SourcePickerView.swift:70`) so unit tests can stub the value without invoking Core Audio.

**Service dependencies:** Calls `PermissionManager.refreshAudioTapStatus()` added by REQ-048. Hard dependency: REQ-048 must merge first.

## Outputs

- `App/Views/SourcePickerView.swift` — added public `onMenuOpen()` method to `SourcePickerViewModel` (calls `permissionManager.refreshAudioTapStatus()`); wired `SourcePickerView.body`'s `Menu` with `.simultaneousGesture(TapGesture().onEnded { viewModel.onMenuOpen() })` so the re-probe fires on every menu open without blocking or replacing the built-in menu action.
- `Tests/AudioEngineTests/SourcePickerViewTests.swift` — added 2 new tests: `testOnMenuOpenCallsRefreshAudioTapStatus` (asserts prober call count > 0 after single `onMenuOpen()`) and `testOnMenuOpenCallsRefreshOnEveryInvocation` (asserts prober count increases on both first and second `onMenuOpen()` calls).
