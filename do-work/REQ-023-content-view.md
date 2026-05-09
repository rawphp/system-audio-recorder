# REQ-023: ContentView — default screen layout shell

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/ContentView.swift`. The default screen per spec Section 4.1: app title, settings cog (top right), `SourcePickerView` (REQ-024), `RecordControlsView` (REQ-025), unified mix-level meter (REQ-026). Window is non-resizable, fixed size approximately 480 × 320 pt. Settings cog opens `OutputSettingsView` (REQ-029) as a sheet.

## Context

Spec Section 4.1 shows the canonical layout. Spec Section 4.7 requires that no permission prompts fire on launch — `ContentView` must not call any permission API itself.

## Acceptance Criteria

- [ ] Layout matches the ASCII mock in spec Section 4.1: title bar, source dropdown, big start button, level meter, dB readout
- [ ] Window is fixed size; no resize handles
- [ ] Settings cog opens `OutputSettingsView` as a sheet (cancellable)
- [ ] No permission prompts are triggered by simply opening this window
- [ ] Title text reads "System Audio Recorder"
- [ ] Mix meter shows live values when a session is recording, otherwise idle (`-∞ dB`)

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
2. **ui** Launch the app, take a snapshot of the main window
   - Expected: snapshot matches spec Section 4.1 layout — title, source dropdown labelled "Recording from: Everything", big record button, dB readout

## Integration

**Reachability:** Window is the primary user interface; `MenuBarController` (REQ-031) provides "Open Window…" command that brings it forward.

**Data dependencies:** Reads `AppStore.settings.lastSourcePreset` and `AppStore.meters.mixLevel`.

**Service dependencies:** Composes REQ-024, REQ-025, REQ-026; opens REQ-029 as a sheet.
