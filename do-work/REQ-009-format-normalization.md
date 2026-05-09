# REQ-009: Format normalization — resample every source to 48 kHz Float32 stereo

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Mixer/FormatNormalizer.swift`: a streaming resampler that consumes `AVAudioPCMBuffer`s at any sample rate / channel count and emits buffers at the canonical format `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)`. Handle mid-stream sample-rate changes (e.g. an app switching between tracks of different rates) by recreating the resampler when the input format changes.

## Context

Spec Section 5.4 mandates a single canonical format (48 kHz, Float32, stereo) at every source node before reaching the mixer. Section 5.8 risk #2 calls out sample-rate drift mid-stream; the fix is to recreate the AUHAL render format on `kAudioDevicePropertyNominalSampleRate` change.

## Acceptance Criteria

- [ ] `FormatNormalizer` accepts an arbitrary input `AVAudioFormat` and outputs the canonical 48 kHz F32 stereo format
- [ ] 44.1 kHz mono input is upsampled to 48 kHz and channel-doubled to stereo
- [ ] 48 kHz F32 stereo input is passed through with no work
- [ ] Mid-stream input format change triggers resampler recreation; no clicks or dropped samples beyond one buffer worth (~10 ms)
- [ ] Tested at four input rates: 44.1k, 48k, 88.2k, 96k
- [ ] If `AVAudioConverter` initialization fails for an input format (e.g. unsupported sample rate or channel layout), the normalizer throws `NormalizerError.unsupportedInputFormat(AVAudioFormat)` and emits no buffers for that source until a new compatible format arrives

## Verification Steps

1. **test** Unit test feeds a 1 kHz sine wave at 44.1 kHz; output is captured for 1 second; assert output sample rate is 48000, peak frequency in FFT is 1 kHz ± 5 Hz
   - Expected: test passes
2. **test** Unit test changes input rate from 48k → 96k mid-stream; assert no more than one output buffer is dropped at the transition
   - Expected: test passes

## Integration

**Reachability:** Sits between source capture nodes (REQ-007 / REQ-008) and the mixer (REQ-010). Not user-facing.

**Data dependencies:** None.

**Service dependencies:** Used by `MixerGraph` (REQ-010) per source.
