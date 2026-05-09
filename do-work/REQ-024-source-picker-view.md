# REQ-024: SourcePickerView — preset dropdown with permission-aware disabled states

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/SourcePickerView.swift`, a SwiftUI `Menu` rendered as the source dropdown. Items per spec Section 4.2:
- Everything *(default)*
- Everything + Mic
- Microphone only
- Specific app… *(opens an app picker)*
- Advanced… *(opens `MixerPanelView` REQ-028)*

Items that need a denied permission appear greyed out with an inline "Mic access denied — Open Settings" affordance (per spec Section 6.5 / REQ-034). Selection persists via `AppSettings.lastSourcePreset`.

## Context

Spec Section 4.2 enumerates the dropdown items and order. Section 4.7 specifies lazy permission UX. Section 6.5 specifies failure-path affordances.

## Acceptance Criteria

- [ ] Default selected item is "Everything" on first launch
- [ ] Selecting any item updates `AppSettings.lastSourcePreset` immediately
- [ ] When mic permission is denied, mic-involving items are greyed and show "Mic access denied — Open Settings"
- [ ] When audio-tap is denied, all items except "Microphone only" are greyed
- [ ] "Specific app…" opens an app picker listing entries from `AudioSourceCatalog`
- [ ] "Advanced…" opens `MixerPanelView` as a sheet

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
2. **ui** Launch app, click the dropdown, take snapshot
   - Expected: 5 items in the documented order; "Everything" shown as selected with checkmark

## Integration

**Reachability:** Embedded in `ContentView` (REQ-023). Same dropdown also reachable via the menu bar status item (REQ-031).

**Data dependencies:** Reads `AppStore.permissionManager` for grey-out logic; reads `AppStore.sourceCatalog` for the app picker; writes `AppSettings.lastSourcePreset`.

**Service dependencies:** Depends on REQ-006 (catalog), REQ-019 (permissions), REQ-021 (settings).
