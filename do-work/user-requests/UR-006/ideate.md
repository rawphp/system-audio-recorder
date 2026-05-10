# Ideate — UR-006

**Reviewed:** 2026-05-10

## Explorer — Assumptions & Perspectives

- The brief says "launchable via the app" but doesn't specify *where* — macOS apps have at least three reachable surfaces: the standard `Help` menu (cmd-? convention), an in-window "Help"/"?" button, and the menu-bar status-item menu (this app has both a `WindowGroup` and a `MenuBarController`). Picking only one leaves users who live in the other surface stranded. Triggered by: "launchable via the app".
- "End-user docs" assumes the reader is a non-technical macOS user, but the existing audience for this app is mixed — `README.md` is developer-oriented (xcodegen, make build, notarytool). The user guide must be written for someone who only sees the DMG and the app icon, with no terminal exposure. Triggered by: "end-user docs".
- The doc must survive offline use — the app is a sandboxed macOS utility distributed via DMG, with no guaranteed network at first run (and recording itself doesn't need network). A doc that links to a remote site fails for users who launch it on a plane or behind a firewall. Triggered by: "launchable via the app" + the app's offline-capable nature.

## Challenger — Risks & Edge Cases

- A bundled Markdown file is not natively renderable by macOS — opening `.md` in Finder hands it to whichever app the user has registered (often a code editor, sometimes nothing). "Open the user-guide.md" via `NSWorkspace.open(_:)` is unreliable as an end-user experience. The doc needs a render path: either bundle as HTML, render Markdown→HTML at build time, or display in an in-app `WebView`/`Text` view. Triggered by: assistant's earlier `docs/user-guide.md` recommendation.
- The "where MP3 files are saved" line in any doc will go stale the moment the user changes the output directory in Settings. Hard-coding `~/Music/Recordings/` in the prose creates a permanent lie for anyone with a custom path. The doc should either (a) say "your configured output folder, default `~/Music/Recordings/`" or (b) deep-link to Settings. Triggered by: existing `OutputSettingsView.swift` allowing path override.
- Permission instructions are version-fragile: macOS rewords System Settings panes between releases (e.g. 14 → 15 changed several pane names). A doc that says "go to System Settings → Privacy & Security → Microphone" will mismatch reality on a future macOS, and updating prose across releases is high-friction. Consider linking directly via `x-apple.systempreferences:` URLs instead of describing the click path. Triggered by: README mentioning permissions, and `PermissionManager.swift` already requesting them.
- Help menu items in a macOS SwiftUI app are not free — the default `Help` menu contains a search field that searches Apple Help Book content via `NSHelpManager`. If we add a custom `Help` command without registering a Help Book, the search is broken/empty for our content. Either register a Help Book (heavyweight) or replace the menu with our own command. Triggered by: "launchable via the app" + SwiftUI `CommandGroup(replacing: .help)` semantics.
- The menu-bar surface (`MenuBarController`) is the *only* UI for users who hide the dock icon — `AppSettings.showInDock` is wired through `DockPolicyController` and a user can run dockless. A `Help` command attached only to the `WindowGroup` `.commands` is invisible to a dockless user. Triggered by: `DockPolicyController` existence.

## Connector — Links & Reuse

- The repo already has a `docs/` folder with `manual-tests.md` and `release-signing.md` — both internal-facing. Add `docs/user-guide.md` alongside them and the project gets a clean separation: `docs/manual-tests.md` and `docs/release-signing.md` for contributors, `docs/user-guide.md` for end users. Same git-tracked surface.
- `PermissionManager.swift` already knows the canonical permission states (granted / denied / pending) for system-audio-tap, microphone, accessibility. The user guide's "permission troubleshooting" section can mirror those exact state names so users can match what they see in the app. Reuse the vocabulary, don't invent new terms.
- The recent REQs (REQ-049 through REQ-052 in the backlog) all touch tap-permission UX (re-probe on source picker open, denied affordance, fail-fast tap gate, real-tap validation). The user-guide troubleshooting section should reference the same observable symptoms those REQs address — there's a coherent permission story emerging that the doc should match, not contradict.

## Summary

The most important call to make before capture: pick *one* in-app launch surface (Help menu vs. menu-bar item vs. in-window button) and *one* render path (bundled HTML in a WebView vs. external Markdown vs. in-app SwiftUI view) — those two choices drive everything else. Second priority: scope the doc to "what an end-user can act on" and exclude developer/release content, which already lives in `README.md`. Third: keep the doc offline and self-contained inside the app bundle so it works on day one of a notarized DMG with no network.
