# REQ-034: Permission failure UX paths

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** ui

## Task

Wire the permission failure paths from spec Section 6.5:
- **Mic denied**: source dropdown options that need mic become disabled with "Mic access denied — Open Settings" affordance (link opens System Settings → Privacy → Microphone deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`)
- **Audio-tap denied**: all options except "Microphone only" disabled with the same affordance for the audio-tap pane
- **MDM blocks tap APIs**: caught at session start; show fatal alert offering fallback to mic-only

## Context

Spec Section 6.5 specifies each path. Section 4.7 specifies lazy permission requests — failures are surfaced post-prompt, not pre-emptively.

## Acceptance Criteria

- [ ] When mic is denied, "Everything + Mic" and "Microphone only" rows in the dropdown are visually greyed and show the affordance text
- [ ] Clicking the "Open Settings" affordance opens System Settings to the correct pane
- [ ] When audio-tap is denied, only "Microphone only" remains enabled
- [ ] On MDM-blocked tap APIs, a fatal alert offers "Switch to mic-only" or "Quit"
- [ ] Granting permission via System Settings updates the dropdown within 1 s of returning to the app

## Verification Steps

1. **test** Unit test sets `permissionManager.microphoneStatus = .denied`; asserts mic-involving options return `.disabled` with the documented affordance
   - Expected: test passes
2. **ui** Manual: deny mic in System Settings, return to app; click dropdown; take snapshot
   - Expected: mic options greyed, affordance visible, link opens correct pane

## Integration

**Reachability:** Surfaces in `SourcePickerView` (REQ-024) and as fatal alerts via `ErrorSurface` (REQ-033).

**Data dependencies:** Reads `PermissionManager` state (REQ-019).

**Service dependencies:** Depends on REQ-019, REQ-024, REQ-033.
