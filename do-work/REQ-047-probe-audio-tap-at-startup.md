# REQ-047: Probe audio tap at app startup

**UR:** UR-005
**Status:** backlog
**Created:** 2026-05-10
**Layer:** supporting

## Task

Invoke `PermissionManager.requestAudioTap()` once during app startup so `audioTapStatus` is populated before the user opens the source picker. Today the function is defined in `Permissions/PermissionManager.swift:152` but has zero call sites — `audioTapStatus` therefore stays `.unknown` for every user, and `SourcePickerViewModel.isDisabled` (`App/Views/SourcePickerView.swift:131`) treats `.unknown` as "not available", greying out every tap-needing item permanently.

The startup probe must complete before the source picker can be opened. The call is async and `PermissionManager` is `@MainActor`, so the natural call site is `SystemAudioRecorderApp.body.onAppear`'s deferred block in `App/SystemAudioRecorderApp.swift:29` (alongside the existing `MenuBarController` / `DockPolicyController` init).

## Context

UR-005's brief reports the source-picker dropdown stuck on "Microphone only" with all other items greyed. Ideate identified the root cause as `requestAudioTap()` never being invoked at startup. This REQ is the universal bug-fix half of the "full hardening" scope chosen in clarifications — it restores the dropdown to a usable state on every Mac that has the entitlement.

REQ-019 created `PermissionManager` and its tap probe. REQ-022 created `AppStore` and threaded `PermissionManager` into the app object graph. This REQ closes the wiring gap left by both.

## Acceptance Criteria

- [ ] On app launch, `PermissionManager.requestAudioTap()` is invoked exactly once before the user can open the source picker.
- [ ] After startup completes on a Mac with a valid Screen Recording entitlement, `permissionManager.audioTapStatus == .available`.
- [ ] When the user opens the source picker for the first time after launch, "Everything", "Everything + Mic", and "Specific app…" are selectable (not greyed) on a permitted Mac.
- [ ] On a Mac where the tap is genuinely denied (entitlement stripped or policy denial), `audioTapStatus` reflects `.deniedByEntitlement` or `.deniedByPolicy` after startup — not `.unknown`.
- [ ] No regression: existing `PermissionManagerTests` still pass.

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** Run the existing permission tests: `swift test --filter PermissionManagerTests`
   - Expected: all green; no new failures.
2. **build** Build the app via the project's standard build (e.g. `make build` or Xcode build): clean compile.
   - Expected: zero warnings, zero errors.
3. **runtime** Add (or update) an automated assertion that `audioTapStatus != .unknown` once startup has completed. If a unit test cannot exercise the real probe, assert the call site invokes `requestAudioTap()` via a stub `PermissionManager` injected at the seam.
   - Expected: the assertion passes; the test fails if the call site is removed.
4. **ui** Launch the built app on this Mac (which has the entitlement granted). Open the "Recording from:" dropdown.
   - Expected: "Everything", "Everything + Mic", and "Specific app…" are all selectable (not greyed). Selecting "Everything" updates the menu's display label and persists across app relaunch (per REQ-021).

## Integration

**Reachability:** `SystemAudioRecorderApp.body` (`App/SystemAudioRecorderApp.swift:17-46`) — `.onAppear`'s `DispatchQueue.main.async { ... }` block at line 29 is the existing app-startup hook. Add an async task there that awaits `appStore.permissionManager.requestAudioTap()`. (Alternative call site: extend `AppStore`'s convenience init to dispatch the probe — but `.onAppear` is preferred because the function is `async` and `@MainActor`.)

**Data dependencies:** Reads `PermissionManager.audioTapStatus` (`Permissions/PermissionManager.swift:77`); writes the same property as a side-effect of the probe via `requestAudioTap()` (line 152). Consumed downstream by `SourcePickerViewModel.isDisabled` (`App/Views/SourcePickerView.swift:123`).

**Service dependencies:** Calls `PermissionManager.requestAudioTap()` (`Permissions/PermissionManager.swift:152`) which in turn calls `AudioHardwareCreateProcessTap` via `probeAudioTap()` (line 166). No new module dependencies introduced.
