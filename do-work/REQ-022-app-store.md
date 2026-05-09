# REQ-022: AppStore — top-level @Observable state container

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** ui

## Task

Implement `App/AppStore.swift`, an `@Observable` class that's the single source of truth for the UI. Owns:
- `currentSession: RecordingSession?` (nil when idle)
- `sourceCatalog: AudioSourceCatalog`
- `permissionManager: PermissionManager`
- `encodingQueue: EncodingQueue`
- `settings: AppSettings`
- `meters: MeterPublisher` (per-source + mix)
- Action methods: `toggleRecording()`, `startRecording(preset:)`, `pauseRecording()`, `resumeRecording()`, `stopRecording()`
- Convenience computed `selectedPreset: SourcePreset` derived from settings

## Context

Spec Section 3 lists `AppStore` as the binding target for both views and the menu bar. Spec Section 5 (menu bar interaction) requires `AppStore` to synchronously reflect state changes so window UI and status item icon stay in lockstep.

## Acceptance Criteria

- [ ] `AppStore` is a singleton accessed via `@Environment(\.appStore)` (or equivalent)
- [ ] `toggleRecording()` is idempotent: starts if idle, stops if recording, no-op if paused
- [ ] State changes propagate to all subscribers within the same run-loop tick
- [ ] Action methods are safe to call from main actor
- [ ] When `currentSession` transitions, dependent UI (RecordControls, MenuBarController) updates without re-entrancy issues

## Verification Steps

1. **test** Unit test calls `toggleRecording()` four times; asserts state sequence is idle → recording → idle → recording → idle
   - Expected: test passes
2. **test** Unit test subscribes to AppStore changes via `withObservationTracking`; asserts the closure fires when `currentSession` mutates
   - Expected: test passes

## Integration

**Reachability:** Injected into the SwiftUI `App` via `@Environment`; consumed by every view and the `MenuBarController`.

**Data dependencies:** Composes `AppSettings` (REQ-021), session state, source catalog, encoding queue, meters.

**Service dependencies:** Wires together REQ-006, REQ-013, REQ-018, REQ-019, REQ-021.
