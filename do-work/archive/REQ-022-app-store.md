# REQ-022: AppStore — top-level @Observable state container

**UR:** UR-001
**Status:** done
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

- [x] `AppStore` is a singleton accessed via `@Environment(\.appStore)` (or equivalent) (`AppStoreEnvironmentKey` defines `\.appStore` in `App/AppStore.swift`; `SystemAudioToMP3App` injects a `@State` instance via `.environment(\.appStore, appStore)`; verified by `testAppStoreEnvironmentKeyHasDefault`)
- [x] `toggleRecording()` is idempotent: starts if idle, stops if recording, no-op if paused (verified by `testToggleRecordingFromIdleStartsRecording`, `testToggleRecordingFromRecordingStops`, `testToggleRecordingFromPausedIsNoOp`, and the four-call sequence in `testToggleRecordingFourTimesProducesExpectedSequence`)
- [x] State changes propagate to all subscribers within the same run-loop tick (`sessionState` and `currentSession` are flipped synchronously on the `@MainActor` *before* `await session.start(config:)`; verified by `testSessionStateMutationFiresObservation` and `testCurrentSessionMutationFiresObservation` using `withObservationTracking`)
- [x] Action methods are safe to call from main actor (`AppStore` is `@MainActor`; all action methods are `async` and serialised on the main actor — verified by all 12 AppStoreTests which run under `@MainActor`)
- [x] When `currentSession` transitions, dependent UI (RecordControls, MenuBarController) updates without re-entrancy issues (state mutations happen in `@MainActor`-isolated methods, then `await` is performed; the underlying `RecordingSession` is an `actor` so its lifecycle calls cannot re-enter `AppStore`. Verified indirectly by `testPauseResumeLifecycle` and `testToggleRecordingFromPausedIsNoOp`)

## Verification Steps

1. **test** Unit test calls `toggleRecording()` four times; asserts state sequence is idle → recording → idle → recording → idle
   - Expected: test passes
   - Result: `testToggleRecordingFourTimesProducesExpectedSequence` passes — sequence verified via the `waitForState` helper after each toggle. **PASS**
2. **test** Unit test subscribes to AppStore changes via `withObservationTracking`; asserts the closure fires when `currentSession` mutates
   - Expected: test passes
   - Result: `testCurrentSessionMutationFiresObservation` passes; companion `testSessionStateMutationFiresObservation` also passes for the parallel state field. **PASS**

## Integration

**Reachability:** Injected into the SwiftUI `App` via `@Environment`; consumed by every view and the `MenuBarController`.

**Data dependencies:** Composes `AppSettings` (REQ-021), session state, source catalog, encoding queue, meters.

**Service dependencies:** Wires together REQ-006, REQ-013, REQ-018, REQ-019, REQ-021.

## Outputs

- `App/AppStore.swift` — `SourcePreset` enum (`everything`, `specificApp(processID:pid_t)`, `micOnly`) with `settingsKey` round-trip; `SessionConfigBuilder` `@MainActor` protocol (test seam) and `DefaultSessionConfigBuilder` production impl (mic-only and `specificApp` paths wired; `everything` rejected with `BuilderError.unsupportedPreset` pending later UI/wiring REQ); `AppStore` `@Observable @MainActor final class` composing `AppSettings`, `AudioSourceCatalog`, `PermissionManager`, `EncodingQueue`, `MeterPublisher`, `SessionConfigBuilder` via constructor injection (production `convenience init()` wires defaults). Public state: `currentSession: RecordingSession?`, `sessionState: SessionState` (mirrors session for synchronous UI updates), `lastError: Error?`, `selectedPreset` computed from `settings.lastSourcePreset`. Action methods: `toggleRecording()`, `startRecording(preset:)`, `pauseRecording()`, `resumeRecording()`, `stopRecording()` — all `async`, main-actor isolated. `stopRecording()` enqueues an `EncodingJob` per WAV URL using `settings.bitrate`/`bitrateMode`/`keepWAVAfterEncode`. `EnvironmentValues.appStore: AppStore?` extension via `AppStoreEnvironmentKey` (default `nil`).
- `App/SystemAudioToMP3App.swift` — Updated to hold a `@State private var appStore = AppStore()` and inject it into the SwiftUI environment via `.environment(\.appStore, appStore)`.
- `Tests/AudioEngineTests/AppStoreTests.swift` — 12 unit tests using injected stubs (`StubSessionConfigBuilder`, `FakeStoreEmitter`, `EmptyAppStoreProcessListProvider`, `StubMicAuthForAppStore`, `PassthroughBookmarkProvider`) — no real audio capture: `testInitialStateIsIdle`, `testSelectedPresetDerivesFromSettings`, `testToggleRecordingFromIdleStartsRecording`, `testToggleRecordingFromRecordingStops`, `testToggleRecordingFromPausedIsNoOp`, `testToggleRecordingFourTimesProducesExpectedSequence`, `testPauseResumeLifecycle`, `testCurrentSessionMutationFiresObservation`, `testSessionStateMutationFiresObservation`, `testStartRecordingPersistsPresetInSettings`, `testStartRecordingPassesPresetToBuilder`, `testAppStoreEnvironmentKeyHasDefault`. All 12 pass. Full suite: 158 tests passing (1 pre-existing flaky `testSilenceDetectorResetsOnAudio` from REQ-015 timing — passes on retry).
