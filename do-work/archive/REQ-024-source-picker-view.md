# REQ-024: SourcePickerView — preset dropdown with permission-aware disabled states

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/SourcePickerView.swift`, a SwiftUI `Menu` rendered as the source dropdown. Items per spec Section 4.2:
- Everything *(default)*
- Everything + Mic
- Microphone only
- Specific app… *(opens an app picker)*
- Advanced… *(opens `MixerPanelView` REQ-028)*

Items that need a denied permission appear greyed out with an inline "Mic access denied — Open Settings" affordance (per spec Section 6.5 / REQ-034). Selection persists via `AppSettings.lastSourcePreset`.

## Context

Spec Section 4.2 enumerates the dropdown items and order. Section 4.7 specifies lazy permission UX. Section 6.5 specifies failure-path affordances.

## Acceptance Criteria

- [x] Default selected item is "Everything" on first launch
- [x] Selecting any item updates `AppSettings.lastSourcePreset` immediately
- [x] When mic permission is denied, mic-involving items are greyed and show "Mic access denied — Open Settings"
- [x] When audio-tap is denied, all items except "Microphone only" are greyed
- [x] "Specific app…" opens an app picker listing entries from `AudioSourceCatalog`
- [x] "Advanced…" opens `MixerPanelView` as a sheet

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
   - Result: `make build` → **BUILD SUCCEEDED**
2. **ui** Launch app, click the dropdown, take snapshot
   - Expected: 5 items in the documented order; "Everything" shown as selected with checkmark
   - Result: **skipped — manual** (no automated UI snapshot harness in this project)

## Integration

**Reachability:** Embedded in `ContentView` (REQ-023). Same dropdown also reachable via the menu bar status item (REQ-031).

**Data dependencies:** Reads `AppStore.permissionManager` for grey-out logic; reads `AppStore.sourceCatalog` for the app picker; writes `AppSettings.lastSourcePreset`.

**Service dependencies:** Depends on REQ-006 (catalog), REQ-019 (permissions), REQ-021 (settings).

## Outputs

- `App/Views/SourcePickerView.swift` — `PickerItem` enum (5 cases: `.everything`, `.everythingPlusMic`, `.micOnly`, `.specificApp`, `.advanced`) with `label`, `involvesMic`, `needsAudioTap`; `SourcePickerViewModel` (`@Observable @MainActor` class) with `selectedPresetKey`, `showAppPicker`, `showMixerPanel`, `availableItems`, `overrideAudioTapAvailable` test seam, `select(_:)`, `selectProcess(pid:)`, `openAppPicker()`, `openMixerPanel()`, `isDisabled(_:)`, `showMicDeniedAffordance(for:)`, `openMicrophoneSettings()`, `currentSelectionLabel`; `MixerPanelView` (REQ-028 stub — `Text("Mixer Panel — REQ-028")` placeholder); `AppPickerView` (inline sheet: lists `AudioSourceCatalog.processes` with per-process Button, empty-state message); `SourcePickerView` (public SwiftUI `Menu` shell over `SourcePickerViewModel` — 5 items in spec order, mic-denied affordance button with "Open Settings" action, `.sheet` for app picker and mixer panel).
- `App/Views/ContentView.swift` — Replaced inline `SourcePickerView` stub with wiring to real `SourcePickerView(viewModel:)`. Added `@State private var sourcePickerVM: SourcePickerViewModel?` built via `.task` from `appStore`. Removed duplicate struct declaration.
- `Tests/AudioEngineTests/SourcePickerViewTests.swift` — 17 unit tests in `SourcePickerViewModelTests`: `testDefaultSelectedItemIsEverything`, `testLoadsPersistedPresetFromSettings`, `testSelectingItemPersistsToSettings`, `testSelectingEverythingPersistsToSettings`, `testSelectingEverythingPlusMicPersistsToSettings`, `testMicDeniedGreysOutMicItems`, `testMicAuthorizedEnablesMicItems`, `testAudioTapDeniedGreysNonMicItems`, `testAudioTapAvailableEnablesNonMicItems`, `testShowMicDeniedAffordanceWhenDenied`, `testShowMicDeniedAffordanceFalseWhenAuthorized`, `testShowAppPickerStartsFalse`, `testOpenAppPickerSetsFlag`, `testShowMixerPanelStartsFalse`, `testOpenMixerPanelSetsFlag`, `testSelectingSpecificAppProcess`, `testAvailableItemsContainsFiveItems`, `testAvailableItemsOrder`. All 17 pass. Full suite: **TEST SUCCEEDED** (all suites pass).
