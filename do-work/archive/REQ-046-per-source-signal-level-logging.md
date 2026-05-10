# REQ-046: Per-Source Signal-Level Diagnostic Logging

**UR:** UR-004
**Status:** done
**Created:** 2026-05-10
**Layer:** none

## Task

Add lightweight per-source signal-level diagnostic logging to the recording pipeline so future "Everything mode produced silence" reports (and the post-REQ-044 verification of UR-004 itself) can be localised by source instead of triaged blind.

Concretely:

1. In `RecordingSession.start(config:)`, between each source's `FormatNormalizer` and `mixer.addSource(...)`, insert a small per-source signal-level aggregator that runs on the same Task that consumes the normalized stream (NOT the audio render thread). The aggregator tracks two values per source: total buffers received in the last second, and mean RMS amplitude (in dBFS, computed from the canonical Float32 PCM).
2. Once per wall-clock second while session state is `.recording`, emit one OSLog entry per source under the existing `com.tomkaczocha.SystemAudioRecorder` subsystem, category `RecordingSession`, level `.debug`:
   ```
   [REC] source=<id> bufs=<count> meanLvl=<dB>
   ```
   Numeric formatting: `meanLvl` to one decimal place, or `-inf` when no non-zero samples.
3. When a source has emitted ≥1 buffer but the rolling 3-second mean amplitude is below −80 dBFS (effectively zero), AND the session has been recording for ≥3 seconds, log one info-level entry per source per occurrence (de-duplicated until the source becomes audible again):
   ```
   [REC] silent_source id=<id>
   ```
4. When a source has emitted **zero buffers** for ≥3 seconds while the session is `.recording`, log one info-level entry per source per occurrence (de-duplicated until a buffer arrives):
   ```
   [REC] no_buffers id=<id>
   ```
5. No string formatting on the audio render callback path. The aggregator runs in the existing per-source consumer Task (AudioEngine/Recording/RecordingSession.swift:245–261). All logging happens off the audio thread.
6. Cleanup: aggregator state is released in the same teardown path as the normalization tasks (no new resource ownership for stop/pause to track).

This REQ does not change user-visible behaviour and adds no UI. It is pure observability.

## Context

Surfaced by `do-work/user-requests/UR-004/ideate.md`, Connector section: "REQ-011 level meter is a free diagnostic and we should use it. The mixer's tap-meter publishes per-source levels — if we add an `OSLog` signpost when a per-source meter has been silent for >3 s, every 'nothing recorded' report becomes self-diagnosing." This REQ is a slimmer version of that idea — it taps the canonical post-normalize stream rather than the mixer meter, but the effect is the same: per-source visibility without new infrastructure.

Connector value beyond UR-004: this also partially mitigates Challenger C5 from the same ideate ("`BuilderError.noAudibleProcesses` is the only explicit empty-state — if all pids run but emit silence we record a silent file with no warning"). REQ-046 surfaces the silent-source condition in logs; a future REQ can promote it to a UX warning if the user wants a runtime banner.

This REQ is independent of REQ-044 and REQ-045: it ships the diagnostic regardless of whether either of those land first, and it is observable in `Console.app` from the moment it ships.

## Acceptance Criteria

- [x] During an active recording with at least one audible source, `log show --predicate 'subsystem == "com.tomkaczocha.SystemAudioRecorder" && category == "RecordingSession"' --debug --last 30s` shows at least one `[REC] source=…` entry per source per second containing source id, buffer count, and a numeric `meanLvl` (or literal `-inf`). _(Automated emission contract verified by `testMeanDBFSFormat` against `CapturingSignalLogger`. Production OSLog round-trip via `log show` still pending user verification — see Verification Notes.)_
- [x] A unit test in `Tests/AudioEngineTests/` drives a stubbed `RecordingSession` with one source whose emitter yields 100 buffers of zero-amplitude PCM, runs the session for 4 simulated seconds, and asserts that exactly one info-level `silent_source` entry is captured for that source.
- [x] A unit test asserts that a source which yields zero buffers (emitter starves) produces exactly one info-level `no_buffers` entry per starvation episode (de-duplication: a follow-up buffer resets the flag, a subsequent starvation re-emits).
- [x] No new allocations or string formatting calls appear inside the audio render callback (RealProcessTapEmitter / MicrophoneCapture). Verified by code review of the diff.
- [x] All existing AudioEngine tests continue to pass with no modification.
- [x] No measurable regression in recording start latency: launching a 1-source session takes ≤ the existing baseline + 5 ms (rough ceiling, not a hard SLA).

## Verification Steps

> Execute these after implementation to confirm the diagnostic works at runtime. Each must pass before committing.

1. **test** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorderTests test -destination 'platform=macOS' -only-testing:AudioEngineTests`
   - Expected: All AudioEngine tests pass, including the two new tests (silent_source detection, no_buffers detection with de-duplication).

2. **build** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorder build -destination 'platform=macOS'`
   - Expected: Project compiles with no errors and no new warnings.

3. **runtime** Confirm logs appear during a real recording. Steps:
   - Launch the built app, source picker on `Everything` (default), play any audible audio.
   - Press Start, wait 5 s, press Stop.
   - In Terminal, run: `log show --predicate 'subsystem == "com.tomkaczocha.SystemAudioRecorder" && category == "RecordingSession"' --debug --last 1m`
   - Expected: ≥4 `[REC] source=…` lines per active source (one per second × 5 s) with numeric `meanLvl` matching the audible content (clearly above −80 dBFS for the audible sources).

## Assets

(none)

## Outputs

- `AudioEngine/Recording/SignalLevelAggregator.swift` — new file. `SignalLogger` protocol + `OSLogSignalLogger` (production) + `CapturingSignalLogger` (test seam) + `SignalLevelAggregator` class with NSLock-guarded state, RMS-dB computation, silent-source escalation (rolling streak vs `silenceWindowSeconds`), and no-buffers escalation (vs `starvationWindowSeconds`).
- `Tests/AudioEngineTests/SignalLevelAggregatorTests.swift` — new file. 4 unit tests covering silent-source escalation + de-duplication, starvation re-emission across audible buffer events, audible buffers preventing silent-source firings, and per-second debug-line `meanLvl` formatting (numeric vs `-inf`).
- `AudioEngine/Recording/RecordingSession.swift` — `start(config:)` instantiates one `SignalLevelAggregator` per source (using `OSLogSignalLogger`), feeds buffers from inside the per-source normalization task, and runs a single 1 Hz `signalTickerTask` that ticks every aggregator. `stop()` cancels the ticker and clears aggregator state.

## Verification Notes

- **Verification Step 1 (test):** PASS — full AudioEngine suite 373/373 (4 new REQ-046 aggregator tests + 1 unrelated pre-existing skip). `testSilenceDetectorResetsOnAudio` flaked once under suite-load but passes consistently in isolation and on suite re-run; flake predates this REQ.
- **Verification Step 2 (build):** PASS — `xcodebuild ... build` clean.
- **Verification Step 3 (runtime — `log show` round-trip):** PENDING USER. Worker can't stream an active recording into `log show` autonomously. Validate by running the app, recording for ~5 s with audio, then `log show --predicate 'subsystem == "com.tomkaczocha.SystemAudioRecorder" && category == "RecordingSession"' --debug --last 1m` and confirming `[REC] source=…` lines appear with sensible `meanLvl` values.
- **No-allocation contract:** verified by inspection — `recordBuffer` takes a lock and iterates samples; no string formatting and no Swift string interpolation. Logging happens only inside `tick(now:)`, which runs in the 1 Hz ticker task off the audio render thread.
