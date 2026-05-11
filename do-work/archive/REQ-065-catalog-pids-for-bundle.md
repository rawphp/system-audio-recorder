# REQ-065: AudioSourceCatalog.pids(forBundle:) grouping helper

**UR:** UR-012
**Status:** done
**Created:** 2026-05-11
**Layer:** audio_engine

## Task

Add a `pids(forBundle bundleID: String) -> [pid_t]` method to `AudioSourceCatalog`. The method returns every process in `self.processes` whose bundle ID is exactly `bundleID` OR begins with `<bundleID>.helper` (catches Chromium `com.google.Chrome.helper`, `com.google.Chrome.helper.GPU`, Electron `com.tinyspeck.slackmacgap.helper`, etc.). Result preserves catalog order; returns an empty array if no pids match. The method does NOT call `refresh()` — callers refresh when they need a current snapshot.

## Context

This is the lookup primitive that makes bundle-keyed `.specificApp` work. UR-012 brief: the parent pid for Chrome is silent; only `<bundle>.helper*` pids emit audio. The catalog already preserves helper pids (REQ-044's bundle-ID fallback at `AudioEngine/Capture/AudioSourceCatalog.swift:176-178`) — this REQ adds the grouping query the picker (REQ-067) and the builder (REQ-066) need.

Connector observation from ideate: the existing `bundleID` field on `AudioProcess` (`AudioSourceCatalog.swift:9`) already carries the data needed for grouping; no new HAL queries are required.

Challenger observation incorporated: the `.helper` suffix matching uses `.helper` followed by either end-of-string or `.` (so `com.google.Chrome.helper.GPU` matches but a hypothetical `com.google.Chromehelper` does not). This is encoded as an acceptance criterion.

## Acceptance Criteria

- [x] Catalog with bundle IDs `[com.google.Chrome, com.google.Chrome.helper, com.google.Chrome.helper.GPU, com.apple.Safari]` returns the first three pids for `pids(forBundle: "com.google.Chrome")`.
- [x] Catalog with bundle ID `com.google.Chromehelper` (no separator) returns an empty array for `pids(forBundle: "com.google.Chrome")` — substring match without the `.` separator is rejected.
- [x] `pids(forBundle: "com.apple.Safari")` returns only the Safari pid when the catalog also contains Chrome — bundle isolation holds.
- [x] `pids(forBundle: "com.nonexistent.app")` returns an empty array, not nil.
- [x] The method does not mutate `self.processes` and does not call `refresh()`.
- [x] Unit tests cover: parent-only group, parent + 1 helper, parent + N helpers with sub-helper variants (`.helper.GPU`, `.helper.Renderer`), no match, exact-match vs prefix-substring edge case.

## Verification Steps

1. **test** `swift test --filter AudioSourceCatalogTests` (or the suite covering catalog behaviour).
   - Expected: all existing catalog tests pass; new `pids(forBundle:)` tests pass — at minimum the six cases listed in Acceptance Criteria.
2. **runtime** With Chrome running and audio playing in one tab, launch the app and call `catalog.refresh()` then `catalog.pids(forBundle: "com.google.Chrome")` in a debug REPL or via a temporary `print`.
   - Expected: the returned array contains at least 2 pids (parent + the audio-emitting helper); the parent's pid resolves to `Google Chrome` via `NSRunningApplication`.
   - **Status:** requires manual run.

## Integration

**Reachability:** Called by `DefaultSessionConfigBuilder.build` (REQ-066) for the `.specificApp` case at `App/AppStore.swift:131` (post-REQ-064 shape), and by `SourcePickerViewModel.currentSelectionLabel` (REQ-068) at `App/Views/SourcePickerView.swift:219` for bundle-ID → displayName resolution.

**Data dependencies:** Reads `self.processes` (the `[AudioProcess]` array populated by `refresh()` at `AudioSourceCatalog.swift:158`). Each `AudioProcess` carries a `bundleID: String` (`AudioSourceCatalog.swift:11`) — the field already exists and is populated.

**Service dependencies:** None new. The method is a pure query over existing in-memory state. `refresh()` remains the caller's responsibility (existing call sites at `App/AppStore.swift:107` and `App/Views/SourcePickerView.swift:118` already refresh at the right moments).

## Outputs

- `AudioEngine/Capture/AudioSourceCatalog.swift` — added `pids(forBundle:)` method with dot-separator boundary guard
- `Tests/AudioEngineTests/AudioSourceCatalogTests.swift` — 7 new tests covering all acceptance criteria (parent+helpers, substring rejection, bundle isolation, no-match, no-mutation, order preservation, parent-only)
