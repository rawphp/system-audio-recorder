# REQ-019: PermissionManager — mic and audio-tap permission checks

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** supporting

## Task

Implement `Permissions/PermissionManager.swift`. Provides:
- `microphoneStatus: AVAuthorizationStatus { get }`
- `requestMicrophone() async -> Bool`
- `audioTapStatus: AudioTapStatus { get }` — checks whether `AudioHardwareCreateProcessTap` will succeed given current entitlements
- `requestAudioTap() async -> Bool` — triggers macOS prompt if needed
- A `@Observable` summary the UI can bind to

Permissions are requested **lazily**, only on first record attempt that needs them (per spec Section 4.7).

## Context

Spec Section 4.7 mandates lazy prompting: mic prompt only when chosen source involves the mic; audio-tap check only when system audio is involved. Section 6.5 specifies failure paths (mic denied → mic options disabled; audio-tap denied → only "Microphone only" enabled).

## Acceptance Criteria

- [ ] `microphoneStatus` returns one of `.notDetermined / .authorized / .denied / .restricted`
- [ ] `requestMicrophone()` triggers the macOS prompt on first call; subsequent calls return cached status without re-prompting
- [ ] `audioTapStatus` returns the runtime check result without firing a permission prompt
- [ ] `requestAudioTap()` returns `true` on systems where the entitlement is granted
- [ ] If the user revokes permission via System Settings while the app is running, status updates within 1 s of next query
- [ ] Status changes publish to subscribers via `@Observable`

## Verification Steps

1. **test** Unit test stubs `AVCaptureDevice.requestAccess` to return false; asserts `requestMicrophone()` returns false and `microphoneStatus == .denied`
   - Expected: test passes
2. **runtime** Manual: launch app on a fresh user account, click record (Everything + Mic preset); assert standard mic prompt appears with the configured description from REQ-004
   - Expected: prompt shows; granting unlocks recording

## Integration

**Reachability:** Consumed by `RecordingSession` (REQ-013) before starting a session, and by `SourcePickerView` (REQ-024) to grey out unavailable presets.

**Data dependencies:** Reads macOS permission state via `AVCaptureDevice.authorizationStatus` and Core Audio HAL.

**Service dependencies:** Required by REQ-007, REQ-008, REQ-013, REQ-024, REQ-034.
