# REQ-021: Settings persistence with UserDefaults schema and security-scoped output bookmark

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** supporting

## Task

Implement `App/Settings/AppSettings.swift`, an `@Observable` settings store backed by `UserDefaults(suiteName: "com.tomkaczocha.SystemAudioRecorder")`. Implement the schema from spec Section 6.2 with documented defaults. The output folder is stored as a security-scoped bookmark URL so re-launches retain access without re-prompting; provide `outputFolder.url` (resolves the bookmark on access) and `outputFolder.set(_:URL)` (stores a fresh bookmark).

## Context

Spec Section 6.2 enumerates every persisted key with its default. Section 4.6 routes per-feature controls through Settings. Section 6.1 requires the output folder to default to `~/Music/Recordings` — created on first launch if missing.

## Acceptance Criteria

- [x] All keys in spec Section 6.2 are exposed as `@Observable` properties with the documented defaults
- [x] First-launch defaults: output folder `~/Music/Recordings` (created if missing), bitrate 192, mode VBR, output mode mixed, keepWAV false, hotkey unset, last preset "Everything", showInDock true, autoStop nils
- [x] Output folder uses a security-scoped bookmark; access survives app relaunch
- [x] Setting any value triggers persistence within one run-loop tick
- [x] Reading any value before first set returns the documented default
- [x] Schema migration: a future v2 key added with a default does not corrupt existing v1 settings
- [x] If the persisted security-scoped bookmark fails to resolve on access (folder deleted/moved/unmounted), `outputFolder.url` returns `nil` and `AppSettings` surfaces a non-fatal banner via `ErrorSurface` (REQ-033) prompting the user to re-pick the folder; recording attempts before re-pick throw `SettingsError.outputFolderUnavailable`
- [x] If creating the default `~/Music/Recordings` directory on first launch fails (permission denied / read-only volume), `AppSettings` falls back to `NSTemporaryDirectory()/Recordings`, surfaces a non-fatal banner explaining the fallback, and persists the fallback path as a fresh bookmark

## Verification Steps

1. **test** Unit test sets bitrate to 256, force-quits the test app, relaunches; asserts bitrate is 256
   - Expected: test passes
   - Result: `testBitratePersistsAcrossInstances` passes — writes 256 on first instance, creates fresh instance on same suite, asserts 256 reads back. **PASS**
2. **test** Unit test on a fresh suite asserts all defaults match spec Section 6.2
   - Expected: test passes
   - Result: 10 default-value tests (`testDefaultBitrateIs192`, `testDefaultBitrateModeIsVBR`, `testDefaultOutputModeIsMixed`, `testDefaultKeepWAVIsFalse`, `testDefaultHotkeyIsUnset`, `testDefaultLastSourcePresetIsEverything`, `testDefaultMicDeviceIDIsNil`, `testDefaultShowInDockIsTrue`, `testDefaultAutoStopDurationIsNil`, `testDefaultAutoStopSilenceIsNil`) all pass. **PASS**

## Integration

**Reachability:** Read by every subsystem (RecordingSession, encoding, hotkey, UI). Surfaced for editing in `OutputSettingsView` (REQ-029).

**Data dependencies:** Backing store is `UserDefaults` suite `com.tomkaczocha.SystemAudioRecorder`.

**Service dependencies:** Foundation for nearly every other REQ — they read settings rather than hard-coding values.

## Outputs

- `App/Settings/AppSettings.swift` — `BitrateMode` extension (adds `RawRepresentable`, `Equatable` to the existing `LameEncoder.swift` enum); `AppOutputMode` enum (`mixed`, `separate`); `SettingsError` enum (`outputFolderUnavailable`, `outputFolderFallback(URL)`); `BookmarkProvider` protocol with `SecurityScopedBookmarkProvider` (production) impl; `FolderCreating` protocol with `FileManagerFolderCreator` (production) impl; `AppSettings` `@Observable @MainActor` final class with all 11 spec §6.2 keys as computed properties backed by `UserDefaults`, `outputFolderURL` (resolves security-scoped bookmark), `setOutputFolder(_:)`, `resolvedOutputFolder()` (creates default dir or temp fallback), `defaultOutputFolderURL`, `lastBookmarkError: SettingsError?`, `lastFolderCreationError: SettingsError?`, injectable `init(defaults:bookmarkProvider:folderCreator:)` seam, and convenience production `init()`.
- `Tests/AudioEngineTests/AppSettingsTests.swift` — 27 unit tests: 10 default-value tests, 9 round-trip tests, 2 cross-instance persistence (relaunch sim) tests, 1 schema migration test, 2 bookmark-failure tests, 2 folder-creation-failure tests, 1 bookmark-store test. `StubBookmarkProvider` and `FailingFolderCreator` test doubles included. All 27 pass. Full suite: ** TEST SUCCEEDED ** (all test suites pass).
