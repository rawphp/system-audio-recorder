# Ideate — UR-012

**Reviewed:** 2026-05-11

## Explorer — Assumptions & Perspectives

- The brief assumes "Google Chrome" is one selectable thing, but Chromium runs a multi-process model where audio is emitted by a helper (`Google Chrome Helper (Renderer/Plugin/GPU)`), not the browser parent. The picker exposes both pids; the parent's pid never emits audio. The user-facing "Google Chrome" label in the picker therefore points at the wrong pid for capture. Triggered by the picker label "Google Chrome" in the first screenshot vs. "helper" in the second.
- The brief reads ambiguously ("It doesn't record when it's marked 'record from everywhere'. It works.") but the follow-up clarifies the actual state: `.everything` mode works, `.specificApp(chrome_parent_pid)` does not, `.specificApp(chrome_helper_pid)` does. The bug is scoped to Specific App + Chromium-family apps, not to Everything mode.
- The brief assumes one app = one pid. This holds for native apps (Safari, Music, Spotify) but breaks for Chromium-based browsers, Electron apps (Slack, VS Code, Discord, Cursor, Notion), and any plugin-host architecture. Every Electron app the user might want to record will hit this same bug.

## Challenger — Risks & Edge Cases

- "Pick all helpers belonging to bundle X" is not enough — Chrome can spawn many helper pids; some are GPU-only (no audio), some are renderers for tabs that are currently silent. Tapping all of them is closer to `.everything`-mode behaviour scoped to one app. Acceptable, but raises permission and resource cost. Triggered by "selecting 'helper' it records from Chrome" — that helper was the *audio* helper; others won't be.
- The catalog currently lists each helper pid as a separate row labeled `helper` (no parent app association, no icon — see screenshot 2). Two failure modes: (a) the user can't tell which `helper` belongs to Chrome vs. Slack vs. VS Code, and (b) deduping helpers under their parent label changes the picker's stable-identity contract — the `SpecificApp:<pid>` settingsKey persists a transient pid that won't survive a relaunch of the target app. AppStore.from(settingsKey:) at AppStore.swift:31 already implicitly handles this by falling back to `.everything`, but that's silent data loss.
- "Tap all helpers of bundle X" must reconcile with the live aliveness check in ProcessTapCapture (kill(pid, 0) at line 167). When Chrome spawns a new helper after recording starts (new tab plays audio), it won't be tapped — the session's pid set is fixed at start. Triggered by ProcessTapCapture taking a static `pids:` list in init.

## Connector — Links & Reuse

- REQ-044 ("catalog-include-helper-pids") already changed the catalog to surface helper pids — see the bundleID fallback at AudioSourceCatalog.swift:176-178 explicitly preserving Chromium renderer helpers. That REQ solved half the problem (helpers are now *visible*); this UR is the second half (helpers must be *usable as a group* and labeled in a way the user understands).
- The `displayName` fallback chain (AudioSourceCatalog.swift:186-190) already has the hook point: when `NSRunningApplication.localizedName` is nil for a helper, today it falls through to HAL exec name → bundle ID tail → "Process \<pid\>". For Chromium helpers the bundle ID is something like `com.google.Chrome.helper` — we could detect the `.helper`/`.helper.*` suffix and prepend the parent bundle's localizedName ("Google Chrome Helper (Renderer)"), and/or group all `com.google.Chrome*` pids under one picker entry.
- The `.specificApp(processID:)` case in DefaultSessionConfigBuilder (AppStore.swift:131-141) only ever taps a single pid. The `.everything` case (lines 102-129) already shows the multi-pid path is fully supported by ProcessTapCapture and SessionConfig. The fix can largely reuse the `.everything` shape, just filtered to one bundle's pids.

## Summary

This is a UX-meets-architecture bug specific to multi-process apps (Chromium browsers, Electron apps): the source picker surfaces both the parent pid and helper pids, but only the helpers actually emit audio. The user picks the obvious "Google Chrome" entry and gets silence. The two-part fix is (1) the picker should present one entry per app bundle (grouping the parent + its helpers) with a clear label, and (2) selecting that entry should tap every audio-relevant pid in the group — effectively `.specificApp(bundleID:)` rather than `.specificApp(pid:)`. Decide before decomposition: do we change the public `SourcePreset` shape (bundle-scoped) or keep pid-scoped and dedupe at the picker layer only?
