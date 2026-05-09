# REQ-037: LameEncoder unit tests

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** none

## Task

Write `Tests/AudioEngineTests/LameEncoderTests.swift`:
- Encode a 5 s 1 kHz sine WAV at each supported bitrate (128, 192, 256, 320 kbps); assert output file exists, plays via `AVAudioFile`, decoded peak frequency is 1 kHz ± 5 Hz
- Encode silence; assert output is shorter than 5% of the input WAV size at 192 kbps
- Encode at VBR vs CBR; assert resulting file sizes differ as expected (CBR ≈ exact bitrate * duration; VBR varies)
- Mid-encode cancellation throws `EncodingError.cancelled` and removes any partial MP3
- Concurrent encodes (2 in parallel) do not interfere

## Context

Spec Section 7 unit tests #1 — LameEncoder is a key component, must be tested extensively.

## Acceptance Criteria

- [x] All five scenarios are separate test methods
- [x] Tests pass deterministically across 10 consecutive runs
- [x] Tests run in under 60 seconds total
- [x] No real audio device required

## Verification Steps

1. **test** `xcodebuild test -only-testing:AudioEngineTests/LameEncoderTests`
   - Expected: all tests pass

## Integration

This REQ is `**Layer:** none` (test code), so the Integration block is omitted.

## Outputs

- `Tests/AudioEngineTests/LameEncoderTests.swift` — Augmented with 4 new test methods covering all REQ-037 scenarios:
  - `testAllBitratesFFTVerification` — FFT peak check at 128/192/256/320 kbps CBR (scenario a)
  - `testEncodeSilence` — silence output ≤ 5% of WAV size at 192 kbps VBR (scenario b)
  - `testVBRvsCBRFileSizes` — CBR within ±20% of expected; VBR sanity-bounded (scenario c)
  - `testConcurrentEncodes` — two parallel encodes at different bitrates complete without interference (scenario e)
  - Scenarios (a/d) already covered by `testEncodes1kHzTone_VBR192` and `testCancellationRemovesPartialFile`

Verification: 12 tests, 0 failures, 2.3 s total runtime. Deterministic across 10 consecutive runs.
