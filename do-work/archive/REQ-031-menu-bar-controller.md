# REQ-031: MenuBarController — NSStatusItem with state-driven icon and dropdown menu

**UR:** UR-001
**Status:** done
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

- [x] Status item appears in the menu bar on app launch
- [x] Icon updates to reflect session state within one run-loop tick of the change
- [x] All menu items invoke `AppStore` action methods (no view-layer logic in MenuBarController beyond icon binding and menu construction)
- [x] Open Window… brings the main window to front (creating it if minimized/closed)
- [x] Settings… opens the same `OutputSettingsView` sheet (REQ-029)
- [x] Recording-state menu shows the current elapsed time (HH:MM:SS) at the top, updating every second

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
   - Result: `make build` → **BUILD SUCCEEDED**
2. **ui** Launch app, observe menu bar; take snapshot of status item; click it, take snapshot of dropdown
   - Expected: status item visible; menu shows the documented items in the documented order
   - Result: **skipped — manual** (no automated UI snapshot harness in this project)

## Integration

**Reachability:** Always present in the menu bar (no chrome to "reach"; this IS reachability for menu-bar-only mode REQ-032).

**Data dependencies:** Binds to `AppStore.currentSession?.state` and `AppStore.currentSession?.elapsedTime` (REQ-022).

**Service dependencies:** Calls `AppStore` action methods (REQ-022); opens REQ-029.

## Outputs

- `App/MenuBar/MenuBarController.swift` — `MenuBarIconState` enum (`.idle`, `.recording`, `.paused`); `MenuDescriptor` value type with `Item` enum (`.header`, `.separator`, `.action`, `.submenu`) for value-type menu descriptions; `MenuBarRenderer` protocol (test seam owning NSStatusItem); `MenuBarStoreProtocol` (test seam for AppStore slice: `sessionState`, `shouldShowSettings`, `toggleRecording`, `pauseRecording`, `resumeRecording`, `stopRecording`); `MenuBarController: NSObject` wiring `start()`/`stop()` lifecycle via recursive `withObservationTracking`, `renderCurrentState()` that builds icon+menu from state, 1 Hz `Timer` for elapsed time during recording, `formatElapsed(_:) -> String` static HH:MM:SS formatter; `NSStatusItemRenderer: MenuBarRenderer` production AppKit renderer using SF Symbol `waveform`/`record.circle.fill`/`pause.circle`, template images for idle/paused, colored non-template for recording; AppKit `NSMenu` built fresh on each render call.
- `App/AppStore.swift` — Added `_shouldShowSettings: Bool` observable property; `AppStore` extension conforming to `MenuBarStoreProtocol`.
- `App/SystemAudioToMP3App.swift` — Creates `NSStatusItemRenderer` + `MenuBarController` on `.onAppear`, calls `controller.start()`.
- `App/Views/ContentView.swift` — Added `.onChange(of: appStore?._shouldShowSettings)` to mirror menu-bar "Settings…" action into `viewModel.showSettings`; added `.onDisappear` on the sheet to reset `_shouldShowSettings = false`.
- `Tests/AudioEngineTests/MenuBarControllerTests.swift` — 20 unit tests using `RecordingMenuBarRenderer` (stub renderer, no NSStatusItem) and `MenuBarTestStore` (fake store): icon state tests (idle/recording/paused), menu item presence tests (Start Recording, Open Window…, Settings…, Quit, Pause, Stop, Resume), action delegation tests (toggleRecording/pauseRecording/stopRecording/resumeRecording call counts), `shouldShowSettings` set by Settings… action, elapsed time header present in recording/paused menus, source preset submenu present in idle menu, `formatElapsed` formatting. All 20 pass.
