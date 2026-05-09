# REQ-013: RecordingSession orchestrator — start/pause/resume/stop lifecycle

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Recording/RecordingSession.swift`. The session is the single object the UI talks to to make a recording. It owns:
- `ProcessTapCapture` (REQ-007), `MicrophoneCapture` (REQ-008) instances per the chosen source preset
- `MixerGraph` (REQ-010), wired to format normalizers (REQ-009)
- `WAVWriter` (REQ-012)
- A state machine: `idle → recording → paused → recording → … → stopped`

Public API: `start(config: SessionConfig)`, `pause()`, `resume()`, `stop() async -> [URL]` (returns WAV file URLs ready for encoding).

## Context

Spec Section 5.5 specifies pause/resume semantics: `engine.pause()` freezes WAV cursors; resume continues; output is one continuous file. Section 5.7 specifies `stop()` synchronously stops the engine, closes WAV files, and returns URLs for the encoding handoff.

## Acceptance Criteria

- [ ] State transitions are valid only from documented predecessors (no resume from idle, no pause from stopped)
- [ ] `start(config:)` succeeds for these source combinations and produces a non-empty buffer stream within 1 s: (a) one app, (b) multiple apps, (c) mic only, (d) multiple apps + mic
- [ ] `pause()` halts buffer writes within one buffer (~10 ms); meters stop updating
- [ ] `resume()` restarts buffer writes; the resulting WAV has no silent gap
- [ ] `stop()` returns a list of file URLs; the engine and all captures are torn down before return
- [ ] All lifecycle methods are safe to call from the main thread

## Verification Steps

1. **test** Integration test using `MockAudioSource` runs start → pause → resume → stop; asserts state transitions are valid and final WAV duration matches active recording time
   - Expected: test passes
2. **test** Integration test starts a session with no sources configured; asserts `.start()` throws `SessionError.noSourcesConfigured`
   - Expected: test passes

## Integration

**Reachability:** Owned by `AppStore` (REQ-022); driven by `RecordControlsView` (REQ-025).

**Data dependencies:** Reads `SessionConfig` (source preset, mic device, output mode) from `AppStore` settings.

**Service dependencies:** Composes REQ-007, REQ-008, REQ-009, REQ-010, REQ-012. Hands WAV URLs to `EncodingQueue` (REQ-018) on stop.
