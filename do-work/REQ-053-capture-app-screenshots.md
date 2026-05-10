# REQ-053: Capture App Screenshots for User Guide

**UR:** UR-006
**Status:** backlog
**Created:** 2026-05-10
**Layer:** supporting

## Task

Capture annotated screenshots of the SystemAudioRecorder app's primary user-facing surfaces and save them as PNG assets for embedding in `docs/user-guide.md`. Screenshots are taken from a running build of the app (debug or release — the chrome looks the same).

The screenshots must cover:

1. **Main window — idle state.** `ContentView` showing source picker collapsed, level meters at zero, Start button enabled.
2. **Source picker — list view.** The "Specific app…" picker showing at least 3 detected processes, with one selected.
3. **Output settings.** `OutputSettingsView` showing the output folder field and format dropdown.
4. **Mixer panel — recording state.** `MixerPanelView` mid-recording, with non-zero level activity.
5. **Save toast — post-stop.** `SaveToast` immediately after a recording completes, showing "Reveal in Finder".

Save each PNG to `docs/user-guide-assets/app/` with descriptive filenames (e.g. `01-main-window-idle.png`, `02-source-picker.png`). Trim window chrome appropriately for embed (full window with title bar is acceptable). Target width: 800–1200px. PNG, no transparency leak.

## Context

UR-006 commits to a "full visual walkthrough" — the user explicitly chose screenshots of the app + macOS permission dialogs over text-only. The user guide opens externally on GitHub (`https://github.com/rawphp/system-audio-recorder/blob/main/docs/user-guide.md`), so embedded images are loaded via GitHub's image renderer — relative paths in the same repo work.

Connector observation: the app already has a `make build` and signed-binary release path. Screenshots should be taken from a non-debug build that visually matches what end-users see (no "DEBUG" overlays, default window size, no developer-only affordances).

## Acceptance Criteria

- [ ] Five PNG files exist under `docs/user-guide-assets/app/` with the filenames listed in the Task section.
- [ ] Each PNG is between 800–1200px wide and shows the full window/sheet content described.
- [ ] No personally identifying info appears in any screenshot (no real account names, no other-user file paths beyond `~/Music/Recordings/`, no visible Slack/email/etc. behind the app).
- [ ] Screenshots are taken on macOS 14.4+ to match the app's deployment target.
- [ ] All five PNGs render correctly when previewed locally (no truncation, no half-loaded UI).

## Verification Steps

> Execute these after capturing the screenshots to confirm they are usable.

1. **runtime** `ls docs/user-guide-assets/app/*.png | wc -l`
   - Expected: `5`
2. **runtime** `file docs/user-guide-assets/app/*.png`
   - Expected: every line reports `PNG image data, 800 x ...` (or wider, up to 1200)
3. **ui** Open each PNG in Preview.app and visually confirm: app window is fully captured, the labelled state matches (e.g. "idle" PNG shows zeroed meters; "recording" PNG shows non-zero meters).
   - Expected: each screenshot matches its filename description; no missing chrome; no obvious artefacts.

## Integration

**Reachability:** Asset files only — not reachable from running code. Embedded into `docs/user-guide.md` (REQ-055) via Markdown image syntax: `![Main window](user-guide-assets/app/01-main-window-idle.png)`. GitHub's blob renderer loads them automatically.

**Data dependencies:** None. Screenshots are static PNG output captured outside the running app. They will be read at view-time by GitHub's renderer when a user opens the guide URL.

**Service dependencies:** None at runtime. The capture process depends on a working signed build (`make build`) and the macOS screenshot facility (`Cmd-Shift-4` / `screencapture` CLI). No app code is modified by this REQ.

## Assets

- `docs/user-guide-assets/app/` — directory created by this REQ to hold the PNGs
