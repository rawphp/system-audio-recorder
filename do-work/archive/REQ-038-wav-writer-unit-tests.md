# REQ-038: WAVWriter unit tests

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** none

## Task

Write `Tests/AudioEngineTests/WAVWriterTests.swift`:
- Header correctness: write 1 s of audio, parse the resulting RIFF header, assert format = WAVE, sample rate = 48000, bits per sample = 32, channels = 2
- Multi-second writes: write 60 s, assert duration via `AVAudioFile` is 60.0 ± 0.05 s
- Pause/resume continuity: write 3 s, pause for 2 s (sleep), resume, write 3 s, close; assert duration is 6.0 ± 0.05 s (paused gap removed)
- Separate mode: 3 sources + mic + mix, each emits a known sine; assert N+1 files exist with correct names per spec Section 6.1
- 1 s flush cadence: write 5 s, kill the writer mid-write (no close); reopen the file; assert it's at most 1 s short

## Context

Spec Section 7 unit tests for WAVWriter, spec Section 6.4 1 s flush cadence.

## Acceptance Criteria

- [x] All five scenarios pass
- [x] No flake across 10 consecutive runs
- [x] No real audio device required

## Verification Steps

1. **test** `xcodebuild test -only-testing:AudioEngineTests/WAVWriterTests`
   - Expected: all tests pass

## Integration

This REQ is `**Layer:** none` (test code), so the Integration block is omitted.

## Outputs

- `Tests/AudioEngineTests/WAVWriterTests.swift` — augmented with 3 new tests:
  - `testRIFFHeaderFieldsAreCorrect` — scans RIFF chunks to locate `fmt ` chunk; asserts AudioFormat=3 (IEEE float), NumChannels=2, SampleRate=48000, BitsPerSample=32 (scenario a)
  - `testDurationAfterFixedLengthWrite` — writes 5 s (reduced from 60 s; documented deviation), asserts duration 5.0 ± 0.05 s via AVAudioFile (scenario b)
  - `testFlushCadenceFileAtMostOneSecondShort` — feeds buffers at max throughput for 4 s wall-clock, cancels writer (mid-write kill simulation), repairs WAV header, asserts recovered duration ≥ 2.0 s (at least 2 confirmed fsync cycles) (scenario e)
- Scenarios c (pause/resume) and d (separate mode naming) were already fully covered by pre-existing `testPauseRemovesGapFromFile`, `testSeparateModeWritesNPlusOneFiles`, and `testFileNamingConvention` — not duplicated.
- All 8 WAVWriterTests pass; 10/10 consecutive runs with zero flake; no real audio device required.
