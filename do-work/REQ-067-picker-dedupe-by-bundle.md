# REQ-067: AppPickerView dedupes catalog by bundle

**UR:** UR-012
**Status:** backlog
**Created:** 2026-05-11
**Layer:** ui

## Task

Rework `AppPickerView` so the list shows one row per app bundle, not one row per pid. Compute a grouped view-model from `catalog.processes`:

1. For each process, compute its `groupKey` — the bundle ID with any trailing `.helper*` segments stripped (e.g. `com.google.Chrome.helper.GPU` → `com.google.Chrome`).
2. Bucket pids by `groupKey`.
3. For each group, pick a "representative" process: prefer the one whose `bundleID == groupKey` (the parent) so its `displayName` and `icon` (from `NSRunningApplication`) drive the row; otherwise pick the first pid in the group and label it with the raw bundle ID, no icon (orphan path per Q4).
4. Sort groups: parent-backed groups first (alphabetised by displayName), orphan groups last (alphabetised by raw bundle ID).
5. The `onSelect` closure is changed from `(pid_t) -> Void` to `(String) -> Void`, where the String is the group's bundle ID (the `groupKey`). Callers consume it via REQ-068.

The "Choose an app" sheet retains its current chrome (header, cancel button, empty state).

## Context

**Depends on:** REQ-064 (the `onSelect` closure signature switches from `(pid_t) -> Void` to `(String) -> Void` to carry the bundle ID; the consuming view model is updated in REQ-068).

UR-012 screenshot 2 shows the picker listing both `Google Chrome` (silent parent) and a bare `helper` row (audio-emitting helper). Users can't tell which to pick, and the obvious choice is wrong. Grouping by bundle collapses the helpers under their parent so "Google Chrome" becomes a single, correct row. Orphans (helpers whose stripped bundle ID has no parent in the catalog) still appear, but labeled with their raw bundle ID so they're identifiable rather than ambiguous.

Connector observation from ideate: the catalog already surfaces helper pids with bundle IDs intact (REQ-044's HAL-bundle-ID-first fallback at `AudioEngine/Capture/AudioSourceCatalog.swift:176`); this REQ is purely a UI grouping pass over data the catalog already provides.

Challenger observation incorporated: the `.helper` stripping rule uses a regex-equivalent `.helper(\.|$)` boundary check — `.helper.GPU` matches, `.helperish` does not. Same rule as REQ-065's `pids(forBundle:)` so the picker grouping and the recording-time pid resolution stay consistent.

## Acceptance Criteria

- [ ] Catalog with processes for `com.google.Chrome`, `com.google.Chrome.helper`, `com.google.Chrome.helper.GPU`, `com.apple.Safari`, and `com.orphan.thing.helper` (with no `com.orphan.thing` parent) yields 3 picker rows: "Google Chrome" (parent-backed, with icon), "Safari" (parent-backed, with icon), and "com.orphan.thing" (orphan, raw bundle ID, no icon).
- [ ] Selecting the "Google Chrome" row calls `onSelect("com.google.Chrome")` — the group key, not a pid.
- [ ] Selecting the orphan row calls `onSelect("com.orphan.thing")` — the stripped bundle ID, even though no process exists for the parent bundle exactly.
- [ ] Parent-backed groups appear before orphan groups in the list; both subsets are alphabetically sorted by their displayed label.
- [ ] When the catalog is empty, the existing "No audio-emitting apps found." empty state still appears (existing behaviour at `App/Views/SourcePickerView.swift:260-267` is preserved).
- [ ] Snapshot or unit test of the grouped view-model with the fixture catalog above asserts the row count, order, and per-row label/icon.

## Verification Steps

1. **test** `swift test --filter AppPickerViewTests` (new test file, or the closest existing view-model test bucket).
   - Expected: new grouping tests pass with the fixture catalog described in the first acceptance criterion.
2. **build** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorder build`.
   - Expected: clean build.
3. **ui** Launch the app with Chrome running and audio playing. Click the source dropdown → "Specific app…". Take a screenshot.
   - Expected: the picker shows a single "Google Chrome" row with the Chrome icon. There is no bare "helper" row alongside it. Any genuine orphan helpers (rare) appear at the bottom of the list with raw bundle IDs and no icons. This is the visual fix the user reported in UR-012.
4. **ui** Click the "Google Chrome" row.
   - Expected: the picker sheet dismisses, and the dropdown's main label changes to "Google Chrome" (label resolution comes from REQ-068 but is verified here end-to-end).

## Integration

**Reachability:** Presented as a SwiftUI sheet from `SourcePickerView` at `App/Views/SourcePickerView.swift:342-347`. The user reaches it via Menu → "Specific app…" (the `specificAppButton` view at `App/Views/SourcePickerView.swift:328`). `AppPickerView` is the sheet's content view at `App/Views/SourcePickerView.swift:241`.

**Data dependencies:** Reads `AudioSourceCatalog.processes` (`AudioEngine/Capture/AudioSourceCatalog.swift:148`) — the `[AudioProcess]` array of `pid`, `bundleID`, `displayName`, `icon`. Does not mutate the catalog. Refresh is the caller's responsibility (already triggered by `openAppPicker()` at `App/Views/SourcePickerView.swift:117-120`).

**Service dependencies:** `AudioSourceCatalog` for the underlying process list. The `onSelect` closure interfaces with `SourcePickerViewModel.selectBundle(_:)` (introduced in REQ-068).
