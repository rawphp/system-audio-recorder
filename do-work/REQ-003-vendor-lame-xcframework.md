# REQ-003: Build and vendor libmp3lame as a static xcframework

**UR:** UR-001
**Status:** backlog
**Created:** 2026-05-09
**Layer:** supporting

## Task

Build `libmp3lame` (lame-3.100) as a static library universal (arm64 + x86_64) for macOS, package it as `lame.xcframework`, and check it into the repo at `Vendor/lame.xcframework/`. Link it into the app target. Include build instructions in `Vendor/README.md` so the framework can be reproduced.

## Context

macOS does not ship an MP3 encoder. Spec Section 3 mandates LAME be vendored as a static `.xcframework` (universal, checked-in, not fetched at build time) so notarization is reproducible. Spec confirms LGPL allows static linking with attribution.

## Acceptance Criteria

- [ ] `Vendor/lame.xcframework/` exists and contains both `macos-arm64` and `macos-x86_64` static libraries
- [ ] `Vendor/README.md` documents the lame-3.100 source URL, configure flags, and exact commands used to build the xcframework
- [ ] App target links `lame.xcframework`
- [ ] A trivial Swift test calling `lame_get_version()` returns a non-empty string
- [ ] `Vendor/lame.xcframework/` is checked into git (NOT gitignored)
- [ ] LICENSE notice for LAME (LGPL) is included in `Vendor/LICENSE-LAME.txt`

## Verification Steps

1. **build** `xcodebuild -project SystemAudioToMP3.xcodeproj -scheme SystemAudioToMP3 build`
   - Expected: BUILD SUCCEEDED on both Apple Silicon and Intel
2. **test** Run a unit test that bridges to LAME and asserts `lame_get_version()` returns "3.100" (or compatible)
   - Expected: test passes on both architectures

## Integration

**Reachability:** Consumed by `AudioEngine/Encoding/LameEncoder.swift` (REQ-017). Not user-facing.

**Data dependencies:** None — the xcframework is a static library.

**Service dependencies:** None at this stage.
