# Ideate — UR-005

**Reviewed:** 2026-05-10

## Explorer — Assumptions & Perspectives

- **The brief reports the symptom, not the desired behaviour.** The user said "cannot change from mic only" with a screenshot showing "Everything", "Everything + Mic", and "Specific app…" greyed out. The unstated expectation is that those options *should* be selectable on a permitted Mac. The fix scope is therefore: figure out *why* they are greyed and either (a) make them selectable when the system actually supports them, or (b) make the disabled-state explanation visible so the user is not stuck silently. The brief triggers this concern by asking "cannot change" rather than "the dropdown should let me pick X".

- **Two distinct user-perspectives are entangled in the same screenshot.** A user with a working tap entitlement seeing greyed items is hitting a *bug* (state-not-probed). A user on a Mac where the entitlement was removed or policy denies it sees the same greyed items but for a *legitimate* reason. The brief assumes the bug case but the fix has to disambiguate, otherwise we will paper over real entitlement failures. Concrete scenario: user installs an unsigned dev build with the entitlement stripped — they will assume the fix is broken when actually the build is wrong.

## Challenger — Risks & Edge Cases

- **Root-cause hypothesis: `PermissionManager.audioTapStatus` is never probed at startup.** `App/AppStore.swift` builds `PermissionManager()` (line 251) but no call site invokes `requestAudioTap()` — grep across `App/` and `Permissions/` shows the function is defined but unreferenced. `SourcePickerView.isDisabled()` reads `audioTapStatus == .available`, which stays `.unknown` forever, so every tap-needing item (`.everything`, `.everythingPlusMic`, `.specificApp`) is permanently disabled. This matches the screenshot exactly. Concrete scenario: any first-run user on any Mac sees the same dropdown — the bug is universal, not edge-case.

- **No timer or re-probe for tap status.** Even when `requestAudioTap()` is wired in at startup, the probe runs once. If the user toggles the entitlement, restarts CoreAudio, or grants permission via System Settings, the picker will not reflect it until the app restarts. The mic status has a 1 Hz poll (`startPolling`); the tap status does not. Concrete scenario: user grants tap permission in Settings while app is running → dropdown stays greyed until they quit and relaunch.

- **The probe itself swallows distinctions.** `probeAudioTap()` collapses every negative `OSStatus` into `.deniedByPolicy` — including transient HAL errors like `kAudioHardwareNotRunningError`. A flaky probe at launch could produce a permanent "denied" state until restart. Concrete scenario: CoreAudio is restarting at the moment of probe → app shows the dropdown greyed for the rest of the session, with no remediation path.

- **Disabled items have no tooltip or explanation.** When an item is greyed, the user has no way to know *why*. The mic-denied path has an inline "Open Settings" affordance (`micDeniedAffordanceButton`); the tap-unavailable path has nothing. Concrete scenario: user sees three greyed options, has no idea what to do, files this exact ticket. (This is happening right now.)

## Connector — Links & Reuse

- **Mic-denied affordance is an existing pattern to mirror.** `SourcePickerView` already has `micDeniedAffordanceButton(label:)` that swaps a disabled item for a clickable "Open Settings" row when mic is denied. The same pattern can wrap the tap-unavailable case (`PermissionDeepLink` already exists; a `tapPermissionURL` would slot in). This avoids inventing a new UX vocabulary.

- **REQ-019 (PermissionManager) and REQ-034 (Permission Failure UX) are the closest neighbours.** REQ-019 created the probe; REQ-034 built the permission-failure UX. The wiring gap (probe never invoked) and the missing tap-denied affordance are both natural extensions of those archived REQs — not greenfield work.

- **`SourcePickerView.overrideAudioTapAvailable` is the existing test seam.** Any new logic should plug into the same seam so the existing `ContentViewTests` / picker tests keep working without rewriting fixtures.

## Summary

The dropdown is greyed because `PermissionManager.requestAudioTap()` is defined but never called — `audioTapStatus` stays `.unknown` for every user from launch. Fix the wiring (probe at app start, mirror the 1 Hz mic poll for tap status), then add a tap-denied affordance that mirrors the existing mic-denied "Open Settings" row so the disabled state is explainable. Resist the urge to also redesign the probe or the picker model — keep the change small, surgical, and testable through the existing seams.
