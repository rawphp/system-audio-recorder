# REQ-038: WAVWriter unit tests

**UR:** UR-001
**Status:** backlog
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

- [ ] All five scenarios pass
- [ ] No flake across 10 consecutive runs
- [ ] No real audio device required

## Verification Steps

1. **test** `xcodebuild test -only-testing:AudioEngineTests/WAVWriterTests`
   - Expected: all tests pass

## Integration

This REQ is `**Layer:** none` (test code), so the Integration block is omitted.
