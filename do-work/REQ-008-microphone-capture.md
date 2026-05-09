# REQ-008: MicrophoneCapture wraps AVAudioEngine input → PCM stream

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Capture/MicrophoneCapture.swift`: select a mic device by `AVCaptureDevice.uniqueID` (or system default), open `AVAudioEngine.inputNode` for that device, expose an `AsyncStream<AVAudioPCMBuffer>`. Provide a `setDevice(_:)` API that re-opens the engine with the chosen device.

## Context

Spec Section 5.2: mic capture via `AVAudioEngine.inputNode`. Section 4.7: mic permission requested lazily on first record attempt that involves the mic. Section 6.2 persists `micDeviceID` in UserDefaults.

## Acceptance Criteria

- [ ] `MicrophoneCapture()` initializes with the system default input device
- [ ] `setDevice(deviceID:)` switches input to the named device; failing devices throw `CaptureError.deviceUnavailable`
- [ ] `AsyncStream<AVAudioPCMBuffer>` produces buffers at the device's native format
- [ ] `stop()` tears down the engine cleanly, no leaks
- [ ] If the user revokes mic permission while running, the stream emits `CaptureError.permissionRevoked` and closes

## Verification Steps

1. **test** Unit test using a mocked `AVAudioInputNode` shim; assert the stream produces buffers when the mock pushes audio
   - Expected: test passes
2. **runtime** Manual: select built-in mic, speak; assert input meter (REQ-011) shows level > -40 dBFS while speaking
   - Expected: visible meter movement during speech

## Integration

**Reachability:** Consumed by `MixerGraph` (REQ-010) when the user picks a mic-involving source preset.

**Data dependencies:** Reads `micDeviceID` from `UserDefaults` (REQ-021) on init.

**Service dependencies:** Depends on REQ-019 (PermissionManager) for the mic permission gate.
