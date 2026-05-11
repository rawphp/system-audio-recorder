# REQ-066: Builder taps all bundle pids on .specificApp

**UR:** UR-012
**Status:** done
**Created:** 2026-05-11
**Layer:** audio_engine

## Task

In `DefaultSessionConfigBuilder.build`, change the `.specificApp(bundleID:)` case (post-REQ-064) to: call `catalog.refresh()`, then `catalog.pids(forBundle: bundleID)` (REQ-065), then construct one `ProcessTapCapture` over the full pid list, and append a `SessionConfig.Source` per pid via `ProcessTapSourceEmitter` — mirroring the `.everything` case at `App/AppStore.swift:102-129`. Throw `BuilderError.noAudibleProcesses` when the bundle group is empty (no pids match the bundle ID — same behaviour the `.everything` case already exhibits). Forward `capture.initFailures` into `initialErrors` so per-pid failures surface to REQ-033's `ErrorSurface`. Snapshot semantics: the pid list is fixed at build time — helpers spawned after recording starts are not added (deliberate per Q2 in clarifications).

## Context

**Depends on:** REQ-064 (consumes the bundle-keyed `.specificApp(bundleID:)` payload), REQ-065 (calls `AudioSourceCatalog.pids(forBundle:)` for pid resolution).

UR-012 root cause: `.specificApp(processID: pid_t)` taps a single pid, but Chromium / Electron apps emit audio from helper pids, not the parent. With REQ-064 (bundle-keyed preset) and REQ-065 (catalog grouping) in place, this REQ is the final wiring change: tap every pid in the bundle group. This is the REQ the user reproduces against — picking "Google Chrome" must now produce a non-silent recording.

Connector observation from ideate: the `.everything` case at `App/AppStore.swift:102-129` already does exactly this shape (refresh → enumerate pids → construct `ProcessTapCapture` → loop emitters) — the new code path reuses the structure with the pid list scoped to one bundle group.

Challenger observation incorporated: the snapshot-at-start trade-off (new helpers spawned mid-recording are not tapped) is explicit in the brief's clarifications. No additional handling is required in this REQ; if it becomes a real problem, a follow-up REQ can extend `ProcessTapCapture` to support dynamic pid attach.

## Acceptance Criteria

- [x] `.specificApp(bundleID: "com.google.Chrome")` builds a `SessionConfig` whose `sources` array contains one `SessionConfig.Source` per pid returned by `catalog.pids(forBundle: "com.google.Chrome")`.
- [x] When the catalog returns N pids for the bundle, the resulting `SessionConfig.sources.count == N` (parent + helpers all get emitters).
- [x] Empty bundle group throws `BuilderError.noAudibleProcesses` — same error the `.everything` case throws when the catalog is empty.
- [x] Per-pid emitter construction failures land in `SessionConfig.initialErrors` via `capture.initFailures` (REQ-045 graceful-failure semantics preserved — partial failure does not abort the build).
- [x] `ProcessTapSourceEmitter` ids follow the existing `"app:<pid>"` convention used by `.everything` so downstream signal-level wiring (REQ-046) and the mixer graph (REQ-010) treat the sources identically.
- [x] Unit test with a stub catalog + stub `ProcessTapCaptureFactory`: `.specificApp(bundleID:)` with a 3-pid group yields a config with 3 sources whose ids are `app:<pid1>`, `app:<pid2>`, `app:<pid3>`.
- [x] Unit test: empty group throws `noAudibleProcesses`.

## Verification Steps

1. **test** `swift test --filter DefaultSessionConfigBuilderTests` (or the suite for the builder).
   - Expected: existing tests still pass; new tests for multi-pid `.specificApp(bundleID:)` and empty-group error path pass.
2. **build** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorder build`.
   - Expected: clean build with no warnings introduced.
3. **runtime** Launch the app. Open Chrome and play audio (e.g. a YouTube video) in one tab. In the System Audio Recorder window, click the source dropdown → "Specific app…" → pick "Google Chrome" (the grouped row from REQ-067) → Start Recording. Speak/let audio play for ~5 seconds → Stop Recording.
   - Expected: the dB meter rises above `-∞` during recording (audio is being captured). The saved WAV file in the configured output folder, when opened in any audio player, contains the audible Chrome audio. This step reproduces the original UR-012 failure path and confirms the fix.
4. **runtime** Repeat step 3 with VS Code or Slack (Electron apps with `<bundle>.helper` helpers playing a notification sound).
   - Expected: same result — non-silent recording from the grouped Electron app.

## Outputs

- `App/AppStore.swift` — replaced `.specificApp` stub (`unsupportedPreset`) with full pid-resolution logic mirroring `.everything`; added `CaptureFactory` typealias and injectable `captureFactory` parameter to `DefaultSessionConfigBuilder.init`; `.everything` case now also routes through `captureFactory` for consistency.
- `Tests/AudioEngineTests/DefaultSessionConfigBuilderTests.swift` — 4 new unit tests covering: 3-pid bundle group, empty group throws, per-pid failure lands in initialErrors, source id convention.

## Integration

**Reachability:** Triggered by `AppStore.startRecording` (search for `startRecording` in `App/AppStore.swift` around line 270+) → `sessionConfigBuilder.build(preset: settings:)` → the `.specificApp` switch arm. User reaches the new code path by selecting an app row in `AppPickerView` (REQ-067) which calls `viewModel.selectBundle(_:)` (REQ-068) which writes `AppSettings.lastSourcePreset`.

**Data dependencies:** Reads `AudioSourceCatalog.processes` via `pids(forBundle:)` (REQ-065). Writes nothing — `SessionConfig` is a value type returned to the caller.

**Service dependencies:** `AudioSourceCatalog` (`AudioEngine/Capture/AudioSourceCatalog.swift:146`) for the catalog query; `ProcessTapCapture` (`AudioEngine/Capture/ProcessTapCapture.swift`) for the actual taps; `ProcessTapSourceEmitter` for per-pid stream emission. All three are already wired in the `.everything` case and reused unchanged.
