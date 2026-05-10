# REQ-055: Write End-User Guide at docs/user-guide.md

**UR:** UR-006
**Status:** backlog
**Created:** 2026-05-10
**Layer:** supporting

## Task

Author `docs/user-guide.md` — a Markdown end-user guide written for a non-technical macOS user who downloads the notarized DMG and double-clicks the app icon. No `make`, no `xcodegen`, no terminal commands. Pure end-user voice.

The guide must cover these sections, in this order:

1. **What this app does** — one paragraph explaining "records system audio (and optionally your mic) to MP3, no virtual audio devices required". Set expectations.
2. **Requirements** — macOS 14.4 (Sonoma) or later; permissions list; disk space note.
3. **Install** — drag-to-Applications from the DMG; first-launch Gatekeeper note (the DMG is notarized, so the user should NOT see "unidentified developer", but document the right-click → Open fallback in case).
4. **First-launch permissions** — the one section that matters most. Walk the user through granting:
   - **System Audio Recording** (required) — link to `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. Embed the screenshot from REQ-054 (denied + granted states). Note the pane label changed across macOS versions ("Screen Recording" on 14, "Screen & System Audio Recording" on 15+).
   - **Microphone** (only if recording mic) — link to `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`. Embed screenshot.
   - Note: the global hotkey does NOT require Accessibility permission. The app uses Carbon's `RegisterEventHotKey` via the `KeyboardShortcuts` SPM package, which is process-scoped and does not surface in System Settings. Do not include an Accessibility section.
5. **Recording your first clip** — pick a source, hit Start, hit Stop, see the toast. Embed screenshots from REQ-053.
6. **Where MP3s are saved** — the default is `~/Music/Recordings/`, but note this is configurable in Settings → Output. Show the OutputSettingsView screenshot. Tell the user to use the "Reveal in Finder" button on the post-stop toast as the path-agnostic way to find their file.
7. **Recording with the menu-bar item** — brief mention that the app has a menu-bar status item for users who hide the dock.
8. **Hotkey** — how to set the global hotkey (REQ-020) inside the app's settings. No system-level permission is required; if the hotkey doesn't fire, the cause is almost always that another app has claimed the same combination.
9. **Troubleshooting** — at minimum:
   - "I get no audio in the recording" — most often System Audio Recording permission denied; jump to step 4.
   - "The Start button is greyed out" — source not selected, or tap unavailable; the in-app affordance from REQ-050 explains why.
   - "My hotkey doesn't fire" — another app has claimed the same shortcut. Pick a different combination in the app's hotkey settings.
   - "The app crashed mid-recording" — REQ-016 handles partial-file recovery; mention briefly that the partial WAV is preserved and a re-encode option appears on next launch.
10. **Uninstall** — drag from /Applications to Trash; mention the Recordings folder is left behind on purpose.

Embed images using GitHub-relative paths: `![alt](user-guide-assets/app/01-main-window-idle.png)`. Use deep-link URLs as inline links wherever a "go to System Settings" instruction appears, e.g. `[Open System Audio Recording in System Settings](x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture)`.

Tone: short paragraphs, second person ("you"), no jargon. ~600–1200 words plus images.

## Context

UR-006 establishes the doc as `docs/user-guide.md`, opened externally on GitHub via `NSWorkspace.shared.open(_:)` from the Help menu and an in-window Help button. Screenshots are produced by REQ-053 (app surfaces) and REQ-054 (permission panes).

Connector observations from ideate:
- The repo already has `docs/manual-tests.md` and `docs/release-signing.md` for contributors. Place the user guide alongside them; the `docs/` folder cleanly separates contributor docs from end-user docs.
- `App/Errors/PermissionDeepLink.swift` is the canonical source of `x-apple.systempreferences:` URLs the app uses internally. The guide should use the *same* URLs so the in-app deep-links and the documentation never drift apart. If a URL changes, both move together.
- Recent REQs (REQ-049 through REQ-052) shipped permission UX affordances — re-probe on picker open, denied state messaging, fail-fast tap gate. The troubleshooting section's symptoms must match what those REQs surface, not invent new failure modes.

Challenger observation incorporated: the "Where MP3s are saved" section is permanently fragile if it states the path as fact. The guide must phrase it as "the default is ~/Music/Recordings/, configurable in Settings → Output" and direct users to the "Reveal in Finder" button as the source of truth.

## Acceptance Criteria

- [ ] `docs/user-guide.md` exists and is valid GitHub-flavored Markdown.
- [ ] All ten section headings listed in the Task section are present, in the listed order.
- [ ] Each `x-apple.systempreferences:` URL in the guide matches an existing constant in `App/Errors/PermissionDeepLink.swift` (or, for Accessibility, a documented Apple-canonical URL added to `PermissionDeepLink.swift` if not already present).
- [ ] Image references resolve: every `![...](user-guide-assets/...)` path points to a file produced by REQ-053 or REQ-054.
- [ ] The output-folder section does NOT state `~/Music/Recordings/` as a fixed location — it qualifies it as "the default" and points to Settings + Reveal in Finder.
- [ ] Document length is between 600 and 2000 words (excluding images).
- [ ] No developer-facing instructions (no `make`, no `xcodegen`, no `xcodebuild`, no terminal commands) appear in the guide.
- [ ] The guide renders cleanly on github.com — verified by previewing the file in a Markdown renderer or pushing to a branch and checking the GitHub blob view.

## Verification Steps

> Execute these after writing the guide.

1. **runtime** `test -f docs/user-guide.md && wc -w docs/user-guide.md`
   - Expected: file exists; word count between 600 and 2000.
2. **runtime** `grep -E '^#{1,3} ' docs/user-guide.md`
   - Expected: at least 10 headings matching the section list above.
3. **runtime** `grep -oE '\(user-guide-assets/[^)]+\)' docs/user-guide.md | while read path; do real="${path#(}"; real="${real%)}"; test -f "docs/$real" || echo "MISSING: $real"; done`
   - Expected: no `MISSING:` lines (every image reference resolves).
4. **runtime** `grep -E '(make build|xcodegen|xcodebuild|brew install|notarytool)' docs/user-guide.md && exit 1 || exit 0`
   - Expected: command exits 0 (no developer-tool references in the user guide).
5. **runtime** `grep -E '~/Music/Recordings/?[^a-zA-Z]' docs/user-guide.md`
   - Expected: matches exist, but every match is in a phrase that includes "default" or links to the Settings → Output flow (manual review of context).
6. **ui** Open `docs/user-guide.md` in a Markdown previewer (or push to a branch and view on github.com) and confirm: images load, deep-links are clickable, headings render in the right order, no broken Markdown.

## Integration

**Reachability:** Reached by end users via the GitHub blob URL `https://github.com/rawphp/system-audio-recorder/blob/main/docs/user-guide.md`, which is opened by REQ-056 (Help menu) and REQ-057 (in-window Help button) via `NSWorkspace.shared.open(_:)`. Also discoverable from the repo's `docs/` folder for users who land on the GitHub page directly.

**Data dependencies:** Reads PNG assets at `docs/user-guide-assets/app/*.png` (produced by REQ-053) and `docs/user-guide-assets/permissions/*.png` (produced by REQ-054) at view time via GitHub's image renderer.

**Service dependencies:** Depends on (a) `App/Errors/PermissionDeepLink.swift` for canonical `x-apple.systempreferences:` URL strings — the guide must cite the same URLs the app uses; (b) GitHub's blob/Markdown renderer to render the document. No new service dependencies.

## Assets

- (none — produced by this REQ)
