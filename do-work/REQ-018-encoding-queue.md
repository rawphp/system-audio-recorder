# REQ-018: EncodingQueue — background OperationQueue draining WAV → MP3 jobs

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Encoding/EncodingQueue.swift` as an `@Observable` actor wrapping an `OperationQueue` (`maxConcurrentOperationCount = 2`, qualityOfService `.userInitiated`). Each `EncodingJob` is one WAV → MP3 conversion using `LameEncoder` (REQ-017). The queue exposes `@Observable` arrays: `pending`, `running`, `completed`, `failed`. On a job's completion: optionally delete the source WAV (per `keepWAVAfterEncode` setting) and surface a toast via `AppStore`.

## Context

Spec Section 5.7 describes the stop → encoding handoff: `session.stop()` synchronously enqueues `EncodingJob`s; UI returns instantly. Section 6.2 stores `keepWAVAfterEncode` (default false). Section 6.3 specifies the toast UX.

## Acceptance Criteria

- [ ] Enqueueing a job from the main thread returns immediately (< 5 ms)
- [ ] Up to 2 jobs run concurrently
- [ ] On job success, MP3 file exists at the expected URL; WAV is deleted iff `keepWAVAfterEncode == false`
- [ ] On job failure, the WAV is preserved regardless of `keepWAVAfterEncode`; failure entry surfaces the underlying `EncodingError`
- [ ] Queue can be cancelled (e.g. on app quit) without leaving partial MP3 files on disk
- [ ] `@Observable` state changes are delivered on the main actor

## Verification Steps

1. **test** Unit test enqueues 3 jobs against synthetic WAVs; asserts all 3 complete and `completed.count == 3`
   - Expected: test passes
2. **test** Unit test enqueues a job that throws mid-encode; asserts entry moves to `failed`, WAV is preserved, partial MP3 is removed
   - Expected: test passes

## Integration

**Reachability:** Driven by `RecordingSession.stop()` (REQ-013). Surfaced visually in `EncodingJobsView` (REQ-030) and the post-stop toast (REQ-027).

**Data dependencies:** Reads WAV files; writes MP3 files. Reads `keepWAVAfterEncode` from `UserDefaults` (REQ-021).

**Service dependencies:** Depends on REQ-017 (LameEncoder).
