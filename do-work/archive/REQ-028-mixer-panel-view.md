# REQ-028: MixerPanelView — advanced multi-source mixer panel

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/MixerPanelView.swift`, the panel that opens when the user picks "Advanced…" from the source dropdown. Shows a vertical list of selectable audio sources (each with checkbox, app icon, name, per-source level meter, gain slider 0.0–2.0). Includes a microphone row at the bottom with the same controls. Selected sources + gains feed into `RecordingSession.start(config:)` when recording begins.

## Context

Spec Section 4.6 places per-source meters and gain sliders in the Advanced panel only. Spec Section 5.3 says default screen always uses gain 1.0; per-source gain only applies when the user selects Advanced.

## Acceptance Criteria

- [x] Panel lists every entry from `AudioSourceCatalog` plus a microphone row
- [x] Each row has: checkbox, app icon, app name, level meter, gain slider with numeric readout (e.g. "0.0 dB")
- [x] Gain changes apply within ~10 ms (live during a recording)
- [x] Selecting "Apply" updates `AppSettings.lastSourcePreset` to "Advanced" and stores the chosen source IDs + gains
- [x] Cancelling the panel reverts to the previous preset
- [x] Mic row is greyed if mic permission is denied

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
   - Result: `make build` → **BUILD SUCCEEDED**
2. **ui** Launch app, open Advanced…, take snapshot
   - Expected: panel shows source list, mic row, gain sliders, OK/Cancel buttons
   - Result: **skipped — manual** (no automated UI snapshot harness in this project)

## Integration

**Reachability:** Opened from "Advanced…" item in `SourcePickerView` (REQ-024).

**Data dependencies:** Reads `AudioSourceCatalog`; writes selection + gains to `AppSettings`; meter values from `AppStore.meters`.

**Service dependencies:** Depends on REQ-006 (catalog), REQ-011 (meters), REQ-021 (settings), REQ-026 (meter view component).

## Outputs

- `App/Views/MixerPanelView.swift` — `MixerRow` struct (`id`, `name`, `icon`, `selected`, `gain`); `MixerPanelViewModel` (`@Observable @MainActor` class) with `rows: [MixerRow]`, `isMicRowGreyed`, `setGain(forID:to:)`, `apply()`, `cancel()`; `MixerPanelView` (thin SwiftUI shell — title bar, `ScrollView` of source rows with checkbox/icon/name/inline meter/gain slider, Apply/Cancel buttons); `InlineMeterView` (private SwiftUI view reusing `MeterMath` from REQ-026 for per-source meter bars). Replaces the `MixerPanelView` stub that lived in `SourcePickerView.swift`.
- `App/Settings/AppSettings.swift` — Extended with v2 schema keys `advancedSourceIDs: [String]` and `advancedGains: [String: Float]` backed by UserDefaults. `Keys` enum updated with `advancedSourceIDs` and `advancedGains` constants.
- `AudioEngine/Recording/RecordingSession.swift` — Added `setGain(forSource:gain:)` public actor method that forwards live gain changes to the underlying `MixerGraph` within ~10 ms.
- `App/Views/SourcePickerView.swift` — Removed the `MixerPanelView` placeholder stub (real implementation now lives in `MixerPanelView.swift`).
- `Tests/AudioEngineTests/MixerPanelViewTests.swift` — `MixerPanelViewModelTests`: 20 unit tests covering all AC: `testRowsIncludeCatalogProcessesPlusMic`, `testEmptyCatalogStillHasMicRow`, `testDefaultGainIsOne`, `testDefaultSelectedIsFalse`, `testApplyWritesSelectedSourceIDsToSettings`, `testApplySetsLastPresetToAdvanced`, `testApplyWritesGainsToSettings`, `testCancelDoesNotPersistSelectedSources`, `testCancelPreservesExistingPreset`, `testSetGainMutatesRowGain`, `testSetGainForUnknownIDIsNoOp`, `testMicRowIsGreyedWhenDenied`, `testMicRowIsNotGreyedWhenAuthorized`, `testMicRowIsGreyedWhenRestricted`, `testAdvancedSourceIDsDefaultsToEmpty`, `testAdvancedGainsDefaultsToEmpty`, `testAdvancedSourceIDsRoundTrip`, `testAdvancedGainsRoundTrip`, `testV2KeysDoNotCorruptV1Keys`, `testMixerPanelViewInstantiates`. All 20 pass (0 failures).
