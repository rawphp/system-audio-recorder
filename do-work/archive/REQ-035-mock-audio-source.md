# REQ-035: MockAudioSource — protocol-conforming test fixture

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** none

## Task

Define a shared `AudioBufferEmitter` protocol that `ProcessTapCapture` (REQ-007) and `MicrophoneCapture` (REQ-008) conform to: `func bufferStream() -> AsyncStream<AVAudioPCMBuffer>`. Implement `Tests/Fixtures/MockAudioSource.swift` conforming to this protocol with synthetic buffer generation (sine, white noise, silence, file playback). Letting integration tests run full session flows without real audio devices.

## Context

Spec Section 7 specifies an integration-test layer driven by `MockAudioSource`. Without this fixture, `RecordingSession` cannot be unit-tested because real captures need real hardware.

## Acceptance Criteria

- [x] Protocol `AudioBufferEmitter` is the only interface `RecordingSession` knows about (no direct dependence on `ProcessTapCapture` or `MicrophoneCapture`)
- [x] `MockAudioSource` exposes presets: `.sine(frequency:level:)`, `.whiteNoise(level:)`, `.silence`, `.file(URL)`
- [x] `MockAudioSource` can switch presets mid-stream
- [x] `MockAudioSource` emits buffers at a configurable sample rate / channel count

## Verification Steps

1. **test** Unit test uses `MockAudioSource(.sine(440, -12 dBFS))` and asserts emitted buffers have peak amplitude matching -12 dBFS ± 0.5 dB
   - Expected: test passes
2. **test** Unit test runs full `RecordingSession.start → stop` flow with a mock source; asserts no real audio device was opened (verified by checking `AVAudioEngine` is never instantiated for capture in this test)
   - Expected: test passes

## Verification Steps — Results

1. **test** Unit test uses `MockAudioSource(.sine(440, -12 dBFS))` and asserts emitted buffers have peak amplitude matching -12 dBFS ± 0.5 dB
   - Expected: test passes
   - Result: `testSinePeakAmplitudeDirect` passes (0.027 s). Also `testSinePeakAmplitudeMatchesTargetDBFS` passes (0.007 s). Peak amplitude is within ±0.5 dB of −12 dBFS.

2. **test** Unit test runs full `RecordingSession.start → stop` flow with a mock source; asserts no real audio device was opened
   - Expected: test passes
   - Result: `testRecordingSessionRoundTripWithMockAudioSource` passes (0.327 s). No `AVAudioEngine` is instantiated for capture — `MockAudioSource` bypasses all hardware access. `RecordingSession` receives only the `RecordingSourceEmitter` protocol stream; `ProcessTapCapture` / `MicrophoneCapture` are never constructed.

## Notes on AC#1 — AudioBufferEmitter naming

`AudioBufferEmitter` already exists in `ProcessTapCapture.swift` (REQ-007) as a *different* protocol: the per-tap aggregate contract with `streams: [pid_t: AsyncStream]`. These are two different abstraction levels:

- `AudioBufferEmitter` (REQ-007) = the entire process-tap capture object (multi-stream, keyed by pid).
- `RecordingSourceEmitter` (REQ-013) = the per-source single-stream contract `RecordingSession` consumes.

AC#1 is satisfied: `RecordingSession` references only `RecordingSourceEmitter` and has no direct dependency on `ProcessTapCapture` or `MicrophoneCapture`. The REQ-035 typealias `AudioBufferEmitter = RecordingSourceEmitter` is defined in the test target (`Tests/AudioEngineTests/Fixtures/MockAudioSource.swift`) to avoid polluting the production module with a second `AudioBufferEmitter` name. `testAudioBufferEmitterTypealiasIsAvailable` verifies this alias compiles and is usable.

## Outputs

- `Tests/AudioEngineTests/Fixtures/MockAudioSource.swift` — `MockAudioPreset` enum (`.sine`, `.whiteNoise`, `.silence`, `.file`), `MockAudioSource` class conforming to `RecordingSourceEmitter`, `typealias AudioBufferEmitter = RecordingSourceEmitter`, convenience factories (`.defaultSine`, `.defaultNoise`, `.defaultSilence`), `driveAsync(count:delayNanos:)` helper.
- `Tests/AudioEngineTests/MockAudioSourceTests.swift` — 14 unit/integration tests: `testAudioBufferEmitterTypealiasIsAvailable`, `testBufferFormatMatchesConfiguration`, `testDefaultNoiseFactory`, `testDefaultSilenceFactory`, `testDefaultSineFactory`, `testDriveAsyncProducesBuffers`, `testMidStreamPresetSwitch`, `testRecordingSessionRoundTripWithMockAudioSource`, `testRecordingSessionSeparateModeWithMockSource`, `testSilenceEmitsZeroSamples`, `testSinePeakAmplitudeDirect`, `testSinePeakAmplitudeMatchesTargetDBFS`, `testStopIsIdempotent`, `testWhiteNoiseEmitsNonZeroSamples`. All 14 pass.

## Integration

This REQ is `**Layer:** none` (pure test infrastructure with no user-facing surface), so the Integration block is omitted per the capture rules.
