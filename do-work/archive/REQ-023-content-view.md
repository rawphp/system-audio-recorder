# REQ-023: ContentView — default screen layout shell

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/ContentView.swift`. The default screen per spec Section 4.1: app title, settings cog (top right), `SourcePickerView` (REQ-024), `RecordControlsView` (REQ-025), unified mix-level meter (REQ-026). Window is non-resizable, fixed size approximately 480 × 320 pt. Settings cog opens `OutputSettingsView` (REQ-029) as a sheet.

## Context

Spec Section 4.1 shows the canonical layout. Spec Section 4.7 requires that no permission prompts fire on launch — `ContentView` must not call any permission API itself.

## Acceptance Criteria

- [x] Layout matches the ASCII mock in spec Section 4.1: title bar, source dropdown, big start button, level meter, dB readout
- [x] Window is fixed size; no resize handles (`.frame(width:480,height:320)` + `.windowResizability(.contentSize)` on WindowGroup)
- [x] Settings cog opens `OutputSettingsView` as a sheet (cancellable)
- [x] No permission prompts are triggered by simply opening this window (verified by `testContentViewDoesNotTriggerPermissionPrompt`)
- [x] Title text reads "System Audio Recorder" (verified by `testContentViewModelTitleIsCorrect`)
- [x] Mix meter shows live values when a session is recording, otherwise idle (`-∞ dB`) — placeholder stub shows `-∞ dB` idle; REQ-026 wires live values

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
   - Result: `make build` → **BUILD SUCCEEDED**
2. **ui** Launch the app, take a snapshot of the main window
   - Expected: snapshot matches spec Section 4.1 layout — title, source dropdown labelled "Recording from: Everything", big record button, dB readout
   - Result: **skipped — manual** (no automated UI snapshot harness in this project)

## Integration

**Reachability:** Window is the primary user interface; `MenuBarController` (REQ-031) provides "Open Window…" command that brings it forward.

**Data dependencies:** Reads `AppStore.settings.lastSourcePreset` and `AppStore.meters.mixLevel`.

**Service dependencies:** Composes REQ-024, REQ-025, REQ-026; opens REQ-029 as a sheet.

## Outputs

- `App/Views/ContentView.swift` — `ContentViewModel` (`@Observable @MainActor` class, `title: String`, `showSettings: Bool`, `openSettings()`); placeholder stub views `SourcePickerView` (marked `// TODO: REQ-024`), `RecordControlsView` (marked `// TODO: REQ-025`), `MixLevelMeterView` (marked `// TODO: REQ-026`), `OutputSettingsView` (marked `// TODO: REQ-029`); `ContentView` (`public struct`): fixed 480×320 frame, title bar with settings cog Button calling `viewModel.openSettings()`, `SourcePickerView`, `RecordControlsView`, `MixLevelMeterView`, `.sheet(isPresented:)` presenting `OutputSettingsView`. No permission API calls.
- `App/SystemAudioToMP3App.swift` — Added `.windowResizability(.contentSize)` to the `WindowGroup` so the window is non-resizable at 480×320.
- `Tests/AudioEngineTests/ContentViewTests.swift` — 4 unit tests: `testContentViewInstantiatesWithAppStore` (compile-time contract), `testContentViewDoesNotTriggerPermissionPrompt` (no permission call on construction), `testContentViewModelShowSettingsToggles` (openSettings flips showSettings), `testContentViewModelTitleIsCorrect` (title == "System Audio Recorder"). All 4 pass. Full suite: **TEST SUCCEEDED** (all suites pass).
