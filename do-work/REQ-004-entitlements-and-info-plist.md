# REQ-004: Configure entitlements and Info.plist for audio capture

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** supporting

## Task

Author `Resources/SystemAudioToMP3.entitlements` enabling: `com.apple.security.device.audio-input` (microphone), `com.apple.security.app-sandbox` set to `false` (notarized direct download, no sandbox per spec Section 2). Add Info.plist usage descriptions: `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription`.

## Context

Spec Section 5.8 calls out the audio-tap entitlement prompt wording. Spec Section 4.7 says permissions are requested lazily on first record attempt. Section 2 commits to non-sandboxed notarized distribution.

## Acceptance Criteria

- [ ] `Resources/SystemAudioToMP3.entitlements` exists, no sandbox, audio-input entitlement enabled
- [ ] `Info.plist` contains `NSMicrophoneUsageDescription` with human-readable text ("System Audio Recorder needs your microphone to mix it into recordings.")
- [ ] `Info.plist` contains `NSAudioCaptureUsageDescription` with human-readable text ("System Audio Recorder records audio from other apps you choose.")
- [ ] App target's "Code Sign Entitlements" build setting points to the entitlements file
- [ ] `LSMinimumSystemVersion` in Info.plist is `14.4`

## Verification Steps

1. **build** `xcodebuild build` and inspect codesign output: `codesign -d --entitlements - <path-to-built-app>`
   - Expected: shows `com.apple.security.device.audio-input = true`, no `app-sandbox` true
2. **runtime** Launch the built app and call `AVCaptureDevice.requestAccess(for: .audio)` from a debug button
   - Expected: macOS shows the standard mic permission prompt with the configured description; user can approve

## Integration

**Reachability:** Entitlements are loaded by macOS on app launch; the prompts surface via `PermissionManager` (REQ-019).

**Data dependencies:** None.

**Service dependencies:** Required for `MicrophoneCapture` (REQ-008) and `ProcessTapCapture` (REQ-007) to function at runtime.
