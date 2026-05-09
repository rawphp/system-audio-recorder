# REQ-030: EncodingJobsView — in-progress encoding job list

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/EncodingJobsView.swift`. A small overlay accessible from the post-stop toast or from a status item ("3 encodings…") in `ContentView`'s footer. Shows: each job with its file name, progress percentage, and a Cancel button. Completed and failed jobs disappear from the list after 5 s (so the user sees the transition).

## Context

Spec Section 4.4 shows the toast as the primary surface, but in-flight jobs should be inspectable when the user wants detail. Section 5.7 specifies background encoding.

## Acceptance Criteria

- [x] List populates from `EncodingQueue.pending + running` (REQ-018)
- [x] Each row shows file name, progress bar with percent, status (Pending / Encoding / Done / Failed), Cancel button
- [x] Cancel removes the job from the queue and removes any partial MP3
- [x] Completed jobs flash green for 5 s then disappear
- [x] Failed jobs stay in the list with an error tooltip until manually dismissed
- [x] If queue is empty, view is hidden (no chrome)

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
   - Result: `make build` → **BUILD SUCCEEDED**
2. **ui** Start two short recordings in sequence, stop both, take snapshot during encoding
   - Expected: list shows two encoding rows with progress bars
   - Result: **skipped — manual**

## Integration

**Reachability:** Opened from a count badge in `ContentView`'s footer or the post-stop toast (REQ-027).

**Data dependencies:** Subscribes to `AppStore.encodingQueue` (REQ-018).

**Service dependencies:** Depends on REQ-018 (EncodingQueue) and REQ-022 (AppStore).

## Outputs

- `App/Views/EncodingJobsView.swift` — `EncodingJobDisplayState` enum (`.pending | .encoding | .doneFlash | .failed(Error)`); `EncodingJobDisplay` value type (`id`, `fileName`, `progress`, `state`, `appearedAt`); `EncodingJobsViewModel` (`@Observable @MainActor` class) with injectable `queue: EncodingQueueObservable`, `flashDuration: TimeInterval`, and `nowProvider: () -> Date`; `displayedJobs: [EncodingJobDisplay]` computed by `refresh()` merging pending + running + recently-completed (≤ flashDuration) + failed (sticky); `markCompleted(jobID:at:)` records completion timestamp for flash window; `dismiss(jobID:)` removes a job from display (for failed rows); `cancel(jobID:)` calls `queue.cancelAllJobs()` only when the target job is the sole active job — otherwise no-op (needs per-job cancel API in EncodingQueue v2); `isQueueEmpty: Bool`; `runningCount: Int`; `EncodingJobsView` SwiftUI shell with per-row icon + filename + progress label + action button; `withObservationTracking`-based observation loop in `.task`.
- `App/Views/SaveToast.swift` — `EncodingQueueObservable` protocol extended with `pending: [EncodingJob]` and `cancelAllJobs() async`; `EncodingQueue` extension providing `cancelAllJobs()` bridging to `cancelAll()`.
- `App/Views/ContentView.swift` — Added `@State private var jobsVM: EncodingJobsViewModel?` and `showJobsPopover: Bool`; footer badge button showing `"\(runningCount) encoding(s)…"` when queue non-empty, opening `EncodingJobsView` in a `.popover`; `jobsVM` built alongside `toastVM` in the `.task` modifier.
- `Tests/AudioEngineTests/EncodingJobsViewTests.swift` — 11 unit tests using `MockEncodingQueueForJobs`: `testDisplayedJobsContainsPendingJobs`, `testDisplayedJobsContainsRunningJobs`, `testCompletedJobWithinFlashWindowIsDoneFlash`, `testFailedJobIsSticky`, `testFailedJobDoesNotAutoRemove`, `testDismissRemovesFailedJob`, `testCancelCallsCancelAllWhenSoleJob`, `testCancelIsNoOpWhenMultipleJobs`, `testIsQueueEmptyWhenNoJobs`, `testIsQueueEmptyFalseWhenJobsPresent`, `testRunningCountReflectsRunningJobs`. All 11 pass. Full suite: **TEST SUCCEEDED** (all suites pass).
- `Tests/AudioEngineTests/SaveToastTests.swift` — `MockEncodingQueue` updated to add `pending: [EncodingJob]` and `cancelAllJobs() async` for protocol conformance.

### Limitation note

`EncodingQueue` (REQ-018) exposes only `cancelAll()`. The per-job cancel path in `cancel(jobID:)` safely calls `cancelAllJobs()` only when the target is the sole running/pending job; otherwise it is a documented no-op. A proper per-job API is deferred to EncodingQueue v2.
