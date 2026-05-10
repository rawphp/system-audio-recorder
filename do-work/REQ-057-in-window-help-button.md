# REQ-057: In-Window Help Button Opens User Guide

**UR:** UR-006
**Status:** backlog
**Created:** 2026-05-10
**Layer:** ui

## Task

Add a Help button to `ContentView`'s title-bar row, sibling to the existing Settings cog at `App/Views/ContentView.swift:88-95`. Clicking the button opens the GitHub-hosted user guide in the user's default browser via `NSWorkspace.shared.open(UserGuide.url)`.

Specifically:

1. In `App/Views/ContentView.swift`, in the title-bar `HStack` (around line 84–96), insert a new button immediately before the existing Settings cog button. Use `Image(systemName: "questionmark.circle")` as the icon, matching the visual weight of the existing gearshape icon.
2. The button's action calls `NSWorkspace.shared.open(UserGuide.url)` — using the same constant introduced in REQ-056. Do NOT duplicate the URL string.
3. Apply `.buttonStyle(.plain)` and `.accessibilityLabel("Open User Guide")` to match the Settings cog's styling and accessibility treatment.
4. The icon must be the standard SF Symbol `questionmark.circle` (or `questionmark.circle.fill` if a heavier weight reads better against the title-bar text — pick whichever matches the gearshape's visual weight in the same row).

## Context

UR-006 commits to two launch surfaces for the user guide: the Help menu (REQ-056) and an in-window button (this REQ). The in-window button reaches users who run dockless (no foreground menu bar visible) — flagged as a real audience by ideate, since `AppSettings.showInDock` and `DockPolicyController` allow that mode. It also matches a common Mac UI pattern where utilities offer a "?" near their settings cog.

Connector observations:
- The existing Settings cog at `App/Views/ContentView.swift:88-95` is the exact pattern to mirror — same title-bar row, same `.buttonStyle(.plain)`, same `.accessibilityLabel(...)` treatment. Reuse, don't reinvent.
- `NSWorkspace.shared.open(URL)` is already used at `App/Views/ContentView.swift:185` (a permission deep-link) — this REQ uses the identical call style.
- The URL constant `UserGuide.url` is introduced by REQ-056 and reused here. If REQ-056 has not landed when this REQ is implemented, declare `UserGuide.url` as part of this REQ instead and have REQ-056 reuse it. Either ordering works; do not duplicate the URL.

Challenger observation incorporated: the "?" icon must not visually crowd the gearshape. Both buttons should fit in the title-bar row without forcing a vertical layout shift. If the row gets too tight, prefer reducing the title text padding over removing either button.

## Acceptance Criteria

- [ ] `App/Views/ContentView.swift`'s title-bar `HStack` contains a Help button placed immediately before the existing Settings cog button.
- [ ] The button icon is `Image(systemName: "questionmark.circle")` (or `.fill` variant), with `.imageScale(.medium)` matching the gearshape.
- [ ] The button's action is exactly `{ NSWorkspace.shared.open(UserGuide.url) }`. The URL string does not appear inline — it is read from the `UserGuide` enum.
- [ ] The button has `.buttonStyle(.plain)` and `.accessibilityLabel("Open User Guide")`.
- [ ] When the app's main window is open, the user sees a "?" icon next to the existing settings cog in the title bar.
- [ ] Clicking the "?" icon opens the user's default browser to the user guide URL.
- [ ] No regression in the title-bar row layout — the title text and existing settings cog still render at their previous positions.
- [ ] `make build` succeeds with no new warnings.
- [ ] `make test` passes; existing `ContentView` and `ContentViewModel` tests are not broken.

## Verification Steps

1. **build** `make build`
   - Expected: build succeeds with no warnings.
2. **test** `make test`
   - Expected: all existing tests pass; no regressions.
3. **ui** Launch the built `.app` and observe the main window's title-bar row.
   - Expected: a "?" icon appears immediately to the left of the settings gearshape; both icons are the same visual weight; the title text "System Audio Recorder" still renders to the left.
4. **ui** Click the "?" icon.
   - Expected: the default browser opens to `https://github.com/rawphp/system-audio-recorder/blob/main/docs/user-guide.md`.
5. **ui** With VoiceOver on (or via the Accessibility Inspector), focus the "?" icon.
   - Expected: the accessibility label reads "Open User Guide".
6. **runtime** `grep -c 'NSWorkspace.shared.open(UserGuide.url)' App/Views/ContentView.swift`
   - Expected: `1` (exactly one call site introduced by this REQ in ContentView).

## Integration

**Reachability:** Reached by the user as a "?" button visible in `ContentView`'s title-bar row at `App/Views/ContentView.swift` (currently lines 82–96 — the title-bar `HStack`). Visible whenever the main window is open, including dockless sessions where the menu-bar Help command (REQ-056) is not visible.

**Data dependencies:** Reads `UserGuide.url` (constant introduced by REQ-056 or this REQ — whichever lands first). Writes nothing.

**Service dependencies:** `NSWorkspace.shared.open(_:)` from AppKit — already used at `App/Views/ContentView.swift:185` for the permission deep-link. No new framework dependency. SwiftUI's `Image(systemName:)` and `Button` — already used throughout `ContentView`.

## Assets

- (none)
