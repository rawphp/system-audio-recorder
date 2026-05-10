---
ur: UR-006
received: 2026-05-10
status: intake
---

# UR-006: User Request

## Request

I want to create documentation for this project - end-user docs... what do you recommend?

(Assistant recommended: a single in-app Help page / short user guide bundled with the DMG covering install/first-run permissions — System Audio Recording + Mic + Accessibility for hotkeys — how to start/stop a recording, where MP3 files are saved, and a troubleshooting section — no audio captured, permission stuck, hotkey not firing. Keep it as one Markdown file in `docs/user-guide.md` plus a "Help" menu item that opens it. Avoid spinning up a docs site since the surface area doesn't justify it. Tradeoff: a full docs site looks more professional but is overkill for a single-screen utility.)

yes, draft it via do-work... it needs to be launchable via the app

## Clarifications

**Q:** You said the docs need to be "launchable via the app" — from which surface(s) should users be able to open them?
**A:** Two surfaces: the standard Help menu (cmd-?) AND an in-window "?"/Help button inside ContentView. NOT the menu-bar status item.

**Q:** When the user clicks the Help menu item or in-window button, how should the doc be displayed?
**A:** Open the doc on GitHub in the user's default browser via `NSWorkspace.shared.open(_:)`. No in-app rendering, no bundled HTML.

**Q:** The current README.md is developer-focused (xcodegen, make build, notarytool). Where on GitHub should the in-app link point?
**A:** A new dedicated end-user guide at `docs/user-guide.md`. Keep README as-is (developer-focused). Link to its GitHub blob URL.

**Q:** There's no git remote configured locally. What URL should the in-app link target ship with?
**A:** Remote was added during this session: `git@github.com:rawphp/system-audio-recorder.git`. The web URL to use is `https://github.com/rawphp/system-audio-recorder/blob/main/docs/user-guide.md`.

**Q:** Should the user guide include screenshots of the app and macOS permission dialogs, or stay text-only?
**A:** Full visual walkthrough — screenshots of the app's main views (window, source picker, settings) AND of the macOS System Settings permission panes (System Audio Recording, Microphone, Accessibility for hotkeys).
