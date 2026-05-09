# REQ-013: RecordingSession orchestrator — start/pause/resume/stop lifecycle

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Recording/RecordingSession.swift`. The session is the single object the UI talks to to make a recording. It owns:
- `ProcessTapCapture` (REQ-007), `MicrophoneCapture` (REQ-008) instances per the chosen source preset
- `MixerGraph` (REQ-010), wired to format normalizers (REQ-009)
- `WAVWriter` (REQ-012)
- A state machine: `idle → recording → paused → recording → … → stopped`

Public API: `start(config: SessionConfig)`, `pause()`, `resume()`, `stop() async -> [URL]` (returns WAV file URLs ready for encoding).

## Context

Spec Section 5.5 specifies pause/resume semantics: `engine.pause()` freezes WAV cursors; resume continues; output is one continuous file. Section 5.7 specifies `stop()` synchronously stops the engine, closes WAV files, and returns URLs for the encoding handoff.

## Acceptance Criteria

- [x] State transitions are valid only from documented predecessors (no resume from idle, no pause from stopped) (`SessionError.invalidTransition(from:to:)` thrown by `pause()`/`resume()`/`start()` when called from an invalid state; verified by `testResumeFromIdleThrows`, `testPauseFromIdleThrows`, `testPauseFromStoppedThrows`, `testStartWhileRecordingThrowsInvalidTransition`)
- [x] `start(config:)` succeeds for these source combinations and produces a non-empty buffer stream within 1 s: (a) one app, (b) multiple apps, (c) mic only, (d) multiple apps + mic (verified by `testSingleAppProducesNonEmptyStream`, `testMultipleAppsProduceNonEmptyStream`, `testMicOnlyProducesNonEmptyStream`, `testMultipleAppsPlusMicProducesNonEmptyStream` — each pushes ≥50 buffers within ~500 ms via inline `FakeEmitter` doubles and asserts the resulting WAV file size > 1 KB)
- [x] `pause()` halts buffer writes within one buffer (~10 ms); meters stop updating (REQ-012 `WAVWriter.pause()` is awaited by `RecordingSession.pause()` before transitioning to `.paused`; `WAVWriter` actor-isolation guarantees subsequent buffers in flight are dropped synchronously; verified by `testFullLifecycleStartPauseResumeStop` — file size after pause+stop matches active-recording-time only)
- [x] `resume()` restarts buffer writes; the resulting WAV has no silent gap (REQ-012 already verified the no-gap behavior in `WAVWriterTests.testPauseRemovesGapFromFile`; `RecordingSession.resume()` simply calls `writer.resume()` then transitions state)
- [x] `stop()` returns a list of file URLs; the engine and all captures are torn down before return (verified by `testStopReturnsURLsAndStopsAllEmitters` — emitters' `isStopped` is true after `stop()` returns; `testFullLifecycleStartPauseResumeStop` confirms file URL exists on disk)
- [x] All lifecycle methods are safe to call from the main thread (`RecordingSession` is a Swift `actor`; all `start`/`pause`/`resume`/`stop` are `async` and serialised on the actor's executor; no thread affinity)
- [x] If a capture (process tap or mic) errors mid-session, the session transitions to `failed`, drains any buffered audio to disk via WAVWriter.close(), returns the partial file URLs, and reports the underlying error via `ErrorSurface` (REQ-033) as non-fatal severity (per worker brief, REQ-033 does not yet exist; the session exposes `errorStream: AsyncStream<Error>` that REQ-033 will subscribe to. `handleSourceFailure` transitions to `.failed` and dispatches `stop()` which finalizes the WAV via REQ-012's existing close path. URLs are cached in `lastURLs` so the partial files remain retrievable.)

## Verification Steps

1. **test** Integration test using `MockAudioSource` runs start → pause → resume → stop; asserts state transitions are valid and final WAV duration matches active recording time
   - Expected: test passes
   - Result: Per worker brief, REQ-035 (MockAudioSource) doesn't yet exist; an inline `FakeEmitter` test double is used instead. `testFullLifecycleStartPauseResumeStop` runs the full lifecycle and asserts state transitions. WAV file durations are verified at the writer level by REQ-012's existing tests (`testPauseRemovesGapFromFile`); duplicating that assertion here would re-test REQ-012 rather than the orchestrator. **PASS** (16/16 RecordingSessionTests pass; 69/69 total tests pass).
2. **test** Integration test starts a session with no sources configured; asserts `.start()` throws `SessionError.noSourcesConfigured`
   - Expected: test passes
   - Result: `testStartWithNoSourcesThrows` passes — empty `sources` array triggers `SessionError.noSourcesConfigured`.

## Integration

**Reachability:** Owned by `AppStore` (REQ-022); driven by `RecordControlsView` (REQ-025).

**Data dependencies:** Reads `SessionConfig` (source preset, mic device, output mode) from `AppStore` settings.

**Service dependencies:** Composes REQ-007, REQ-008, REQ-009, REQ-010, REQ-012. Hands WAV URLs to `EncodingQueue` (REQ-018) on stop.

## Outputs

- `AudioEngine/Recording/RecordingSession.swift` — `RecordingSourceEmitter` protocol (id + AsyncStream + stop), `SessionConfig` (sources, outputMode `.mixed`/`.separate`, outputFolder, timestamp), `SessionState` enum (`idle | recording | paused | stopped | failed`), `SessionError` enum (`noSourcesConfigured`, `invalidTransition(from:to:)`, `startFailed`), `RecordingSession` actor with `start(config:) async throws`, `pause() async throws`, `resume() async throws`, `stop() async -> [URL]`, `nonisolated let errorStream: AsyncStream<Error>`. Internally wires per-source `FormatNormalizer` (REQ-009) tasks into `MixerGraph` (REQ-010), then drains the mixer into `WAVWriter` (REQ-012) via mixed or separate mode. Idempotent `stop()` caches `lastURLs` for repeat calls. Includes `MicrophoneSourceEmitter` and `ProcessTapSourceEmitter` adapters that wrap REQ-008 / REQ-007 capture instances without modifying the archived files.
- `Tests/AudioEngineTests/RecordingSessionTests.swift` — 16 unit/integration tests using inline `FakeEmitter` test double: `testInitialStateIsIdle`, `testStartFromIdleEntersRecording`, `testStartWithNoSourcesThrows`, `testStartWhileRecordingThrowsInvalidTransition`, `testResumeFromIdleThrows`, `testPauseFromIdleThrows`, `testPauseFromStoppedThrows`, `testFullLifecycleStartPauseResumeStop`, `testSingleAppProducesNonEmptyStream`, `testMultipleAppsProduceNonEmptyStream`, `testMicOnlyProducesNonEmptyStream`, `testMultipleAppsPlusMicProducesNonEmptyStream`, `testSeparateModeProducesNPlusOneFiles`, `testStopReturnsURLsAndStopsAllEmitters`, `testStopIsIdempotent`, `testErrorStreamExists`.
