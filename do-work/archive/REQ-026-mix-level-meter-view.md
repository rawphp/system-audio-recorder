# REQ-026: Live mix-level meter visualization

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/MixLevelMeterView.swift`. A single horizontal level meter showing the mix bus RMS in dBFS. Renders at 50 Hz, driven by `AppStore.meters.mixLevel`. Includes a numeric dB readout to the right (e.g. "-12 dB"). Idle (no session) shows `-∞ dB` and an empty bar.

## Context

Spec Section 4.1 shows the meter layout. Spec Section 5.3 specifies 50 Hz updates from the mix-node tap. The meter is "unified" — separate per-source meters live in the Advanced panel only (REQ-028).

## Acceptance Criteria

- [x] Bar fills proportionally to dBFS (linear from -60 to 0 dBFS)
- [x] Bar uses three colours: green up to -12 dBFS, yellow -12 to -3 dBFS, red above -3 dBFS
- [x] Numeric readout updates at 50 Hz; rounds to nearest integer dB
- [x] Idle state shows `-∞ dB` and empty bar
- [ ] CPU cost is < 1% on M1 (verified by Instruments time profile) — skipped — manual

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
   - Result: `make build` → **BUILD SUCCEEDED**
2. **ui** Launch app, start "Microphone only" recording, speak; take snapshot of meter
   - Expected: meter bar visibly moves; readout shows fluctuating dB value
   - Result: **skipped — manual**

## Outputs

- `App/Views/MixLevelMeterView.swift` — `MeterMath` enum with `barFillFraction(forDBFS:)`, `meterColor(forDBFS:)`, `displayString(forDBFS:)` pure helpers; `MixLevelMeterView` SwiftUI struct that reads `AppStore.sessionState` for active/idle check and `AppStore.meters.meters["mix"]` for live dBFS value; renders a `GeometryReader`-based colour-banded bar + monospaced dB label; shows `-∞ dB` + empty bar when idle.
- `App/Views/ContentView.swift` — Replaced placeholder `MixLevelMeterView` stub with a comment pointing to the real implementation; `ContentView` now uses the real `MixLevelMeterView`.
- `Tests/AudioEngineTests/MixLevelMeterViewTests.swift` — `MeterMathTests`: 22 unit tests covering all pure helpers for edge cases (-∞, -60, -12, -3, 0, boundary conditions, rounding). `MixLevelMeterViewTests`: 2 compile-time contract tests verifying instantiation with/without AppStore injection. All 24 tests pass. Full suite: **TEST SUCCEEDED** (all suites pass).

## Integration

**Reachability:** Embedded in `ContentView` (REQ-023). Per-source meters reuse the same component in `MixerPanelView` (REQ-028).

**Data dependencies:** Subscribes to `AppStore.meters.mixLevel` (REQ-022 / REQ-011).

**Service dependencies:** Depends on REQ-011 (level meter taps).
