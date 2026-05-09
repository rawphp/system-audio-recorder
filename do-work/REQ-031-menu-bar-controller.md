# REQ-031: MenuBarController — NSStatusItem with state-driven icon and dropdown menu

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/MenuBar/MenuBarController.swift`. Creates an `NSStatusItem` (variable length) with a template image. Three icon assets (distinct shapes per spec Section 4.5):
- **Idle**: outlined waveform glyph
- **Recording**: filled red dot + small waveform
- **Paused**: filled outlined dot

The icon updates when `AppStore.currentSession?.state` changes. Click the status item to open an `NSMenu` with the items from spec Section 4.5: while recording — elapsed time header, Pause, Stop, Source preset submenu, Open Window…, Settings…, Quit. While idle — Start Recording + source preset submenu + Open Window… + Settings… + Quit.

## Context

Spec Section 4.5 gives the full menu structure for both states. Spec Section 5 (menu bar interaction) specifies that hotkey toggles update the status item icon synchronously.

## Acceptance Criteria

- [ ] Status item appears in the menu bar on app launch
- [ ] Icon updates to reflect session state within one run-loop tick of the change
- [ ] All menu items invoke `AppStore` action methods (no view-layer logic in MenuBarController beyond icon binding and menu construction)
- [ ] Open Window… brings the main window to front (creating it if minimized/closed)
- [ ] Settings… opens the same `OutputSettingsView` sheet (REQ-029)
- [ ] Recording-state menu shows the current elapsed time (HH:MM:SS) at the top, updating every second

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
2. **ui** Launch app, observe menu bar; take snapshot of status item; click it, take snapshot of dropdown
   - Expected: status item visible; menu shows the documented items in the documented order

## Integration

**Reachability:** Always present in the menu bar (no chrome to "reach"; this IS reachability for menu-bar-only mode REQ-032).

**Data dependencies:** Binds to `AppStore.currentSession?.state` and `AppStore.currentSession?.elapsedTime` (REQ-022).

**Service dependencies:** Calls `AppStore` action methods (REQ-022); opens REQ-029.
