# REQ-026: Live mix-level meter visualization

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/MixLevelMeterView.swift`. A single horizontal level meter showing the mix bus RMS in dBFS. Renders at 50 Hz, driven by `AppStore.meters.mixLevel`. Includes a numeric dB readout to the right (e.g. "-12 dB"). Idle (no session) shows `-∞ dB` and an empty bar.

## Context

Spec Section 4.1 shows the meter layout. Spec Section 5.3 specifies 50 Hz updates from the mix-node tap. The meter is "unified" — separate per-source meters live in the Advanced panel only (REQ-028).

## Acceptance Criteria

- [ ] Bar fills proportionally to dBFS (linear from -60 to 0 dBFS)
- [ ] Bar uses three colours: green up to -12 dBFS, yellow -12 to -3 dBFS, red above -3 dBFS
- [ ] Numeric readout updates at 50 Hz; rounds to nearest integer dB
- [ ] Idle state shows `-∞ dB` and empty bar
- [ ] CPU cost is < 1% on M1 (verified by Instruments time profile)

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
2. **ui** Launch app, start "Microphone only" recording, speak; take snapshot of meter
   - Expected: meter bar visibly moves; readout shows fluctuating dB value

## Integration

**Reachability:** Embedded in `ContentView` (REQ-023). Per-source meters reuse the same component in `MixerPanelView` (REQ-028).

**Data dependencies:** Subscribes to `AppStore.meters.mixLevel` (REQ-022 / REQ-011).

**Service dependencies:** Depends on REQ-011 (level meter taps).
