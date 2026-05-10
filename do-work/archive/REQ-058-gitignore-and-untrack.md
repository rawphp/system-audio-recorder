# REQ-058: Add .gitignore and untrack files that shouldn't be in repo

**UR:** UR-009
**Status:** done
**Created:** 2026-05-10
**Layer:** none

## Task

Create a `.gitignore` at the repo root covering Xcode artefacts, build output, signing materials, and tooling. In the same commit, untrack files that are currently committed but should not be (`xcuserstate`, the xcodegen-generated `.xcodeproj/`).

## Context

This is the first step of UR-009 (open-source release prep). Today there is no `.gitignore` and one user-specific Xcode file (`UserInterfaceState.xcuserstate`) is committed. The `.xcodeproj/` is also committed, but `project.yml` + xcodegen is the source of truth — keeping the generated project under version control causes recurring `project.pbxproj` conflicts.

`do-work/` is **kept tracked** despite the original recommendation: the do-work workflow commits UR/REQ files as it runs, and gitignoring the folder would silently break that. `do-work/` is acceptable to publish — it shows engineering process.

`.claude/` is currently untracked; this REQ adds it to `.gitignore` so it stays untracked across machines.

## Acceptance Criteria

- [x] `.gitignore` exists at the repo root and is committed
- [x] `.gitignore` covers: `.DS_Store`, `xcuserdata/`, `*.xcuserstate`, `build/`, `DerivedData/`, `SystemAudioRecorder.xcodeproj/`, `.swiftpm/`, `.build/`, `dist/`, `*.dmg`, `*.app` (in repo root, not anywhere), `*.zip`, signing artefacts (`*.p12`, `*.cer`, `*.mobileprovision`, `ExportOptions.plist`), `.env`, `.env.*`, `.claude/`
- [x] `do-work/` is **not** in `.gitignore` (must remain tracked for the workflow)
- [x] `git ls-files | grep xcuserstate` returns nothing after the commit
- [x] `git ls-files SystemAudioRecorder.xcodeproj/` returns nothing after the commit
- [x] `make build` still works after the commit (xcodegen regenerates the project from `project.yml`)
- [x] `git status` is clean after `make build` (the regenerated project is correctly ignored)

## Verification Steps

> Execute these after implementation to confirm the feature actually works at runtime. Each must pass before committing.

1. **runtime** `git ls-files | grep -E '(xcuserstate|SystemAudioRecorder\.xcodeproj/)'`
   - Expected: no output (both are no longer tracked)
2. **runtime** `rm -rf SystemAudioRecorder.xcodeproj && make build`
   - Expected: build succeeds; xcodegen recreates the project; build artefacts produced
3. **runtime** `git status --porcelain`
   - Expected: empty output (regenerated `.xcodeproj/`, `build/`, `.swiftpm/` etc. are all ignored)
4. **runtime** `git ls-files do-work/ | head -1`
   - Expected: at least one line (do-work/ remains tracked)

## Outputs

- `.gitignore` — repo .gitignore covering Xcode/build/signing/tooling; `do-work/` excluded (remains tracked)
