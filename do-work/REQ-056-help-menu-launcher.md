# REQ-056: Help Menu Command Opens User Guide

**UR:** UR-006
**Status:** backlog
**Created:** 2026-05-10
**Layer:** ui

## Task

Wire a "User Guide" command into the standard macOS Help menu of `SystemAudioRecorderApp` that, when invoked, opens the GitHub-hosted user guide in the user's default browser.

Specifically:

1. Add a `UserGuide` constant (URL) to a centralised location. Recommended location: extend `App/Errors/PermissionDeepLink.swift` to also house non-permission user-facing URLs, OR add a new `App/Resources/UserGuide.swift` enum with a single `static let url: URL` constant. Pick the latter to keep `PermissionDeepLink` focused on its current responsibility.
   - URL value: `https://github.com/rawphp/system-audio-recorder/blob/main/docs/user-guide.md`
2. In `App/SystemAudioRecorderApp.swift`, attach a `.commands { ... }` modifier to the `WindowGroup`. Inside, use `CommandGroup(replacing: .help) { ... }` to replace the default SwiftUI Help menu — this avoids the broken-Help-Book search problem flagged in ideate (the default menu searches an Apple Help Book we have not registered).
3. Inside the replacing `CommandGroup`, add one button: `Button("System Audio Recorder User Guide…") { NSWorkspace.shared.open(UserGuide.url) }`. Assign the standard help shortcut `.keyboardShortcut("?", modifiers: .command)` so cmd-? opens the guide.

The button title ends with "…" because clicking it leaves the app (per macOS HIG for menu items that open external content).

## Context

UR-006's clarifications established that the docs open externally — `NSWorkspace.shared.open(...)` to a GitHub URL — and that the Help menu is one of two launch surfaces (the in-window button is the other, REQ-057). Both surfaces target the same URL, so a single shared constant prevents drift.

Connector observation from ideate: the existing codebase uses `NSWorkspace.shared.open(URL)` in `App/Views/ContentView.swift:185` and `App/Views/SourcePickerView.swift:169` for permission deep-links. Reuse the same call site pattern; do not introduce a wrapper service for a one-line operation.

Challenger observation incorporated: the default SwiftUI `.help` `CommandGroup` includes a search field bound to `NSHelpManager` searching for an Apple Help Book. Without registering one, the search field is functional UI that returns nothing — confusing. `CommandGroup(replacing: .help)` removes that machinery and leaves only the button we add. This is the correct treatment.

The user guide URL points to the file produced by REQ-055; if that REQ has not landed yet at run time, the link will 404 on GitHub. That is acceptable — REQ-055 is sequenced earlier in the same UR.

## Acceptance Criteria

- [ ] A new file `App/Resources/UserGuide.swift` (or equivalent) contains a single public enum `UserGuide` with `static let url: URL = URL(string: "https://github.com/rawphp/system-audio-recorder/blob/main/docs/user-guide.md")!`.
- [ ] `App/SystemAudioRecorderApp.swift`'s `WindowGroup` carries a `.commands { CommandGroup(replacing: .help) { ... } }` modifier.
- [ ] Inside the `CommandGroup(replacing: .help)`, exactly one button is present, titled "System Audio Recorder User Guide…", with `keyboardShortcut("?", modifiers: .command)`.
- [ ] The button's action calls `NSWorkspace.shared.open(UserGuide.url)`.
- [ ] When the app is run and the menu bar is inspected, the Help menu shows only "System Audio Recorder User Guide…" — no Help Book search field, no other items.
- [ ] Triggering the menu item (or pressing cmd-?) opens the URL in the user's default browser.
- [ ] `make build` succeeds with no new warnings or errors.
- [ ] `make test` passes (no existing tests should regress; new code is wiring-only and does not introduce testable logic beyond the URL constant).

## Verification Steps

1. **build** `make build`
   - Expected: build succeeds with no warnings about deprecated APIs or missing symbols.
2. **test** `make test`
   - Expected: all existing tests pass; no regressions.
3. **ui** Launch the built `.app`, click the **Help** menu in the menu bar.
   - Expected: exactly one item visible, titled "System Audio Recorder User Guide…". No search field. No other Apple-default Help Book items.
4. **ui** Click the menu item. (Equivalently, press `cmd-?` while the app is foreground.)
   - Expected: the user's default browser opens to `https://github.com/rawphp/system-audio-recorder/blob/main/docs/user-guide.md`. Network state permitting, GitHub's Markdown view renders the user guide.
5. **runtime** `grep -n 'UserGuide.url' App/` (after the change)
   - Expected: at least one match in `SystemAudioRecorderApp.swift` (the menu wiring), and one in REQ-057's button (after that REQ lands).

## Integration

**Reachability:** Reached by the user via the standard macOS menu bar `Help` menu (visible whenever the app is foreground) or the `cmd-?` keyboard shortcut. The reachability surface is `App/SystemAudioRecorderApp.swift`'s `WindowGroup`'s `.commands` modifier — the menu only renders when there is at least one window (a known macOS behaviour). For dockless / menu-bar-only sessions, REQ-057's in-window Help button is the alternative entry point (and the user can also open the window from the menu-bar item to get the menu).

**Data dependencies:** Reads `UserGuide.url` (the new constant). Writes nothing.

**Service dependencies:** `NSWorkspace.shared.open(_:)` from AppKit — already an established pattern in `App/Views/ContentView.swift:185` and `App/Views/SourcePickerView.swift:169`. No new framework dependency. SwiftUI `Commands` API (`CommandGroup`) requires macOS 11+; the project already targets macOS 14.4+.

## Assets

- (none)
