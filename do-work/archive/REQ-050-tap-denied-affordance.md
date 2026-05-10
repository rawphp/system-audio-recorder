# REQ-050: Tap-unavailable "Open Settings" affordance in source picker

**UR:** UR-005
**Status:** done
**Created:** 2026-05-10
**Layer:** ui

## Task

Add a tap-denied affordance to `SourcePickerView` that mirrors the existing `micDeniedAffordanceButton` (`App/Views/SourcePickerView.swift:374`). When `permissionManager.audioTapStatus != .available`, render the tap-needing items (`.everything`, `.everythingPlusMic`, `.specificApp`) as a single clickable row labelled `"<label> — Tap unavailable — Open Settings"` (warning icon, secondary foreground style) instead of leaving them silently greyed.

Clicking the affordance opens System Settings → Privacy & Security → Screen Recording via the existing `PermissionDeepLink.screenRecordingSettingsURL` constant (`App/Errors/PermissionDeepLink.swift:27`). No new URL helpers are needed — the constant was created by REQ-034.

The affordance must hide once `audioTapStatus == .available` (e.g. after the user grants the entitlement and REQ-048 / REQ-049 re-probe), restoring the normal selectable items.

## Task scope guards:
- Mic-denied affordance behaviour is unchanged.
- The `"Advanced…"` row (which never needed the tap entitlement) is unchanged.
- The "Specific app…" item is included in the affordance group because it relies on the tap.

## Context

UR-005 ideate flagged that the disabled-state was silent — users had no way to know *why* items were greyed. Clarifications confirmed scope: "Full hardening — wiring fix + tap-denied affordance + re-probe", and the affordance click action: "Deep-link to System Settings > Privacy & Security."

Connector: this REQ reuses two existing patterns. (1) `micDeniedAffordanceButton` is the visual / interaction template; the tap variant should match its style so the menu has one consistent vocabulary for permission gates. (2) `PermissionDeepLink.screenRecordingSettingsURL` already exists for exactly this destination — REQ-034 anticipated this.

Challenger: the affordance must not flash on every probe. If `audioTapStatus` is `.unknown` momentarily during startup (before REQ-047 lands or during a probe), prefer treating `.unknown` as "show normal items disabled" rather than as "show affordance" — the affordance is only for confirmed denials.

## Acceptance Criteria

- [x] When `permissionManager.audioTapStatus` is `.deniedByEntitlement` or `.deniedByPolicy`, the source-picker dropdown renders a clickable affordance for the three tap-needing items (Everything, Everything+Mic, Specific app…) labelled `"<item label> — Tap unavailable — Open Settings"` with a warning icon.
- [x] Clicking the affordance opens `PermissionDeepLink.screenRecordingSettingsURL` (System Settings → Privacy & Security → Screen Recording).
- [x] When `permissionManager.audioTapStatus == .available`, the affordance is hidden and the normal selectable items return.
- [x] When `permissionManager.audioTapStatus == .unknown` (transient), the items render as disabled (current behaviour) — not as the affordance.
- [x] The mic-denied affordance behaviour is unchanged.
- [x] No regression: existing `SourcePickerView` / source-picker view-model tests still pass.

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** `make test`. Add view-model tests that drive the override seam (`overrideAudioTapAvailable = false`, plus a parallel seam for tap-denied vs unknown if needed) and assert: (a) the affordance appears for the three tap-needing items when status is denied; (b) it disappears when status is `.available`; (c) it does NOT appear when status is `.unknown`.
   - Result: PASS — 385 tests, 1 pre-existing skip, 0 failures. 5 new tests added: `testShowTapDeniedAffordanceWhenDeniedByEntitlement`, `testShowTapDeniedAffordanceWhenDeniedByPolicy`, `testShowTapDeniedAffordanceFalseWhenAvailable`, `testShowTapDeniedAffordanceFalseWhenUnknown`, `testExistingBooleanSeamUnaffectedByNewSeam`. All pass.
2. **build** `make build` — clean compile.
   - Result: PASS — BUILD SUCCEEDED, zero errors, zero warnings.
3. **ui (manual — deferred to user)** Launch the app on a Mac with the Screen Recording entitlement revoked (or simulate via the override seam). Open the dropdown. The worker cannot automate native macOS UI; this step is documentation for manual verification post-merge.
   - Result: deferred (manual) — cannot automate native macOS UI.

## Integration

**Reachability:** `SourcePickerView.body`'s `Menu` (`App/Views/SourcePickerView.swift:255`). The affordance is rendered by replacing `everythingButton`, `everythingPlusMicButton`, and `specificAppButton` (lines 294-348) with conditional logic that branches on `audioTapStatus` — analogous to the existing `micDeniedAffordanceButton` branching at lines 309-320 / 326-336.

**Data dependencies:** Reads `permissionManager.audioTapStatus` (`Permissions/PermissionManager.swift:77`) via `SourcePickerViewModel`. Reads `PermissionDeepLink.screenRecordingSettingsURL` (`App/Errors/PermissionDeepLink.swift:27`).

**Service dependencies:** Uses `NSWorkspace.shared.open(_:)` (already used by `openMicrophoneSettings()` at `App/Views/SourcePickerView.swift:155`). Pairs with REQ-048 / REQ-049 so the affordance disappears when the user grants the permission. No new module dependencies.

## Outputs

- `App/Views/SourcePickerView.swift` — added `overrideAudioTapStatus: AudioTapStatus?` full-enum test seam; added `resolvedAudioTapStatus` private computed property; added `showTapDeniedAffordance(for:)` public method; added `openScreenRecordingSettings()` public method; added `tapDeniedAffordanceButton(label:)` private view helper; updated `everythingButton`, `everythingPlusMicButton`, `specificAppButton` to branch on `showTapDeniedAffordance` before `showMicDeniedAffordance`; fixed `PickerItem.needsAudioTap` to also exclude `.advanced` (scope guard: "The Advanced… row is unchanged").
- `Tests/AudioEngineTests/SourcePickerViewTests.swift` — added 5 new tests: `testShowTapDeniedAffordanceWhenDeniedByEntitlement`, `testShowTapDeniedAffordanceWhenDeniedByPolicy`, `testShowTapDeniedAffordanceFalseWhenAvailable`, `testShowTapDeniedAffordanceFalseWhenUnknown`, `testExistingBooleanSeamUnaffectedByNewSeam`.
