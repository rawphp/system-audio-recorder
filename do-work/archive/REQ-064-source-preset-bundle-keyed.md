# REQ-064: SourcePreset bundle-keyed payload

**UR:** UR-012
**Status:** done
**Created:** 2026-05-11
**Layer:** audio_engine

## Task

Replace `SourcePreset.specificApp(processID: pid_t)` with `SourcePreset.specificApp(bundleID: String)`. Update `settingsKey` to emit `SpecificApp:<bundleID>` and `from(settingsKey:)` to parse it. Old persisted `SpecificApp:<numeric-pid>` values silently fall back to `.everything` (matches today's graceful default at `App/AppStore.swift:37` for unparseable keys). Update every reference site (builder `.specificApp` case, SourcePickerViewModel.selectProcess, currentSelectionLabel, tests) so the codebase compiles after this REQ ships.

## Context

The Specific App preset currently carries a transient pid that points at the parent process of an app. For Chromium-based browsers and Electron apps, the parent pid does not emit audio — helper pids do — so selecting "Google Chrome" produces a silent recording (UR-012 brief). The fix shape (Q3 in clarifications) is to make the preset payload a stable bundle identifier and resolve pids at recording-start time. This REQ is the foundational API change; REQ-065 and REQ-066 build on top of it.

Connector observation from ideate: the `.everything` builder case at `App/AppStore.swift:102-129` already demonstrates the multi-pid path is fully supported by `ProcessTapCapture`; subsequent REQs reuse that shape rather than inventing a parallel flow.

## Acceptance Criteria

- [x] `SourcePreset.specificApp` has a single associated value `bundleID: String` — pid is removed from the public API.
- [x] `SourcePreset.specificApp(bundleID: "com.google.Chrome").settingsKey == "SpecificApp:com.google.Chrome"`.
- [x] `SourcePreset.from(settingsKey: "SpecificApp:com.google.Chrome") == .specificApp(bundleID: "com.google.Chrome")`.
- [x] `SourcePreset.from(settingsKey: "SpecificApp:1234")` returns `.everything` (legacy pid-keyed value silently falls back; not parsed as bundle ID).
- [x] `SourcePreset.from(settingsKey: "SpecificApp:")` returns `.everything` (empty bundle ID is rejected).
- [x] The Swift package builds without warnings — every former `case .specificApp(let pid)` site has been migrated to handle the new payload.
- [x] Existing tests covering `SourcePreset` parsing pass; new unit tests cover the legacy-pid fallback and round-trip behaviour.

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** `swift test --filter SourcePresetTests` (or the project's equivalent suite filter).
   - Expected: all `SourcePreset` tests pass, including new tests for legacy-pid fallback (`SpecificApp:1234` → `.everything`) and bundle-ID round-trip (`SpecificApp:com.google.Chrome` ↔ `.specificApp(bundleID:)`).
2. **build** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorder build` (or `make build` per Makefile).
   - Expected: build succeeds, no warnings introduced. Every call site that previously pattern-matched `.specificApp(let pid)` now uses `.specificApp(let bundleID)`.
3. **runtime** Launch the app fresh after wiping `~/Library/Preferences/<app-bundle>.plist` so `lastSourcePreset` is unset.
   - Expected: app opens with "Everything" selected by default (`AppSettings.lastSourcePreset` falls through to the `"Everything"` default at `App/Settings/AppSettings.swift:245`).
4. **runtime** Manually set `defaults write <bundle-id> lastSourcePreset "SpecificApp:9999"` (a stale pid-shaped key), then launch.
   - Expected: app opens with "Everything" selected — the stale legacy value is rejected and the graceful default applies. No crash, no error toast.

## Outputs

- App/AppStore.swift — `SourcePreset.specificApp` changed to `bundleID: String`; `settingsKey`/`from(settingsKey:)` updated; `DefaultSessionConfigBuilder.build` `.specificApp` case updated to compile (REQ-066 implements pid resolution)
- App/Views/SourcePickerView.swift — `selectProcess(bundleID:)`, `currentSelectionLabel`, `AppPickerView.onSelect` updated
- Tests/AudioEngineTests/SourcePresetTests.swift — new unit tests (14 cases)
- Tests/AudioEngineTests/AppStoreTests.swift — migrated 2 test calls to new API
- Tests/AudioEngineTests/SourcePickerViewTests.swift — migrated 1 test call to new API

## Integration

**Reachability:** Type is consumed by `App/AppStore.swift:233` (`currentPreset`), `App/AppStore.swift:131` (the `.specificApp` case of `DefaultSessionConfigBuilder.build`), `App/Views/SourcePickerView.swift:108` (`selectProcess(pid:)` — replaced in REQ-068), and `App/Views/SourcePickerView.swift:221` (`currentSelectionLabel`). All four sites must be migrated in this REQ for the codebase to compile.

**Data dependencies:** Persisted via `AppSettings.lastSourcePreset` — a `String` UserDefaults entry defined at `App/Settings/AppSettings.swift:244`. The change is on-the-wire (settings key format) but does not require a UserDefaults schema migration: invalid keys already fall back to `.everything`.

**Service dependencies:** `SessionConfigBuilder` protocol at `App/AppStore.swift:53` — REQ-066 updates `DefaultSessionConfigBuilder.build`'s `.specificApp` case to consume the new payload.
