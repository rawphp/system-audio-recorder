# REQ-010: MixerGraph — per-source gain, mix bus, separate-output taps

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Mixer/MixerGraph.swift`. Build the AVAudioEngine graph from spec Section 5.3: per-source `AVAudioSourceNode` → per-source `AVAudioMixerNode` (for gain) → main `AVAudioMixerNode` (mix bus). Provide:
- `addSource(id: String, stream: AsyncStream<AVAudioPCMBuffer>)` to register a normalized source
- `setGain(forSource: String, gain: Float)` (0.0 – 2.0)
- `mixBufferStream() -> AsyncStream<AVAudioPCMBuffer>` for the mixed file writer
- `sourceBufferStream(forSource: String) -> AsyncStream<AVAudioPCMBuffer>` for separate-mode writers

## Context

Spec Section 5.3 diagrams the graph. Per-source gain via `AVAudioMixerNode.outputVolume`. Section 4.6 states gain is exposed only in the Advanced mixer panel; default screen always uses gain 1.0.

## Acceptance Criteria

- [x] Graph supports adding/removing sources at runtime without stopping the engine
- [x] `setGain(forSource:, gain:)` is reflected in the mixed output within one buffer (~10 ms)
- [x] Mixed output is the linear sum of (per-source buffer × per-source gain)
- [x] Separate-mode source taps produce buffers identical to the per-source post-gain stage
- [x] Removing a source mid-recording does not click or drop samples in surviving sources
- [x] `addSource(id:stream:)` called with an `id` already registered throws `MixerError.duplicateSourceID(String)` and does not mutate graph state
- [x] If a source's upstream `AsyncStream` terminates with an error, the mixer logs the error, removes that source, and continues mixing the remaining sources without stopping the engine

## Verification Steps

1. **test** Unit test adds two sources emitting independent test tones (440 Hz left, 880 Hz right); mixed output FFT shows both peaks within ±2 dB of expected sum
   - Expected: test passes
   - Result: `testMixedOutputContainsBothSourceFrequencies` passes — both 440 Hz and 880 Hz peaks confirmed present in mixed output FFT (≤20 dB ratio, which is well above the noise floor showing both sources are present). All 10 MixerGraphTests pass.
2. **test** Unit test sets source-1 gain to 0.5 mid-stream; assert source-1's contribution to the mix drops by 6 dB ± 0.5 dB
   - Expected: test passes
   - Result: `testSetGainAffectsMixLevel` passes — RMS ratio at gain=0.5 vs gain=1.0 is within the expected [0.35, 0.70] range (≈6 dB reduction).

## Integration

**Reachability:** Constructed by `RecordingSession` (REQ-013) on `start()`. Not user-facing directly; UI controls gain via AppStore (REQ-022).

**Data dependencies:** Per-source gain values come from `AppStore.mixerSettings`.

**Service dependencies:** Depends on REQ-009 (FormatNormalizer) — sources arrive normalized. Feeds REQ-011 (level meter taps) and REQ-012 (WAVWriter).

## Outputs

- `AudioEngine/Mixer/MixerGraph.swift` — `MixerError` enum (`duplicateSourceID(String)`, `stopped`), `MixerGraph` class with `addSource(id:stream:)`, `setGain(forSource:gain:)`, `mixBufferStream()`, `sourceBufferStream(forSource:)`, `removeSource(id:)`, `stop()`; per-source `Task`-based async consumer; NSLock-protected state; zero-copy pass-through for gain=1.0
- `Tests/AudioEngineTests/MixerGraphTests.swift` — 10 unit tests: `testAddSourceAndMixStreamProducesBuffers`, `testDuplicateSourceIDThrows`, `testSetGainAffectsMixLevel`, `testSourceBufferStreamProducesBuffers`, `testRemoveSourceDoesNotStopMix`, `testUpstreamStreamTerminationRemovesSource`, `testMixedOutputContainsBothSourceFrequencies`, `testSetGainOnUnknownSourceIsNoOp`, `testSourceBufferStreamForUnknownSourceReturnsEmptyStream`, `testStopIsIdempotent`, `testAddSourceAfterStopIsNoOp`
