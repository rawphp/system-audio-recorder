# REQ-039: FormatNormalizer + silence detector unit tests

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** none

## Task

Two test classes:

`Tests/AudioEngineTests/FormatNormalizerTests.swift`:
- 44.1k mono → 48k stereo: peak frequency preserved
- 96k stereo → 48k stereo: aliasing absent (no spurious peaks)
- 48k → 48k: identity (input == output buffers)
- Mid-stream input format change: at most one buffer dropped at the boundary

`Tests/AudioEngineTests/SilenceDetectorTests.swift`:
- All-silence input below -60 dBFS triggers detector after threshold
- One audible buffer above -60 dBFS resets the silence counter
- Startup grace period (first 2 s) suppresses detection regardless of input
- Threshold of 30 s (default): silence input fires stop at t = 32 s ± 0.5 s. Threshold of 5 s (custom): silence input fires stop at t = 7 s ± 0.5 s (both account for the 2 s startup grace)

## Context

Spec Section 7 unit tests; Section 5.4 (format) and Section 5.6 (silence).

## Acceptance Criteria

- [ ] Both test classes pass deterministically
- [ ] No flake across 10 consecutive runs
- [ ] No real audio device required

## Verification Steps

1. **test** `xcodebuild test -only-testing:AudioEngineTests/FormatNormalizerTests -only-testing:AudioEngineTests/SilenceDetectorTests`
   - Expected: all tests pass

## Integration

This REQ is `**Layer:** none` (test code), so the Integration block is omitted.
