# REQ-047: Probe audio tap at app startup

**UR:** UR-005
**Status:** in-progress
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

1. **test** `make test` — full Xcode test suite. Permission-related tests must remain green; the new assertion (see step 3) must be present and passing.
   - Expected: all green; no new failures.
2. **build** `make build` — clean compile of the app target.
   - Expected: zero warnings, zero errors.
3. **test** Add a unit test that injects a stub `PermissionManager` (or uses the existing test seam) and asserts the startup call site invokes `requestAudioTap()` exactly once. The test must fail if the call site is removed.
   - Expected: new test passes; deleting the wiring causes it to fail.
4. **ui (manual — deferred to user)** Launch the built app on a Mac with the Screen Recording entitlement granted; open the "Recording from:" dropdown.
   - Expected: "Everything", "Everything + Mic", and "Specific app…" are all selectable. The worker cannot automate native macOS UI; this step is documentation for manual user verification post-merge.

## Integration

**Reachability:** `SystemAudioRecorderApp.body` (`App/SystemAudioRecorderApp.swift:17-46`) — `.onAppear`'s `DispatchQueue.main.async { ... }` block at line 29 is the existing app-startup hook. Add an async task there that awaits `appStore.permissionManager.requestAudioTap()`. (Alternative call site: extend `AppStore`'s convenience init to dispatch the probe — but `.onAppear` is preferred because the function is `async` and `@MainActor`.)

**Data dependencies:** Reads `PermissionManager.audioTapStatus` (`Permissions/PermissionManager.swift:77`); writes the same property as a side-effect of the probe via `requestAudioTap()` (line 152). Consumed downstream by `SourcePickerViewModel.isDisabled` (`App/Views/SourcePickerView.swift:123`).

**Service dependencies:** Calls `PermissionManager.requestAudioTap()` (`Permissions/PermissionManager.swift:152`) which in turn calls `AudioHardwareCreateProcessTap` via `probeAudioTap()` (line 166). No new module dependencies introduced.
