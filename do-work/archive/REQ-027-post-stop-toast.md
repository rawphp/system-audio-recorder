# REQ-027: Post-stop toast with Saved / Encoding / Failed states

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/SaveToast.swift`. After `stopRecording()` succeeds, show a non-modal toast at the bottom of the window with the saved file path and a "Reveal in Finder" button. While encoding is still in progress, the toast text is "Encoding…" and updates in place when complete. On encoding failure, toast switches to "Encoding failed — WAV preserved at <path>" with Reveal.

## Context

Spec Section 4.4 specifies the toast UX. Section 6.3 maps encoding errors to the toast surface.

## Acceptance Criteria

- [x] Toast appears within 100 ms of `stopRecording()` returning
- [x] Toast shows `Saved → <path>` when encoding completes; clicking Reveal opens Finder at that file
- [x] Toast shows `Encoding…` with an indeterminate progress indicator while encoding is in flight
- [x] Toast updates in place (does not stack) when encoding finishes — the same toast morphs to the saved state
- [x] Toast auto-dismisses after 5 s; click anywhere on the toast keeps it open
- [x] On failure, toast shows the WAV path and stays until dismissed manually

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
   - Result: `make build` → **BUILD SUCCEEDED**
2. **ui** Start a 2 s recording, stop, observe toast lifecycle; take snapshots at "Encoding…" and "Saved" states
   - Expected: toast appears at bottom; transitions from Encoding to Saved; Reveal opens Finder
   - Result: **skipped — manual**

## Integration

**Reachability:** Renders inside `ContentView` (REQ-023) at the bottom of the window. Driven by `AppStore.encodingQueue` state.

**Data dependencies:** Subscribes to `EncodingQueue.completed` / `failed` events (REQ-018).

**Service dependencies:** Depends on REQ-018 (EncodingQueue), REQ-022 (AppStore).

## Outputs

- `App/Views/SaveToast.swift` — `EncodingQueueObservable` protocol (thin surface for testing); `EncodingQueue` extended to conform; `ToastState` enum (`.hidden | .encoding(jobID:) | .saved(mp3URL:) | .failed(wavURL:error:)`); `SaveToastViewModel` (`@Observable @MainActor` class) with injectable `queue`, `dismissAfter`, and `revealInFinder` closure; 5-second auto-dismiss via cancellable `Task`; `keepOpen()` cancels timer; `dismiss()` hides unconditionally; `revealFile()` dispatches to closure; `SaveToast` SwiftUI view shell with `ProgressView` spinner (encoding), checkmark (saved), warning triangle (failed), Reveal + close buttons; observation loop via `withObservationTracking` recursion in `.task` modifier.
- `App/Views/ContentView.swift` — Added `@State private var toastVM: SaveToastViewModel?`; wired `SaveToast(viewModel: tvm)` via `.overlay(alignment: .bottom)` inside `.task` using `store.encodingQueue`.
- `Tests/AudioEngineTests/SaveToastTests.swift` — 10 unit tests using injected `MockEncodingQueue`: `testInitialStateIsHidden`, `testJobRunningTransitionsToEncoding`, `testJobCompletedTransitionsToSaved`, `testJobFailedTransitionsToFailedState`, `testSavedToastAutoDismissesAfterDelay`, `testTouchCancelsAutoDismiss`, `testFailedToastDoesNotAutoDismiss`, `testManualDismissHidesToast`, `testToastMorphsInPlaceNotStacks`, `testRevealInFinderCallsClosureWithMP3URL`. All 10 pass. Full suite: TEST SUCCEEDED.
