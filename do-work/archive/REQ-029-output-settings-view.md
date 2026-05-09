# REQ-029: OutputSettingsView — settings sheet covering folder, bitrate, mode, hotkey, auto-stop

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/OutputSettingsView.swift`, the sheet opened by the cog icon in `ContentView`. Sections:
- **Output**: folder (button to change via `NSOpenPanel`), output mode (mixed / separate), keep-WAV toggle
- **Encoding**: bitrate (128 / 192 / 256 / 320), mode (VBR / CBR)
- **Hotkey**: `KeyboardShortcuts.Recorder(name: .toggleRecording)` (REQ-020)
- **Auto-stop**: enable + duration, enable + silence threshold (default 30 s)
- **App**: "Show in Dock" toggle (REQ-032)

All controls bind two-way to `AppSettings` (REQ-021).

## Context

Spec Section 4.6 lists every setting that lives in this sheet. Section 6.2 documents defaults.

## Acceptance Criteria

- [x] Every key in spec Section 6.2 has a matching control
- [x] Folder button opens `NSOpenPanel`, configured for directories only; chosen folder is stored as a security-scoped bookmark via REQ-021
- [x] Bitrate is a segmented control or popup with the four documented options
- [x] Hotkey recorder uses the KeyboardShortcuts SwiftUI helper
- [x] Sheet has Done + Cancel; Cancel reverts changes; Done persists them
- [x] Auto-stop sub-controls are disabled until the corresponding toggle is on

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
   - Result: `make build` → **BUILD SUCCEEDED**
2. **ui** Open Settings sheet, change bitrate to 256 and click Done; reopen sheet; take snapshot
   - Expected: bitrate persists across open/close
   - Result: **skipped — manual** (no automated UI snapshot harness in this project)

## Outputs

- `App/Views/OutputSettingsView.swift` — `FolderPicker` protocol + `NSOpenPanelFolderPicker` (production impl); `OutputSettingsViewModel` (`@Observable @MainActor final class`) with staging properties for all spec §6.2 editable keys (`stageBitrate`, `stageBitrateMode`, `stageOutputMode`, `stageKeepWAV`, `stageShowInDock`, `stageAutoStopDurationEnabled`, `stageAutoStopDuration`, `stageAutoStopSilenceEnabled`, `stageAutoStopSilence`, `stagePendingFolderURL`), `selectFolder()`, `cancel()`, `done()`, injectable `init(settings:folderPicker:)` seam, and convenience `init(settings:)`; `OutputSettingsView` (`public struct`) with sections Output (folder picker button, output mode segmented, keep-WAV checkbox), Encoding (bitrate segmented 128/192/256/320, mode VBR/CBR), Hotkey (`HotkeyManager.recorder()`), Auto-Stop (duration + silence toggles with disabled sub-fields per AC #6), App (show-in-dock toggle); Done + Cancel buttons with correct keyboard shortcuts; `SectionHeader` helper view; replaces stub in `ContentView`.
- `App/Views/ContentView.swift` — Removed placeholder `OutputSettingsView` stub; updated `.sheet` to pass `settings: store.settings` to the real `OutputSettingsView`.
- `Tests/AudioEngineTests/OutputSettingsViewTests.swift` — 25 unit tests: 9 init-snapshot tests (`testInitSnapshotsBitrateIntoStage`, `testInitSnapshotsBitrateModeIntoStage`, `testInitSnapshotsOutputModeIntoStage`, `testInitSnapshotsKeepWAVIntoStage`, `testInitSnapshotsShowInDockIntoStage`, `testInitSnapshotsAutoStopDurationEnabledIntoStage`, `testInitAutoStopDurationDisabledWhenNil`, `testInitSnapshotsAutoStopSilenceEnabledIntoStage`, `testInitAutoStopSilenceDisabledWhenNil`); 1 cancel test; 9 done-write tests; 2 toggle-gating tests; 2 folder-picker tests; 1 view compile-time contract test. All 25 pass. Full suite: **TEST SUCCEEDED** (all suites pass).

## Integration

**Reachability:** Opened from the cog icon in `ContentView` (REQ-023). Also opened by "Settings…" item in the menu bar status menu (REQ-031).

**Data dependencies:** Two-way bindings against `AppSettings` (REQ-021).

**Service dependencies:** Composes the KeyboardShortcuts recorder (REQ-020), `NSOpenPanel`, `NSApp.setActivationPolicy` (REQ-032).
