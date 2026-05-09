# REQ-040: Manual test plan markdown

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** none

## Task

Write `docs/manual-tests.md` covering the third test layer per spec Section 7. Each item is a checkbox with explicit steps + expected outcome:
- Real Core Audio Tap against Spotify (5 min recording)
- Real Core Audio Tap against Safari (YouTube tab, 5 min)
- Mic capture with built-in mic, then external USB mic
- First-launch permission prompts: mic, audio-tap
- Permission denial paths: deny mic in System Settings, observe UX (REQ-034 acceptance)
- Sample rate drift: switch tracks at different rates mid-recording, verify continuous output
- Target app quits mid-recording: kill Spotify mid-recording, verify warning banner + recording continues
- Long recording stress test: 60-minute Everything+Mic recording, verify no leaks via Activity Monitor
- Notarized DMG install: download fresh DMG, install, run, verify no Gatekeeper warnings (post-REQ-042)

The file is gated by a release checklist; CI runs only the unit + integration layers.

## Context

Spec Section 7 mandates the manual test plan as part of the release readiness checklist.

## Acceptance Criteria

- [x] `docs/manual-tests.md` exists with all listed scenarios as checklist items
- [x] Each item has explicit setup steps and pass/fail criteria
- [x] File is referenced from `README.md` (REQ created later if README work is added)

## Verification Steps

1. **runtime** Read the file end-to-end as if executing the plan; confirm each step is unambiguous
   - Expected: no "TBD" or "figure out" instructions

## Integration

This REQ is `**Layer:** none` (documentation), so the Integration block is omitted.

## Outputs

- `docs/manual-tests.md` — manual test plan with 9 MT-001…MT-009 scenarios, each with setup, steps, and pass/fail criteria.
- `README.md` — minimal project README with build/test instructions and links to spec and manual test plan.
