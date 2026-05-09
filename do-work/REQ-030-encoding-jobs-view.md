# REQ-030: EncodingJobsView — in-progress encoding job list

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/EncodingJobsView.swift`. A small overlay accessible from the post-stop toast or from a status item ("3 encodings…") in `ContentView`'s footer. Shows: each job with its file name, progress percentage, and a Cancel button. Completed and failed jobs disappear from the list after 5 s (so the user sees the transition).

## Context

Spec Section 4.4 shows the toast as the primary surface, but in-flight jobs should be inspectable when the user wants detail. Section 5.7 specifies background encoding.

## Acceptance Criteria

- [ ] List populates from `EncodingQueue.pending + running` (REQ-018)
- [ ] Each row shows file name, progress bar with percent, status (Pending / Encoding / Done / Failed), Cancel button
- [ ] Cancel removes the job from the queue and removes any partial MP3
- [ ] Completed jobs flash green for 5 s then disappear
- [ ] Failed jobs stay in the list with an error tooltip until manually dismissed
- [ ] If queue is empty, view is hidden (no chrome)

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
2. **ui** Start two short recordings in sequence, stop both, take snapshot during encoding
   - Expected: list shows two encoding rows with progress bars

## Integration

**Reachability:** Opened from a count badge in `ContentView`'s footer or the post-stop toast (REQ-027).

**Data dependencies:** Subscribes to `AppStore.encodingQueue` (REQ-018).

**Service dependencies:** Depends on REQ-018 (EncodingQueue) and REQ-022 (AppStore).
