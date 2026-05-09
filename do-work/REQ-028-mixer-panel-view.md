# REQ-028: MixerPanelView — advanced multi-source mixer panel

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/MixerPanelView.swift`, the panel that opens when the user picks "Advanced…" from the source dropdown. Shows a vertical list of selectable audio sources (each with checkbox, app icon, name, per-source level meter, gain slider 0.0–2.0). Includes a microphone row at the bottom with the same controls. Selected sources + gains feed into `RecordingSession.start(config:)` when recording begins.

## Context

Spec Section 4.6 places per-source meters and gain sliders in the Advanced panel only. Spec Section 5.3 says default screen always uses gain 1.0; per-source gain only applies when the user selects Advanced.

## Acceptance Criteria

- [ ] Panel lists every entry from `AudioSourceCatalog` plus a microphone row
- [ ] Each row has: checkbox, app icon, app name, level meter, gain slider with numeric readout (e.g. "0.0 dB")
- [ ] Gain changes apply within ~10 ms (live during a recording)
- [ ] Selecting "Apply" updates `AppSettings.lastSourcePreset` to "Advanced" and stores the chosen source IDs + gains
- [ ] Cancelling the panel reverts to the previous preset
- [ ] Mic row is greyed if mic permission is denied

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
2. **ui** Launch app, open Advanced…, take snapshot
   - Expected: panel shows source list, mic row, gain sliders, OK/Cancel buttons

## Integration

**Reachability:** Opened from "Advanced…" item in `SourcePickerView` (REQ-024).

**Data dependencies:** Reads `AudioSourceCatalog`; writes selection + gains to `AppSettings`; meter values from `AppStore.meters`.

**Service dependencies:** Depends on REQ-006 (catalog), REQ-011 (meters), REQ-021 (settings), REQ-026 (meter view component).
