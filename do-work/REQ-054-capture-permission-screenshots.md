# REQ-054: Capture macOS Permission-Pane Screenshots for User Guide

**UR:** UR-006
**Status:** backlog
**Created:** 2026-05-10
**Layer:** supporting

## Task

Capture annotated screenshots of the macOS System Settings panes that SystemAudioRecorder requires permission for, and save them as PNG assets for embedding in `docs/user-guide.md`.

The screenshots must cover the two privacy panes the app actually requests permission from:

1. **System Audio Recording** — `System Settings → Privacy & Security → Screen & System Audio Recording` (gates `AudioHardwareCreateProcessTap`; the pane is labelled "Screen Recording" on macOS 14 and "Screen & System Audio Recording" on macOS 15+).
2. **Microphone** — `System Settings → Privacy & Security → Microphone` showing SystemAudioRecorder in the app list (only relevant when the user enables mic recording).

Note: the global hotkey is registered via Carbon's `RegisterEventHotKey` (through the `KeyboardShortcuts` SPM package). That API does NOT require the Accessibility permission and the app never appears in `Privacy & Security → Accessibility`. Do not capture or document Accessibility — it's not part of this app's permission surface.

For System Audio Recording, capture both states (most users start denied):
- **Toggle off (denied)** — the state the user lands in on first install.
- **Toggle on (granted)** — the state needed for the app to work.

For Microphone, capture granted-only (most users have already granted it to some other app, so the pane is non-empty by the time they look).

Save PNGs to `docs/user-guide-assets/permissions/` with descriptive filenames:
- `01-system-audio-denied.png`
- `01-system-audio-granted.png`
- `02-microphone-granted.png`

Three PNGs total. PNG, 800–1200px wide.

## Context

UR-006 commits to a "full visual walkthrough" including macOS permission dialogs. Ideate flagged that permission-pane visuals shift across macOS releases — these screenshots are inherently version-fragile and will need re-capturing on each major macOS release. To minimise damage, the user guide will pair every screenshot with an `x-apple.systempreferences:` deep link (already centralised in `App/Errors/PermissionDeepLink.swift`) so users can jump there directly even if the pane has been renamed.

Connector observation: `App/Errors/PermissionDeepLink.swift` already enumerates the canonical permission URLs the app deep-links to (microphone, screen capture). Use the same labels in the screenshots' filenames and captions so the user guide and the in-app deep links speak the same vocabulary.

Capture on the lowest supported macOS version (14.4 Sonoma) where practical — visuals from older OS are more likely to still render correctly on newer ones than the reverse. If only macOS 15+ is available, document the version captured in `docs/user-guide-assets/permissions/README.md` so the guide can flag "screenshots taken on macOS X" if needed.

## Acceptance Criteria

- [ ] Exactly three PNG files exist under `docs/user-guide-assets/permissions/` with the filenames listed in the Task section.
- [ ] Each PNG shows the full System Settings pane content (not just the toggle row) — enough chrome for the user to recognise where they are.
- [ ] Toggle states (on/off) are unambiguous — a user can match what they see in their own System Settings to the screenshot.
- [ ] No personally identifying info appears in any screenshot (other apps in the permission list are acceptable; user account names in window chrome should be cropped or anonymised).
- [ ] All PNGs render correctly when previewed locally (no truncation, no broken redraws).

## Verification Steps

> Execute these after capturing the screenshots to confirm they are usable.

1. **runtime** `ls docs/user-guide-assets/permissions/*.png | wc -l`
   - Expected: `3`
2. **runtime** `file docs/user-guide-assets/permissions/*.png`
   - Expected: every line reports `PNG image data, 800 x ...` (or wider)
3. **ui** Open each PNG in Preview.app and visually confirm: the labelled pane is the one shown; the labelled toggle state (on/off) matches what the filename advertises.
   - Expected: each screenshot matches its filename description; the toggle row for SystemAudioRecorder is visible.

## Integration

**Reachability:** Asset files only — not reachable from running code. Embedded into `docs/user-guide.md` (REQ-055) via Markdown image syntax. GitHub renders them when the guide URL is opened.

**Data dependencies:** None. Screenshots are static PNG output captured outside the running app.

**Service dependencies:** None at runtime. The capture process depends on macOS System Settings being navigable and on the app having been launched at least once so it appears in the permission lists. No app code is modified.

## Assets

- `docs/user-guide-assets/permissions/` — directory created by this REQ to hold the PNGs
