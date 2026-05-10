---
ur: UR-005
received: 2026-05-10
status: captured
classification: feature
layers_in_scope: [audio_engine, ui, supporting]
layer_decisions: {}
reqs:
  - { id: REQ-047, layer: supporting, integration_confidence: high }
  - { id: REQ-048, layer: supporting, integration_confidence: high }
  - { id: REQ-049, layer: ui, integration_confidence: high }
  - { id: REQ-050, layer: ui, integration_confidence: high }
  - { id: REQ-051, layer: ui, integration_confidence: high }
  - { id: REQ-052, layer: audio_engine, integration_confidence: high }
acknowledged_partials: []
---

<!-- capture-summary-start -->
## Capture summary (2026-05-10)

| Item | Value |
|---|---|
| Classification | feature |
| Layers in scope | audio_engine, ui, supporting |
| Layer decisions | (none — all covered) |
| REQs generated | 6 |

| REQ | Layer | Integration confidence |
|---|---|---|
| REQ-047 | supporting | high |
| REQ-048 | supporting | high |
| REQ-049 | ui | high |
| REQ-050 | ui | high |
| REQ-051 | ui | high |
| REQ-052 | audio_engine | high |
<!-- capture-summary-end -->

# UR-005: User Request

## Request

start cannot change from mic only

[Screenshot attached: assets/dropdown-screenshot.png]

The screenshot shows the "Recording from:" dropdown opened in the System Audio Recorder app. "Microphone only" is the current selection (checkmark visible). The other options "Everything", "Everything + Mic", and "Specific app..." appear greyed out / disabled and cannot be selected. Only "Microphone only" and "Advanced..." are selectable.

## Clarifications

**Q:** The most likely root cause is that PermissionManager.requestAudioTap() is never called at startup, so audioTapStatus stays .unknown for everyone. What's the scope of the fix you want?
**A:** Full hardening — wiring fix (probe at startup) + tap-denied affordance (mirroring the mic-denied "Open Settings" row) + re-probe so granting the entitlement at runtime updates the picker without restart.

**Q:** AudioHardwareCreateProcessTap is a real CoreAudio call. How should the re-probe balance freshness vs. cost?
**A:** Event-driven — probe on app foreground, on menu open, and on tap-related setting change. No timer; picker-open is the moment of truth.

**Q:** Tap denial is an entitlement/policy issue, not a System Settings toggle. What should the "Tap unavailable" affordance do when clicked?
**A:** Deep-link to System Settings > Privacy & Security (general pane). Closest analogue to the existing mic affordance, even if there's no specific tap toggle.
