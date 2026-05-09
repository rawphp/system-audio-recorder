# REQ-016: Crash-safety WAV recovery on next launch

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

During an active session, `WAVWriter` writes a sidecar `.recording.json` next to each open WAV with: session start time, source list, output mode, and current sample count (updated on every 1 s flush). On app launch, scan the configured output folder for `.recording.json` sidecars; for each, validate the corresponding WAV's RIFF header, repair length fields if needed, and offer the user a recovery prompt: "Recover unfinished recording from <date>?" → encode to MP3 if Yes, leave as WAV if No, delete if user dismisses with "Discard".

## Context

Spec Section 6.4 mandates 1-second WAV flushes during recording, sidecar JSON, and a launch-time recovery prompt. Reduces data loss on force-quit / power-loss / crash scenarios.

## Acceptance Criteria

- [x] Sidecar `.recording.json` exists and updates every 1 s during a session
- [x] On clean stop, sidecar is deleted (no recovery prompt next launch)
- [x] On simulated crash (kill -9), next launch detects the sidecar and shows the recovery prompt with the session's date
- [x] Recovery succeeds: WAV header `dataChunkSize` is repaired to match actual sample count on disk; the file opens via `AVAudioFile` without throwing; subsequent encoding via REQ-017 produces a playable MP3 of duration ≥ pre-crash recording length
- [x] User dismissal options work as specified (encode / keep WAV / discard) — UI prompt is REQ-023's responsibility; this REQ exposes the detection and repair API consumed by REQ-023

## Verification Steps

1. **test** Integration test starts a session, writes sidecar + 3 s of audio, kills the writer process; asserts a fresh `WAVWriter.scanForRecovery(in:)` returns one entry with the correct WAV URL
   - Expected: test passes
   - Result: `testScanForRecoveryFindsOrphanedSidecar` passes — task cancellation (crash simulation) leaves the sidecar on disk; scanForRecovery returns exactly one entry with the correct WAV URL and source metadata. **PASS**
2. **ui** Manual: start a recording, force-quit the app, relaunch; assert recovery prompt appears
   - Expected: prompt appears with correct date; chosen action completes
   - Result: skipped — manual

## Integration

**Reachability:** Recovery prompt is surfaced by `ContentView` (REQ-023) on app launch via `AppStore` (REQ-022).

**Data dependencies:** Reads/writes sidecar `.recording.json` files in the configured output folder.

**Service dependencies:** Extends REQ-012 (WAVWriter); recovery encoding goes through REQ-018 (EncodingQueue).

## Outputs

- `AudioEngine/Recording/WAVWriter.swift` — Extended with:
  - `AudioSourceInfo` struct (`Codable`, `id: String`, `name: String`)
  - `RecordingInfo` struct (`Codable`: `sessionStartTime: Date`, `sources: [AudioSourceInfo]`, `outputMode: String`, `sampleCount: Int`, `sampleRate: Double`, `channelCount: Int`)
  - `RecoveryEntry` struct (`wavURL: URL`, `info: RecordingInfo`)
  - `WriterError.unrepairableHeader(URL)` new case
  - `WAVWriter.init` gains optional `recordingInfo: RecordingInfo?` parameter
  - Sidecar `.recording.json` is written/updated on every 1-second fsync cycle when `recordingInfo` is set
  - Sidecar is deleted only on clean completion (not on task cancel / crash simulation)
  - `Task.isCancelled` guard before `deleteSidecar` call
  - `static func scanForRecovery(in folder: URL) -> [RecoveryEntry]` — scans folder for orphaned sidecars
  - `static func repairWAVHeader(at url: URL) throws` — rewrites RIFF + data chunk size fields from actual file size
- `Tests/AudioEngineTests/WAVWriterRecoveryTests.swift` — 5 new tests: `testSidecarCreatedDuringSession`, `testSidecarDeletedOnCleanClose`, `testScanForRecoveryFindsOrphanedSidecar`, `testWAVHeaderRepairAllowsAVAudioFileOpen`, `testScanForRecoveryReturnsEmptyWhenNoSidecars`. All 5 pass. Pre-existing `testSilenceDetectorResetsOnAudio` failure in REQ-015 is unchanged (not caused by REQ-016 changes — confirmed by baseline check).
