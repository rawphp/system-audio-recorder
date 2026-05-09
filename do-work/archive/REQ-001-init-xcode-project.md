# REQ-001: Initialize Xcode project for SwiftUI macOS app

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** supporting

## Task

Create the `SystemAudioRecorder.xcodeproj` Xcode project: SwiftUI macOS app target, deployment target macOS 14.4, Swift 5.10, universal (arm64 + x86_64). Bundle id `com.tomkaczocha.SystemAudioRecorder`. Establish the folder structure documented in Section 9 of the design spec.

## Context

This is the foundation REQ — every later REQ adds files inside this project. The spec (Section 9) defines the directory layout under groups `App/`, `AudioEngine/`, `Permissions/`, `Hotkey/`, `Resources/`, `Vendor/`, `Tests/`. Bundle id is the suite key used by `UserDefaults` (Section 6.2) so it must match.

## Acceptance Criteria

- [x] `SystemAudioRecorder.xcodeproj` exists at the repo root
- [x] App target builds an empty SwiftUI window (default `App` + `ContentView` showing "System Audio Recorder")
- [x] Deployment target is `macOS 14.4`; build settings include both `arm64` and `x86_64` architectures
- [x] Bundle identifier is `com.tomkaczocha.SystemAudioRecorder`
- [x] Project shows the group structure from Section 9 (empty groups for modules not yet created are fine)

## Verification Steps

1. **build** `xcodebuild -project SystemAudioRecorder.xcodeproj -scheme SystemAudioRecorder -configuration Debug build`
   - Expected: BUILD SUCCEEDED, no warnings
2. **runtime** Open the built `.app` from `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/`
   - Expected: an empty window titled "System Audio Recorder" opens; closing it quits the app

## Integration

**Reachability:** App entry point is `App/SystemAudioRecorderApp.swift` — the `@main` SwiftUI `App` struct. Cited in design spec Section 9.

**Data dependencies:** None at this stage. Future REQs add `AppStore` and persisted settings keyed under bundle id `com.tomkaczocha.SystemAudioRecorder` (spec Section 6.2).

**Service dependencies:** None — this REQ creates the project shell that all other modules will live inside.

## Outputs

- `project.yml` — XcodeGen spec (macOS 14.4, Swift 5.10, arm64+x86_64, bundle id com.tomkaczocha.SystemAudioRecorder)
- `SystemAudioRecorder.xcodeproj/` — generated Xcode project + scheme
- `App/SystemAudioRecorderApp.swift` — `@main` SwiftUI App, `WindowGroup("System Audio Recorder")`
- `App/Views/ContentView.swift` — minimal ContentView showing "System Audio Recorder"
- `AudioEngine/.gitkeep`, `Permissions/.gitkeep`, `Hotkey/.gitkeep`, `Resources/.gitkeep`, `Vendor/.gitkeep`, `Tests/.gitkeep` — empty group placeholders per spec Section 9

Verification: `xcodebuild ... build` → BUILD SUCCEEDED (no warnings). Built `.app` Info.plist confirms `CFBundleIdentifier=com.tomkaczocha.SystemAudioRecorder`, `LSMinimumSystemVersion=14.4`. `lipo -info` reports `x86_64 arm64`.
