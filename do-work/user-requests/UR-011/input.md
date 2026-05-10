---
ur: UR-011
received: 2026-05-11
status: captured
classification: feature
layers_in_scope: [audio_engine, ui, supporting]
layer_decisions:
  audio_engine: no
reqs:
  - { id: REQ-062, layer: supporting, integration_confidence: n/a }
  - { id: REQ-063, layer: ui, integration_confidence: high }
acknowledged_partials: []
---

<!-- capture-summary-start -->
## Capture summary (2026-05-11)

| Item | Value |
|---|---|
| Classification | feature |
| Layers in scope | audio_engine, ui, supporting |
| Layer decisions | audio_engine: no |
| REQs generated | 2 |

| REQ | Layer | Integration confidence |
|---|---|---|
| REQ-062 | supporting | n/a |
| REQ-063 | ui | high |
<!-- capture-summary-end -->

# UR-011: User Request

## Request

it seems like I have to click 'Stop' recording button twice to make it fire. Once does not do the stopping job. Verify and fix.

## Clarifications

**Q:** The same await-before-flip-state pattern exists in pauseRecording and resumeRecording (App/AppStore.swift:385-396). On Stop the lag is visible because the session teardown drains writer/encoder work. On Pause/Resume the work is short, so users probably don't notice. What scope?
**A:** Stop + Pause + Resume — apply the same fix to all three transitions for consistency with the class docstring's stated pattern.

**Q:** When the user clicks Stop and sessionState flips to .stopped synchronously, the controls collapse to the idle layout immediately — but encoding is still running in the background. Do you want any additional in-flight feedback during the brief stop-tail (while session.stop() drains)?
**A:** Add a transient toast — flip to idle, but show a "Finishing recording…" toast that disappears when session.stop() returns.
