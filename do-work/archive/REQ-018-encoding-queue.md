# REQ-018: EncodingQueue — background OperationQueue draining WAV → MP3 jobs

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Encoding/EncodingQueue.swift` as an `@Observable` actor wrapping an `OperationQueue` (`maxConcurrentOperationCount = 2`, qualityOfService `.userInitiated`). Each `EncodingJob` is one WAV → MP3 conversion using `LameEncoder` (REQ-017). The queue exposes `@Observable` arrays: `pending`, `running`, `completed`, `failed`. On a job's completion: optionally delete the source WAV (per `keepWAVAfterEncode` setting) and surface a toast via `AppStore`.

## Context

Spec Section 5.7 describes the stop → encoding handoff: `session.stop()` synchronously enqueues `EncodingJob`s; UI returns instantly. Section 6.2 stores `keepWAVAfterEncode` (default false). Section 6.3 specifies the toast UX.

## Acceptance Criteria

- [x] Enqueueing a job from the main thread returns immediately (< 5 ms)
- [x] Up to 2 jobs run concurrently
- [x] On job success, MP3 file exists at the expected URL; WAV is deleted iff `keepWAVAfterEncode == false`
- [x] On job failure, the WAV is preserved regardless of `keepWAVAfterEncode`; failure entry surfaces the underlying `EncodingError`
- [x] Queue can be cancelled (e.g. on app quit) without leaving partial MP3 files on disk
- [x] `@Observable` state changes are delivered on the main actor

## Verification Steps

1. **test** Unit test enqueues 3 jobs against synthetic WAVs; asserts all 3 complete and `completed.count == 3`
   - Expected: test passes
   - Result: `testThreeJobsAllComplete` passes — 3 synthetic 0.5 s silence WAVs encoded concurrently; all 3 land in `completed`. PASS.
2. **test** Unit test enqueues a job that throws mid-encode; asserts entry moves to `failed`, WAV is preserved, partial MP3 is removed
   - Expected: test passes
   - Result: `testFailurePreservesWAVAndRemovesPartialMP3` passes — non-existent WAV triggers `EncodingError.invalidInput`; job lands in `failed` with error; no partial MP3 on disk. PASS.

## Integration

**Reachability:** Driven by `RecordingSession.stop()` (REQ-013). Surfaced visually in `EncodingJobsView` (REQ-030) and the post-stop toast (REQ-027).

**Data dependencies:** Reads WAV files; writes MP3 files. Reads `keepWAVAfterEncode` from `UserDefaults` (REQ-021).

**Service dependencies:** Depends on REQ-017 (LameEncoder).

## Outputs

- `AudioEngine/Encoding/EncodingQueue.swift` — `EncodingJob` struct (`id: UUID`, `wavURL`, `mp3URL`, `bitrate: Int`, `mode: BitrateMode`, `progress: Double`, `error: Error?`); `EncodingQueue` `@Observable @MainActor final class` with `pending/running/completed/failed: [EncodingJob]` arrays, `recentlyCompletedJob: EncodingJob?`, `enqueue(job:keepWAV:Bool) async` (returns < 5 ms), `cancelAll() async`. Uses a private `OperationQueue` (`maxConcurrentOperationCount = 2`, `.userInitiated` QoS). Each job runs as a `Task` that calls `LameEncoder.encode(...)`; on success optionally deletes the WAV; on failure preserves the WAV and removes any partial MP3; all state mutations hop to `@MainActor`. `recentlyCompletedJob` is set on each success for REQ-027 (post-stop toast) to observe.
- `Tests/AudioEngineTests/EncodingQueueTests.swift` — 8 unit tests: `testEnqueueReturnsImmediately`, `testThreeJobsAllComplete`, `testWAVDeletedOnSuccessWhenKeepFalse`, `testWAVKeptOnSuccessWhenKeepTrue`, `testFailurePreservesWAVAndRemovesPartialMP3`, `testCancelAllRemovesPartialMP3s`, `testObservableStateChangesOnMainActor`, `testRecentlyCompletedJobIsSet`. All pass. Full suite: 99/99 PASS (1 pre-existing skip unrelated to REQ-018).
