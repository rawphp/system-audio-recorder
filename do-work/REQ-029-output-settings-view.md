# REQ-029: OutputSettingsView — settings sheet covering folder, bitrate, mode, hotkey, auto-stop

**UR:** UR-001
**Status:** backlog
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

- [ ] Every key in spec Section 6.2 has a matching control
- [ ] Folder button opens `NSOpenPanel`, configured for directories only; chosen folder is stored as a security-scoped bookmark via REQ-021
- [ ] Bitrate is a segmented control or popup with the four documented options
- [ ] Hotkey recorder uses the KeyboardShortcuts SwiftUI helper
- [ ] Sheet has Done + Cancel; Cancel reverts changes; Done persists them
- [ ] Auto-stop sub-controls are disabled until the corresponding toggle is on

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
2. **ui** Open Settings sheet, change bitrate to 256 and click Done; reopen sheet; take snapshot
   - Expected: bitrate persists across open/close

## Integration

**Reachability:** Opened from the cog icon in `ContentView` (REQ-023). Also opened by "Settings…" item in the menu bar status menu (REQ-031).

**Data dependencies:** Two-way bindings against `AppSettings` (REQ-021).

**Service dependencies:** Composes the KeyboardShortcuts recorder (REQ-020), `NSOpenPanel`, `NSApp.setActivationPolicy` (REQ-032).
