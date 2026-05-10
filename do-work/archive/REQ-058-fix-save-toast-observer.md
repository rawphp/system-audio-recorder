# REQ-058: Fix SaveToast Observer Wiring So Toast Appears After Stop

**UR:** UR-008
**Status:** done
**Created:** 2026-05-10
**Layer:** none

## Task

Fix `observeQueue()` in `App/Views/SaveToast.swift` (lines 322–338) so the SaveToast actually responds to encoding-queue changes. Two independent bugs in the existing code:

1. **Wrong property tracked.** `withObservationTracking` accesses `vm.toastState` — that is the toast's own output, not its input. The encoding queue is what changes when a recording is stopped (a job appears in `running`, then moves to `completed` or `failed`). The tracker must observe `vm.queue.running`, `vm.queue.completed`, and `vm.queue.failed` so changes to those arrays wake the loop.
2. **Missing action on change.** When the tracker fires, the current code just resumes the continuation and yields. It must call `vm.handleQueueChange()` (already implemented at `SaveToast.swift:119`) so the view model transitions through `.encoding → .saved` (or `.failed`).

`vm.queue` is currently `private` (`SaveToast.swift:79: private let queue: any EncodingQueueObservable`). Either expose it via an internal accessor on `SaveToastViewModel` or move the observation loop inside the view model itself. Prefer moving the loop into `SaveToastViewModel` — it owns the queue reference and the `handleQueueChange()` method, so the observer logic belongs there too. The SwiftUI view's `.task` modifier then just calls `await viewModel.observeQueue()`.

Pseudocode for the corrected loop (place it on `SaveToastViewModel`):

```swift
public func observeQueue() async {
    while !Task.isCancelled {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = queue.running
                _ = queue.completed
                _ = queue.failed
            } onChange: {
                continuation.resume()
            }
        }
        // Run the queue change handler on every observed mutation.
        handleQueueChange()
    }
}
```

Then in the view (`SaveToast.swift:297-300`):

```swift
.task {
    await viewModel.observeQueue()
}
```

Also do an initial `handleQueueChange()` once at startup of the loop, because if a job was already running/completed before the observer attached, we need to reflect that state.

## Context

The bug is in production code that has been silently broken — the toast was wired in REQ-027 with this same observer pattern, but the wiring never actually fired. Manual confirmation from the user (UR-008): pressing Stop produces no toast.

The issue is exactly what the comment at `SaveToast.swift:117-118` describes the *correct* behavior to be:

> Production usage: wire via `withObservationTracking` inside the SwiftUI `.task` modifier on `SaveToast`. Tests call this directly after mutating the mock.

The "wire via withObservationTracking" intent was correct but the implementation reads the toast's own output state instead of the queue's input state. The bug is in two lines (the tracked property and the missing `handleQueueChange()` call), and is contained to `App/Views/SaveToast.swift` — no API changes outward, no other view affected.

## Acceptance Criteria

- [ ] `observeQueue()` (or its replacement) tracks all three encoding-queue arrays: `queue.running`, `queue.completed`, `queue.failed`. Verified by reading the source.
- [ ] On each observation cycle, `handleQueueChange()` is called on the view model. Verified by reading the source.
- [ ] An initial `handleQueueChange()` runs at the start of the observation loop (handles the case where a job is already in flight before the observer attaches).
- [ ] `queue` property is reachable from the observation loop without violating encapsulation — either via an internal accessor or by moving the observation loop into `SaveToastViewModel` (the latter is preferred).
- [ ] `make build` succeeds with no new warnings.
- [ ] `make test` passes for SaveToast tests specifically. The pre-existing flaky `testSilenceDetectorResetsOnPause` failure is **not** caused by this REQ and is acceptable (note the suite's pass/fail counts before and after to confirm the toast-related counts don't regress).
- [ ] Manual UI verification: launch the app, record briefly, press Stop. The post-stop toast appears at the bottom of the window with "Encoding…" then transitions to "Saved" with a "Reveal in Finder" button. Auto-dismisses after 5 s.

## Verification Steps

1. **build** `make build`
   - Expected: build succeeds with no new warnings.
2. **test** `make test 2>&1 | grep -E "Executed [0-9]+ tests"`
   - Expected: SaveToast-related tests still pass (the SaveToastViewModel test count must not decrease vs the baseline).
3. **runtime** `grep -nE 'queue\.(running|completed|failed)' App/Views/SaveToast.swift | wc -l`
   - Expected: at least 3 matches inside the observation loop body (one per array).
4. **runtime** `grep -nE 'handleQueueChange\(\)' App/Views/SaveToast.swift | wc -l`
   - Expected: at least 2 matches (the original method definition + at least one call site inside the observer loop).
5. **ui** Launch the app (`make build && open ~/Library/Developer/Xcode/DerivedData/SystemAudioRecorder-*/Build/Products/Debug/System*Audio*Recorder.app`). Pick a source, click Start, click Stop after ~3 seconds.
   - Expected: a toast appears at the bottom of the window showing encoding progress, then "Saved" with a "Reveal in Finder" button. Auto-dismisses after ~5 s.

## Outputs

- `App/Views/SaveToast.swift` — moved `observeQueue()` from `SaveToast` view into `SaveToastViewModel`. New implementation tracks `queue.running`, `queue.completed`, `queue.failed` (not `vm.toastState`). Calls `handleQueueChange()` both at loop start (initial state) and after each observation change. View's `.task` modifier now calls `await viewModel.observeQueue()`.
- `Tests/AudioEngineTests/SaveToastTests.swift` — added `testObserveQueueTransitionsToEncodingWhenJobStarts` which verifies the observer transitions `toastState` to `.encoding` when a job is added to `queue.running` via `withObservationTracking`.

### Acceptance criteria verification

- [x] `observeQueue()` tracks all three encoding-queue arrays: `queue.running`, `queue.completed`, `queue.failed`. Verified: `grep -nE 'queue\.(running|completed|failed)' App/Views/SaveToast.swift | wc -l` → 6.
- [x] On each observation cycle, `handleQueueChange()` is called on the view model. Verified: `grep -nE 'handleQueueChange\(\)' App/Views/SaveToast.swift | wc -l` → 8 (definition + 2 call sites in the new loop).
- [x] An initial `handleQueueChange()` runs at the start of the observation loop. Verified by reading source (`handleQueueChange()` called before the `while` loop).
- [x] `queue` property is reachable from the observation loop without violating encapsulation — observation loop moved inside `SaveToastViewModel` which already holds `private let queue`.
- [x] `make build` succeeds with no new warnings (only pre-existing BitrateMode/Sendable warning).
- [x] `make test` SaveToast suite: 10 tests, 0 failures. Total: 396 tests (+1 new), 1 pre-existing flaky RecordingSession failure unrelated to this REQ.
- [ ] Manual UI verification: deferred — worker cannot drive the GUI. User must launch the app, record briefly, press Stop, and confirm the encoding/saved toast appears.
