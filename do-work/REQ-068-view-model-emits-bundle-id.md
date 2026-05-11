# REQ-068: SourcePickerViewModel emits bundle IDs

**UR:** UR-012
**Status:** backlog
**Created:** 2026-05-11
**Layer:** ui

## Task

Migrate `SourcePickerViewModel` from pid-keyed to bundle-keyed selection:

1. Replace `selectProcess(pid: pid_t)` at `App/Views/SourcePickerView.swift:108` with `selectBundle(bundleID: String)`. The new method writes `settings.lastSourcePreset = "SpecificApp:\(bundleID)"` and dismisses the picker sheet.
2. Update `currentSelectionLabel` at `App/Views/SourcePickerView.swift:219` to parse `SpecificApp:<bundleID>` (string after the prefix), then resolve the display label via `sourceCatalog.pids(forBundle: bundleID)` (REQ-065) and `NSRunningApplication(processIdentifier:)`. Resolution order: (a) if any pid in the group has an `NSRunningApplication` with a `localizedName`, use that; (b) otherwise show the raw bundle ID. Final fallback string when nothing resolves is `"Specific app"` (current behaviour for unmatched pids at `App/Views/SourcePickerView.swift:227`).
3. Update the `AppPickerView` `onSelect` wiring at `App/Views/SourcePickerView.swift:345` to pass the bundle ID through to `selectBundle(_:)`.
4. Remove the legacy `SpecificApp:<pid>` numeric parsing branch — REQ-064 already makes those keys fall back to `.everything`, so the view model no longer needs to handle them. Document the removal in the method comment.

## Context

This REQ closes the user-visible loop: REQ-064 changed the preset payload, REQ-067 changed what the picker emits, this REQ wires the view model to consume bundle IDs end-to-end and shows the right label in the dropdown. Without it, selecting "Google Chrome" in the new picker would persist a bundle key but the dropdown label would still try to parse a pid and show "Specific app".

Connector observation from ideate: `currentSelectionLabel`'s existing structure (`App/Views/SourcePickerView.swift:219-238`) already follows a "parse key → resolve display name → fallback" shape; this REQ swaps the resolution mechanism without reshaping the function.

## Acceptance Criteria

- [ ] `selectProcess(pid:)` no longer exists on `SourcePickerViewModel`; calls site at `App/Views/SourcePickerView.swift:345` is updated to `selectBundle(bundleID:)`.
- [ ] Calling `selectBundle(bundleID: "com.google.Chrome")` sets `settings.lastSourcePreset` to `"SpecificApp:com.google.Chrome"` and toggles `showAppPicker = false`.
- [ ] After `selectBundle(bundleID: "com.google.Chrome")`, `currentSelectionLabel` returns `"Google Chrome"` when the catalog contains a Chrome parent process with an `NSRunningApplication` entry.
- [ ] After `selectBundle(bundleID: "com.orphan.thing")` (no parent in catalog), `currentSelectionLabel` returns `"com.orphan.thing"` — the raw bundle ID, matching the orphan label from REQ-067.
- [ ] After `selectBundle(bundleID: "com.something.not.running")` (no pids match), `currentSelectionLabel` returns `"Specific app"` — the preserved final fallback.
- [ ] A persisted `SpecificApp:1234` (legacy numeric pid) loaded on launch does NOT cause `currentSelectionLabel` to attempt pid lookup; the legacy branch is removed. Effective behaviour: `currentPreset` resolves to `.everything` (REQ-064), so this code path is unreachable in practice.
- [ ] Unit tests for `selectBundle`, label resolution (parent-backed, orphan, missing), and the removal of the legacy pid branch.

## Verification Steps

1. **test** `swift test --filter SourcePickerViewModelTests` (or the suite covering the view model).
   - Expected: existing tests still pass after the `selectProcess` → `selectBundle` rename; new label-resolution tests pass.
2. **build** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorder build`.
   - Expected: clean build.
3. **ui** Launch app with Chrome running. Click source dropdown → "Specific app…" → pick "Google Chrome" → sheet dismisses.
   - Expected: the dropdown's main label reads "Google Chrome" (replacing the prior "Specific app" or stale label). Screenshot for the manual test bundle.
4. **ui** Pre-set `defaults write <bundle-id> lastSourcePreset "SpecificApp:com.google.Chrome"` before launching.
   - Expected: app opens with the dropdown labeled "Google Chrome" — round-trip persistence works.
5. **ui** Pre-set `defaults write <bundle-id> lastSourcePreset "SpecificApp:1234"` (legacy pid value) before launching.
   - Expected: app opens with the dropdown labeled "Everything" — the legacy value is discarded by REQ-064's parser and the default applies.

## Integration

**Reachability:** `SourcePickerViewModel` is instantiated in `SystemAudioRecorderApp` / `AppStore` wiring (search `SourcePickerViewModel(` for the injection point) and consumed by `SourcePickerView` (`App/Views/SourcePickerView.swift:300+`). The new method is called from `AppPickerView`'s `onSelect` closure at `App/Views/SourcePickerView.swift:345`.

**Data dependencies:** Reads and writes `AppSettings.lastSourcePreset` (`App/Settings/AppSettings.swift:244`). Reads `AudioSourceCatalog.processes` via `pids(forBundle:)` (REQ-065) for label resolution.

**Service dependencies:** `AppSettings`, `AudioSourceCatalog`, `NSRunningApplication` (already imported via `AppKit`/`SwiftUI` for the existing label-resolution path).
