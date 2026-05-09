# REQ-035: MockAudioSource — protocol-conforming test fixture

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** none

## Task

Define a shared `AudioBufferEmitter` protocol that `ProcessTapCapture` (REQ-007) and `MicrophoneCapture` (REQ-008) conform to: `func bufferStream() -> AsyncStream<AVAudioPCMBuffer>`. Implement `Tests/Fixtures/MockAudioSource.swift` conforming to this protocol with synthetic buffer generation (sine, white noise, silence, file playback). Letting integration tests run full session flows without real audio devices.

## Context

Spec Section 7 specifies an integration-test layer driven by `MockAudioSource`. Without this fixture, `RecordingSession` cannot be unit-tested because real captures need real hardware.

## Acceptance Criteria

- [ ] Protocol `AudioBufferEmitter` is the only interface `RecordingSession` knows about (no direct dependence on `ProcessTapCapture` or `MicrophoneCapture`)
- [ ] `MockAudioSource` exposes presets: `.sine(frequency:level:)`, `.whiteNoise(level:)`, `.silence`, `.file(URL)`
- [ ] `MockAudioSource` can switch presets mid-stream
- [ ] `MockAudioSource` emits buffers at a configurable sample rate / channel count

## Verification Steps

1. **test** Unit test uses `MockAudioSource(.sine(440, -12 dBFS))` and asserts emitted buffers have peak amplitude matching -12 dBFS ± 0.5 dB
   - Expected: test passes
2. **test** Unit test runs full `RecordingSession.start → stop` flow with a mock source; asserts no real audio device was opened (verified by checking `AVAudioEngine` is never instantiated for capture in this test)
   - Expected: test passes

## Integration

This REQ is `**Layer:** none` (pure test infrastructure with no user-facing surface), so the Integration block is omitted per the capture rules.
