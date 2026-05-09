# REQ-007: ProcessTapCapture wires Core Audio Tap → PCM stream per process

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Capture/ProcessTapCapture.swift`. Given an array of `pid_t` values, build a `CATapDescription` (mode `.unmuted`), call `AudioHardwareCreateProcessTap`, create a private aggregate device aggregating that tap, and attach an AUHAL audio unit whose render callback delivers PCM buffers. Expose one `AsyncStream<AVAudioPCMBuffer>` per tapped process via a lockless ring buffer for the audio thread → Swift consumer handoff.

## Context

Spec Section 5.1 specifies the full pipeline: `CATapDescription` → `AudioHardwareCreateProcessTap` → private aggregate device → AUHAL → ring buffer → `AVAudioSourceNode`. Buffers are typically 48 kHz Float32 stereo. Section 5.8 risk #1 (process dies mid-recording) requires aliveness polling.

## Acceptance Criteria

- [ ] `ProcessTapCapture(pids: [pid_t])` initializer succeeds when given valid pids
- [ ] Per-process `AsyncStream<AVAudioPCMBuffer>` produces buffers when the tapped process emits audio
- [ ] `stop()` tears down the AUHAL, the aggregate device, and the tap object cleanly (no Core Audio leaks)
- [ ] If a tapped process dies mid-stream, the stream emits a final `.processTerminated` signal and stays open for siblings (1 Hz aliveness poll)
- [ ] No audio is muted on the host system (`.unmuted` mode confirmed by listening test in manual checklist)
- [ ] Buffers carry their original sample rate / channel count (no resampling here — that's REQ-009)

## Verification Steps

1. **test** Integration test using a `MockProcess` that the catalog exposes, plus a synthetic 1 kHz sine source piped into the tap path; assert at least 100 PCM buffers arrive within 5 seconds
   - Expected: test passes; buffer format is non-interleaved Float32, sample rate >= 44100
2. **runtime** Manual: tap Spotify (or Music.app), play a known track, save 10 seconds of buffers to a file, listen back
   - Expected: audible content matches what was playing; spec confirms `.unmuted` (Spotify still plays through speakers)

## Integration

**Reachability:** Consumed by `MixerGraph` (REQ-010) via `AVAudioSourceNode` source nodes. Used during `RecordingSession.start()` (REQ-013).

**Data dependencies:** Reads from Core Audio HAL (process taps, aggregate devices). No persistent storage.

**Service dependencies:** Depends on REQ-006 (AudioSourceCatalog) for pid resolution and REQ-019 (PermissionManager) for the audio-tap entitlement check.
