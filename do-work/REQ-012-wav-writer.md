# REQ-012: WAVWriter — streaming AVAudioFile writes for mixed and separate modes

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Recording/WAVWriter.swift`. A session-scoped writer that opens one or many `AVAudioFile`s in 32-bit float WAV format and consumes `AsyncStream<AVAudioPCMBuffer>`s. Modes:
- **mixed**: writes one file (`<timestamp>.wav`) consuming the mix stream from `MixerGraph.mixBufferStream()`
- **separate**: writes one file per source plus a `<timestamp> - Mix.wav`, each fed by its respective stream

Flush every 1 second (per spec Section 6.4 crash safety). On `close()`, finalize headers and return the file URLs.

## Context

Spec Section 5.7 specifies `AVAudioFile` writes at 48 kHz Float32 (matching FormatNormalizer output). Section 6.1 specifies file-naming conventions. Section 6.4 mandates 1-second flush cadence.

## Acceptance Criteria

- [ ] Mixed mode writes exactly one valid WAV file with correct RIFF header, 48 kHz, 32-bit float, 2 channels
- [ ] Separate mode writes N+1 files (N sources + mix) with consistent timestamps and source-suffix naming per spec Section 6.1
- [ ] Files flush to disk every 1 second (verifiable: kill the writer mid-record, opened file is at most 1 s short of expected length)
- [ ] `close()` finalizes WAV headers correctly; files play in QuickTime / VLC
- [ ] Pause/resume produces one continuous file with no silent fill at the gap (file write cursor freezes during pause)

## Verification Steps

1. **test** Unit test writes a 5-second 1 kHz tone in mixed mode, opens the resulting WAV, asserts duration 5.0 ± 0.05 s, dominant FFT peak at 1 kHz
   - Expected: test passes
2. **test** Unit test writes 3 seconds, calls `pause()`, waits 2 s, calls `resume()`, writes 3 more seconds, closes; asserts resulting file is 6.0 s ± 0.05 s (paused gap removed)
   - Expected: test passes

## Integration

**Reachability:** Driven by `RecordingSession` (REQ-013); writes files to the user's chosen folder (REQ-021 settings).

**Data dependencies:** Writes WAV files to disk under the configured output folder.

**Service dependencies:** Consumes streams from REQ-010 (MixerGraph). Files are later read by REQ-017 (LameEncoder).
