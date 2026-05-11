---
ur: UR-012
received: 2026-05-11
status: captured
classification: feature
layers_in_scope: [audio_engine, ui, supporting]
layer_decisions: { supporting: no }
reqs:
  - { id: REQ-064, layer: audio_engine, integration_confidence: high }
  - { id: REQ-065, layer: audio_engine, integration_confidence: high }
  - { id: REQ-066, layer: audio_engine, integration_confidence: high }
  - { id: REQ-067, layer: ui, integration_confidence: high }
  - { id: REQ-068, layer: ui, integration_confidence: high }
acknowledged_partials: []
---

<!-- capture-summary-start -->
## Capture summary (2026-05-11)

| Item | Value |
|---|---|
| Classification | feature |
| Layers in scope | audio_engine, ui, supporting |
| Layer decisions | supporting: no |
| REQs generated | 5 |

| REQ | Layer | Integration confidence |
|---|---|---|
| REQ-064 | audio_engine | high |
| REQ-065 | audio_engine | high |
| REQ-066 | audio_engine | high |
| REQ-067 | ui | high |
| REQ-068 | ui | high |
<!-- capture-summary-end -->

# UR-012: User Request

## Request

when I select Google Chrome as the source for recording, there is no recording. It doesn't record when it's marked "record from everywhere". It works.

(Attached screenshot: System Audio Recorder window showing "Recording from: Google Chrome" selected with the Start Recording button. See assets/screenshot.png)

### Follow-up clarification

> selecting 'helper' it records from Chrome

(Attached screenshot of the "Choose an app" picker showing a `helper` entry alongside `Google Chrome`. See assets/picker-helper.png. Picking the un-iconed `helper` entry records audio from Chrome; picking the `Google Chrome` entry does not.)

## Clarifications

**Q:** How should the picker treat multi-process apps (Chrome, Slack, VS Code, etc.)?
**A:** Group by bundle. One row per app bundle. Selecting "Google Chrome" taps the parent pid + every helper pid sharing the bundle prefix. Requires changing `SourcePreset` to carry a bundle ID and tapping multiple pids in `.specificApp`.

**Q:** Should grouped capture track helpers that spawn after recording starts?
**A:** Snapshot at start. Tap every helper alive at recording start; ignore new ones spawned mid-recording. Matches today's `.everything` behaviour, ships the fix without expanding `ProcessTapCapture`'s contract. Trade-off: a new tab playing audio mid-recording is missed — accepted.

**Q:** How should the public `SourcePreset` encode a grouped-bundle selection?
**A:** Change to bundle ID. Replace `.specificApp(processID: pid_t)` with `.specificApp(bundleID: String)`. `settingsKey` becomes `SpecificApp:com.google.Chrome`. Pids resolve at recording-start time. Old persisted `SpecificApp:<numeric-pid>` values silently fall back to `.everything` (matches the existing graceful-default behaviour at `AppStore.swift:37`).

**Q:** What happens to audio-emitting pids that can't be grouped under a parent app bundle?
**A:** Show them with their raw bundle ID as the label (and no icon). Power-user escape hatch. Groupable helpers (those whose bundle ID matches the parent + `.helper*` pattern) are folded into the parent row — only the parent shows.
