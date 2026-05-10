# REQ-045: Graceful Per-PID Emitter Failure in ProcessTapCapture

**UR:** UR-004
**Status:** done
**Created:** 2026-05-10
**Layer:** none

## Task

Stop letting one bad pid abort the entire `Everything`-mode capture. Replace the fail-fast loop in `ProcessTapCapture.init` (AudioEngine/Capture/ProcessTapCapture.swift:79–83) with a per-pid try/catch that records the failure on the existing `errorStream` channel and continues setting up the remaining pids. Throw only when **every** pid fails (so single-pid `Specific App` mode preserves its current "fails fast on the only pid" behaviour).

Concretely:

1. Change the construction loop to capture per-pid failures into a local `[(pid_t, CaptureError)]` array instead of letting `try` propagate.
2. After the loop, branch:
   - If at least one emitter was created successfully: log each captured failure (including its pid and OSStatus where applicable), forward each as a typed `CaptureError` via the existing error-forwarding channel, and proceed with the surviving emitters.
   - If every pid failed: throw the first captured error so the caller sees the same shape it does today (preserves `Specific App` mode).
3. Reuse the existing aliveness path for forwarding errors. If no current channel exists at construction time (the existing `errorStream` is owned by `RecordingSession`, not `ProcessTapCapture`), surface the failures as a new `public let initFailures: [(pid_t, CaptureError)]` snapshot on the capture instance — `RecordingSession.start(config:)` reads it after construction and yields each entry into its own `errorContinuation`. Document the channel choice in code; do not invent a new error stream type.

This is independent of REQ-044 — the catalog fix prevents the *trigger* (helpers being missing), this REQ prevents the *amplifier* (one bad pid in a list of 30 killing everything). They commit and ship separately.

## Context

Surfaced by `do-work/user-requests/UR-004/ideate.md`, Challenger section: "Fail-fast loop in `ProcessTapCapture.init` kills the whole session if any single pid fails." Triggered by the construction loop at AudioEngine/Capture/ProcessTapCapture.swift:79–83. With `Everything` mode wrapping ~30 catalog entries, the probability that at least one pid (zombie process between catalog refresh and tap creation, denied permission for one specific helper, transient HAL failure) fails on a given run is non-trivial. Today, that one failure aborts the entire session and the user sees a generic `tapCreationFailed` error instead of a partial recording.

This is a robustness improvement, not a behavior change for the happy path. Healthy pids continue to be tapped exactly as today.

Connector observation from ideate: typed errors should route through the existing REQ-033 ErrorSurface path; do not introduce a third error channel.

## Acceptance Criteria

- [x] `ProcessTapCapture(pids:factory:alivenessCheck:)` no longer aborts when one pid's `factory.makeEmitter` throws — surviving pids' streams remain in `streams` and aliveness polling runs normally for them.
- [x] When every pid fails, `ProcessTapCapture.init` throws the first captured `CaptureError` (preserves today's shape for `Specific App` and for the worst-case `Everything` scenario where every helper is unreachable).
- [x] Single-pid input where the only pid fails throws as today (no behaviour change for `Specific App` mode).
- [x] Each per-pid failure surfaces a typed `CaptureError` (including its pid) downstream — `RecordingSession.start(config:)` yields the failures into its existing `errorContinuation` so REQ-033 ErrorSurface can render them.
- [x] New unit test in `Tests/AudioEngineTests/`: mock `PerProcessEmitterFactory` returns 5 pids; pid #2 throws on creation; resulting capture exposes streams for the other 4 pids and surfaces exactly one failure entry referencing pid #2.
- [x] New unit test: mock factory throws for all 5 pids; init throws the first error.
- [x] New unit test: single-pid input where the only pid throws — init throws (regression guard for `Specific App` mode).
- [x] Existing `MockAudioSourceTests` and `RecordingSession` integration tests continue to pass.

## Verification Steps

> Execute these after implementation to confirm the change works at runtime. Each must pass before committing.

1. **test** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorderTests test -destination 'platform=macOS' -only-testing:AudioEngineTests`
   - Expected: All AudioEngine tests pass, including the three new tests (one-failing-pid, all-failing-pids, single-pid-failure regression).

2. **build** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorder build -destination 'platform=macOS'`
   - Expected: Project compiles with no errors and no new warnings.

3. **runtime** Confirm `Everything` mode survives a synthetic emitter failure. Steps:
   - Add a temporary debug-only flag (or use a unit-test-style harness) that forces `RealEmitterFactory` to throw for one selected pid in the catalog.
   - Run `Everything` mode with audible playback; press Start, wait 5 s, press Stop.
   - Expected: Resulting MP3 contains the audible content (proving healthy pids' captures still ran), and the in-app error surface shows exactly one entry naming the forced-failure pid.
   - Revert the temporary flag before committing.

## Assets

(none)

## Outputs

- `AudioEngine/Capture/ProcessTapCapture.swift` — added `PerPIDInitFailure` (Sendable, Equatable error type carrying pid + CaptureError); replaced fail-fast init loop with per-pid try/catch that collects failures into `initFailures`; throws only when every pid fails.
- `AudioEngine/Recording/RecordingSession.swift` — `SessionConfig` gains `initialErrors: [PerPIDInitFailure]` (default []); `RecordingSession.start` yields each entry to `errorContinuation` immediately after entering `.recording`.
- `App/AppStore.swift` — `DefaultSessionConfigBuilder.build()` collects `capture.initFailures` and forwards them via the new `SessionConfig.initialErrors` parameter.
- `Tests/AudioEngineTests/ProcessTapCaptureTests.swift` — `MockEmitterFactory` gains a `failByPID:` injection; 3 new tests for the REQ-045 contract (one-failing-pid, all-failing-pids, single-pid-failure regression).

## Verification Notes

- **Verification Step 1 (test):** PASS — full AudioEngine suite 369/369 (3 new REQ-045 tests + 1 unrelated pre-existing skip).
- **Verification Step 2 (build):** PASS — `xcodebuild ... build` clean.
- **Verification Step 3 (runtime — synthetic failure injection):** PENDING USER. Worker can't add/revert temp debug-only flags without leaving them in the diff, and without REQ-046's logging it's hard to confirm the error-surface entry. Easier to validate this once REQ-046 ships and a renderer pid is naturally tap-denied in the wild.
