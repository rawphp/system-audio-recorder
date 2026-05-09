# REQ-006: AudioSourceCatalog enumerates running audio-emitting processes

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Implement `AudioEngine/Capture/AudioSourceCatalog.swift`: an `@Observable` class that enumerates running processes capable of emitting audio by querying `kAudioHardwarePropertyProcessObjectList`. For each process expose: pid (`pid_t`), bundle identifier, display name, app icon (`NSImage`). Provide a `refresh()` method (cheap; idempotent) that the source dropdown calls on open.

## Context

Spec Section 5.1 step 1 specifies polling `kAudioHardwarePropertyProcessObjectList`. Section 4.2 source dropdown's "Specific app…" option consumes this catalog.

## Acceptance Criteria

- [x] `AudioSourceCatalog` exposes a published array of `AudioProcess` records (pid, bundleID, displayName, icon)
- [x] `refresh()` updates the array; calling twice in a row produces a stable result
- [x] Processes that are not actually emitting audio are filtered out (catalog only shows audio-capable processes per HAL query)
- [x] System processes (coreaudiod, etc.) are filtered from the user-facing list
- [x] Catalog handles processes that quit between query and read without crashing

## Verification Steps

1. **test** Unit test creates an `AudioSourceCatalog`, calls `refresh()` while a known audio app (e.g. `afplay /System/Library/Sounds/Glass.aiff &`) is playing, asserts that `afplay` (or its parent process) appears in the list
   - Expected: test passes, catalog includes the playing process
2. **test** Unit test calls `refresh()` 100 times in quick succession and asserts no crashes / no leaks
   - Expected: completes within 1 second

## Integration

**Reachability:** Consumed by `SourcePickerView` (REQ-024) and `MixerPanelView` (REQ-028). Stored on `AppStore` (REQ-022).

**Data dependencies:** Reads Core Audio HAL process list. No persistent storage.

**Service dependencies:** Foundation for `ProcessTapCapture` (REQ-007), which uses pids from this catalog to build `CATapDescription`.
