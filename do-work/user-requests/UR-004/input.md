---
ur: UR-004
received: 2026-05-10
status: captured
classification: bug-fix
layers_in_scope: []
layer_decisions: {}
reqs:
  - { id: REQ-044, layer: none, integration_confidence: n/a }
  - { id: REQ-045, layer: none, integration_confidence: n/a }
acknowledged_partials: []
---

<!-- capture-summary-start -->
## Capture summary (2026-05-10)

| Item | Value |
|---|---|
| Classification | bug-fix |
| Layers in scope | (none — bug-fix) |
| Layer decisions | (none — all covered) |
| REQs generated | 2 |

| REQ | Layer | Integration confidence |
|---|---|---|
| REQ-044 | none | n/a |
| REQ-045 | none | n/a |
<!-- capture-summary-end -->

# UR-004: User Request

## Request

with this default configuration: [screenshot of System Audio Recorder UI showing the source picker open with "Everything" selected as default, alongside options "Everything + Mic", "Microphone only", "Specific app...", "Advanced..."]

what is supposed to be recorded?

(follow-up after explanation that "Everything" taps every audio-emitting process the catalog knows about and mixes them into one file, excluding the mic)

if everything should be recorded then we have a bug... nothing is getting recorded

## Clarifications

**Q:** You said "nothing is getting recorded" — when you press Start Recording in Everything mode and then Stop, what actually happens to the output file?
**A:** A WAV/MP3 file is produced and plays as silence. Confirmed by Finder Get Info on `~/Music/Recordings/20260510-092323.mp3`: 24,672 bytes (29 KB on disk), 5 s duration, stereo, 48 kHz. File structure is correct; it just contains silence.

**Q:** During those ~5 seconds while recording was active, was there any audio actually playing audibly out of your speakers/headphones?
**A:** Yes — there was audible playback during the recording window, so "silent file" is a real bug, not a "nothing was playing" misunderstanding.

**Q:** macOS 14.4+ requires you to grant System Audio Recorder explicit permission to capture audio. Did you grant this?
**A:** Yes — saw the prompt on first launch and granted it. TCC is not the cause.

**Q:** Which app was producing the audible audio during the 5-second recording?
**A:** A web browser.

**Q:** Which web browser specifically?
**A:** A Chromium-based browser (Chrome / Arc / Edge / Brave family).

## Notes — Open Gaps (carried over from ideate.md)

- Hypothesis to verify in Capture: Chromium browsers emit audio from helper PIDs (`Google Chrome Helper (Renderer)`, `Google Chrome Helper (GPU)`) — not the main browser PID. The current `AudioSourceCatalog.refresh()` enumerates running processes via `NSRunningApplication.runningApplications`, which typically returns parent app PIDs only. If audio is emitted by a helper PID that's not in the catalog snapshot, Everything mode taps the silent parent and misses the audible helper — producing exactly the observed 5 s silent MP3.
- Unverified but in-scope: does Specific App mode reproduce the same bug when "Chrome" is selected? (Cheap diagnostic — same code path, single pid.)
- Unverified: does Everything mode work when audio is playing from `Music.app` (a non-helper-process source)?
- Diagnostics gap: no per-pid signal-level logging exists, so we cannot tell from a user report which pid was/wasn't producing audio. REQ-011 meter taps could be repurposed.
- Robustness gap: `ProcessTapCapture.init` fails fast on the first pid whose `RealProcessTapEmitter` throws (AudioEngine/Capture/ProcessTapCapture.swift:79–83) — degrading gracefully would prevent a single zombie pid from killing the whole Everything session.

