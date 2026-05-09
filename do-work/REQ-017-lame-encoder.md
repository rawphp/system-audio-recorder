# REQ-017: LameEncoder — WAV → MP3 via libmp3lame

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Encoding/LameEncoder.swift`, a Swift wrapper around the vendored libmp3lame. Public API: `encode(wavURL: URL, mp3URL: URL, bitrate: Int, mode: BitrateMode, progress: (Double) -> Void) async throws`. Internally: open WAV via `AVAudioFile`, init LAME with sample rate / channels / bitrate / mode, read 1-second chunks, feed `lame_encode_buffer_ieee_float`, finalize with `lame_encode_flush`, write the resulting MP3 bytes to disk.

## Context

Spec Section 5.7 specifies the LAME pipeline: 1-second chunks, `lame_encode_buffer_ieee_float`, `lame_encode_flush`. Spec Section 6.2 default bitrate 192 kbps VBR. LAME's VBR uses target bitrate as an average; CBR is straightforward.

## Acceptance Criteria

- [ ] Encodes a 5 s 1 kHz tone WAV at 192 kbps VBR; resulting MP3 plays in QuickTime; FFT of decoded MP3 shows dominant peak at 1 kHz ± 5 Hz
- [ ] Supports bitrates 128, 192, 256, 320 kbps
- [ ] Supports both VBR and CBR modes
- [ ] `progress` callback fires at least 5 times during a 5 s file encode (sub-1-second granularity)
- [ ] Throws `EncodingError.cancelled` if the task is cancelled mid-encode (Task.checkCancellation respected)
- [ ] Output MP3 size for a 60 s tone at 192 kbps VBR is within ±10% of expected (1.44 MB ± 144 KB)

## Verification Steps

1. **test** Unit test encodes a known sine WAV; opens result via `AVAudioFile`; asserts decoded waveform matches source within −40 dB tolerance over the 1 kHz fundamental
   - Expected: test passes
2. **test** Unit test cancels mid-encode; asserts `EncodingError.cancelled` is thrown and partial MP3 is removed
   - Expected: test passes

## Integration

**Reachability:** Consumed by `EncodingQueue` (REQ-018). Not user-facing directly; progress flows up to `EncodingJobsView` (REQ-030).

**Data dependencies:** Reads WAV from disk; writes MP3 to disk.

**Service dependencies:** Depends on REQ-003 (vendored LAME xcframework). Output URLs are derived from the WAV URLs returned by REQ-013 (RecordingSession.stop).
