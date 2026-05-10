# REQ-059: Add MIT LICENSE file

**UR:** UR-009
**Status:** backlog
**Created:** 2026-05-10
**Layer:** none

## Task

Add an MIT-licensed `LICENSE` file at the repo root, with copyright assigned to Tom Kaczocha for the current year.

## Context

For the project to be legally redistributable as a free download, it needs an explicit licence — without one, no one has the right to use, modify, or share the source. MIT is the standard permissive choice for this kind of small utility.

Note: LAME (the bundled MP3 encoder in `Vendor/lame.xcframework`) is LGPL-licensed. That is unaffected by this REQ — `Vendor/LICENSE-LAME.txt` and `Vendor/LICENSE-LAME-additional.txt` already cover it correctly. The repo-level `LICENSE` only governs the project's own source.

## Acceptance Criteria

- [ ] `LICENSE` exists at the repo root and is committed
- [ ] File contains the standard MIT licence text
- [ ] Copyright line reads: `Copyright (c) 2026 Tom Kaczocha`
- [ ] GitHub recognises the licence on the repo page (will show "MIT" in the sidebar after push)
- [ ] No changes are made to LAME's existing licence files in `Vendor/`

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **runtime** `head -3 LICENSE`
   - Expected: lines containing `MIT License`, blank, `Copyright (c) 2026 Tom Kaczocha`
2. **runtime** `grep -c 'Permission is hereby granted, free of charge' LICENSE`
   - Expected: `1`
3. **runtime** `ls Vendor/LICENSE-LAME.txt Vendor/LICENSE-LAME-additional.txt`
   - Expected: both files still present and unchanged (vendor licences untouched)
