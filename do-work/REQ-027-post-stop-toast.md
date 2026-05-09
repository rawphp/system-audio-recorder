# REQ-027: Post-stop toast with Saved / Encoding / Failed states

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/Views/SaveToast.swift`. After `stopRecording()` succeeds, show a non-modal toast at the bottom of the window with the saved file path and a "Reveal in Finder" button. While encoding is still in progress, the toast text is "Encoding…" and updates in place when complete. On encoding failure, toast switches to "Encoding failed — WAV preserved at <path>" with Reveal.

## Context

Spec Section 4.4 specifies the toast UX. Section 6.3 maps encoding errors to the toast surface.

## Acceptance Criteria

- [ ] Toast appears within 100 ms of `stopRecording()` returning
- [ ] Toast shows `Saved → <path>` when encoding completes; clicking Reveal opens Finder at that file
- [ ] Toast shows `Encoding…` with an indeterminate progress indicator while encoding is in flight
- [ ] Toast updates in place (does not stack) when encoding finishes — the same toast morphs to the saved state
- [ ] Toast auto-dismisses after 5 s; click anywhere on the toast keeps it open
- [ ] On failure, toast shows the WAV path and stays until dismissed manually

## Verification Steps

1. **build** `xcodebuild build`
   - Expected: BUILD SUCCEEDED
2. **ui** Start a 2 s recording, stop, observe toast lifecycle; take snapshots at "Encoding…" and "Saved" states
   - Expected: toast appears at bottom; transitions from Encoding to Saved; Reveal opens Finder

## Integration

**Reachability:** Renders inside `ContentView` (REQ-023) at the bottom of the window. Driven by `AppStore.encodingQueue` state.

**Data dependencies:** Subscribes to `EncodingQueue.completed` / `failed` events (REQ-018).

**Service dependencies:** Depends on REQ-018 (EncodingQueue), REQ-022 (AppStore).
