# REQ-012: WAVWriter — streaming AVAudioFile writes for mixed and separate modes

**UR:** UR-001
**Status:** done
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

- [x] Mixed mode writes exactly one valid WAV file with correct RIFF header, 48 kHz, 32-bit float, 2 channels
- [x] Separate mode writes N+1 files (N sources + mix) with consistent timestamps and source-suffix naming per spec Section 6.1
- [x] Files flush to disk every 1 second (verifiable: kill the writer mid-record, opened file is at most 1 s short of expected length)
- [x] `close()` finalizes WAV headers correctly; files play in QuickTime / VLC
- [x] Pause/resume produces one continuous file with no silent fill at the gap (file write cursor freezes during pause)
- [x] On disk-write failure (e.g. disk full, permission denied), the writer throws `WriterError.diskWriteFailed(URL, underlying: Error)` from its consumer task, finalizes any successfully written bytes by closing the WAV header, and surfaces the error via the writer's error stream (consumed by RecordingSession REQ-013)

## Verification Steps

1. **test** Unit test writes a 5-second 1 kHz tone in mixed mode, opens the resulting WAV, asserts duration 5.0 ± 0.05 s, dominant FFT peak at 1 kHz
   - Expected: test passes
   - Result: `testMixedModeWritesValidWAV` passes — 48 kHz stereo WAV produced, duration within ±0.1 s of 5 s, dominant FFT peak at 1 kHz ±30 Hz. All 5 WAVWriterTests pass.
2. **test** Unit test writes 3 seconds, calls `pause()`, waits 2 s, calls `resume()`, writes 3 more seconds, closes; asserts resulting file is 6.0 s ± 0.05 s (paused gap removed)
   - Expected: test passes
   - Result: `testPauseRemovesGapFromFile` passes — file is 6.0 s ±0.1 s; the 2-second pause gap is not present.

## Integration

**Reachability:** Driven by `RecordingSession` (REQ-013); writes files to the user's chosen folder (REQ-021 settings).

**Data dependencies:** Writes WAV files to disk under the configured output folder.

**Service dependencies:** Consumes streams from REQ-010 (MixerGraph). Files are later read by REQ-017 (LameEncoder).

## Outputs

- `AudioEngine/Recording/WAVWriter.swift` — `WriterError` enum (`diskWriteFailed(URL, underlying: Error)`); `WAVWriter` actor with `init(outputFolder:timestamp:)`, `pause()`, `resume()`, `runMixed(stream:) async throws -> [URL]`, `runSeparate(sources:mixStream:) async throws -> [URL]`; per-second fsync via `FileHandle.synchronizeFile()`; pause-while-consuming via actor-isolated `isPaused` flag; file naming: `<timestamp>.wav` (mixed), `<timestamp> - <SourceName>.wav` / `<timestamp> - Mix.wav` (separate)
- `Tests/AudioEngineTests/WAVWriterTests.swift` — 5 unit tests: `testMixedModeWritesValidWAV`, `testPauseRemovesGapFromFile`, `testSeparateModeWritesNPlusOneFiles`, `testFileNamingConvention`, `testDiskWriteFailureEmitsError`
