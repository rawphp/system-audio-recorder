# REQ-002: Add Swift Package Manager manifest with KeyboardShortcuts dependency

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** supporting

## Task

Add a `Package.swift` at the repo root and link the `KeyboardShortcuts` SPM dependency (Sindre Sorhus, https://github.com/sindresorhus/KeyboardShortcuts) into the app target. This is the only third-party SPM dependency for v1 per spec Section 3.

## Context

Spec Section 3 lists `KeyboardShortcuts` as the standard wrapper for global hotkeys on macOS — used by REQ-020 (HotkeyManager). LAME is bundled separately as an xcframework (REQ-003), not via SPM.

## Acceptance Criteria

- [ ] `Package.swift` exists at the repo root and declares the macOS 14.4 platform
- [ ] `KeyboardShortcuts` is listed as an SPM dependency at the latest stable version (pin to a major.minor; allow patch updates)
- [ ] The Xcode project links `KeyboardShortcuts` to the app target
- [ ] `import KeyboardShortcuts` compiles in any source file in the app target

## Verification Steps

1. **build** `xcodebuild -project SystemAudioToMP3.xcodeproj -scheme SystemAudioToMP3 build`
   - Expected: BUILD SUCCEEDED, KeyboardShortcuts resolved and built
2. **test** Add a temporary file with `import KeyboardShortcuts` and rebuild
   - Expected: import resolves; remove the temp file before commit

## Integration

**Reachability:** SPM dependency is consumed by future `Hotkey/HotkeyManager.swift` (spec Section 9). Not user-facing yet.

**Data dependencies:** None. The package itself manages a `UserDefaults` key for the persisted shortcut binding; that's part of REQ-020.

**Service dependencies:** None at this stage — the dependency is declared but not wired in until REQ-020.
