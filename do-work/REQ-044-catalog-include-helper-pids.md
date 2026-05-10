# REQ-044: Include Audio-Registered Helper PIDs Regardless of NSWorkspace Visibility

**UR:** UR-004
**Status:** backlog
**Created:** 2026-05-10
**Layer:** none

## Task

Stop dropping audio-emitting processes from `AudioSourceCatalog` just because `NSRunningApplication(processIdentifier:)` returns nil for them. Source bundle IDs from Core Audio's `kAudioProcessPropertyBundleID` (and a display-name property) directly off the audio process object instead of relying on NSWorkspace, so renderer/GPU helpers (e.g. `Google Chrome Helper (Renderer)`) that emit audio but aren't visible to NSWorkspace are included in `Everything` mode.

Concretely:

1. Extend `ProcessListProvider` with two new methods so tests can mock them:
   - `bundleID(for objectID: AudioObjectID) -> String?`
   - `executableName(for objectID: AudioObjectID) -> String?` (optional fallback for display)
2. Implement both on `HALProcessListProvider` using `kAudioProcessPropertyBundleID` (and `kAudioProcessPropertyBundleAlias` / executable name property as fallback).
3. Rewrite `AudioSourceCatalog.refresh()` so:
   - Bundle ID is sourced from the HAL provider, NOT from `NSRunningApplication`.
   - A process is kept iff (a) the HAL provided a non-empty bundle ID, AND (b) it is not `coreaudiod`.
   - `NSRunningApplication(processIdentifier:)` is still consulted, but only as a best-effort enrichment for `localizedName` and `icon`. Its absence no longer drops the process.
   - Display name fallback chain, in order: `NSRunningApplication.localizedName` → HAL executable name → bundle ID's last component → `"Process \(pid)"`.

This is the root-cause fix for UR-004: helper PIDs that actually emit Chromium browser audio are present in `kAudioHardwarePropertyProcessObjectList` but were silently filtered out at AudioEngine/Capture/AudioSourceCatalog.swift:125.

## Context

UR-004: Recording in `Everything` mode while audible Chrome/Arc/Edge/Brave audio is playing produces a 5-second, structurally valid 24 KB MP3 file that plays as silence (`~/Music/Recordings/20260510-092323.mp3`). Audio Capture TCC permission was granted; failure is not a permission issue.

Investigation in `do-work/user-requests/UR-004/ideate.md` initially suspected NSWorkspace-based enumeration. Reading the code shows the catalog already uses the correct Core Audio enumeration API (`kAudioHardwarePropertyProcessObjectList` at AudioEngine/Capture/AudioSourceCatalog.swift:36–65). The actual cause is one step further down the same function: line 125 drops any process whose `NSRunningApplication(processIdentifier:)` lookup returned `nil`. Chromium renderer and GPU helpers register with Core Audio (so they are enumerated by HAL) but are LSUIElement / non-presented helpers that NSWorkspace's running-applications list often omits — so `bundleIdentifier` is nil and the process is filtered before any tap is created.

Connector observation from ideate: REQ-006 (`AudioSourceCatalog`), REQ-007 (`ProcessTapCapture`) are the existing surface; this REQ refines REQ-006 and does not introduce new public types. `ProcessListProvider` is already a test seam — extending it preserves the existing test pattern.

## Acceptance Criteria

- [ ] `ProcessListProvider` has new methods `bundleID(for:)` and `executableName(for:)`. `HALProcessListProvider` implements them using Core Audio process properties; both return `nil` on HAL error rather than throwing.
- [ ] `AudioSourceCatalog.refresh()` no longer calls `NSRunningApplication.bundleIdentifier` for filtering. Bundle ID comes from `provider.bundleID(for:)`. NSRunningApplication is consulted only for `localizedName` and `icon` enrichment, with documented nil-tolerance.
- [ ] A process whose HAL bundle ID is non-empty is kept even when `NSRunningApplication(processIdentifier:)` returns nil — its `displayName` is non-empty and is picked deterministically from the documented fallback chain in the order: `NSRunningApplication.localizedName` (when non-nil) → HAL executable name (when non-nil) → bundle ID's last `.`-separated component → `"Process \(pid)"`.
- [ ] `coreaudiod` filter is preserved (matches by bundle ID `com.apple.audio.coreaudiod` AND by display-name substring as belt-and-braces).
- [ ] Unit test in `Tests/AudioEngineTests/AudioSourceCatalogTests.swift` covers the Chromium-helper case: mock provider returns one object id whose HAL bundle ID is `com.google.Chrome.helper.Renderer` but for whose pid `NSRunningApplication(processIdentifier:)` would return nil; the test verifies the process appears in `catalog.processes` with the correct bundle ID and a sensible display name.
- [ ] Existing `AudioSourceCatalogTests` continue to pass without modification (filter for missing bundle ID still works — just sourced from HAL now).
- [ ] After the fix, recording for ~10 seconds in `Everything` mode while Chrome plays a known audio source produces an MP3 whose audible content matches the source (not silence).
- [ ] `docs/manual-tests.md` gains a new test case (next available `MT-NNN` number) titled "Real Core Audio Tap — Chromium Browser in Everything mode" that explicitly reproduces the UR-004 path: Chromium browser playing audible audio, source picker on `Everything`, recording for ~30 s, output MP3 contains the audible browser audio. Pass criteria reference `AudioSourceCatalog` including helper PIDs.

## Verification Steps

> Execute these after implementation to confirm the fix works at runtime. Each must pass before committing.

1. **test** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorderTests test -destination 'platform=macOS' -only-testing:AudioEngineTests/AudioSourceCatalogTests`
   - Expected: All catalog tests pass, including the new test that asserts a Chromium-helper-style process is present in the catalog when HAL provides its bundle ID even though NSRunningApplication does not.

2. **build** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorder build -destination 'platform=macOS'`
   - Expected: Project compiles with no errors and no new warnings.

3. **runtime** Reproduce the original UR-004 bug, then confirm fix. Steps:
   - Open Chrome (or Arc/Edge/Brave), play a recognisable audio source (e.g. a YouTube clip with speech).
   - Launch the built app, leave the source picker on `Everything` (default).
   - Press Start Recording, let it run for ~10 seconds while audio plays audibly, press Stop.
   - Open the resulting MP3 in `~/Music/Recordings/`.
   - Expected (PRE-fix repro): file plays as silence (this is the original bug — confirm the test machine reproduces it before the fix).
   - Expected (POST-fix): file's audio content matches what was playing in Chrome — speech intelligible, file not silent.

4. **runtime** Confirm helper inclusion via app diagnostics. Steps:
   - With Chrome playing audio, in a debug build, log `catalog.processes.map(\.displayName)` after `refresh()`.
   - Expected: at least one entry whose name or bundle ID identifies it as a Chromium helper (e.g. contains "Helper", `com.google.Chrome.helper`, or equivalent).

## Assets

(none)
