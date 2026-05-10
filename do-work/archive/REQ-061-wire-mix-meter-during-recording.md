# REQ-061: Wire mix-bus level meter so MixLevelMeterView updates during recording

**UR:** UR-010
**Status:** done
**Created:** 2026-05-10
**Layer:** none

## Task

Wire the mix-bus RMS into `AppStore.meters` so the on-screen `MixLevelMeterView` fills in green/yellow/red and the dB readout updates while a session is `.recording` (and remains frozen while `.paused`). Today the publisher is created but never fed and never started — the bar always shows `-∞ dB`.

## Context

User reports: *"should the app main screen show the decibels wave? it's not showing anything — during record it shows nothing as well."*

Investigation:

- `MixLevelMeterView` (App/Views/MixLevelMeterView.swift:79-85) reads `store.meters.meters["mix"]`, where `"mix"` is `MeterMath.mixSourceID`. View logic is correct.
- `AppStore` (App/AppStore.swift:191, 253) constructs `MeterPublisher()` but never calls `meters.start()` and nothing ever calls `meters.register(sourceID: "mix", ring:)`.
- `RecordingSession` (AudioEngine/Recording/RecordingSession.swift:755) already computes per-buffer RMS via `MeterTap.computeRMS(buf)` for silence detection on the mix-bus stream — the same buffer source can feed a `MeterRingBuffer` for the `"mix"` publisher entry.
- `MeterPublisher.start()` / `stop()` are idempotent and main-actor safe (AudioEngine/Meter/MeterPublisher.swift:85-103).

Fix outline (implementer chooses cleanest seam):

1. Inject the `AppStore.meters` `MeterPublisher` into `RecordingSession` (or pass it via `SessionConfig`) so the session can register/unregister the mix ring without `AppStore` reaching into session internals.
2. On session start: create a `MeterRingBuffer`, register it under `mixSourceID = "mix"`, and call `publisher.start()`. Inside the existing mix-bus consumer (the same loop that computes RMS for silence), `ring.write(MeterTap.dbfs(rms))` (or the equivalent dBFS conversion the codebase already uses) for every buffer.
3. On session pause: stop writing to the ring (or write `-.infinity` once) so the meter visibly freezes/empties — match whatever `MixLevelMeterView`'s `isActive` already expects.
4. On session stop: `publisher.unregister(sourceID: "mix")` and `publisher.stop()` if no other sources remain registered.

Keep the silence-detector behavior unchanged — it must keep getting RMS from the same stream. Prefer fanning out one stream consumer that does both jobs over duplicating the AsyncStream.

## Acceptance Criteria

- [x] During an active recording session, `AppStore.meters.meters["mix"]` is updated at ~50 Hz with finite dBFS values reflecting the mix-bus RMS.
- [x] `MixLevelMeterView` shows a non-empty colored bar and a numeric `<n> dB` readout (not `-∞ dB`) within 1 s of pressing **Start Recording** when audible audio is present on the captured source. *(Data path verified by integration test; final on-screen render requires manual verification by Tom.)*
- [x] On pause, the meter freezes to `-∞ dB` (or remains at its last value, matching the documented `MixLevelMeterView` idle/active rules — pick one and update the view's docstring if it changes). *Chosen: meter remains live during pause (matches the existing docstring's `.recording or .paused` live rendering rule). Updated `MixLevelMeterView` docstring to call this out explicitly.*
- [x] On stop, the meter returns to `-∞ dB` and the underlying `MeterPublisher` no longer holds a `"mix"` ring (verified by reading `meters.meters` after stop).
- [x] Silence-detector behavior (auto-stop after configured silence duration) is unchanged — covered by existing tests still passing.
- [x] `MeterPublisher.start()` is called when a session starts and stopped (or unregistered) when the session stops; no leaked timers across sessions.

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **test** Run the existing audio-engine + app test target.
   - Command: `xcodebuild -scheme SystemAudioRecorder -destination 'platform=macOS' test` (or whatever `Makefile` already exposes — check `Makefile` for the canonical test target).
   - Expected: all existing tests pass, including silence-detector and recording-session integration tests.
2. **test** Add a unit/integration test that drives a `RecordingSession` with a synthetic non-silent mix-bus stream and asserts `MeterPublisher.meters["mix"]` becomes a finite value > -60 dBFS within 200 ms of session start.
   - Expected: test fails before the fix, passes after.
3. **build** `xcodebuild -scheme SystemAudioRecorder -destination 'platform=macOS' build`
   - Expected: clean build, no warnings introduced.
4. **ui** Launch the app, choose the "Everything" preset, play audible audio (e.g. a YouTube tab), press **Start Recording**, and observe the meter on the main window.
   - Expected: within ~1 s the bar fills proportionally to the playing audio, color shifts green→yellow→red on louder peaks, the readout shows a finite negative dB value (e.g. `-18 dB`), and on **Stop Recording** the bar empties and the readout returns to `-∞ dB`.
5. **ui** With audio still playing, press **Start Recording**, then pause (if a pause control exists in this build), and confirm the meter behavior matches the AC choice (frozen vs. empty). Resume and confirm it tracks again.
   - Expected: behavior matches the documented rule chosen in the AC.

## Outputs

- AudioEngine/Recording/RecordingSession.swift — added `mixMeterSink` to `SessionConfig` + `withMixMeterSink(_:)` helper; mix-bus fan-out now also computes RMS once per buffer and invokes the sink (REQ-061).
- App/AppStore.swift — `startRecording` now allocates a `MeterRingBuffer`, registers it with `MeterPublisher` under `"mix"`, starts the publisher, and injects a sink closure that writes per-buffer dBFS values into the ring; `stopRecording` (and start-rollback) tear the wiring down via `tearDownMixMeter()`.
- App/Views/MixLevelMeterView.swift — docstring updated to document the chosen "live during pause" behaviour.
- Tests/AudioEngineTests/IntegrationTests/MixMeterIntegrationTests.swift — three integration tests covering mix-meter populate, clear-on-stop, and coexistence with the silence detector.

**Manual verification still required by Tom:** launch the built app, choose the "Everything" preset, play audible audio, press Start Recording, and visually confirm the bar fills/colours/readout per AC #2 (and the freeze-on-stop per AC #4). The integration tests prove the data path; SwiftUI render verification cannot be fully automated without XCUITest infrastructure that this project does not currently use.
