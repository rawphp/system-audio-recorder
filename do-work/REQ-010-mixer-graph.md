# REQ-010: MixerGraph — per-source gain, mix bus, separate-output taps

**UR:** UR-001
**Status:** backlog
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

- [ ] Graph supports adding/removing sources at runtime without stopping the engine
- [ ] `setGain(forSource:, gain:)` is reflected in the mixed output within one buffer (~10 ms)
- [ ] Mixed output is the linear sum of (per-source buffer × per-source gain)
- [ ] Separate-mode source taps produce buffers identical to the per-source post-gain stage
- [ ] Removing a source mid-recording does not click or drop samples in surviving sources

## Verification Steps

1. **test** Unit test adds two sources emitting independent test tones (440 Hz left, 880 Hz right); mixed output FFT shows both peaks within ±2 dB of expected sum
   - Expected: test passes
2. **test** Unit test sets source-1 gain to 0.5 mid-stream; assert source-1's contribution to the mix drops by 6 dB ± 0.5 dB
   - Expected: test passes

## Integration

**Reachability:** Constructed by `RecordingSession` (REQ-013) on `start()`. Not user-facing directly; UI controls gain via AppStore (REQ-022).

**Data dependencies:** Per-source gain values come from `AppStore.mixerSettings`.

**Service dependencies:** Depends on REQ-009 (FormatNormalizer) — sources arrive normalized. Feeds REQ-011 (level meter taps) and REQ-012 (WAVWriter).
